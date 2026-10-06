// device_registry.dart — the durable list of spoons this phone knows about.
//
// Follows "Smart Spoon BLE Final Production Design v3.0" §8.1 (DeviceRegistry)
// and §30 (Device Registry Rules), and is the persistence half of §14 (add /
// claim), §15 (factory reset) and §16 (forget / logout). Edge cases #40, #42,
// #43, #59 and #60 from the §36 matrix are handled here explicitly.
//
// SECURITY — read before adding a field:
//   Nothing in this file is a secret. The ownership / claim token from §2 and
//   §14 lives in flutter_secure_storage and is written by the claim flow, NEVER
//   by this class and NEVER into SharedPreferences. §38 additionally forbids
//   logging claim secrets or raw auth tokens, which is why every debugPrint
//   below prints only serials and reasons.
//
// WHY A PLAIN CLASS (not a ChangeNotifier):
//   §8.4 gives the ConnectionCoordinator exclusive ownership of connection
//   state and of telling the UI about it. If the registry also notified, two
//   sources of truth would race during a switch and the UI could act on a
//   half-applied change. The registry is therefore a passive store: it can be
//   unit-tested with no Flutter widget tree, and the coordinator notifies.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:smartspoon/features/devices/domain/spoon_identity.dart';

import 'models/spoon_models.dart';

/// Persistent, non-secret metadata for every claimed spoon (design §8.1).
///
/// Lifecycle: construct once, `await load()` before anything else, then mutate
/// through the methods here — each one persists. The [SpoonRecord] objects
/// handed back by [all] / [byId] are live and mutable; if a caller edits one in
/// place (the §30 pseudo-update does exactly that) it MUST call [save]
/// afterwards, or prefer [updateAfterValidation] which does both.
class DeviceRegistry {
  /// [prefs] is injectable so tests can run against
  /// `SharedPreferences.setMockInitialValues` without a plugin channel.
  DeviceRegistry({SharedPreferences? prefs}) : _prefs = prefs;

  /// One JSON envelope under one key. A single key means a load or a save is
  /// one atomic SharedPreferences operation — a multi-key layout could be
  /// interrupted mid-write by a crash and leave the registry inconsistent
  /// (records saved, primary pointer not).
  static const String storageKey = 'ble_device_registry_v1';

  /// Envelope schema version — §30 "registry schema version" and edge case #40
  /// (app update must migrate, not misread). Bump this and add a step to
  /// [_migrate] whenever the on-disk record shape changes.
  static const int schemaVersion = 2;

  /// §30: corrupt records must be logged and quarantined, not silently
  /// dropped. Capped so a pathological loop cannot grow prefs without bound.
  static const int maxQuarantinedEntries = 10;

  SharedPreferences? _prefs;
  List<SpoonRecord> _records = <SpoonRecord>[];
  List<Map<String, dynamic>> _quarantined = <Map<String, dynamic>>[];
  bool _loaded = false;

  /// Firebase UID this registry is scoped to. Empty/null is the unscoped
  /// slot used before sign-in. Two accounts on one phone must not share
  /// spoons (§16).
  String? _ownerId;

  String get _storageKey {
    final uid = _ownerId?.trim() ?? '';
    return uid.isEmpty ? storageKey : '${storageKey}_$uid';
  }

  /// Set when [load] had to repair something (a quarantine, a dedupe, an extra
  /// primary). Repairs are written straight back, otherwise the same corrupt
  /// file would be re-repaired and re-logged on every single launch.
  bool _repairedOnLoad = false;

  /// Saves are serialised through this chain. Dart is single-threaded, so the
  /// in-memory mutations below are already atomic; what is NOT atomic is the
  /// awaited write. Without the chain, two overlapping mutations could land on
  /// disk out of order and persist a stale snapshot.
  Future<void> _writeChain = Future<void>.value();

  // ───────────────────────────── reads ──────────────────────────────────────

  /// Every known record, normalised. Unmodifiable so callers cannot add/remove
  /// behind the registry's back and skip persistence.
  List<SpoonRecord> get all => List<SpoonRecord>.unmodifiable(_records);

  /// Rule 7 — only known AND enabled spoons may be auto-connected. The
  /// CandidateSelector (§8.3) must score against this list, never [all]:
  /// a record that is disabled is mid-forget (§16) and must not come back.
  List<SpoonRecord> get enabled =>
      _records.where((r) => r.isAutoConnectCandidate).toList(growable: false);

  /// The single primary spoon, or null if none is flagged (§30 "at most one
  /// primary"). Normalisation guarantees at most one, so this is unambiguous.
  ///
  /// Callers must still check `isAutoConnectCandidate` before acting on it:
  /// [primary] answers "which spoon does the user prefer", not "may I connect".
  SpoonRecord? get primary {
    for (final r in _records) {
      if (r.isPrimary) return r;
    }
    return null;
  }

  /// Records that failed to parse or violated a §30 uniqueness rule. Kept for
  /// diagnostics only — they never participate in scanning or connecting.
  List<Map<String, dynamic>> get quarantined =>
      List<Map<String, dynamic>>.unmodifiable(_quarantined);

  bool get isLoaded => _loaded;

  /// Lookup by the PERMANENT identity (§1.2).
  SpoonRecord? byId(String spoonSerial) {
    for (final r in _records) {
      if (r.spoonSerial == spoonSerial) return r;
    }
    return null;
  }

  /// Lookup by the advertised stable id (§1.2 / §1.3).
  ///
  /// This exists because the platform `bleRemoteId` is a CACHE, not an
  /// identity: iOS rotates its remoteId and Android can hand out a randomised
  /// MAC, so after an OS change the only thing linking an advertisement to a
  /// saved record is `publicDeviceId` (edge case #20). The serial is still
  /// verified after connecting — a matching publicDeviceId is a *hint* that
  /// justifies connecting, never proof of identity (edge case #24).
  SpoonRecord? byPublicDeviceId(String publicDeviceId) {
    // Case- and whitespace-insensitive: the same 8-byte Device ID reaches us
    // as uppercase hex from a GATT read and lowercase from the advertisement
    // parser. An exact == made the reclaim sighting match (§13) miss silently
    // whenever those two sources disagreed on case.
    final wanted = publicDeviceId.trim().toLowerCase();
    if (wanted.isEmpty) return null;
    for (final r in _records) {
      if (r.publicDeviceId.trim().toLowerCase() == wanted) return r;
    }
    return null;
  }

  // ───────────────────────── load / save ────────────────────────────────────

  /// Reads, migrates and normalises the registry. Safe to call again; the last
  /// call wins. Must complete before any mutation (mutations assert on this),
  /// otherwise a save would overwrite storage that was never read.
  Future<List<SpoonRecord>> load() async {
    final prefs = await _resolvePrefs();
    var raw = prefs.getString(_storageKey);

    _records = <SpoonRecord>[];
    _quarantined = <Map<String, dynamic>>[];
    _repairedOnLoad = false;
    _loaded = true;

    if (raw == null || raw.isEmpty) {
      await _tryMigrateLegacy(prefs);
      return all;
    }

    int version;
    List<dynamic> rawRecords;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        // Pre-envelope shape: a bare JSON array with no version field. Treat
        // it as v0 so [_migrate] can lift it forward (edge case #40).
        version = 0;
        rawRecords = decoded;
      } else if (decoded is Map<String, dynamic>) {
        version = (decoded['version'] as num?)?.toInt() ?? 0;
        rawRecords = decoded['records'] as List<dynamic>? ?? const <dynamic>[];
        final priorQuarantine = decoded['quarantined'];
        if (priorQuarantine is List) {
          _quarantined = priorQuarantine
              .whereType<Map<String, dynamic>>()
              .toList(growable: true);
        }
      } else {
        throw const FormatException('registry envelope is neither list nor map');
      }
    } catch (e) {
      // The whole blob is unreadable. §30 forbids silently ignoring it: keep a
      // truncated copy for diagnostics and start empty rather than crash the
      // app on launch. The user re-adds spoons; nothing dangerous is retained.
      _quarantineEntry(<String, dynamic>{
        '_reason': 'envelope decode failed: $e',
        '_raw': raw.length > 500 ? '${raw.substring(0, 500)}…' : raw,
      });
      await _persist();
      return all;
    }

    final migrated = _migrate(rawRecords, version);

    final parsed = <SpoonRecord>[];
    for (final json in migrated) {
      final record = _parseRecord(json);
      if (record != null) parsed.add(record);
    }

    _records = _normalize(parsed);

    // Write back a migrated or repaired registry immediately.
    if (version != schemaVersion || _repairedOnLoad) {
      await _persist();
    }
    return all;
  }

  /// Flush the in-memory list. Public because a caller that mutated a live
  /// [SpoonRecord] in place (§30's pseudo-update pattern) needs a way to
  /// commit it without going through a typed setter.
  Future<void> save() {
    _ensureLoaded();
    return _persist();
  }

  // ───────────────────────── mutations ──────────────────────────────────────

  /// Insert or replace by [SpoonRecord.spoonSerial] (§30 unique serial).
  ///
  /// Called at the end of the §14 claim flow and after every successful
  /// post-connect validation. If the incoming record carries `isPrimary`, the
  /// flag is applied through the same single-primary path as [setPrimary].
  ///
  /// REPLACE semantics: the incoming record wins field-for-field, including
  /// `isPrimary: false`. Build the record from [byId] when updating an
  /// existing spoon, or use [updateAfterValidation] / [setPrimary], so a
  /// freshly constructed record does not silently demote the primary.
  Future<void> upsert(SpoonRecord record) async {
    _ensureLoaded();
    if (record.spoonSerial.isEmpty) {
      throw ArgumentError.value(
          record.spoonSerial, 'spoonSerial', 'must not be empty (§1.2)');
    }
    if (record.publicDeviceId.isEmpty) {
      throw ArgumentError.value(
          record.publicDeviceId, 'publicDeviceId', 'must not be empty (§1.2)');
    }

    // §30 unique publicDeviceId. A different serial claiming the same public
    // id means one of the two is stale or spoofed (edge cases #24 / #59). The
    // incoming record is the one that just passed identity validation, so the
    // older one loses and is quarantined rather than deleted.
    _records.removeWhere((r) {
      final conflicts = r.publicDeviceId == record.publicDeviceId &&
          r.spoonSerial != record.spoonSerial;
      if (conflicts) {
        _quarantineEntry(<String, dynamic>{
          ...r.toJson(),
          '_reason': 'publicDeviceId collision with ${record.spoonSerial}',
        });
      }
      return conflicts;
    });

    final index =
        _records.indexWhere((r) => r.spoonSerial == record.spoonSerial);
    if (index >= 0) {
      _records[index] = record;
    } else {
      _records.add(record);
    }

    if (record.isPrimary) _applyPrimary(record.spoonSerial);
    await _persist();
  }

  /// Make [spoonSerial] the one primary spoon, clearing the flag everywhere
  /// else in the same synchronous pass before a single write (§30 "at most one
  /// primary"). Doing it as two awaited steps could persist an intermediate
  /// state with zero or two primaries if the app died between them.
  ///
  /// Returns false if the serial is unknown or disabled — a disabled record is
  /// mid-forget (§16) and must never become the reclaim target.
  Future<bool> setPrimary(String spoonSerial) async {
    _ensureLoaded();
    final target = byId(spoonSerial);
    if (target == null || !target.enabled) return false;
    _applyPrimary(spoonSerial);
    await _persist();
    return true;
  }

  /// Step 1 of the §16 forget order: mark disabled FIRST, so that any
  /// disconnect callback that fires during teardown sees a record that is no
  /// longer an auto-connect candidate and cannot schedule a reconnect.
  ///
  /// Deliberately separate from [remove] so the coordinator can do steps 2–9
  /// (invalidate generation, cancel timers, clear queue, cancel subscriptions,
  /// disconnect GATT, drop bond, revoke backend, delete secure token) in
  /// between. Clearing `isPrimary` here is what makes edge cases #42/#43 work:
  /// the PrimaryReclaimMonitor (§8.7) stops targeting a spoon being forgotten.
  Future<bool> disable(String spoonSerial) async {
    _ensureLoaded();
    final record = byId(spoonSerial);
    if (record == null) return false;
    record.enabled = false;
    record.isPrimary = false;
    await _persist();
    return true;
  }

  /// Final step of the §16 forget order. Call [disable] and complete teardown
  /// first — "do not remove the record first and let a disconnect callback
  /// schedule a reconnect".
  Future<bool> remove(String spoonSerial) async {
    _ensureLoaded();
    final record = byId(spoonSerial);
    if (record == null) return false;
    if (record.enabled) {
      // Not fatal, but it means the caller skipped step 1 and a teardown
      // callback could still race a reconnect. Loud in debug builds only.
      debugPrint('⚠️ BLE registry: remove($spoonSerial) without disable() '
          'first — §16 forget order violated');
    }
    _records.remove(record);
    await _persist();
    return true;
  }

  /// Persist the platform locator AFTER identity validation succeeded.
  ///
  /// §30 "update bleRemoteId only after full identity validation" (design fix
  /// #14). Writing this from a scan result instead would let a spoofed or
  /// recycled advertisement repoint a saved spoon at someone else's hardware
  /// (edge case #59). The old locator is simply overwritten — it is a cache.
  ///
  /// Any other record holding the same locator has it cleared: an OS can
  /// reassign a remoteId to different hardware, and two records pointing at
  /// one address would send a direct-connect to the wrong spoon (#20).
  Future<bool> updateRemoteIdCache(String spoonSerial, String remoteId) async {
    _ensureLoaded();
    final record = byId(spoonSerial);
    if (record == null) return false;
    for (final other in _records) {
      if (!identical(other, record) && other.bleRemoteId == remoteId) {
        other.bleRemoteId = null;
      }
    }
    record.bleRemoteId = remoteId;
    await _persist();
    return true;
  }

  /// The §30 post-validation update, as one atomic write.
  ///
  /// Only non-null arguments are applied, so a caller that could not read (for
  /// example) the firmware version does not blank a previously known value.
  /// [claimEpoch] moves only through here: §15 says a factory reset keeps the
  /// serial and bumps the epoch, so it may be written only after a successful
  /// re-claim — persisting a new epoch on mismatch would silently swallow the
  /// `requiresReclaim` condition (edge case #22).
  /// Forget the cached platform locator for [spoonSerial], keeping everything
  /// else about the record.
  ///
  /// §1.2 — the locator is a cache, and a cache that has stopped working is
  /// worse than no cache: every connection attempt spends its whole timeout on
  /// a dead address before falling back to the scan that would have found the
  /// spoon immediately. Clearing it costs one scan and fixes an address that
  /// rotated behind our back.
  Future<bool> clearRemoteId(String spoonSerial) async {
    _ensureLoaded();
    final record = byId(spoonSerial);
    if (record == null || record.bleRemoteId == null) return false;
    record.bleRemoteId = null;
    await _persist();
    return true;
  }

  Future<bool> updateAfterValidation(
    String spoonSerial, {
    String? bleRemoteId,
    String? firmwareVersion,
    int? protocolVersion,
    int? claimEpoch,
    int? lastRssi,
    String? displayName,
    DateTime? lastConnectedAt,
    bool? hasHeater,
  }) async {
    _ensureLoaded();
    final record = byId(spoonSerial);
    if (record == null) return false;

    if (bleRemoteId != null) {
      for (final other in _records) {
        if (!identical(other, record) && other.bleRemoteId == bleRemoteId) {
          other.bleRemoteId = null;
        }
      }
      record.bleRemoteId = bleRemoteId;
    }
    if (firmwareVersion != null) record.firmwareVersion = firmwareVersion;
    if (protocolVersion != null) record.protocolVersion = protocolVersion;
    if (claimEpoch != null) record.claimEpoch = claimEpoch;
    if (lastRssi != null) record.lastRssi = lastRssi;
    if (displayName != null && displayName.isNotEmpty) {
      record.displayName = displayName;
    }
    if (hasHeater != null) record.hasHeater = hasHeater;
    record.lastConnectedAt = lastConnectedAt ?? DateTime.now();

    await _persist();
    return true;
  }

  /// Switch the in-memory registry to [userId]'s store. Does not write the
  /// previous owner's key, so logout can unload spoons without wiping them.
  Future<void> bindOwner(String? userId) async {
    final next = userId?.trim() ?? '';
    final normalized = next.isEmpty ? null : next;
    if (_ownerId == normalized && _loaded) return;
    _ownerId = normalized;
    _loaded = false;
    await load();
  }

  /// Wipe the CURRENT owner's store — account deletion, not ordinary logout.
  Future<void> clear() async {
    _records = <SpoonRecord>[];
    _quarantined = <Map<String, dynamic>>[];
    _loaded = true;
    final prefs = await _resolvePrefs();
    await prefs.remove(_storageKey);
  }

  // ───────────────────────── internals ──────────────────────────────────────

  void _applyPrimary(String spoonSerial) {
    for (final r in _records) {
      r.isPrimary = r.spoonSerial == spoonSerial;
    }
  }

  void _ensureLoaded() {
    if (!_loaded) {
      throw StateError(
          'DeviceRegistry.load() must complete before mutating — otherwise '
          'the first save would overwrite storage that was never read.');
    }
  }

  Future<SharedPreferences> _resolvePrefs() async =>
      _prefs ??= await SharedPreferences.getInstance();

  Future<void> _persist() {
    final next = _writeChain.then((_) => _write());
    // Keep the chain alive even if one write fails, otherwise every later save
    // inherits the error and the registry silently stops persisting.
    _writeChain = next.catchError((Object _) {});
    return next;
  }

  Future<void> _write() async {
    final prefs = await _resolvePrefs();
    final envelope = <String, dynamic>{
      'version': schemaVersion,
      'records': _records.map((r) => r.toJson()).toList(),
      if (_quarantined.isNotEmpty) 'quarantined': _quarantined,
    };
    await prefs.setString(_storageKey, jsonEncode(envelope));
  }

  /// Schema migration hook (edge case #40 — "app update: registry schema
  /// migration"). Each step lifts the raw maps one version forward, so an
  /// upgrade from any older version replays every step in order.
  List<Map<String, dynamic>> _migrate(List<dynamic> raw, int fromVersion) {
    final maps = <Map<String, dynamic>>[];
    for (final entry in raw) {
      if (entry is Map<String, dynamic>) {
        maps.add(entry);
      } else {
        _quarantineEntry(<String, dynamic>{
          '_reason': 'registry entry is not a JSON object',
          '_value': entry.toString(),
        });
      }
    }

    var version = fromVersion;
    if (version < 1) {
      // v0 → v1: the bare array gained a versioned envelope. Record fields did
      // not change, so there is nothing to rewrite per record.
      version = 1;
    }
    if (version < 2) {
      // v1 → v2: persist heater capability instead of encoding it in the
      // display name. Missing flags fall back to a one-time name hint.
      for (final m in maps) {
        if (!m.containsKey('hasHeater')) {
          final name = (m['displayName'] as String? ?? '').toLowerCase();
          m['hasHeater'] = name.contains('pro');
        }
      }
      version = 2;
    }

    if (version != schemaVersion) {
      debugPrint('⚠️ BLE registry: stored schema v$fromVersion is newer than '
          'this build (v$schemaVersion) — reading it as-is');
    }
    return maps;
  }

  /// One record, or null if it is unusable. [SpoonRecord.fromJson] tolerates
  /// missing keys but throws on wrong types, and it happily yields empty
  /// identity strings — both are corruption, and §30 says to quarantine.
  SpoonRecord? _parseRecord(Map<String, dynamic> json) {
    SpoonRecord record;
    try {
      record = SpoonRecord.fromJson(json);
    } catch (e) {
      _quarantineEntry(<String, dynamic>{
        ...json,
        '_reason': 'record parse failed: $e',
      });
      return null;
    }
    if (record.spoonSerial.isEmpty || record.publicDeviceId.isEmpty) {
      _quarantineEntry(<String, dynamic>{
        ...json,
        '_reason': 'missing spoonSerial or publicDeviceId',
      });
      return null;
    }
    return record;
  }

  /// One-time lift of older stores into this owner's registry.
  ///
  /// Order matters: this owner's legacy list first, then the unscoped
  /// coordinator registry (initialize() may have already migrated there
  /// before bindOwner ran), then the unscoped pre-coordinator list.
  Future<void> _tryMigrateLegacy(SharedPreferences prefs) async {
    final adopted = _recordsFromLegacyList(
          prefs.getStringList(savedSpoonsStorageKey(_ownerId)),
        ) ??
        _recordsFromEnvelope(prefs.getString(storageKey)) ??
        _recordsFromLegacyList(
          prefs.getStringList(kSavedSpoonsStorageKey),
        );
    if (adopted == null || adopted.isEmpty) return;
    _records = _normalize(adopted);
    _repairedOnLoad = true;
    await _persist();
    debugPrint(
      '📂 BLE registry: adopted ${_records.length} spoon(s) for '
      '${_ownerId ?? "unscoped"}',
    );
  }

  List<SpoonRecord>? _recordsFromEnvelope(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      final list = decoded is Map<String, dynamic>
          ? decoded['records'] as List<dynamic>?
          : decoded is List
              ? decoded
              : null;
      if (list == null || list.isEmpty) return null;
      final parsed = <SpoonRecord>[];
      for (final entry in list) {
        if (entry is! Map<String, dynamic>) continue;
        final record = _parseRecord(entry);
        if (record != null) parsed.add(record);
      }
      return parsed.isEmpty ? null : parsed;
    } catch (_) {
      return null;
    }
  }

  List<SpoonRecord>? _recordsFromLegacyList(List<String>? list) {
    if (list == null || list.isEmpty) return null;
    final parsed = <SpoonRecord>[];
    for (final s in list) {
      try {
        final m = jsonDecode(s);
        if (m is! Map<String, dynamic>) continue;
        final id = m['id'] as String? ?? '';
        final name = m['name'] as String? ?? 'iSpoon';
        final productId = (m['productId'] as String?)?.trim().toLowerCase();
        final serial =
            (productId != null && productId.length == 16) ? productId : id;
        if (serial.isEmpty) continue;
        parsed.add(SpoonRecord(
          spoonSerial: serial,
          publicDeviceId: serial,
          bleRemoteId: id,
          displayName: (m['customName'] as String?)?.trim().isNotEmpty == true
              ? m['customName'] as String
              : name,
          hasHeater: m['hasHeater'] as bool? ??
              name.toLowerCase().contains('pro'),
          enabled: m['autoConnect'] as bool? ?? true,
          firmwareVersion: m['firmwareVersion'] as String?,
          lastConnectedAt:
              DateTime.tryParse(m['lastConnected'] as String? ?? ''),
        ));
      } catch (_) {
        continue;
      }
    }
    return parsed.isEmpty ? null : parsed;
  }

  /// Enforce the §30 invariants on a freshly parsed list.
  ///
  /// Order matters: dedupe identity first, then resolve the primary flag, so
  /// a duplicate that would have won the primary contest is already gone.
  List<SpoonRecord> _normalize(List<SpoonRecord> input) {
    final bySerial = <String, SpoonRecord>{};
    for (final record in input) {
      final existing = bySerial[record.spoonSerial];
      if (existing == null) {
        bySerial[record.spoonSerial] = record;
        continue;
      }
      final winner = _mostRecent(existing, record);
      _quarantineEntry(<String, dynamic>{
        ...(identical(winner, existing) ? record : existing).toJson(),
        '_reason': 'duplicate spoonSerial ${record.spoonSerial}',
      });
      bySerial[record.spoonSerial] = winner;
    }

    final byPublic = <String, SpoonRecord>{};
    for (final record in bySerial.values) {
      final existing = byPublic[record.publicDeviceId];
      if (existing == null) {
        byPublic[record.publicDeviceId] = record;
        continue;
      }
      final winner = _mostRecent(existing, record);
      _quarantineEntry(<String, dynamic>{
        ...(identical(winner, existing) ? record : existing).toJson(),
        '_reason': 'duplicate publicDeviceId ${record.publicDeviceId}',
      });
      byPublic[record.publicDeviceId] = winner;
    }

    final result = byPublic.values.toList();

    // Edge case #60 — corrupt storage can contain several primaries. Keep
    // exactly one: the most recently connected, because that is the spoon the
    // user actually used last. If nothing is flagged, there is NO primary; the
    // registry must not invent one, or a spoon the user never chose would win
    // reclaim (§13) over their real preference.
    final flagged = result.where((r) => r.isPrimary).toList();
    if (flagged.length > 1) {
      flagged.sort((a, b) {
        final byTime = _connectedAt(b).compareTo(_connectedAt(a));
        // Serial tiebreak: List.sort is not stable, and normalisation must be
        // deterministic or two launches could disagree on the primary.
        return byTime != 0 ? byTime : a.spoonSerial.compareTo(b.spoonSerial);
      });
      for (final loser in flagged.skip(1)) {
        loser.isPrimary = false;
      }
      _repairedOnLoad = true;
      debugPrint('⚠️ BLE registry: ${flagged.length} primary spoons in '
          'storage — kept ${flagged.first.spoonSerial} (§30 / #60)');
    }

    return result;
  }

  SpoonRecord _mostRecent(SpoonRecord a, SpoonRecord b) =>
      _connectedAt(b).isAfter(_connectedAt(a)) ? b : a;

  DateTime _connectedAt(SpoonRecord r) =>
      r.lastConnectedAt ?? DateTime.fromMillisecondsSinceEpoch(0);

  void _quarantineEntry(Map<String, dynamic> entry) {
    entry['_quarantinedAt'] = DateTime.now().toIso8601String();
    _quarantined.add(entry);
    _repairedOnLoad = true;
    if (_quarantined.length > maxQuarantinedEntries) {
      _quarantined.removeRange(0, _quarantined.length - maxQuarantinedEntries);
    }
    // §38: serials and reasons only — never tokens.
    debugPrint('⚠️ BLE registry: quarantined a record — ${entry['_reason']}');
  }
}
