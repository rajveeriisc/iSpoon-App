// candidate_selector.dart — decides WHICH spoon a scan should connect to.
//
// Follows "Smart Spoon BLE Final Production Design v3.0" §8.3, §9 (9.1, 9.2,
// 9.3), Rule 6 and Rule 7 of §3, and edge cases #2, #3, #4, #10, #19 and #23
// of §36. It is also where four of the §0 fixes actually live:
//
//   #5  scan connected to the first saved spoon it happened to see
//        → candidates are collected for a window BEFORE anything is committed
//   #6  seenCount existed but was never used to prove RSSI stability
//        → every candidate must pass SpoonCandidate.isStable
//   #7  scanResults could contain devices from a PREVIOUS scan
//        → beginCollection() wipes all state; only live sightings are scored
//   #8  no commit guard, so overlapping scan callbacks could start two
//       connections → commit() is single-shot
//
// This module is deliberately inert. It does not scan, does not connect and
// holds no BLE handles or platform types; the ConnectionCoordinator (§8.4)
// feeds it sightings and asks it for exactly one decision. That is what makes
// the rules below testable without a radio, two spoons and a stopwatch.
library;

import 'constants.dart';
import 'models/spoon_models.dart';

/// Which set of rules the selector is running under.
///
/// Rule 7 and edge case #23: normal auto-connect must ignore unknown spoons
/// completely — a stranger's spoon advertising our service UUID is not a
/// candidate, it is noise. Adding a spoon is therefore a SEPARATE mode
/// (design §14), not a relaxed flag on the normal one, so that no bug in the
/// automatic path can ever fall through into "connect to anything".
enum SelectionMode {
  /// §9 auto-connect. Known + enabled spoons only.
  automatic,

  /// §14 Add Spoon / Claim Spoon. Unknown devices ARE returned, because
  /// discovering an unknown spoon is the entire point of the flow.
  provisioning,
}

/// Why a candidate won. Kept as a value so the coordinator can log it (§38)
/// and map it onto a [ConnectionRequestReason] without re-deriving the rules.
enum SelectionTier {
  manualConfirmed,
  activeMealSpoon,
  manualCooldownTarget,
  primary,
  recentlyUsed,
  previouslyUsed,

  /// Known, enabled, stable — but no business rule applies. Signal quality and
  /// configured priority decide.
  eligible,

  /// §14 provisioning: ranked by signal only, business rules do not apply.
  provisioningCandidate,

  /// The coordinator addressed one specific spoon for a non-user reason —
  /// today only primary reclaim (§13). A filter, never a score: it narrows
  /// which candidates are admissible and then the §9.3 table decides.
  directedTarget,
}

/// The §9.3 score table, as constants so tests can assert against the design
/// document rather than against magic numbers.
///
/// The categories are MUTUALLY EXCLUSIVE — the highest applicable one wins and
/// they are never summed. That is not a simplification, it is what makes Rule 6
/// hold: summing them inverts the design's own ordering (a primary spoon used
/// 2 minutes ago would score 800,000 + 300,000 = 1,100,000 and beat the
/// manually confirmed spoon's 1,000,000, which Rule 6 explicitly forbids).
/// Treating them as exclusive tiers reproduces Rule 6's order exactly while
/// keeping every number from §9.3 untouched.
class CandidateScore {
  CandidateScore._();

  // ── Business categories (§9.3, in Rule 6 order) ──────────────────────────
  static const int manualConfirmed = 1000000;
  static const int sameMealSpoon = 900000;
  static const int manualCooldownTarget = 850000;
  static const int primary = 800000;
  static const int lastUsedUnder10Min = 300000;
  static const int lastUsedUnder1Hour = 100000;

  /// §9.3 last-used windows. They are literals of the design doc and have no
  /// home in [BleConstants], which is a fixed contract.
  static const Duration recentUseWindow = Duration(minutes: 10);
  static const Duration priorUseWindow = Duration(hours: 1);

  // ── Discretionary bonuses (Rule 6 steps 6 and 7) ─────────────────────────
  /// §9.3 "stable RSSI +20,000". A quality signal, never a business rule.
  static const int stableRssi = 20000;

  /// §9.3 "configured priority +variable". Deliberately bounded: priority is a
  /// tie-break between otherwise-equal spoons, so a user who types a big number
  /// into a priority field must not be able to out-vote the meal guard.
  static const int priorityStep = 1000;
  static const int priorityMaxSteps = 29;
  static const int priorityMax = priorityStep * priorityMaxSteps; // 29,000

  /// Everything Rule 6 ranks BELOW the business categories, summed.
  ///
  /// 29,000 + 20,000 = 49,000, which is less than 50,000 — the smallest gap
  /// between two §9.3 categories (900,000 → 850,000 → 800,000). So no amount of
  /// signal strength or configured priority can ever promote a candidate past a
  /// business rule. This is the invariant the whole table exists to protect.
  static const int maxDiscretionary = priorityMax + stableRssi;

  /// Rule 6 step 6, clamped into [priorityMax].
  static int priorityBonus(int configuredPriority) =>
      configuredPriority.clamp(0, priorityMaxSteps) * priorityStep;
}

/// Everything the selector needs to know about the world, captured once per
/// scan. Passing it in (instead of reaching into a registry/meal singleton)
/// keeps this module pure and lets a test describe an entire scenario in one
/// literal.
class SelectionContext {
  const SelectionContext({
    this.mode = SelectionMode.automatic,
    this.knownSpoons = const <SpoonRecord>[],
    this.manualConfirmedSerial,
    this.activeMealSpoonSerial,
    this.strictMealGuard = true,
    this.manualOverrideSerial,
    this.manualOverrideAt,
    this.hardTargetSerial,
    this.isForeground = true,
  });

  /// §14 Add Spoon. No registry, no targets — just rank what is in range.
  static const SelectionContext provisioning =
      SelectionContext(mode: SelectionMode.provisioning);

  final SelectionMode mode;

  /// Whether the app is in the foreground. Only affects how many sightings a
  /// candidate must show before it counts as stable — see
  /// [SpoonCandidate.isStableFor].
  final bool isForeground;

  /// The registry's view (§8.1). "Known" means present here; a record that is
  /// absent is an unknown device and Rule 7 applies.
  final List<SpoonRecord> knownSpoons;

  /// Rule 6 step 1 — the user tapped a specific spoon and confirmed it.
  final String? manualConfirmedSerial;

  /// Rule 5 / §12.1 — the spoon the active meal belongs to.
  final String? activeMealSpoonSerial;

  /// §12.1 strict safe mode is the recommended default: during a meal, only
  /// the meal's own spoon may be selected (edge case #15 — no silent switch to
  /// spoon B). Set false for the segmented-meal policy of §12.2.
  final bool strictMealGuard;

  /// §13 / Rule 6 step 3 — the spoon the user last chose by hand, and when.
  /// Inside [BleConstants.manualOverrideCooldown] that choice still outranks
  /// the primary spoon, so primary reclaim cannot undo a deliberate decision.
  final String? manualOverrideSerial;
  final DateTime? manualOverrideAt;

  /// A coordinator-directed target that must be matched exactly or not at all,
  /// ranked BELOW the user-facing targets above.
  ///
  /// Primary reclaim (§13) is the only caller. It exists because reclaim is a
  /// swap of a working link for a better one: if the primary spoon is not
  /// actually there, the correct outcome is "no selection" and the fallback
  /// keeps streaming. Without the filter the reclaim scan would happily
  /// re-select the spoon already connected and tear down a healthy session for
  /// nothing.
  ///
  /// Deliberately NOT used for resume (FIX 4). A spoon that was streaming
  /// moments ago already wins through the §9.3 "used <10 min" row via its
  /// `lastConnectedAt`, so resume gets its preference without a filter that
  /// would strand the user when only the other saved spoon is in range.
  final String? hardTargetSerial;
}

/// One candidate with its §9.3 score. Returned in rank order so the Add-Spoon
/// UI and the logs can see the runners-up, not just the winner.
class ScoredCandidate {
  const ScoredCandidate({
    required this.candidate,
    required this.record,
    required this.score,
    required this.tier,
    required this.reasons,
  });

  final SpoonCandidate candidate;

  /// Null only in provisioning mode — an unknown, not-yet-claimed device.
  final SpoonRecord? record;

  final int score;
  final SelectionTier tier;

  /// Human-readable trace of every term that contributed, for §38 logging.
  final List<String> reasons;

  @override
  String toString() => 'ScoredCandidate(${record?.spoonSerial ?? "unknown"} '
      'pid:${candidate.publicDeviceId} score:$score ${tier.name} '
      'rssi:${candidate.rssiEma.toStringAsFixed(1)} n:${candidate.seenCount})';
}

/// The single committed decision of one scan.
class SpoonSelection {
  const SpoonSelection({
    required this.candidate,
    required this.record,
    required this.bleRemoteId,
    required this.score,
    required this.tier,
    required this.mode,
    required this.reasons,
    required this.candidatesConsidered,
    required this.decidedAt,
    this.runnerUpScore,
  });

  final SpoonCandidate candidate;

  /// Null only in provisioning mode.
  final SpoonRecord? record;

  /// The freshest platform locator heard for this identity in THIS scan.
  /// A cache, never an identity (§1.2, edge case #20) — the connection is only
  /// trusted after post-connect identity validation (§10.3).
  final String bleRemoteId;

  final int score;
  final SelectionTier tier;
  final SelectionMode mode;
  final List<String> reasons;
  final int candidatesConsidered;
  final DateTime decidedAt;

  /// Score of the second-best candidate, if any. Purely diagnostic: it is how
  /// you prove after the fact that edge cases #3 and #4 behaved.
  final int? runnerUpScore;

  String get publicDeviceId => candidate.publicDeviceId;
  String? get spoonSerial => record?.spoonSerial;

  @override
  String toString() => 'SpoonSelection(${spoonSerial ?? "unknown"} '
      'pid:$publicDeviceId ble:$bleRemoteId score:$score ${tier.name} '
      'of $candidatesConsidered [${reasons.join(", ")}])';
}

/// §8.3 CandidateSelector.
///
/// Lifecycle, once per scan:
///
///   beginCollection(ctx)          // wipes the previous scan (fix #7)
///   observe(...) ×N               // every advertisement heard
///   ... wait candidateCollectionWindow ...   (§9.1 — never first-found)
///   commit()                      // atomic, single-shot (fix #8)
///
/// A plain object on purpose: no ChangeNotifier, no streams, no timers. The
/// coordinator owns the clock and the radio; this owns the rules.
class CandidateSelector {
  /// [clock] exists for tests. Note that [SpoonCandidate.isStable] reads the
  /// real wall clock internally (it is part of the fixed model contract), so
  /// the injected clock governs only this class's own time arithmetic:
  /// the collection window, the manual cooldown and the last-used windows.
  CandidateSelector({DateTime Function()? clock})
      : _now = clock ?? DateTime.now;

  final DateTime Function() _now;

  /// Live candidates of the CURRENT scan, keyed by identity (fix #7).
  final Map<String, SpoonCandidate> _candidates = <String, SpoonCandidate>{};

  /// Freshest platform locator per identity. Kept beside the candidate because
  /// SpoonCandidate.bleRemoteId is final, and on iOS/Android the same spoon can
  /// surface under a new locator mid-scan (edge case #20).
  final Map<String, String> _latestRemoteId = <String, String>{};

  final Map<String, SpoonRecord> _recordsByPublicId = <String, SpoonRecord>{};
  final Map<String, SpoonRecord> _recordsBySerial = <String, SpoonRecord>{};

  SelectionContext _context = const SelectionContext();
  DateTime? _collectionStartedAt;
  bool _collecting = false;

  /// Fix #8. Once true, this scan can never produce a second decision.
  bool _committed = false;

  /// Resolved publicDeviceId of a hard target (manual confirm / meal guard),
  /// or null when the scan is free to choose.
  String? _targetPublicId;
  SelectionTier? _targetTier;

  /// True when a hard target was requested but the registry has no record for
  /// it. Nothing may then be selected — silently connecting a different spoon
  /// is exactly the bug Rule 5 and Rule 6 exist to prevent.
  bool _targetUnresolved = false;

  /// Why the last commit() returned null. Diagnostics only (§38).
  String? _lastCommitFailureReason;

  // ── Introspection ────────────────────────────────────────────────────────

  SelectionMode get mode => _context.mode;

  /// Which hard target (if any) this scan is pinned to. Diagnostics only —
  /// the filtering itself happens in [_evaluate].
  SelectionTier? get targetTier => _targetTier;

  bool get isCollecting => _collecting;
  bool get hasCommitted => _committed;
  int get candidateCount => _candidates.length;
  String? get lastCommitFailureReason => _lastCommitFailureReason;

  /// How long the current collection window has been open.
  Duration get elapsed {
    final started = _collectionStartedAt;
    return started == null ? Duration.zero : _now().difference(started);
  }

  /// §9.1 — the guard against first-found selection. Until this is true, a
  /// spoon that advertised first has no advantage over one still arriving.
  bool get isCollectionWindowElapsed =>
      _collectionStartedAt != null &&
      elapsed >= BleConstants.candidateCollectionWindow;

  /// True when commit() would return a selection right now.
  bool get isReadyToCommit =>
      _collecting &&
      !_committed &&
      isCollectionWindowElapsed &&
      rankedCandidates().isNotEmpty;

  // ── Lifecycle ────────────────────────────────────────────────────────────

  /// Starts a new collection window and throws away EVERYTHING from the last
  /// one (fix #7). Results of a previous scan must never influence a decision:
  /// a spoon that was in range 40 seconds ago may be in a drawer now, and a
  /// cached RSSI is a lie the moment the scan stops.
  void beginCollection(SelectionContext context) {
    _candidates.clear();
    _latestRemoteId.clear();
    _recordsByPublicId.clear();
    _recordsBySerial.clear();

    _context = context;
    _collectionStartedAt = _now();
    _collecting = true;
    _committed = false;
    _lastCommitFailureReason = null;
    _targetPublicId = null;
    _targetTier = null;
    _targetUnresolved = false;

    // Index the registry once. Identity is matched on publicDeviceId, never on
    // the BLE name (edge case #19: every spoon ships with the same name) and
    // never on the remote id (edge case #20: iOS rotates it).
    for (final record in context.knownSpoons) {
      final publicId = _normalize(record.publicDeviceId);
      if (publicId.isNotEmpty) {
        _recordsByPublicId.putIfAbsent(publicId, () => record);
      }
      final serial = _normalize(record.spoonSerial);
      if (serial.isNotEmpty) {
        _recordsBySerial.putIfAbsent(serial, () => record);
      }
    }

    _resolveHardTarget();
  }

  /// Feeds one advertisement. Cheap and allocation-light — it runs on every
  /// scan callback, which on Android can be tens per second.
  ///
  /// Sightings arriving when no collection is open are DROPPED, not an error:
  /// stopping a scan is asynchronous on both platforms, so late callbacks from
  /// an abandoned scan are normal and must not crash the app or, worse, leak
  /// into the next scan's candidate set (fix #7).
  void observe({
    required String bleRemoteId,
    required String publicDeviceId,
    required int rssi,
    String displayName = 'iSpoon',
  }) {
    if (!_collecting || _committed) return;
    if (bleRemoteId.isEmpty && publicDeviceId.isEmpty) return;

    final key = _keyFor(publicDeviceId: publicDeviceId, remoteId: bleRemoteId);
    _latestRemoteId[key] = bleRemoteId;

    final existing = _candidates[key];
    if (existing != null) {
      existing.observe(rssi);
      existing.updateMetadata(
        publicDeviceId: publicDeviceId,
        displayName: displayName,
      );
      return;
    }

    _candidates[key] = SpoonCandidate(
      bleRemoteId: bleRemoteId,
      publicDeviceId: publicDeviceId,
      displayName: displayName,
      rssi: rssi,
      firstSeen: _now(),
    );
  }

  /// Drops the scan without a decision: adapter switched off (edge case #27),
  /// the user cancelled, or a higher-priority request superseded this one (§6).
  void abandon() {
    _collecting = false;
    _candidates.clear();
    _latestRemoteId.clear();
    _collectionStartedAt = null;
  }

  // ── Scoring ──────────────────────────────────────────────────────────────

  /// Every eligible candidate, best first. Ineligible ones are absent, not
  /// zero-scored — Rule 7 means "not a candidate", not "a bad candidate".
  ///
  /// Ordering is fully deterministic (edge case #4): score, then smoothed RSSI,
  /// then sighting count, then identity. Two spoons on the table always produce
  /// the same winner, which is the difference between a testable rule and a
  /// coin toss.
  List<ScoredCandidate> rankedCandidates() {
    final scored = <ScoredCandidate>[];
    for (final candidate in _candidates.values) {
      final result = _evaluate(candidate);
      if (result != null) scored.add(result);
    }

    scored.sort((a, b) {
      final byScore = b.score.compareTo(a.score);
      if (byScore != 0) return byScore;
      // Rounded to whole dBm on purpose. rssiEma is a continuously smoothed
      // double, so two radios never tie on it to 15 decimal places — comparing
      // it raw made every tiebreak below this line dead code, and a 1e-7 dBm
      // antenna flutter decided the winner instead of "the one you used last".
      final byRssi =
          b.candidate.rssiEma.round().compareTo(a.candidate.rssiEma.round());
      if (byRssi != 0) return byRssi;
      final bySeen = b.candidate.seenCount.compareTo(a.candidate.seenCount);
      if (bySeen != 0) return bySeen;

      // Most recently used wins before identity does. The §9.3 bands only
      // reward use inside the last hour, so three saved spoons that were all
      // last used days ago land in the same band — and without this the
      // winner would be decided by hex ordering, which is arbitrary dressed up
      // as deterministic. "The one you used most recently" is the answer a
      // user expects and can predict.
      final aUsed = a.record?.lastConnectedAt;
      final bUsed = b.record?.lastConnectedAt;
      if (aUsed != null || bUsed != null) {
        if (aUsed == null) return 1;
        if (bUsed == null) return -1;
        final byUse = bUsed.compareTo(aUsed);
        if (byUse != 0) return byUse;
      }

      final byId =
          a.candidate.publicDeviceId.compareTo(b.candidate.publicDeviceId);
      if (byId != 0) return byId;
      return a.candidate.bleRemoteId.compareTo(b.candidate.bleRemoteId);
    });
    return scored;
  }

  /// Fix #8 — the commit guard. Atomic and single-shot.
  ///
  /// Dart runs each event-loop callback to completion on one isolate, so the
  /// check-and-set below cannot interleave with another scan callback: there is
  /// no await between reading [_committed] and writing it. Two overlapping
  /// scan results therefore cannot both walk out of here with a selection, and
  /// the coordinator can never be told to open two connections.
  ///
  /// Returns null when there is nothing to commit — window still open, no
  /// eligible candidate, or a decision was already taken.
  /// [lastCommitFailureReason] says which.
  ///
  /// [force] skips ONLY the collection-window check, for when the scan has
  /// already ended (scanTimeout) and the choice is "decide now or not at all".
  /// It never relaxes stability, Rule 7, the hard target or the commit guard.
  SpoonSelection? commit({bool force = false}) {
    if (_committed) {
      // The whole point of fix #8: a second attempt is not an error to retry,
      // it is a race that must lose.
      _lastCommitFailureReason = 'already committed';
      return null;
    }
    if (!_collecting) {
      _lastCommitFailureReason = 'no collection in progress';
      return null;
    }
    if (!force && !isCollectionWindowElapsed) {
      // §9.1 / edge cases #2 and #3: the primary spoon may still be one
      // advertising interval away. Committing now is first-found selection.
      _lastCommitFailureReason = 'collection window still open';
      return null;
    }

    final ranked = rankedCandidates();
    if (ranked.isEmpty) {
      _lastCommitFailureReason = _targetUnresolved
          ? 'target spoon is not in the registry'
          : 'no stable eligible candidate';
      return null;
    }

    // Claim the decision BEFORE building the result. Nothing below yields.
    _committed = true;
    _collecting = false;
    _lastCommitFailureReason = null;

    final winner = ranked.first;
    final key = _keyFor(
      publicDeviceId: winner.candidate.publicDeviceId,
      remoteId: winner.candidate.bleRemoteId,
    );

    return SpoonSelection(
      candidate: winner.candidate,
      record: winner.record,
      bleRemoteId: _latestRemoteId[key] ?? winner.candidate.bleRemoteId,
      score: winner.score,
      tier: winner.tier,
      mode: _context.mode,
      reasons: winner.reasons,
      candidatesConsidered: ranked.length,
      decidedAt: _now(),
      runnerUpScore: ranked.length > 1 ? ranked[1].score : null,
    );
  }

  // ── Internals ────────────────────────────────────────────────────────────

  /// Resolves a serial-addressed hard target to the publicDeviceId the scan
  /// actually sees.
  ///
  /// Rule 6 step 1 and Rule 5 are not merely high scores, they are filters: if
  /// the user confirmed spoon B, or a meal is running on spoon B, then spoon A
  /// is not a lesser answer — it is the wrong answer. Returning nothing lets
  /// the coordinator report notFound instead of silently switching devices
  /// (edge case #15).
  void _resolveHardTarget() {
    // Provisioning has no meal and no manual target; the user is picking from
    // a list (§14).
    if (_context.mode != SelectionMode.automatic) return;

    final manual = _normalize(_context.manualConfirmedSerial ?? '');
    // Rule 6 step 1 outranks step 2, so an explicit confirmation during a meal
    // wins and the meal policy of §12.2 takes over at the meal layer.
    final mealSerial = _context.strictMealGuard
        ? _normalize(_context.activeMealSpoonSerial ?? '')
        : '';

    final directed = _normalize(_context.hardTargetSerial ?? '');

    final serial = manual.isNotEmpty
        ? manual
        : mealSerial.isNotEmpty
            ? mealSerial
            : directed;
    if (serial.isEmpty) return;

    _targetTier = manual.isNotEmpty
        ? SelectionTier.manualConfirmed
        : mealSerial.isNotEmpty
            ? SelectionTier.activeMealSpoon
            : SelectionTier.directedTarget;

    final record = _recordsBySerial[serial];
    if (record == null) {
      _targetUnresolved = true;
      return;
    }
    _targetPublicId = _normalize(record.publicDeviceId);
    if (_targetPublicId!.isEmpty) _targetUnresolved = true;
  }

  ScoredCandidate? _evaluate(SpoonCandidate candidate) {
    if (_targetUnresolved) return null;

    final publicId = _normalize(candidate.publicDeviceId);
    var record = publicId.isEmpty ? null : _recordsByPublicId[publicId];
    if (record == null && publicId.isNotEmpty) {
      record = _recordsBySerial[publicId];
    }
    if (record == null && candidate.bleRemoteId.isNotEmpty) {
      for (final r in _context.knownSpoons) {
        if (_normalize(r.bleRemoteId ?? '') == _normalize(candidate.bleRemoteId)) {
          record = r;
          break;
        }
      }
    }

    if (_context.mode == SelectionMode.automatic) {
      // Rule 7 + edge case #23: an unknown device advertising our service UUID
      // is ignored entirely. Not scored low — ignored. Anything else is how a
      // neighbour's spoon ends up in someone's meal data.
      if (record == null) return null;
      // Rule 7 again: a disabled/forgotten spoon is never auto-connected
      // (edge case #43).
      if (!record.isAutoConnectCandidate) return null;
    }

    // Fix #6 / §9.2 — repeated sightings, recent, and above the too-weak
    // floor for automatic connection. For user provisioning scan, show any
    // discovered spoon seen at least once so slow advertising doesn't hide it.
    if (_context.mode != SelectionMode.provisioning &&
        !candidate.isStableFor(isForeground: _context.isForeground)) {
      return null;
    }
    if (_context.mode == SelectionMode.provisioning && candidate.seenCount < 1) return null;

    // Hard target filter (Rule 5 / Rule 6 step 1).
    if (_targetPublicId != null && publicId != _targetPublicId) return null;

    final reasons = <String>[];
    var score = 0;
    SelectionTier tier;

    if (_context.mode == SelectionMode.provisioning) {
      // §14: the user is holding the spoon they want to add. Auto-connect
      // business rules would actively harm here — they would rank an already
      // claimed primary spoon across the room above the new one in their hand.
      tier = SelectionTier.provisioningCandidate;
      reasons.add(record == null ? 'unknown device' : 'already claimed');
    } else {
      // ── §9.3 business categories, highest applicable only ────────────────
      final known = record!;
      final cooldownTarget = _isInsideManualCooldown(known);
      final isMealSpoon = _matchesSerial(known, _context.activeMealSpoonSerial);
      final isManual = _matchesSerial(known, _context.manualConfirmedSerial);

      if (isManual) {
        score = CandidateScore.manualConfirmed;
        tier = SelectionTier.manualConfirmed;
        reasons.add('manual confirmed +${CandidateScore.manualConfirmed}');
      } else if (isMealSpoon) {
        score = CandidateScore.sameMealSpoon;
        tier = SelectionTier.activeMealSpoon;
        reasons.add('same meal spoon +${CandidateScore.sameMealSpoon}');
      } else if (cooldownTarget) {
        score = CandidateScore.manualCooldownTarget;
        tier = SelectionTier.manualCooldownTarget;
        reasons.add('manual cooldown +${CandidateScore.manualCooldownTarget}');
      } else if (known.isPrimary) {
        // Rule 6: primary sits BELOW the meal and manual categories, which is
        // the whole reason primary is not simply "always wins".
        score = CandidateScore.primary;
        tier = SelectionTier.primary;
        reasons.add('primary +${CandidateScore.primary}');
      } else {
        final lastUsed = known.lastConnectedAt;
        final age = lastUsed == null ? null : _now().difference(lastUsed);
        if (age != null &&
            !age.isNegative &&
            age < CandidateScore.recentUseWindow) {
          score = CandidateScore.lastUsedUnder10Min;
          tier = SelectionTier.recentlyUsed;
          reasons.add('used <10min +${CandidateScore.lastUsedUnder10Min}');
        } else if (age != null &&
            !age.isNegative &&
            age < CandidateScore.priorUseWindow) {
          score = CandidateScore.lastUsedUnder1Hour;
          tier = SelectionTier.previouslyUsed;
          reasons.add('used <1hr +${CandidateScore.lastUsedUnder1Hour}');
        } else {
          tier = SelectionTier.eligible;
          reasons.add('known+enabled');
        }
      }

      // Rule 6 step 6 — configured priority, bounded (see CandidateScore).
      final priorityBonus = CandidateScore.priorityBonus(known.priority);
      if (priorityBonus > 0) {
        score += priorityBonus;
        reasons.add('priority +$priorityBonus');
      }
    }

    // Rule 6 step 7 — signal quality, and nothing more. Capped at 20,000
    // against a minimum 50,000 category gap, so RSSI can tie-break inside a
    // category but can never climb out of one (§9.3).
    if (candidate.rssiEma > BleConstants.rssiStable) {
      score += CandidateScore.stableRssi;
      reasons.add('stable rssi +${CandidateScore.stableRssi}');
    }

    return ScoredCandidate(
      candidate: candidate,
      record: record,
      score: score,
      tier: tier,
      reasons: reasons,
    );
  }

  /// §13 / Rule 6 step 3 — a deliberate manual choice keeps outranking the
  /// primary spoon until the cooldown expires (edge case #13).
  bool _isInsideManualCooldown(SpoonRecord record) {
    final at = _context.manualOverrideAt;
    if (at == null) return false;
    if (!_matchesSerial(record, _context.manualOverrideSerial)) return false;
    final age = _now().difference(at);
    return !age.isNegative && age < BleConstants.manualOverrideCooldown;
  }

  bool _matchesSerial(SpoonRecord record, String? serial) {
    if (serial == null || serial.isEmpty) return false;
    return _normalize(record.spoonSerial) == _normalize(serial);
  }

  /// Identity key for the scan. publicDeviceId is the stable identity (§1.2),
  /// so it wins whenever it was advertised; the remote id is only a fallback
  /// for provisioning scans of spoons that do not advertise a stable id yet
  /// (§1.3 / edge case #21). The BLE name is never part of the key — edge case
  /// #19, every unit ships as "iSpoon".
  String _keyFor({required String publicDeviceId, required String remoteId}) {
    if (remoteId.isNotEmpty) return 'ble:${_normalize(remoteId)}';
    final publicId = _normalize(publicDeviceId);
    if (publicId.isNotEmpty) return 'pid:$publicId';
    return '';
  }

  /// Advertised ids arrive with inconsistent case and padding across the two
  /// platforms; the registry stores whatever was written at claim time.
  String _normalize(String value) => value.trim().toLowerCase();
}
