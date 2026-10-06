// sync_service.dart — offline-first cloud sync engine (local SQLite ↔ backend).
//
// Bidirectional bridge between the on-device SQLite store and the REST backend.
// Upload: syncMeals() POSTs each unsynced meal, marks it synced with the server
// id, then uploads that meal's bites — batching a single "Data Synced" alert,
// backing off on HTTP 429, and never blocking the UI. Download/restore:
// autoRestoreOnLoginIfNeeded() and the CloudSyncResult-returning restore path
// pull cloud data after reinstall/new-login using last-write-wins merge.
// Helpers: hasUnsyncedData(), isConnected(), and syncIfNeeded() which runs only
// when pending data AND connectivity exist. All HTTP goes through ResilientHttp.
import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../services/database_service.dart';
import '../models/meal.dart';
import '../models/bite.dart';
import '../models/cloud_sync_result.dart';
import '../../features/auth/domain/services/auth_service.dart';
import '../../features/notifications/domain/services/notification_service.dart';
import '../config/app_config.dart';
import 'resilient_http.dart';
import 'sync_restore_policy.dart';

class SyncService {
  final DatabaseService _db = DatabaseService();
  final String _baseUrl = AppConfig.apiBaseUrl;

  /// Maximum age of data that participates in cloud sync. Meals older than this
  /// are neither uploaded, counted as pending, nor pulled back on restore —
  /// they remain readable locally but are outside the sync window. Both the
  /// push and restore paths use the SAME cutoff so the two directions agree.
  static const Duration syncWindow = Duration(days: 90); // last 3 months

  /// Start of the sync window (now − [syncWindow]).
  DateTime get _syncCutoff => DateTime.now().subtract(syncWindow);

  /// True once an automatic restore-on-login attempt has run this process
  /// lifetime — prevents re-checking/re-downloading every time the home
  /// screen is rebuilt (it's only meant to fire once per fresh session).
  static final Set<String> _autoRestoreAttemptedUserIds = <String>{};

  /// Static (cross-instance) guard so overlapping triggers — startup, resume,
  /// scheduled background sync, session-end — don't run the push concurrently.
  static bool _pushInProgress = false;

  /// Exposed so logout can wait for an in-flight push before clearing the
  /// local DB (clearing mid-push interleaves deletes with is_synced writes).
  static bool get isPushInProgress => _pushInProgress;

  /// All SyncService instances share one cloud restore. Home, Insights, and a
  /// manual button can otherwise start the same 200-meal download together,
  /// multiplying requests until the backend correctly rate-limits the phone.
  static final Map<String, Future<CloudSyncResult>> _restoreInFlight =
      <String, Future<CloudSyncResult>>{};

  /// True while ANY restore is running for ANY user — used to keep push and
  /// restore mutually exclusive (see the note above `restoreFromCloud`).
  static bool get _restoreInProgress => _restoreInFlight.isNotEmpty;

  /// Build standard auth headers for API calls.
  /// Tunnel bypass headers are only added in debug mode targeting a tunnel URL.
  Map<String, String> _authHeaders(String token) {
    return <String, String>{
      'Authorization': 'Bearer $token',
      'Content-Type': 'application/json',
      ...ResilientHttp.tunnelBypassHeaders(),
    };
  }

  // GET/POST with retry on stale-TLS HandshakeException — shared with
  // AuthService via ResilientHttp so the retry policy can't diverge.
  Future<http.Response> _get(Uri uri, {required Map<String, String> headers}) =>
      ResilientHttp.get(uri, headers: headers);

  Future<http.Response> _post(
    Uri uri, {
    required Map<String, String> headers,
    Object? body,
  }) => ResilientHttp.post(uri, headers: headers, body: body);

  Future<void> syncAll() async {
    if (kDebugMode) print('Starting sync...');
    await syncMeals();
  }

  Future<void> syncMeals() async {
    // Skip entirely if backend URL is not configured
    if (!AppConfig.isBackendConfigured) return;

    // Let the first caller own the push; a concurrent trigger is a no-op.
    if (_pushInProgress) {
      if (kDebugMode) print('[Sync] push already running — skipping duplicate');
      return;
    }
    // H5: push and restore are NOT mutually exclusive at the SQLite layer —
    // _mergeRemoteMeal reads a meal row, decides whether to overwrite it, and
    // writes the decision several awaits later. A push landing in that window
    // writes fresh local data (e.g. the live bite count mid-meal) that the
    // restore's already-stale in-memory read then clobbers on its own write,
    // with no compare-and-set to catch it (unlike markMealSynced's, see C2).
    // Serializing the two closes the window. Push just retries next cycle —
    // it is triggered periodically (app_setup_service, every 5 min) — so
    // skipping here costs nothing a restore-in-progress isn't already doing.
    if (_restoreInProgress) {
      if (kDebugMode) {
        print('[Sync] restore in progress — skipping push this cycle');
      }
      return;
    }
    _pushInProgress = true;
    try {
      await _pushUnsyncedData();
    } finally {
      _pushInProgress = false;
    }
  }

  Future<void> _pushUnsyncedData() async {
    final currentUserId = FirebaseAuth.instance.currentUser?.uid;
    if (currentUserId == null || currentUserId.isEmpty) {
      if (kDebugMode) print('[Sync] push skipped: no Firebase user');
      return;
    }

    final cutoff = _syncCutoff;
    final unsyncedMeals = await _db.getUnsyncedMeals(
      userId: currentUserId,
      since: cutoff,
    );
    // Also handle bites orphaned by an earlier partial failure — their meal is
    // already synced, so it won't appear in getUnsyncedMeals, but the bites
    // still need pushing. Without this the app stays permanently "needs sync".
    final orphanedBiteMealUuids = await _db.getSyncedMealUuidsWithUnsyncedBites(
      userId: currentUserId,
      since: cutoff,
    );

    if (unsyncedMeals.isEmpty && orphanedBiteMealUuids.isEmpty) return;

    final token = await _ensureToken();
    if (token == null) return;

    int syncedCount = 0;

    for (var meal in unsyncedMeals) {
      try {
        String formattedMealType = meal.mealType ?? 'Snack';
        if (formattedMealType.toLowerCase().startsWith('snack')) {
          formattedMealType = 'Snack';
        } else if (formattedMealType.isNotEmpty) {
          formattedMealType =
              '${formattedMealType[0].toUpperCase()}${formattedMealType.substring(1).toLowerCase()}';
        } else {
          formattedMealType = 'Snack';
        }

        // Send only the fields the backend expects — exclude SQLite-specific columns
        final encodedBody = await compute(jsonEncode, {
          'uuid': meal.uuid,
          'device_id': meal.deviceId,
          // Stable per-spoon (per-person) key — carried so per-spoon attribution
          // survives a cross-device restore (e.g. a new phone).
          'spoon_key': meal.spoonKey,
          'started_at': meal.startedAt.toUtc().toIso8601String(),
          'ended_at': meal.endedAt?.toUtc().toIso8601String(),
          'local_date': meal.startedAt.toLocal().toIso8601String().substring(
            0,
            10,
          ),
          'meal_type': formattedMealType,
          'total_bites': meal.totalBites,
          'avg_pace_bpm': meal.avgPaceBpm,
          'tremor_index': meal.tremorIndex,
          'duration_minutes': meal.durationMinutes,
          'avg_food_temp_c': meal.avgFoodTemp,
          // Whole-meal movement figures (backend migration 021). Held locally
          // since schema v16 but dropped on sync until the columns existed, so
          // a restore on a new phone silently lost every steadiness reading.
          'steady_pct': meal.steadyPct,
          'rhythm_hz': meal.rhythmHz,
          'measured_seconds': meal.measuredSeconds,
          'movement_source': meal.movementSource,
        });

        final response = await _post(
          Uri.parse('$_baseUrl/meals'),
          headers: _authHeaders(token),
          body: encodedBody,
        );

        if (response.statusCode == 201 || response.statusCode == 200) {
          // Guard the parse: an unexpected response shape here used to throw
          // an unguarded `[...]['id']` deref straight into the generic catch
          // below. Because the server had ALREADY committed the row (2xx),
          // the meal stayed unsynced locally and got silently re-POSTed on
          // every future sync cycle forever — same uuid, same outcome, no
          // visible error beyond a generic "Error syncing meal" debug line
          // indistinguishable from a genuine network failure.
          dynamic responseData;
          try {
            responseData = await compute(jsonDecode, response.body);
          } on FormatException catch (e) {
            if (kDebugMode) {
              print(
                'Meal ${meal.uuid}: server returned ${response.statusCode} '
                'with a non-JSON body ($e) — will retry next cycle.',
              );
            }
            continue;
          }
          final mealJson = responseData is Map
              ? (responseData['data'] is Map
                    ? responseData['data']['meal']
                    : responseData['meal'])
              : null;
          final serverId = mealJson is Map ? mealJson['id'] : null;
          if (serverId == null) {
            // Row is committed server-side but we can't read its id back.
            // Leaving is_synced=0 is safe to retry — the meal upsert is
            // idempotent on uuid (see H3) — but this is a genuine shape
            // mismatch, not ordinary "not synced yet", so it gets its own
            // diagnostic instead of blending into the network-failure log.
            if (kDebugMode) {
              print(
                'Meal ${meal.uuid}: ${response.statusCode} response had no '
                'parsable meal.id — will retry next cycle. '
                'Body: ${response.body}',
              );
            }
            continue;
          }

          // Compare-and-set against the values we actually uploaded. If the
          // user finished the meal while this request was in flight, the row
          // now differs and must stay unsynced so the next cycle sends the
          // final bite count and ended_at.
          final applied = await _db.markMealSynced(
            meal.uuid,
            serverId,
            expectedTotalBites: meal.totalBites,
            expectedEndedAt: meal.endedAt?.toIso8601String(),
          );

          if (kDebugMode) {
            print(
              applied
                  ? 'Synced meal ${meal.uuid}'
                  : 'Meal ${meal.uuid} changed mid-sync — will re-upload',
            );
          }

          // Sync bites for this meal now that the meal exists on the server
          final bitesCompleted = await syncBitesForMeal(
            meal.uuid,
            token,
            userId: currentUserId,
          );
          if (bitesCompleted) syncedCount++;
        } else if (response.statusCode == 429) {
          if (kDebugMode) print('Rate limited by server. Pausing sync.');
          break; // Stop the loop, don't spam the server
        } else {
          if (kDebugMode) {
            print('Failed to sync meal ${meal.uuid}: ${response.body}');
          }
        }
      } catch (e) {
        if (kDebugMode) print('Error syncing meal ${meal.uuid}: $e');
      }
    }

    // Retry bites stranded by a prior partial failure (meal synced, bites
    // didn't). These meals aren't in unsyncedMeals, so their bites are only
    // reachable here. syncBitesForMeal + backend upsert are idempotent.
    for (final uuid in orphanedBiteMealUuids) {
      await syncBitesForMeal(uuid, token, userId: currentUserId);
    }

    // Show ONE notification after the entire batch, not one per meal.
    if (syncedCount > 0) {
      final body = syncedCount == 1
          ? 'Your eating analysis has been securely synced to the cloud.'
          : '$syncedCount meals synced to the cloud.';
      NotificationService().showLocalAlert(
        title: 'Data Synced',
        body: body,
        type: 'system_alerts',
      );
    }
  }

  Future<bool> syncBitesForMeal(
    String mealUuid,
    String token, {
    required String userId,
  }) async {
    // Fetch all unsynced bites for this specific meal (no global limit)
    final mealBites = await _db.getUnsyncedBitesForMeal(
      mealUuid,
      userId: userId,
    );

    if (mealBites.isEmpty) return true;

    try {
      const maxBitesPerRequest = 500;
      for (
        var start = 0;
        start < mealBites.length;
        start += maxBitesPerRequest
      ) {
        final chunk = mealBites
            .skip(start)
            .take(maxBitesPerRequest)
            .where((b) => b.sequenceNumber != null)
            .toList();
        if (chunk.isEmpty) continue;

        final encodedBody = await compute(jsonEncode, {
          'bites': chunk
              .map(
                (b) => {
                  'sequence_number': b.sequenceNumber,
                  'timestamp': b.timestamp.toUtc().toIso8601String(),
                  'tremor_magnitude': b.tremorMagnitude,
                  'tremor_frequency': b.tremorFrequency,
                  'tremor_confidence': b.tremorConfidence,
                  'tremor_window_ms': b.tremorWindowMs,
                  'steady_pct': b.steadyPct,
                  'food_temp_c': b.foodTempC,
                  'is_valid': b.isValid,
                },
              )
              .toList(),
        });

        final response = await _post(
          Uri.parse('$_baseUrl/meals/$mealUuid/bites'),
          headers: _authHeaders(token),
          body: encodedBody,
        );

        if (response.statusCode == 201 || response.statusCode == 200) {
          final ids = chunk
              .where((b) => b.id != null)
              .map((b) => b.id!)
              .toList();
          await _db.markBitesSynced(ids);
          if (kDebugMode) {
            print('Synced ${ids.length} bites for meal $mealUuid');
          }
        } else {
          if (kDebugMode) {
            print('Failed to sync bites for meal $mealUuid: ${response.body}');
          }
          return false;
        }
      }
      return true;
    } catch (e) {
      if (kDebugMode) print('Error syncing bites: $e');
      return false;
    }
  }

  // Temperature logs deprecated — stats stored in meal object (avgFoodTemp)
  Future<void> syncTemperaturesForMeal(
    String mealUuid,
    int serverMealId,
    String token,
  ) async {}

  // ==========================================================================
  // RESTORE (download / pull from cloud)
  // ==========================================================================
  //
  // Mirrors the upload path above, but in reverse: pulls meals + bites the
  // user already synced to the backend and writes them into local SQLite.
  // This is what makes a reinstall / new-device login non-destructive.

  /// Number of meals fetched per page from GET /api/meals.
  /// Server clamps `limit` to 100 (see mealModel.getUserMeals), so this is
  /// comfortably within that ceiling.
  static const int _restorePageSize = 100;

  /// Pulls the user's full meal + bite history from the backend and merges it
  /// into the local SQLite database. Safe to call repeatedly — every write is
  /// either an "insert if missing" or a conflict-aware upsert keyed by UUID,
  /// so this never duplicates rows and never clobbers newer local data with
  /// stale server data.
  ///
  /// Returns the number of meals restored (newly inserted or updated locally).
  /// Throws nothing — all failures are caught, logged, and surfaced via the
  /// return value being null, so callers can show an error without the app
  /// ever crashing because the restore path failed.
  /// Returns a valid backend JWT, re-authenticating via Firebase if no token
  /// is stored. This handles the case where the app has a Firebase session but
  /// the backend JWT was never written (e.g., previous login hit a bad URL).
  Future<String?> _ensureToken() async {
    final firebaseUser = FirebaseAuth.instance.currentUser;
    if (firebaseUser == null) return null;

    final boundFirebaseUid = await AuthService.getBoundFirebaseUid();
    if (boundFirebaseUid != firebaseUser.uid) {
      // A token without an exact owner binding is unsafe on shared devices.
      await AuthService.clearLocalTokens();
    }

    String? token = await AuthService.getValidToken();
    if (token != null) return token;

    try {
      if (kDebugMode) {
        print('[Sync] No JWT stored — re-authenticating via Firebase...');
      }
      final idToken = await firebaseUser.getIdToken(true);
      if (idToken == null) return null;
      await AuthService.verifyFirebaseToken(idToken: idToken);
      token = await AuthService.getValidToken();
    } catch (e) {
      if (kDebugMode) print('[Sync] Firebase re-auth failed: $e');
    }
    return token;
  }

  Future<CloudSyncResult> restoreFromCloud({
    String? userId,
    bool skipLegacyRepair = false,
  }) async {
    final firebaseUid = FirebaseAuth.instance.currentUser?.uid;
    if (userId != null && userId != firebaseUid) {
      return const CloudSyncResult(status: CloudSyncStatus.accountUnavailable);
    }

    final operationKey = firebaseUid ?? '<signed-out>';
    final pending = _restoreInFlight[operationKey];
    if (pending != null) {
      if (kDebugMode) print('[Sync] Joining cloud restore already in progress');
      return pending;
    }

    // H5: mirror of the push-side check in syncMeals(). Don't start a restore
    // while a push is mid-flight — same bounded-wait idiom as
    // AuthService._clearLocalUserData uses before clearing the DB. Once this
    // returns, _restoreInFlight is populated for the remainder of the restore,
    // which is what makes syncMeals()'s own check hold push off in return.
    var waitedMs = 0;
    while (_pushInProgress && waitedMs < 5000) {
      await Future.delayed(const Duration(milliseconds: 100));
      waitedMs += 100;
    }
    if (_pushInProgress) {
      return const CloudSyncResult(
        status: CloudSyncStatus.interrupted,
        detail: 'Restore skipped because a push is still in progress',
      );
    }

    final operation = _restoreFromCloudOnce(
      userId: firebaseUid,
      skipLegacyRepair: skipLegacyRepair,
    );
    _restoreInFlight[operationKey] = operation;
    try {
      return await operation;
    } finally {
      if (identical(_restoreInFlight[operationKey], operation)) {
        _restoreInFlight.remove(operationKey);
      }
    }
  }

  Future<CloudSyncResult> _restoreFromCloudOnce({
    String? userId,
    bool skipLegacyRepair = false,
  }) async {
    if (!AppConfig.isBackendConfigured) {
      return const CloudSyncResult(status: CloudSyncStatus.notConfigured);
    }

    // Firebase UID is the canonical local user_id — all SQLite queries use it.
    // Backend numeric ID (from JWT) is for API calls only, never stored locally.
    final resolvedUserId = FirebaseAuth.instance.currentUser?.uid;
    if (resolvedUserId == null) {
      if (kDebugMode) print('Restore skipped: no user id available');
      return const CloudSyncResult(status: CloudSyncStatus.unauthenticated);
    }
    if (userId != null && userId != resolvedUserId) {
      return const CloudSyncResult(status: CloudSyncStatus.accountUnavailable);
    }

    final token = await _ensureToken();
    if (token == null) {
      if (kDebugMode) print('Restore skipped: not authenticated');
      return const CloudSyncResult(status: CloudSyncStatus.unauthenticated);
    }

    // Repair only safe placeholder ids so they become visible to Firebase UID
    // queries before we count what's already synced. Skipped when the caller
    // already ran the same repair this flow.
    int repairedCount = 0;
    if (!skipLegacyRepair) {
      repairedCount = await _db.repairLegacyUserIdTags(resolvedUserId);
      if (kDebugMode && repairedCount > 0) {
        print(
          '[Sync] restoreFromCloud: re-tagged $repairedCount meal(s) to Firebase UID',
        );
      }
    }

    var scannedMeals = 0;
    var changedMeals = 0;
    var insertedBites = 0;
    var localChangesKept = 0;
    var skippedRecords = 0;
    final remoteMealUuids = <String>{};
    // Only restore the last 3 months (same window as the push path).
    final cutoff = _syncCutoff;

    try {
      int offset = 0;
      String? beforeStartedAt;
      int? beforeId;
      while (true) {
        _assertCurrentUser(resolvedUserId);
        final pageMeals = await _fetchMealsPage(
          token: token,
          limit: _restorePageSize,
          offset: beforeStartedAt == null ? offset : 0,
          beforeStartedAt: beforeStartedAt,
          beforeId: beforeId,
        );

        if (pageMeals.isEmpty) break;

        // Merge meal rows first (local SQLite writes — fast, sequential).
        final bitesToFetch = <String>[];
        var reachedCutoff = false;
        for (final remoteMeal in pageMeals) {
          _assertCurrentUser(resolvedUserId);
          // 3-month sync window: meals are sorted started_at DESC, so the first
          // one older than the cutoff means every remaining meal (this page and
          // all later pages) is older too — skip it and stop paginating.
          final mealStartedAt = _parseDate(remoteMeal['started_at']);
          if (mealStartedAt != null && mealStartedAt.isBefore(cutoff)) {
            reachedCutoff = true;
            break;
          }
          scannedMeals++;
          try {
            final mealMerge = await _mergeRemoteMeal(
              remoteMeal,
              resolvedUserId,
            );
            switch (mealMerge) {
              case _MealMerge.inserted:
              case _MealMerge.updated:
                changedMeals++;
              case _MealMerge.identical:
                break;
              case _MealMerge.localKept:
                localChangesKept++;
              case _MealMerge.invalid:
                skippedRecords++;
            }

            final uuid = remoteMeal['uuid'] as String?;
            if (uuid != null && uuid.isNotEmpty) {
              remoteMealUuids.add(uuid);
              final embeddedBites = remoteMeal['bites'];
              final needsDedicatedFetch = mealNeedsDedicatedBiteFetch(
                embeddedBites,
                totalBites: _jsonInt(remoteMeal['total_bites']),
              );
              if (!needsDedicatedFetch && embeddedBites is List) {
                final biteMerge = await _mergeEmbeddedBites(
                  uuid,
                  embeddedBites,
                  expectedUserId: resolvedUserId,
                );
                insertedBites += biteMerge.inserted;
                localChangesKept += biteMerge.localKept;
                skippedRecords += biteMerge.skipped;
              } else {
                bitesToFetch.add(uuid);
              }
            }
          } catch (e) {
            // A session change is not a per-meal failure — it invalidates
            // everything already scanned under the old user, so it must abort
            // the whole restore rather than being counted as one skipped meal.
            if (e is _SyncSessionChangedException) rethrow;
            // One bad meal shouldn't abort the whole restore — log, COUNT, and
            // continue. Previously this was silently dropped: a restore that
            // failed on 30 meals reported skippedRecords=0, which routes the
            // status straight to `upToDate` — the caller believes everything
            // is current when 30 meals were actually never restored.
            skippedRecords++;
            if (kDebugMode) {
              print('Error restoring meal ${remoteMeal['uuid']}: $e');
            }
          }
        }

        // Fetch bites with bounded parallelism instead of one serial HTTP
        // round-trip per meal — a 300-meal history was 300 sequential GETs.
        //
        // _restoreBitesForMeal DOES throw (see its catch-log-rethrow) — the
        // comment that used to be here claiming otherwise was wrong. Left
        // unguarded, one meal hitting an HTTP 500 rejected this Future.wait,
        // which propagated to the outer catch and aborted every remaining
        // page of the restore — not just that one meal. Each call is now
        // caught individually and turned into a skipped-record outcome, so a
        // single bad meal costs one meal, not the rest of the restore. A
        // session change is the one exception that still must abort
        // everything, so it is rethrown rather than swallowed.
        const bitesConcurrency = 6;
        for (var i = 0; i < bitesToFetch.length; i += bitesConcurrency) {
          _assertCurrentUser(resolvedUserId);
          final outcomes = await Future.wait(
            bitesToFetch
                .skip(i)
                .take(bitesConcurrency)
                .map(
                  (uuid) =>
                      _restoreBitesForMeal(
                        uuid,
                        token,
                        expectedUserId: resolvedUserId,
                      ).catchError((Object e) {
                        if (e is _SyncSessionChangedException) throw e;
                        if (kDebugMode) {
                          print('Skipping bites for $uuid after failure: $e');
                        }
                        return const _BiteMergeResult(skipped: 1);
                      }),
                ),
          );
          for (final outcome in outcomes) {
            insertedBites += outcome.inserted;
            localChangesKept += outcome.localKept;
            skippedRecords += outcome.skipped;
          }
        }

        // Hit the 3-month cutoff on this page → older data follows, stop here.
        if (reachedCutoff) break;

        // Server doesn't return a total count, so we detect the last page by
        // a short page (fewer rows than requested) rather than truncating to
        // page 1 or looping forever.
        if (pageMeals.length < _restorePageSize) break;

        final lastMeal = pageMeals.last;
        beforeStartedAt = lastMeal['started_at'] as String?;
        beforeId = _jsonInt(lastMeal['id']);
        if (beforeStartedAt == null || beforeId == null) {
          offset += _restorePageSize;
        }
      }

      _assertCurrentUser(resolvedUserId);
      final localMeals = await _db.getMeals(
        userId: resolvedUserId,
        limit: 1000000,
      );
      // Only count IN-WINDOW local meals as "pending upload". Meals older than
      // the 3-month cutoff are intentionally never synced, so counting them here
      // would falsely report "local changes pending" and never clear.
      localChangesKept += localMeals
          .where(
            (meal) =>
                !meal.startedAt.isBefore(cutoff) &&
                !remoteMealUuids.contains(meal.uuid),
          )
          .length;

      final status = skippedRecords > 0
          ? CloudSyncStatus.partial
          : changedMeals > 0 || insertedBites > 0 || repairedCount > 0
          ? CloudSyncStatus.updated
          : localChangesKept > 0
          ? CloudSyncStatus.localChangesPending
          : CloudSyncStatus.upToDate;
      final result = CloudSyncResult(
        status: status,
        scannedMeals: scannedMeals,
        changedMeals: changedMeals,
        insertedBites: insertedBites,
        localChangesKept: localChangesKept,
        skippedRecords: skippedRecords,
        repairedMeals: repairedCount,
      );
      if (kDebugMode) {
        print(
          'Restore complete: ${result.status.name}; '
          '$changedMeals meal(s), $insertedBites bite(s) changed',
        );
      }
      return result;
    } catch (e) {
      if (kDebugMode) print('Restore from cloud failed: $e');
      if (scannedMeals > 0 || changedMeals > 0 || insertedBites > 0) {
        return CloudSyncResult(
          status: CloudSyncStatus.partial,
          scannedMeals: scannedMeals,
          changedMeals: changedMeals,
          insertedBites: insertedBites,
          localChangesKept: localChangesKept,
          skippedRecords: skippedRecords + 1,
          repairedMeals: repairedCount,
          detail: e.toString(),
        );
      }
      return _resultForRestoreFailure(e);
    }
  }

  /// Fetch a single page of GET /api/meals. Returns an empty list on a clean
  /// 200 with no data (real end-of-data). Throws on transient errors so the
  /// caller can retry or abort properly instead of silently truncating.
  Future<List<Map<String, dynamic>>> _fetchMealsPage({
    required String token,
    required int limit,
    required int offset,
    String sortBy = 'started_at',
    String? beforeStartedAt,
    int? beforeId,
    bool includeBites = true,
  }) async {
    final queryParameters = {
      'limit': '$limit',
      'offset': '$offset',
      'sort_by': sortBy,
      'include_bites': '$includeBites',
      if (beforeStartedAt != null && beforeId != null) ...{
        'before_started_at': beforeStartedAt,
        'before_id': '$beforeId',
      },
    };
    final uri = Uri.parse(
      '$_baseUrl/meals',
    ).replace(queryParameters: queryParameters);

    // Retry up to 2 times on transient failures (network hiccup, 5xx, etc.)
    const maxRetries = 2;
    int? lastServerStatus;
    for (int attempt = 0; attempt <= maxRetries; attempt++) {
      try {
        final response = await _get(uri, headers: _authHeaders(token));

        if (response.statusCode == 200) {
          final dynamic decoded;
          try {
            decoded = await compute(jsonDecode, response.body);
          } on FormatException catch (e) {
            throw _SyncInvalidResponseException(e.message);
          }
          if (decoded is! Map<String, dynamic>) {
            throw const _SyncInvalidResponseException(
              'Expected a JSON object response.',
            );
          }
          final data = decoded['data'];
          final meals = data is Map
              ? data['meals'] ?? decoded['meals']
              : decoded['meals'];
          if (meals is! List) {
            throw const _SyncInvalidResponseException(
              'Missing meals list in response.',
            );
          }
          if (meals.any((meal) => meal is! Map)) {
            throw const _SyncInvalidResponseException(
              'A meal entry was not a JSON object.',
            );
          }
          return meals
              .map((meal) => Map<String, dynamic>.from(meal as Map))
              .toList();
        }

        if (response.statusCode == 429) {
          throw _SyncHttpException(
            response.statusCode,
            retryAfter: response.headers['retry-after'],
          );
        }

        // Authentication/validation errors are failures, not an empty final
        // page. Treating them as [] falsely reported "Already up to date".
        if (response.statusCode >= 400 &&
            response.statusCode < 500 &&
            response.statusCode != 429) {
          if (kDebugMode) {
            print(
              'Failed to fetch meals page (offset=$offset): ${response.body}',
            );
          }
          throw _SyncHttpException(response.statusCode);
        }

        lastServerStatus = response.statusCode;
        // 5xx server errors — retry after a short delay.
        if (kDebugMode) {
          print(
            'Server error ${response.statusCode} fetching meals page (offset=$offset), retry ${attempt + 1}/$maxRetries',
          );
        }
        if (attempt < maxRetries) {
          await Future.delayed(Duration(milliseconds: 500 * (attempt + 1)));
        }
      } catch (e) {
        if (e is _SyncInvalidResponseException) rethrow;
        if (e is _SyncHttpException && e.statusCode < 500) rethrow;
        if (kDebugMode) {
          print(
            'Network error fetching meals page (offset=$offset): $e, retry ${attempt + 1}/$maxRetries',
          );
        }
        if (attempt < maxRetries) {
          await Future.delayed(Duration(milliseconds: 500 * (attempt + 1)));
        } else {
          // All retries exhausted — rethrow so restoreFromCloud catches it
          // and returns null (partial restore) instead of silently truncating
          rethrow;
        }
      }
    }
    // Persistent 429/5xx after all retries — throw so restoreFromCloud
    // reports failure instead of treating it as a clean end-of-data page.
    if (lastServerStatus != null) {
      throw _SyncHttpException(lastServerStatus);
    }
    throw const _SyncTransportException();
  }

  Future<_BiteMergeResult> _mergeEmbeddedBites(
    String mealUuid,
    List<dynamic> remoteBites, {
    required String expectedUserId,
  }) async {
    _assertCurrentUser(expectedUserId);
    final localBites = await _db.getBitesForMeal(mealUuid);
    final existingByKey = <String, Bite>{
      for (final bite in localBites) _biteKey(bite): bite,
    };
    final remoteKeys = <String>{};

    final toInsert = <Bite>[];
    var localKept = 0;
    var skipped = 0;
    for (final value in remoteBites) {
      if (value is! Map) {
        skipped++;
        continue;
      }
      final remote = Map<String, dynamic>.from(value);
      final timestamp = _parseDate(remote['timestamp']);
      if (timestamp == null) {
        skipped++;
        continue;
      }

      final sequenceNumber = _jsonInt(remote['sequence_number']);
      final remoteBite = Bite(
        mealUuid: mealUuid,
        timestamp: timestamp,
        sequenceNumber: sequenceNumber,
        tremorMagnitude: _jsonDouble(remote['tremor_magnitude']),
        tremorFrequency: _jsonDouble(remote['tremor_frequency']),
        tremorConfidence: _jsonDouble(remote['tremor_confidence']),
        tremorWindowMs: (remote['tremor_window_ms'] as num?)?.toInt(),
        steadyPct: _jsonDouble(remote['steady_pct']),
        foodTempC: _jsonDouble(remote['food_temp_c']),
        isValid: _jsonBool(remote['is_valid'], fallback: true),
        isSynced: true,
      );
      final key = _biteKey(remoteBite);
      if (!remoteKeys.add(key)) {
        skipped++;
        continue;
      }
      final existing = existingByKey[key];
      if (existing == null) {
        toInsert.add(remoteBite);
      } else if (!existing.hasSameSyncContent(remoteBite)) {
        // Bites have no local version/tombstone yet. Preserve the local sample
        // instead of silently replacing it, and report the conflict.
        localKept++;
      }
    }

    _assertCurrentUser(expectedUserId);
    if (toInsert.isNotEmpty) await _db.insertBites(toInsert);
    localKept += existingByKey.keys
        .where((key) => !remoteKeys.contains(key))
        .length;
    return _BiteMergeResult(
      inserted: toInsert.length,
      localKept: localKept,
      skipped: skipped,
    );
  }

  /// Merge one remote meal into local SQLite, keyed by uuid.
  ///
  /// Conflict-safety: if a local row already exists for this uuid we compare
  /// `updated_at` and only overwrite when the server's copy is strictly newer.
  /// A meal that's actively being written locally (e.g. the spoon is mid-bite
  /// and `dirty`/unsynced) is never clobbered by an older server snapshot —
  /// local-dirty rows always win regardless of timestamp, since they represent
  /// data the server hasn't seen yet.
  ///
  Future<_MealMerge> _mergeRemoteMeal(
    Map<String, dynamic> remoteMeal,
    String userId,
  ) async {
    final uuid = remoteMeal['uuid'] as String?;
    if (uuid == null || uuid.isEmpty) return _MealMerge.invalid;

    final startedAtRaw = remoteMeal['started_at'] as String?;
    final startedAt = _parseDate(startedAtRaw);
    if (startedAt == null) return _MealMerge.invalid;

    final existing = await _db.getMeal(uuid);
    final remoteUpdatedAt = _parseDate(remoteMeal['updated_at']) ?? startedAt;

    final mergedMeal = Meal(
      id: existing?.id,
      uuid: uuid,
      serverId: _jsonInt(remoteMeal['id']) ?? existing?.serverId,
      userId: userId,
      deviceId: remoteMeal['device_id'] as String?,
      // Restore the per-spoon key; fall back to device_id (matches the local v15
      // backfill). Critically, if the server row predates per-spoon tracking
      // (spoon_key AND device_id both null), keep the LOCAL key rather than
      // nulling it out — otherwise a restore would wipe the attribution the
      // local backfill just set.
      spoonKey: (remoteMeal['spoon_key'] as String?) ??
          (remoteMeal['device_id'] as String?) ??
          existing?.spoonKey,
      startedAt: startedAt,
      endedAt: _parseDate(remoteMeal['ended_at']),
      mealType: remoteMeal['meal_type'] as String?,
      totalBites: _jsonInt(remoteMeal['total_bites']) ?? 0,
      avgPaceBpm: _jsonDouble(remoteMeal['avg_pace_bpm']),
      tremorIndex: _jsonDouble(remoteMeal['tremor_index']),
      durationMinutes: _jsonDouble(remoteMeal['duration_minutes']),
      avgFoodTemp: _jsonDouble(remoteMeal['avg_food_temp_c']),
      // Movement figures, restored the same way as spoonKey: a server row that
      // predates migration 021 carries none, and must not wipe what this phone
      // already measured for the same meal.
      steadyPct: _jsonDouble(remoteMeal['steady_pct']) ?? existing?.steadyPct,
      rhythmHz: _jsonDouble(remoteMeal['rhythm_hz']) ?? existing?.rhythmHz,
      measuredSeconds:
          _jsonInt(remoteMeal['measured_seconds']) ?? existing?.measuredSeconds,
      movementSource: (remoteMeal['movement_source'] as String?) ??
          existing?.movementSource,
      isSynced: true, // it came from the server, so it's synced by definition
      dirty: false,
      createdAt: _parseDate(remoteMeal['created_at']) ?? startedAt,
      updatedAt: remoteUpdatedAt,
    );

    if (existing == null) {
      _assertCurrentUser(userId);
      await _db.insertMeal(mergedMeal);
      return _MealMerge.inserted;
    }

    // Exact content equality is stronger than timestamp equality. Backend
    // upserts advance updated_at even when the submitted payload is unchanged;
    // metadata-only advancement must not be reported as a restored meal.
    if (existing.hasSameSyncContent(mergedMeal)) {
      if (!existing.dirty && existing.isSynced) {
        _assertCurrentUser(userId);
        await _db.updateMeal(
          mergedMeal.copyWith(id: existing.id, createdAt: existing.createdAt),
        );
        return _MealMerge.identical;
      }
      return _MealMerge.localKept;
    }

    // Never overwrite unacknowledged local content.
    if (existing.dirty || !existing.isSynced) return _MealMerge.localKept;

    // Without server revisions the safest available rule is timestamp order.
    // A clean local row that is equal/newer is preserved and surfaced as a
    // conflict instead of being falsely called "up to date".
    if (!remoteUpdatedAt.isAfter(existing.updatedAt)) {
      return _MealMerge.localKept;
    }

    _assertCurrentUser(userId);
    await _db.updateMeal(mergedMeal);
    return _MealMerge.updated;
  }

  /// Restore bites for a single meal from GET /api/meals/:uuid/bites.
  /// Only inserts bites that don't already exist locally (matched on
  /// meal_uuid + sequence_number, mirroring the server's own conflict key) —
  /// never overwrites a local bite, since bites are immutable point samples.
  Future<_BiteMergeResult> _restoreBitesForMeal(
    String mealUuid,
    String token, {
    required String expectedUserId,
  }) async {
    try {
      const pageSize = 500;
      var afterSequence = -1;
      final allRemoteBites = <dynamic>[];
      while (true) {
        _assertCurrentUser(expectedUserId);
        final uri = Uri.parse('$_baseUrl/meals/$mealUuid/bites').replace(
          queryParameters: {
            'limit': '$pageSize',
            'after_sequence': '$afterSequence',
          },
        );
        final response = await _get(uri, headers: _authHeaders(token));
        if (response.statusCode != 200) {
          throw _SyncHttpException(
            response.statusCode,
            retryAfter: response.headers['retry-after'],
          );
        }

        final dynamic decoded;
        try {
          decoded = await compute(jsonDecode, response.body);
        } on FormatException catch (e) {
          throw _SyncInvalidResponseException(e.message);
        }
        if (decoded is! Map<String, dynamic>) {
          throw const _SyncInvalidResponseException(
            'Expected a JSON object response.',
          );
        }
        final data = decoded['data'];
        final remoteBites = data is Map
            ? data['bites'] ?? decoded['bites']
            : decoded['bites'];
        if (remoteBites is! List || remoteBites.isEmpty) break;
        allRemoteBites.addAll(remoteBites);

        final sequenceValues = remoteBites
            .whereType<Map>()
            .map((bite) => _jsonInt(bite['sequence_number']))
            .whereType<int>()
            .toList();
        if (remoteBites.length >= pageSize) {
          if (sequenceValues.isEmpty) {
            throw const _SyncInvalidResponseException(
              'Bite pagination did not provide a sequence cursor.',
            );
          }
          final nextSequence = sequenceValues.reduce(
            (current, value) => value > current ? value : current,
          );
          if (nextSequence <= afterSequence) {
            throw const _SyncInvalidResponseException(
              'Bite pagination did not advance.',
            );
          }
          afterSequence = nextSequence;
        }
        if (remoteBites.length < pageSize) break;
      }

      _assertCurrentUser(expectedUserId);
      return _mergeEmbeddedBites(
        mealUuid,
        allRemoteBites,
        expectedUserId: expectedUserId,
      );
    } catch (e) {
      if (kDebugMode) print('Error restoring bites for $mealUuid: $e');
      rethrow;
    }
  }

  DateTime? _parseDate(dynamic value) {
    if (value is! String || value.isEmpty) return null;
    try {
      return DateTime.parse(value).toLocal();
    } catch (_) {
      return null;
    }
  }

  int? _jsonInt(dynamic value) {
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '');
  }

  double? _jsonDouble(dynamic value) {
    if (value is num) return value.toDouble();
    return double.tryParse(value?.toString() ?? '');
  }

  bool _jsonBool(dynamic value, {required bool fallback}) {
    if (value is bool) return value;
    if (value is num) return value != 0;
    final normalized = value?.toString().trim().toLowerCase();
    if (normalized == 'true' || normalized == '1') return true;
    if (normalized == 'false' || normalized == '0') return false;
    return fallback;
  }

  String _biteKey(Bite bite) {
    final sequence = bite.sequenceNumber;
    return sequence != null
        ? 'sequence:$sequence'
        : 'timestamp:${bite.timestamp.toUtc().microsecondsSinceEpoch}';
  }

  void _assertCurrentUser(String expectedUserId) {
    if (FirebaseAuth.instance.currentUser?.uid != expectedUserId) {
      throw const _SyncSessionChangedException();
    }
  }

  CloudSyncResult _resultForRestoreFailure(Object error) {
    if (error is _SyncSessionChangedException) {
      return const CloudSyncResult(status: CloudSyncStatus.accountUnavailable);
    }
    if (error is _SyncInvalidResponseException || error is FormatException) {
      return CloudSyncResult(
        status: CloudSyncStatus.invalidResponse,
        detail: error.toString(),
      );
    }
    if (error is _SyncHttpException) {
      if (error.statusCode == 401 || error.statusCode == 403) {
        return const CloudSyncResult(status: CloudSyncStatus.unauthenticated);
      }
      if (error.statusCode == 429) {
        return CloudSyncResult(
          status: CloudSyncStatus.rateLimited,
          retryAfterSeconds: int.tryParse(error.retryAfter ?? ''),
        );
      }
      if (error.statusCode >= 500) {
        return CloudSyncResult(
          status: CloudSyncStatus.serviceUnavailable,
          detail: error.toString(),
        );
      }
      return CloudSyncResult(
        status: CloudSyncStatus.invalidResponse,
        detail: error.toString(),
      );
    }
    if (error is _SyncTransportException ||
        error is SocketException ||
        error is TimeoutException ||
        error is http.ClientException) {
      return CloudSyncResult(
        status: CloudSyncStatus.networkUnavailable,
        detail: error.toString(),
      );
    }
    return CloudSyncResult(
      status: CloudSyncStatus.interrupted,
      detail: error.toString(),
    );
  }

  /// True if local storage has no/near-zero meal history for this user —
  /// the signal used to decide whether an automatic restore-on-login should
  /// run (e.g. after a reinstall or first login on a new device).
  Future<bool> hasSparseLocalData({
    required String userId,
    int threshold = 1,
  }) async {
    final localMeals = await _db.getMeals(userId: userId, limit: threshold + 1);
    return localMeals.length <= threshold;
  }

  /// True if the cloud has meal history meaningfully newer than the newest
  /// meal we have locally. Catches the case the sparse check misses: local
  /// storage is NOT empty (so hasSparseLocalData says "fine, skip"), but it's
  /// stale relative to the cloud — e.g. this device's local data stopped
  /// updating months ago (app data reset, long-unused install, etc.) while
  /// other devices/the backend kept moving forward. A pure count check can
  /// never catch this; it requires comparing actual timestamps.
  Future<bool> isLocalDataStale({
    required String userId,
    Duration threshold = const Duration(days: 3),
  }) async {
    try {
      final localLatestUpdatedAt = await _db.getLatestMealUpdatedAt(
        userId: userId,
      );
      if (localLatestUpdatedAt == null) {
        return false; // hasSparseLocalData already covers this case
      }

      final token = await AuthService.getValidToken();
      if (token == null) return false;

      final remoteLatestPage = await _fetchMealsPage(
        token: token,
        limit: 1,
        offset: 0,
        sortBy: 'updated_at',
        includeBites: false,
      );
      if (remoteLatestPage.isEmpty) return false;

      final remoteUpdatedAt =
          _parseDate(remoteLatestPage.first['updated_at']) ??
          _parseDate(remoteLatestPage.first['started_at']);
      if (remoteUpdatedAt == null) return false;

      return remoteUpdatedAt.difference(localLatestUpdatedAt) > threshold;
    } catch (e) {
      if (kDebugMode) print('isLocalDataStale check failed: $e');
      return false;
    }
  }

  /// Convenience wrapper: only restores when local data looks sparse OR
  /// stale relative to the cloud, and never throws — intended to be
  /// fired-and-forgotten from a post-login hook. Returns true if a restore
  /// actually ran (regardless of how many meals it found), false if it was
  /// skipped or failed outright.
  Future<bool> restoreFromCloudIfSparse({String? userId}) async {
    try {
      // Firebase UID is the canonical local user_id.
      final resolvedUserId = userId ?? FirebaseAuth.instance.currentUser?.uid;
      if (resolvedUserId == null) return false;

      // Repair safe placeholder user_id tags before sparse check,
      // so mistagged rows don't make the device look empty when it isn't.
      await _db.repairLegacyUserIdTags(resolvedUserId);

      final sparse = await hasSparseLocalData(userId: resolvedUserId);
      final stale = sparse
          ? false
          : await isLocalDataStale(userId: resolvedUserId);
      if (!sparse && !stale) {
        if (kDebugMode) {
          print('Local data present and up to date, skipping auto-restore');
        }
        return false;
      }

      if (kDebugMode) {
        print(
          sparse
              ? 'Local data sparse — attempting restore from cloud...'
              : 'Local data stale vs. cloud — attempting restore from cloud...',
        );
      }
      // Legacy-id repair already ran above — don't repeat it inside.
      final result = await restoreFromCloud(
        userId: resolvedUserId,
        skipLegacyRepair: true,
      );
      return result.completed;
    } catch (e) {
      if (kDebugMode) print('restoreFromCloudIfSparse failed: $e');
      return false;
    }
  }

  /// Entry point for the automatic "restore on first login" flow.
  /// Call this once from the first authenticated screen after login/launch.
  ///
  /// Guarded so it only ever attempts once per app process lifetime.
  /// Returns true if a restore actually ran and data was written.
  Future<bool> autoRestoreOnLoginIfNeeded() async {
    final userId = FirebaseAuth.instance.currentUser?.uid;
    if (userId == null || _autoRestoreAttemptedUserIds.contains(userId)) {
      return false;
    }

    try {
      final completed = await restoreFromCloudIfSparse(userId: userId);
      if (completed) _autoRestoreAttemptedUserIds.add(userId);
      return completed;
    } catch (e) {
      if (kDebugMode) print('autoRestoreOnLoginIfNeeded failed: $e');
      return false;
    }
  }

  /// Check if there's any unsynced data in the local database
  Future<bool> hasUnsyncedData() async {
    final currentUserId = FirebaseAuth.instance.currentUser?.uid;
    if (currentUserId == null || currentUserId.isEmpty) return false;

    // Same 90-day window as the push path, so out-of-window data can never make
    // the app report "needs sync" for meals it will deliberately never upload.
    final cutoff = _syncCutoff;
    final unsyncedMeals = await _db.getUnsyncedMeals(
      userId: currentUserId,
      since: cutoff,
    );
    final unsyncedBites = await _db.getUnsyncedBites(
      limit: 1,
      userId: currentUserId,
      since: cutoff,
    );
    return unsyncedMeals.isNotEmpty || unsyncedBites.isNotEmpty;
  }

  /// Check if device has internet connectivity
  Future<bool> isConnected() async {
    try {
      final connectivityResult = await Connectivity().checkConnectivity();
      return connectivityResult == ConnectivityResult.mobile ||
          connectivityResult == ConnectivityResult.wifi ||
          connectivityResult == ConnectivityResult.ethernet;
    } catch (e) {
      if (kDebugMode) print('Connectivity check failed: $e');
      return false;
    }
  }

  /// Sync only if there's unsynced data and internet is available
  Future<bool> syncIfNeeded() async {
    if (kDebugMode) print('Checking if sync is needed...');

    final hasData = await hasUnsyncedData();
    if (!hasData) {
      if (kDebugMode) print('No unsynced data, skipping sync');
      return false;
    }

    final connected = await isConnected();
    if (!connected) {
      if (kDebugMode) print('No internet connection, skipping sync');
      return false;
    }

    if (kDebugMode) print('Conditions met, starting sync...');
    try {
      await syncAll();
      return !await hasUnsyncedData();
    } catch (e) {
      if (kDebugMode) print('Sync failed: $e');
      return false;
    }
  }
}

enum _MealMerge { inserted, updated, identical, localKept, invalid }

class _BiteMergeResult {
  const _BiteMergeResult({
    this.inserted = 0,
    this.localKept = 0,
    this.skipped = 0,
  });

  final int inserted;
  final int localKept;
  final int skipped;
}

class _SyncSessionChangedException implements Exception {
  const _SyncSessionChangedException();

  @override
  String toString() => 'The authenticated user changed during sync.';
}

class _SyncInvalidResponseException implements Exception {
  const _SyncInvalidResponseException(this.message);

  final String message;

  @override
  String toString() => 'Invalid sync response: $message';
}

class _SyncTransportException implements Exception {
  const _SyncTransportException();

  @override
  String toString() => 'The sync request could not reach the backend.';
}

class _SyncHttpException implements Exception {
  const _SyncHttpException(this.statusCode, {this.retryAfter});

  final int statusCode;
  final String? retryAfter;

  String get userMessage {
    if (statusCode == 401 || statusCode == 403) {
      return 'Your session expired. Please sign in again.';
    }
    if (statusCode == 429) {
      final suffix = retryAfter == null
          ? ''
          : ' Try again in $retryAfter seconds.';
      return 'Too many sync requests were started.$suffix';
    }
    if (statusCode >= 500) {
      return 'The cloud service is temporarily unavailable.';
    }
    return 'The cloud rejected the sync request (HTTP $statusCode).';
  }

  @override
  String toString() => 'Sync HTTP $statusCode';
}
