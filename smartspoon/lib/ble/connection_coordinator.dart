// connection_coordinator.dart — the SINGLE authority over scanning,
// connecting, switching and recovery.
//
// Follows design §8.4 and §31. Design §8.4 is emphatic: only this module may
// start/stop automatic scans, connect, disconnect, switch devices, run
// fallback, run same-spoon meal recovery or invoke primary reclaim. UI widgets
// must never call connect() themselves — that is how two owners of one radio
// happen.
//
// ─────────────────────────────────────────────────────────────────────────
// FIXES CARRIED FORWARD FROM THE OLD ble_service.dart
// These were each found by debugging real hardware. Re-introducing any of
// them re-introduces a shipped bug, so they are encoded here with the reason:
//
//  1. SYNCHRONOUS STATE FLIP. Session state must change BEFORE the first
//     await of a teardown. Setting `connected = false` after
//     `await sub.cancel()` left two sessions reading as connected for the
//     whole cancel, and a cancel that threw left one connected forever.
//
//  2. NEVER DEFER TO A PENDING RETRY TIMER. A parked Dart timer does not run
//     while Android has the process frozen, so a guard of "skip if a retry
//     timer is active" deadlocked the session: the kick refused to arm
//     because a timer was pending, and the timer could not fire to arm it.
//     An explicit request cancels the timer and acts now.
//
//  3. ONE LIVE LINK. Arming a pending connect for every saved spoon and
//     leaving them armed after one links let the second spoon take the link
//     over later. After a link is established, every other candidate is
//     stood down.
//
//  4. PREFER THE LINK THAT WAS ALREADY LIVE. On resume, reconnect the spoon
//     that was actually streaming rather than racing all saved spoons.
//
//  5. AN EXPLICIT DISCONNECT MUST RE-KICK. Disconnecting the live spoon
//     without re-evaluating left the other spoon un-armed indefinitely.
//
//  6. RESPECT THE RADIO'S TEARDOWN TIME. Samsung/Xiaomi need ~2 s after a
//     GATT close before a connect to the same address stops failing with
//     status 133, and iOS asserts if a connect stream is re-opened too soon.
// ─────────────────────────────────────────────────────────────────────────
//
// THE ONE COUNTER THAT MAKES THIS SAFE
// `_generation` is both the session identity (Rule 3) and the abort token for
// the operation in flight. Every teardown, every superseding request and every
// adapter loss increments it, and every await boundary below re-checks it. If
// a check is missing, an old scan/connect/read can walk into a session that
// belongs to a different spoon — which is the entire class of bug this file
// exists to prevent.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:smartspoon/ble/ble_platform_bridge.dart';
import 'package:smartspoon/ble/candidate_selector.dart';
import 'package:smartspoon/ble/constants.dart';
import 'package:smartspoon/ble/device_authenticator.dart';
import 'package:smartspoon/ble/device_registry.dart';
import 'package:smartspoon/ble/meal_session_guard.dart';
import 'package:smartspoon/ble/models/runtime_models.dart'
    show SpoonEventPacket;
import 'package:smartspoon/ble/models/spoon_models.dart';
import 'package:smartspoon/ble/primary_reclaim_monitor.dart';
import 'package:smartspoon/ble/session_command_queue.dart';
import 'package:smartspoon/ble/telemetry_session.dart';
import 'package:smartspoon/features/devices/domain/spoon_identity.dart'
    show productIdFromGattBytes;

/// The live session's identity. Rule 3: any async callback carrying an older
/// generation is discarded rather than acted on.
class _Session {
  _Session({
    required this.generation,
    required this.nonce,
    required this.remoteId,
    this.record,
  });

  final int generation;
  final String nonce;
  final String remoteId;
  SpoonRecord? record;

  StreamSubscription<BleLinkState>? link;
  StreamSubscription<List<int>>? telemetry;
  StreamSubscription<List<int>>? events;
  StreamSubscription<void>? servicesReset;
  StreamSubscription<List<int>>? ack;

  /// True once the link actually reached `connected`, so a teardown knows
  /// whether the radio owes us the same-address settle time (FIX 6).
  bool linkWasUp = false;

  /// §18.3 / §33 allow ONE controlled resubscribe per session before falling
  /// back to a full teardown. Without the once-guard a spoon that accepts the
  /// subscription and then never notifies would loop forever at full power.
  bool resubscribeUsed = false;

  String? get serial => record?.spoonSerial;
}

/// Why a connect attempt ended. A bool cannot express this: "it failed" and
/// "it failed permanently" and "something better came along" demand three
/// different responses, and collapsing them is how a fallback scan or a retry
/// gets silently skipped.
enum _ConnectOutcome {
  /// Reached STREAMING.
  streaming,

  /// Transport-level failure. The generation was bumped by the teardown, so
  /// the caller must re-read it before continuing with a scan or a retry.
  transient,

  /// Rule 8 — identity/ownership/protocol. No scan, no retry.
  permanent,

  /// A higher-priority request (or an adapter loss) took over. The caller
  /// must do nothing at all; whoever superseded it owns the next step.
  superseded,
}

/// Why a bonding attempt ended. The three failure modes need three different
/// answers, and collapsing them is how a timeout ends up telling the user their
/// phone refused the pairing.
enum _BondOutcome {
  /// The link is encrypted — either it just bonded, or the bond already existed.
  bonded,

  /// The spoon already belongs to a different phone. Permanent until someone
  /// long-holds the pad for 6 seconds.
  spoonOwnedByAnother,

  /// This phone's stack refused, and the stale bond could not be deleted.
  /// Permanent until the user forgets the spoon in system Bluetooth settings.
  phoneRefused,

  /// The stale bond WAS deleted. The link dropped with it, so the caller
  /// should reconnect and pair fresh.
  retryAfterBondCleared,

  /// Nobody refused anything; the handshake just did not finish. Transient.
  incomplete,

  /// The spoon is free to pair, this phone holds no stale key, and the SMP
  /// handshake still failed. That is not a state either side can retry out of
  /// — the two ends disagree about what pairing must provide.
  pairingIncompatible,

  /// A newer request took over mid-bond.
  superseded,
}

/// Outcome of the §14 Add/Claim flow.
enum ClaimOutcome {
  claimed,
  alreadyClaimedByOther,
  identityUnreadable,
  connectFailed,
}

class ClaimResult {
  const ClaimResult(this.outcome, {this.record, this.detail});

  final ClaimOutcome outcome;
  final SpoonRecord? record;
  final String? detail;

  bool get isSuccess => outcome == ClaimOutcome.claimed;

  @override
  String toString() =>
      'ClaimResult(${outcome.name}${detail != null ? ": $detail" : ""})';
}

/// What a user's tap on a saved spoon actually did.
enum SwitchOutcome {
  /// The tapped spoon is streaming.
  streaming,

  /// The tapped spoon was not advertising, so the spoon that WAS streaming was
  /// kept. It needs switching on (double-tap) or bringing closer.
  notNearby,

  /// The tapped spoon answered but reports no owner — it was reset. It needs
  /// pairing again, which only the user may confirm (§15).
  needsRepair,

  /// Queued behind other work, or still connecting; the result arrives through
  /// the ordinary state stream.
  pending,
}

class ConnectionCoordinator extends ChangeNotifier {
  ConnectionCoordinator({
    required DeviceRegistry registry,
    required DeviceAuthenticator authenticator,
    required MealSessionGuard mealGuard,
    required PrimaryReclaimMonitor reclaimMonitor,
    BleTransport? transport,
    CandidateSelector? selector,
    TelemetrySession? telemetry,
    SessionCommandQueue? commandQueue,
    bool? backgroundUsesOsStandby,
  })  : _registry = registry,
        _authenticator = authenticator,
        _mealGuard = mealGuard,
        _reclaim = reclaimMonitor,
        _transport = transport ?? BlePlatformBridge(),
        _selector = selector ?? CandidateSelector(),
        // Both platforms: a pending OS connect is what actually finds a
        // spoon once the app is off screen. Dart timers freeze on iOS, and
        // Android's FGS still cannot mix a scan with autoConnect — the
        // connect stream drops immediately. Scan is the fallback only when
        // there is no cached locator to arm.
        _backgroundUsesOsStandby = backgroundUsesOsStandby ?? true {
    _telemetry = telemetry ?? TelemetrySession();
    // Assigned here rather than in the default constructor call above, so an
    // INJECTED session is wired identically. Without this, passing a session
    // in (a test, or a future per-device session) would silently disable
    // stale-stream recovery — the failure that §18.3 exists to catch.
    _telemetry.onStale = (_) => _onTelemetryStale();
    _telemetry.onFirstTelemetryTimeout = _onFirstTelemetryTimeout;
    _commands = commandQueue ??
        SessionCommandQueue(
          write: _writeCommand,
          canWrite: () => _state == SpoonState.streaming,
        );
    // Design bug #12: the guard has always been able to say "the meal is
    // over", but nothing listened. Hooking it in the constructor means no
    // future code path can forget to.
    _mealGuard.onMealInterrupted = _onMealInterrupted;
  }

  final DeviceRegistry _registry;
  final DeviceAuthenticator _authenticator;
  final MealSessionGuard _mealGuard;
  final PrimaryReclaimMonitor _reclaim;
  final BleTransport _transport;
  final CandidateSelector _selector;
  final bool _backgroundUsesOsStandby;
  late final TelemetrySession _telemetry;
  late final SessionCommandQueue _commands;

  // ── State ────────────────────────────────────────────────────────────────
  SpoonState _state = SpoonState.unknown;
  DisconnectReason? _lastReason;
  _Session? _session;
  int _generation = 0;
  bool _busy = false;
  bool _disposed = false;
  bool _foreground = true;

  /// Completes when the operation in flight is aborted, so its waits end at
  /// once instead of running to their own timeouts. Replaced on every abort.
  ///
  /// Bumping [_generation] only makes an old operation's RESULT irrelevant; it
  /// does not make the operation finish. Before this, a tap on another spoon
  /// queued behind whatever the old attempt happened to be waiting on — a
  /// 2.5 s scan window, a 10 s discovery, an 8 s read, a 60 s bond read — and
  /// that queue is most of why switching spoons felt slow.
  Completer<void> _abortSignal = Completer<void>();

  /// [work], or null the moment the operation in flight is aborted. An error
  /// from [work] still propagates if it arrives first.
  Future<T?> _unlessAborted<T>(Future<T> work) {
    final aborted = _abortSignal.future.then<T?>((_) => null);
    return Future.any<T?>(<Future<T?>>[work, aborted]);
  }

  /// A sleep that an abort cuts short.
  Future<void> _pause(Duration d) =>
      _unlessAborted<void>(Future<void>.delayed(d));

  /// Bite counter last reported by the live spoon, and when it last went up.
  /// Drives [_eatingRecently] — see [BleConstants.backgroundEatingWindow].
  int? _lastBiteCount;
  DateTime? _lastBiteIncreaseAt;
  Timer? _backgroundEatingTimer;

  /// Whether the last unexpected drop was the spoon deliberately closing the
  /// link (switched off) rather than the link timing out (out of range). See
  /// [BleTransport.droppedDeliberately].
  bool _droppedDeliberately = false;

  /// Serial of the spoon a manual switch just refused because it was not
  /// advertising. Read once by [selectSpoon] to report [SwitchOutcome.notNearby].
  String? _switchMissSerial;

  /// Waiters for specific requests, released once that request has run (or
  /// was dropped / replaced). Identity map: two requests are never "equal".
  final Map<ConnectionRequest, Completer<void>> _requestDone =
      Map<ConnectionRequest, Completer<void>>.identity();

  /// Saved spoons that answered with NO owner (reset), and the address they
  /// answered from. §15 forbids re-bonding them automatically; this is what
  /// lets the user do it with one confirmed tap ([reclaimSavedSpoon]).
  final Map<String, String> _resetSpoonAt = <String, String>{};

  /// Rule 9 — reset ONLY after first valid telemetry, never per request.
  int _backoffIndex = 0;
  Timer? _retryTimer;

  ConnectionRequest? _pendingRequest;
  StreamSubscription<BleSighting>? _scanSub;
  StreamSubscription<BleAdapterState>? _adapterSub;
  Timer? _reclaimTimer;
  BleAdapterState _adapter = BleAdapterState.unknown;

  /// FIX 6 — which address the radio last closed, and when.
  String? _lastLinkRemoteId;
  DateTime? _lastLinkClosedAt;

  /// How long a stream cancel may take during teardown before it is
  /// abandoned. Generous enough for a real GATT close, short enough that a
  /// wedged plugin cannot take the connection layer down with it.
  static const Duration _cancelTimeout = Duration(seconds: 3);

  /// True while the user is driving an operation that must run to completion:
  /// Add Spoon today. Background requests queue behind it instead of aborting
  /// it — a pairing the user started must not be cancelled by housekeeping.
  bool _userOperationActive = false;

  /// Devices whose stale phone-side bond we have already tried to delete once
  /// this run. Bounded on purpose — see the pairing-refused branch.
  final Set<String> _bondHealAttempted = <String>{};

  /// §16 — the user asked to forget this spoon. Held so that a disconnect
  /// callback still in flight cannot schedule a reconnect for it, which is the
  /// forget/disconnect race the design calls out.
  final Set<String> _forgetting = <String>{};

  /// Notified when a meal had to be paused because its spoon never came back
  /// (§12.1). The UI shows the "choose another spoon?" prompt from here.
  void Function(String spoonSerial)? onMealPaused;

  /// Every advertisement this coordinator sees, whatever the scan was for.
  ///
  /// §8.4 gives the coordinator sole control of the radio, so the device list
  /// cannot run a scan of its own to work out which saved spoons are in range.
  /// It listens here instead: one scanner, many readers.
  final StreamController<BleSighting> _sightings =
      StreamController<BleSighting>.broadcast();
  Stream<BleSighting> get sightings => _sightings.stream;

  void _publishSighting(BleSighting s) {
    final pid = s.publicDeviceId;
    SpoonRecord? rec = pid.isEmpty ? null : _registry.byPublicDeviceId(pid);
    rec ??= _registry.all.where((r) => r.bleRemoteId == s.remoteId).firstOrNull;
    if (rec != null && s.rssi > BleConstants.rssiTooWeak) {
      _heardAt[rec.spoonSerial] = (remoteId: s.remoteId, at: DateTime.now());
    }
    if (!_sightings.isClosed) _sightings.add(s);
  }

  /// When each saved spoon was last heard advertising, and at which address.
  /// Any scan feeds it, so a spoon the device list just showed "In range" is
  /// connected to without listening for it all over again.
  final Map<String, ({String remoteId, DateTime at})> _heardAt =
      <String, ({String remoteId, DateTime at})>{};

  /// The address [r] was heard at within [BleConstants.recentlyHeardWindow].
  String? _recentlyHeard(SpoonRecord r) {
    final heard = _heardAt[r.spoonSerial];
    if (heard == null) return null;
    return DateTime.now().difference(heard.at) <=
            BleConstants.recentlyHeardWindow
        ? heard.remoteId
        : null;
  }

  /// Raw bytes from the telemetry characteristic, before [TelemetrySession]
  /// classifies them.
  ///
  /// [TelemetrySession] is strict on purpose — it only accepts a full 129-byte
  /// batch, because that is what "a valid packet" has to mean for Rule 2 and
  /// for the stale watchdog. Firmware also sends a 9-byte header-only
  /// heartbeat in low-power mode, which carries a real battery/temperature/bite
  /// reading. Dropping it silently would make a power-saving spoon look dead,
  /// so the raw stream is published alongside the parsed one and the app layer
  /// decodes the short form itself.
  final StreamController<List<int>> _rawTelemetry =
      StreamController<List<int>>.broadcast();
  Stream<List<int>> get rawTelemetry => _rawTelemetry.stream;

  /// Raw bytes from the event characteristic (f00d0007): heater rail bit,
  /// charge state, faults. Empty on firmware that does not expose it.
  final StreamController<List<int>> _events =
      StreamController<List<int>>.broadcast();
  Stream<List<int>> get events => _events.stream;

  SpoonState get state => _state;
  DisconnectReason? get lastDisconnectReason => _lastReason;
  BleAdapterState get adapterState => _adapter;

  /// Whether the app is in the foreground. Callers that need a UI — a
  /// permission dialog, a pairing prompt — must check this first.
  bool get isForeground => _foreground;

  /// Rule 2 / §4 "State rule": [activeSpoon] is non-null only once the spoon
  /// actually reached streaming. A half-connected device lives in
  /// [targetSerial] instead, so the UI can never treat it as usable.
  SpoonRecord? get activeSpoon =>
      _state == SpoonState.streaming ? _session?.record : null;

  /// The spoon this coordinator is working on, or — once the session is gone —
  /// the last one that was actually live.
  ///
  /// The fallback is not cosmetic: `_teardown` nulls `_session`, so on a resume
  /// that follows a dropped link this returned null exactly when the caller
  /// needed it most, and `onAppResumed` lost its preference for the spoon the
  /// user had been using.
  String? get targetSerial => _session?.serial ?? _lastLiveSerial;

  /// Serial of the most recent session that reached a live link. Survives
  /// teardown so [targetSerial] can still answer after a drop.
  String? _lastLiveSerial;

  /// The last spoon that actually STREAMED. Unlike [targetSerial] it never
  /// names a spoon that was only being attempted — a resume must go back to
  /// the spoon the user had, not to the one that was just refused.
  String? get lastLiveSerial => _lastLiveSerial;

  /// The platform locator of the live session, or null. The app layer keys its
  /// per-device state on this because that is the id every screen already
  /// shows; the registry serial remains the identity (§1.2).
  String? get activeRemoteId => _session?.remoteId;

  /// The last locator this coordinator tried, whether or not it worked, and
  /// SURVIVING the teardown that a failure performs.
  ///
  /// Without it a diagnosis is invisible: every failure path tears the session
  /// down before setting the state that explains it, so by the time the app
  /// layer is notified [activeRemoteId] is already null and it has no device to
  /// attach "this spoon belongs to another phone" to. The user then sees a
  /// spinner with no reason — which is the whole problem the owner-status read
  /// exists to solve.
  String? get lastAttemptedRemoteId => _session?.remoteId ?? _lastAttempted;
  String? _lastAttempted;
  TelemetrySession get telemetry => _telemetry;
  SessionCommandQueue get commands => _commands;
  DeviceRegistry get registry => _registry;
  MealSessionGuard get mealGuard => _mealGuard;
  bool get isBusy => _busy;

  /// Whether an OS-managed reconnect is armed and waiting. Callers must not
  /// "help" by requesting a connection: a request disarms it.
  bool get isInStandby => _inStandby;

  /// Whether the 10 Hz telemetry stream is subscribed on the live session.
  @visibleForTesting
  bool get isBulkStreamActive => _session?.telemetry != null;

  void _setState(SpoonState s, {DisconnectReason? reason}) {
    if (_disposed) return;
    if (_state == s && reason == null) return;
    _state = s;
    if (reason != null) _lastReason = reason;
    notifyListeners();
  }

  /// §38 — one line per connection event, carrying generation and reason.
  /// Never logs a claim secret or a raw token (§38's explicit prohibition);
  /// there are none in this layer, and none may be added.
  void _log(String message) => debugPrint('🔵 coord[g$_generation] $message');

  // ── Lifecycle ────────────────────────────────────────────────────────────

  Future<void> initialize({bool autoConnect = true}) async {
    await _registry.load();

    // The listener goes on BEFORE the first adapter question, so a user who
    // toggles Bluetooth during startup is not missed (edge cases #27–#29).
    _adapterSub = _transport.adapterStates.listen(_onAdapterState);

    _adapter = await _transport.waitForResolvedAdapter();
    if (!_applyAdapterState(_adapter)) return;

    // §32 — adopt or clear what the OS already had open before adding a scan
    // of our own on top of it.
    await _reconcileExistingConnections();
    if (_state == SpoonState.streaming) return;

    _startReclaimMonitor();
    if (!autoConnect) return;
    await request(ConnectionRequest(
      reason: ConnectionRequestReason.startupRestore,
    ));
  }

  /// §34 / edge cases #30, #31 — never collapse these into "Bluetooth is off".
  bool _applyAdapterState(BleAdapterState s) {
    if (s != BleAdapterState.ready && _inStandby) {
      // The radio is gone; the arms are meaningless and would be re-armed
      // against a stale adapter when it returns.
      unawaited(_exitStandby());
    }
    switch (s) {
      case BleAdapterState.ready:
        return true;
      case BleAdapterState.poweredOff:
        _setState(SpoonState.bluetoothOff, reason: DisconnectReason.adapterOff);
      case BleAdapterState.unauthorized:
        _setState(SpoonState.permissionDenied,
            reason: DisconnectReason.permissionLost);
      case BleAdapterState.unsupported:
        _setState(SpoonState.unsupported);
      case BleAdapterState.unknown:
        _setState(SpoonState.unknown);
    }
    return false;
  }

  /// Edge cases #27, #28, #29, #30 — the adapter is not a startup question,
  /// it changes under a live session.
  void _onAdapterState(BleAdapterState s) {
    if (_disposed) return;
    final previous = _adapter;
    _adapter = s;
    if (s == previous) return;
    _log('adapter ${previous.name} → ${s.name}');

    if (s != BleAdapterState.ready) {
      // Edge cases #27/#28: a scan or a half-open connect must be abandoned,
      // not left to time out against a radio that is gone. Bumping the
      // generation is what makes every pending completion below inert.
      _abortOperation();
      unawaited(_teardown(s == BleAdapterState.unauthorized
          ? DisconnectReason.permissionLost
          : DisconnectReason.adapterOff));
      _stopReclaimMonitor();
      _applyAdapterState(s);
      return;
    }

    // Edge case #29 — Bluetooth came back.
    if (_state.isUsable) return;
    // Rule 8: a quarantined/incompatible spoon is not fixed by a radio toggle.
    if (_state.isTerminal) return;
    _startReclaimMonitor();
    unawaited(request(ConnectionRequest(
      reason: ConnectionRequestReason.adapterRecovery,
    )));
  }

  /// §32 — reconcile devices this app already holds open.
  ///
  /// flutter_blue_plus reports them ([BleTransport.alreadyConnectedRemoteIds]),
  /// which matters most after iOS state restoration relaunches the app with a
  /// spoon already connected. Starting a scan while the OS still holds a link
  /// from a previous process is exactly the duplicate-connection bug §32
  /// exists to prevent, so the existing link is adopted or closed first.
  Future<void> _reconcileExistingConnections() async {
    final open = await _transport.alreadyConnectedRemoteIds();
    if (open.isEmpty) return;
    _log('reconcile: ${open.length} link(s) already open');

    var adopted = false;

    for (final remoteId in open) {
      final record = _registry.all
          .where((r) => r.bleRemoteId == remoteId && r.enabled)
          .firstOrNull;

      // Not ours, forgotten, or we already adopted one. Either way this link
      // must go: §32 step 6, and Rule 1 — a second live link is not a spare,
      // it is a second owner of a radio that allows one.
      if (record == null || adopted) {
        _log('reconcile: closing stray link $remoteId');
        await _transport.disconnectDevice(remoteId);
        continue;
      }

      _log('reconcile: adopting ${record.spoonSerial}');
      final gen = _generation;
      final outcome = await _connectAndValidate(
        record,
        remoteId,
        ConnectionRequest(
          reason: ConnectionRequestReason.startupRestore,
          targetSerial: record.spoonSerial,
        ),
        gen,
      );
      if (outcome == _ConnectOutcome.streaming) {
        adopted = true;
        continue; // keep going: the remaining links still have to be closed
      }
      if (outcome == _ConnectOutcome.superseded) return;
      // Validation failed on a link that is nonetheless open — close it before
      // moving on, or it lingers exactly like a stray one.
      await _transport.disconnectDevice(remoteId);
    }
  }

  // ── Request entry point (§6) ─────────────────────────────────────────────

  /// The ONLY way to ask for a connection. Priority-aware: a background
  /// fallback can never displace a pending user request (§6).
  Future<void> request(ConnectionRequest req) async {
    if (_disposed) return;

    // FIX 2 — an explicit request acts NOW. A parked timer cannot be trusted
    // to fire (a frozen process never runs it), so cancel it and proceed.
    _retryTimer?.cancel();
    _retryTimer = null;

    if (_busy) {
      if (!req.supersedes(_pendingRequest)) {
        _log('ignoring $req — outranked by ${_pendingRequest ?? "in-flight"}');
        _requestDone.remove(req)?.complete();
        return;
      }
      // The request this one replaces will never run; release its waiter.
      final replaced = _pendingRequest;
      if (replaced != null) _requestDone.remove(replaced)?.complete();
      _pendingRequest = req;

      // A user-initiated operation is NOT abortable by background work. The
      // user is standing in front of the phone with a pairing dialog open;
      // having an auto-reconnect for some other spoon invalidate the
      // generation underneath them produced a bare "superseded" error on
      // screen and a claim that could never finish. Automatic work waits.
      if (_userOperationActive) {
        _log('$req queued — a user-initiated operation is in progress');
        return;
      }

      // Edge case #6 — a manual request arriving during a fallback does not
      // wait politely for the fallback to finish failing. Aborting the
      // in-flight operation is what makes "supersedes" mean something.
      _log('$req supersedes the operation in flight');
      _abortOperation();
      return;
    }

    await _runLoop(req);
  }

  /// Runs [first], then whatever superseded it, until nothing is pending.
  ///
  /// The design's `_runPendingRequestIfAny` (§31): without this drain a
  /// higher-priority request stored during a busy period is remembered and
  /// never executed — the user taps a spoon, the tap outranks the fallback,
  /// and nothing happens (edge cases #5, #6).
  Future<void> _runLoop(ConnectionRequest first) async {
    _busy = true;
    // A fresh abort signal per run: the old one's listeners belong to
    // operations that have finished, and dropping it lets them be collected.
    _abortSignal = Completer<void>();
    var next = first;
    try {
      while (!_disposed) {
        await _run(next);
        _requestDone.remove(next)?.complete();
        final pending = _pendingRequest;
        _pendingRequest = null;
        if (pending == null) break;
        next = pending;
      }
    } finally {
      _busy = false;
      // Nothing is running any more, so a transitional state is a lie the UI
      // will show forever — "Discovering services…" under a card that is not
      // connecting to anything. Land on a state the user can act on.
      if (!_disposed && _state.isTransitional && _session == null) {
        _log('operation ended in ${_state.name} with no session — resting');
        _setState(SpoonState.idle,
            reason: _lastReason ?? DisconnectReason.unknown);
      }
    }
  }

  /// Armed OS-managed reconnects, keyed by platform locator. Non-empty only
  /// while the coordinator is in passive standby.
  final Map<String, StreamSubscription<BleLinkState>> _standby =
      <String, StreamSubscription<BleLinkState>>{};

  /// True once a standby arm has produced a link and is being promoted, so a
  /// second device coming up in the same instant cannot race it.
  bool _standbyResolving = false;

  /// Serial of the spoon whose link just dropped unexpectedly. Consumed by the
  /// next unaddressed fallback so the direct-connect shortcut does not aim at
  /// a spoon that may have just been switched off.
  String? _droppedSerial;

  /// A connect that is currently being awaited by a connect path, so a
  /// supersede can free the run loop instead of waiting out the radio timeout.
  Completer<bool>? _pendingLinkUp;

  /// Cancels the scan and invalidates every in-flight completion.
  void _abortOperation() {
    _generation++;
    // End every abortable wait of the operation in flight right now.
    final signal = _abortSignal;
    _abortSignal = Completer<void>();
    if (!signal.isCompleted) signal.complete();
    _selector.abandon();
    unawaited(_scanSub?.cancel());
    _scanSub = null;
    unawaited(_transport.stopScan());

    // Bumping the generation alone only makes the in-flight connect's RESULT
    // irrelevant — it does not make it finish. Without this, tapping spoon B
    // while a connect to spoon A was in flight waited out the full radio
    // timeout before B was even attempted, because _run was still parked on
    // A's completer. Completing it here hands the loop back at once; the
    // generation check downstream still discards A's outcome.
    final pending = _pendingLinkUp;
    if (pending != null && !pending.isCompleted) {
      pending.complete(false);
    }
    _pendingLinkUp = null;

    // Drop the half-open link too, so the radio is free for the new target.
    final session = _session;
    if (session != null && !session.linkWasUp) {
      unawaited(
          _transport.disconnectDevice(session.remoteId).catchError((_) {}));
    }
  }

  Future<void> _run(ConnectionRequest req) async {
    // A request that arrives before the adapter has answered (start-up) waits
    // for the answer instead of being dropped on the floor.
    if (_adapter == BleAdapterState.unknown) {
      _adapter = await _transport.waitForResolvedAdapter();
    }
    if (_adapter != BleAdapterState.ready) {
      _applyAdapterState(_adapter);
      return;
    }

    // A real request outranks passive waiting. Keep the arm for the spoon this
    // request is about (it may be the very link standby just won, and
    // disarming would drop it), disarm the rest.
    if (_inStandby) {
      final keep = req.targetSerial == null
          ? null
          : _registry.byId(req.targetSerial!)?.bleRemoteId;
      await _exitStandby(keep: keep);
    }

    // Resolve an addressed request against the registry FIRST: §31 refuses a
    // target that is unknown, disabled or being forgotten before it touches
    // the radio.
    SpoonRecord? directed;
    final serial = req.targetSerial;
    if (serial != null && serial.isNotEmpty) {
      directed = _registry.byId(serial);
      if (directed == null || !directed.enabled || _forgetting.contains(serial)) {
        _log('$req: target $serial is not a connectable record');
        _setState(SpoonState.forgotten, reason: DisconnectReason.userForget);
        return;
      }
    } else {
      // §10.1 "if none valid, choose startup target". An unaddressed request
      // is not the same as having no idea which spoon we want.
      // Consume the drop marker: it steers exactly one fallback, so a spoon
      // that dropped once is not permanently denied the fast path.
      final avoid = _droppedSerial;
      _droppedSerial = null;
      // Only a spoon that was SWITCHED OFF gives up the direct shortcut. One
      // that drifted out of range is the spoon the user wants back, and a
      // direct connect is the fastest way to get it.
      directed = _preferredTarget(
          avoidSerial: req.reason == ConnectionRequestReason.fallback &&
                  _droppedDeliberately
              ? avoid
              : null);
    }

    // Rule 5 — the meal gate is checked against the RECORD, before any radio
    // work, so a blocked switch costs nothing and cannot half-happen.
    if (directed != null && !_mealGateAllows(directed.spoonSerial, req)) return;

    // Already streaming what this request asks for? Then there is nothing to
    // do. Everything below tears the session down before rebuilding it, and
    // rebuilding an identical session is pure loss: a visible "reconnecting"
    // blip, a gap in the meal data, and on Android a fresh 133-risk connect.
    // An unaddressed request (startup, refresh, fallback) while a healthy link
    // is live has nothing better to offer either — moving to a *better* spoon
    // is primary reclaim's job, and that always names its target.
    final live = _session;
    if (_state == SpoonState.streaming && live != null) {
      final activeSerial = live.serial;
      final wantsActive = directed == null
          ? req.targetSerial == null
          : directed.spoonSerial == activeSerial;
      if (wantsActive) {
        _log('$req: already streaming ${activeSerial ?? live.remoteId} — no-op');
        return;
      }
    }

    // The spoon the user had, if any — what a refused switch goes back to.
    final previousLive = _state == SpoonState.streaming ? live?.serial : null;

    // MAKE BEFORE BREAK. A tap on another spoon used to tear the live spoon
    // down first and only then discover the tapped one was not there: a 10 s
    // connect timeout, a scan, a retry loop — and the user left with NO spoon
    // where a moment ago they had a working one. So while a spoon is
    // streaming, listen for the tapped one first (the live link stays up) and
    // only let go once it is actually on the air.
    //
    // IN RANGE BEFORE CONNECTING. The same rule for every foreground request:
    // a direct connect to a spoon that is not on the air cannot fail fast — it
    // sat on "Connecting…" for the whole 10 s radio timeout, then scanned, then
    // went back to "Connecting…" for another 10 s, round and round, for a spoon
    // that was switched off in a drawer. Listening first (the answer usually
    // comes in well under a second) means "Connecting…" is only ever shown for
    // a spoon that is actually here; otherwise the screen honestly says
    // "Not connected" while the app keeps looking.
    //
    // Background is left alone: nothing is on screen, iOS hands the wait to
    // the OS (standby), and an Android low-power scan hears a spoon too rarely
    // for a short listen to be a fair test.
    String? presentAt;
    if (directed != null && _foreground) {
      // A session left behind by an operation that was aborted still reads
      // "connecting", and the screen would claim a connect was under way for
      // the whole listen below. Nothing is running on it — clear it first.
      if (_session != null && _state != SpoonState.streaming) {
        await _teardown(DisconnectReason.userSwitch, keepMealGuard: true);
        _setState(SpoonState.idle);
      }
      final cached = directed.bleRemoteId;
      // A link the OS already made (standby win, restoration) is proof enough
      // — and a connected spoon does not advertise, so listening would miss it.
      final alreadyUp = cached != null &&
          (await _transport.alreadyConnectedRemoteIds()).contains(cached);
      if (!alreadyUp) {
        final before = _generation;
        presentAt =
            _recentlyHeard(directed) ?? await _findAdvertising(directed);
        if (before != _generation) return; // a newer request took over
      }
      if (!alreadyUp && presentAt == null) {
        final absent = directed.spoonSerial;
        final manual = req.reason == ConnectionRequestReason.manualConfirmed;
        if (manual) _switchMissSerial = absent;
        if (previousLive != null) {
          // Never drop a working spoon for one nobody can hear.
          _log('$req: $absent not advertising — keeping $previousLive');
          notifyListeners();
          return;
        }
        final others = _registry.enabled
            .where((r) =>
                r.spoonSerial != absent && !_forgetting.contains(r.spoonSerial))
            .isNotEmpty;
        // The resume target is a preference, not a filter (see onAppResumed).
        final flexible = req.targetSerial == null ||
            req.reason == ConnectionRequestReason.resumeRecovery;
        if (flexible && others) {
          // The preferred spoon is not here, but another saved spoon may be:
          // the selection scan finds whichever IS on the air.
          _log('$req: $absent not advertising — looking for the others');
          directed = null;
        } else {
          _log('$req: $absent not advertising — not connecting');
          _setState(SpoonState.idle, reason: DisconnectReason.notFound);
          _scheduleRetry(
            manual
                ? ConnectionRequest(reason: ConnectionRequestReason.fallback)
                : req,
            DisconnectReason.notFound,
          );
          return;
        }
      }
    }

    await _teardown(DisconnectReason.userSwitch, keepMealGuard: true);
    var gen = _generation;

    // §10.2 — a known spoon with a cached locator is connected directly; the
    // scan is the fallback for when that locator has gone stale (edge #20).
    // A presence check that just heard the spoon supplies the fresher address
    // — after a full-erase re-flash that is the only one that answers.
    final directLocator = presentAt ?? directed?.bleRemoteId;
    if (directed != null && directLocator != null) {
      final outcome =
          await _connectAndValidate(directed, directLocator, req, gen);
      switch (outcome) {
        case _ConnectOutcome.streaming:
        case _ConnectOutcome.superseded:
          return;
        case _ConnectOutcome.permanent:
          _returnToPreviousAfterRefusal(
              req, previousLive, directed.spoonSerial);
          return;
        case _ConnectOutcome.transient:
          // The failed attempt tore its own session down, which bumped the
          // generation. Continuing with the stale one would make every check
          // below fail instantly and the scan would never run.
          gen = _generation;
          _log('direct connect to ${directed.spoonSerial} failed — scanning');

          // The cached address is KEPT. A failed connect cannot tell "this
          // spoon is switched off" from "its address changed", and the first
          // is by far the common case: deleting the address after two misses
          // threw away the fast path — and iOS standby's only way to arm —
          // every time the app was opened with the spoon off. A spoon that
          // genuinely moved is found by the scan below on its stable Device ID,
          // and updateAfterValidation replaces the address once identity is
          // proven (§1.2: the locator is a cache, the Device ID is identity).
      }
    }

    final selection = await _scanSelect(req, gen);
    if (gen != _generation) return;
    if (selection == null) {
      _log('$req: no stable candidate (${_selector.lastCommitFailureReason})');
      _setState(SpoonState.idle, reason: DisconnectReason.notFound);
      _scheduleRetry(req, DisconnectReason.notFound);
      return;
    }

    // A scan can surface a spoon the meal gate has not seen yet.
    final chosen = selection.spoonSerial;
    if (chosen != null && !_mealGateAllows(chosen, req)) return;

    final outcome = await _connectAndValidate(
        selection.record!, selection.bleRemoteId, req, gen);
    // Only a transport failure earns a retry: a permanent one is Rule 8, and a
    // superseded one already has a successor in flight.
    if (outcome == _ConnectOutcome.transient) {
      _scheduleRetry(req, _lastReason ?? DisconnectReason.connectTimeout);
    }
    if (outcome == _ConnectOutcome.permanent) {
      _returnToPreviousAfterRefusal(
          req, previousLive, selection.record!.spoonSerial);
    }
  }

  /// Listen for [record] on the air WITHOUT touching the live session or the
  /// published state — the screen keeps showing the spoon that is streaming
  /// while this runs. Returns the address it was heard at, or null.
  Future<String?> _findAdvertising(SpoonRecord record) async {
    final heard = Completer<String?>();
    final sub = _transport.scan(filterByService: !_foreground).listen((s) {
      if (!s.looksLikeSpoon) return;
      _publishSighting(s);
      final byDeviceId = s.publicDeviceId.isNotEmpty &&
          _registry.byPublicDeviceId(s.publicDeviceId)?.spoonSerial ==
              record.spoonSerial;
      final byAddress =
          record.bleRemoteId != null && s.remoteId == record.bleRemoteId;
      if ((byDeviceId || byAddress) &&
          s.rssi > BleConstants.rssiTooWeak &&
          !heard.isCompleted) {
        heard.complete(s.remoteId);
      }
    }, onError: (Object e) => _log('presence scan error $e'));
    try {
      return await _unlessAborted<String?>(heard.future.timeout(
        BleConstants.switchPresenceWindow,
        onTimeout: () => null,
      ));
    } finally {
      await sub.cancel();
    }
  }

  /// A manual switch the SPOON refused (reset, owned elsewhere) must not leave
  /// the user with nothing: go back to the spoon they had. Queued rather than
  /// run, so the run loop drains it the moment this request ends.
  void _returnToPreviousAfterRefusal(
      ConnectionRequest req, String? previous, String refused) {
    if (req.reason != ConnectionRequestReason.manualConfirmed) return;
    if (previous == null || previous == refused) return;
    if (_pendingRequest != null) return; // a newer request is already queued
    _log('switch to $refused refused by the spoon — going back to $previous');
    _pendingRequest = ConnectionRequest(
      reason: ConnectionRequestReason.fallback,
      targetSerial: previous,
    );
  }

  /// §10.1 / §10.2 — which saved spoon an unaddressed request should try
  /// directly, before spending a scan.
  ///
  /// Only ever returns a record with a cached locator, because that is the
  /// whole point: a direct connect to a known address is faster and cheaper
  /// than a scan, and it is the path that keeps working when the spoon is in a
  /// drawer advertising weakly. If it fails, [_run] scans — so a stale locator
  /// costs one failed connect, never a missed spoon (edge case #20).
  ///
  /// The order mirrors Rule 6: the meal's spoon, then the primary, then the
  /// most recently used. It deliberately refuses to guess when several saved
  /// spoons are equally plausible — that is what the §9 scan scoring is for.
  /// The spoon an unaddressed request should aim at, or null to let the scan
  /// decide.
  ///
  /// [avoidSerial] names a spoon whose link just dropped. It is NOT excluded
  /// from the answer — a spoon that briefly drops is usually the one you want
  /// back, and refusing it would fail over to a spoon in another room. What it
  /// does is give up the direct-connect SHORTCUT when other saved spoons
  /// exist: §10.2 treats that shortcut as an optimisation for a spoon known to
  /// be present, and after an unexplained drop that is exactly what we no
  /// longer know. Returning null sends the request to the scan, which is the
  /// only thing that can tell "switched off" from "still on the table" — and
  /// the scan will re-pick the dropped spoon anyway if it is still there,
  /// without first burning a full connect timeout on a dead address.
  SpoonRecord? _preferredTarget({String? avoidSerial}) {
    bool usable(SpoonRecord? r) =>
        r != null &&
        r.enabled &&
        r.bleRemoteId != null &&
        !_forgetting.contains(r.spoonSerial);

    final mealSerial = _mealGuard.mealSpoonSerial;
    if (mealSerial != null) {
      // Rule 5 outranks this entirely: a meal is pinned to its spoon and the
      // shortcut stays, drop or no drop.
      final meal = _registry.byId(mealSerial);
      return usable(meal) ? meal : null;
    }

    if (avoidSerial != null) {
      final alternatives = _registry.enabled
          .where(usable)
          .where((r) => r.spoonSerial != avoidSerial)
          .isNotEmpty;
      if (alternatives) {
        final choice = _preferredTarget();
        if (choice != null && choice.spoonSerial == avoidSerial) return null;
        return choice;
      }
    }

    final primary = _registry.primary;
    if (usable(primary)) return primary;

    final candidates = _registry.enabled
        .where(usable)
        .where((r) => r.lastConnectedAt != null)
        .toList()
      ..sort((a, b) => b.lastConnectedAt!.compareTo(a.lastConnectedAt!));
    if (candidates.isNotEmpty) return candidates.first;

    // No history to go on: one saved spoon is unambiguous, several are not.
    final withLocator = _registry.enabled.where(usable).toList();
    return withLocator.length == 1 ? withLocator.first : null;
  }

  /// Rule 5 / Rule 6 — may [candidateSerial] be connected right now?
  bool _mealGateAllows(String candidateSerial, ConnectionRequest req) {
    final verdict = _mealGuard.evaluate(
      candidateSerial,
      userConfirmed: req.mealSwitchConfirmed,
    );
    switch (verdict) {
      case MealGuardVerdict.noMeal:
      case MealGuardVerdict.allowSameSpoon:
        return true;
      case MealGuardVerdict.blockOtherSpoon:
        // Edge case #15 — never silently. The meal keeps its spoon and the UI
        // is told why nothing happened.
        _log('meal guard blocks $candidateSerial '
            '(meal is on ${_mealGuard.mealSpoonSerial})');
        _setState(SpoonState.blockedByMealGuard);
        return false;
      case MealGuardVerdict.budgetExpired:
        _mealGuard.pauseMealAndNotify();
        _setState(SpoonState.blockedByMealGuard,
            reason: DisconnectReason.mealReconnectExpired);
        return false;
    }
  }

  // ── Selection (§9) ───────────────────────────────────────────────────────

  Future<SpoonSelection?> _scanSelect(ConnectionRequest req, int gen) async {
    final known = _registry.enabled
        .where((r) => !_forgetting.contains(r.spoonSerial))
        .toList(growable: false);
    if (known.isEmpty) return null;

    final mealSerial = _mealGuard.isMealActive ? _mealGuard.mealSpoonSerial : null;
    final primarySerial = _registry.primary?.spoonSerial;

    _selector.beginCollection(SelectionContext(
      mode: SelectionMode.automatic,
      knownSpoons: known,
      manualConfirmedSerial:
          req.reason == ConnectionRequestReason.manualConfirmed
              ? req.targetSerial
              : null,
      activeMealSpoonSerial: mealSerial,
      // Edge case #13 — a deliberate choice keeps outranking the primary for
      // the whole cooldown, not just at the moment it was made.
      manualOverrideSerial: _reclaim.manualOverrideSerial,
      manualOverrideAt: _reclaim.manualOverrideAt,
      // §13 — reclaim is all-or-nothing: get the primary or keep what we have.
      hardTargetSerial: req.reason == ConnectionRequestReason.primaryReclaim
          ? req.targetSerial
          : null,
      // Background scans deliver far fewer advertisements per peripheral, so
      // the two-sighting stability rule has to relax or nothing is ever
      // eligible while the app is not on screen.
      isForeground: _foreground,
    ));

    _setState(SpoonState.scanning);
    var sawPrimary = false;

    await _scanSub?.cancel();
    _scanSub = _transport.scan(filterByService: !_foreground).listen((s) {
      if (gen != _generation) return;
      // §1.3 / edge case #23 — noise is dropped here, before the selector.
      if (!s.looksLikeSpoon) return;
      _publishSighting(s);
      _selector.observe(
        bleRemoteId: s.remoteId,
        // §1.2 — the platform locator is NEVER an identity. An advertisement
        // with no stable id keys on the locator inside the selector, which is
        // correct for §14 provisioning and harmless here because Rule 7 drops
        // anything that does not match a saved record anyway.
        publicDeviceId: s.publicDeviceId,
        rssi: s.rssi,
        displayName: s.name,
      );
      if (primarySerial != null &&
          _registry.byPublicDeviceId(s.publicDeviceId)?.spoonSerial ==
              primarySerial) {
        sawPrimary = true;
        _reclaim.observePrimary(isStable: true);
      }
    }, onError: (Object e) => _log('scan error $e'));

    // User-tapped switch already named the spoon — don't make them wait the
    // full 2.5 s + 8 s primary-collection window.
    final collect = req.reason == ConnectionRequestReason.manualConfirmed
        ? const Duration(milliseconds: 800)
        : BleConstants.candidateCollectionWindow;
    final limit = req.reason == ConnectionRequestReason.manualConfirmed
        ? const Duration(seconds: 4)
        : BleConstants.scanTimeout;

    await _pause(collect);
    if (gen != _generation) return null;

    var selection = _selector.commit();

    if (selection == null && _selector.lastCommitFailureReason != null) {
      final remaining = limit - collect;
      if (remaining > Duration.zero) {
        await _pause(remaining);
        if (gen != _generation) return null;
        selection = _selector.commit(force: true);
      }
    }

    if (!sawPrimary) _reclaim.onPrimaryMissing();

    await _scanSub?.cancel();
    _scanSub = null;
    await _transport.stopScan();

    if (selection != null) {
      _log('selected ${selection.spoonSerial} tier:${selection.tier.name} '
          'score:${selection.score} of ${selection.candidatesConsidered} '
          'runnerUp:${selection.runnerUpScore}');
    }
    // A provisioning-mode record can be null; the automatic path cannot select
    // an unknown device (Rule 7), so guard the cast rather than assume it.
    if (selection != null && selection.record == null) return null;
    return selection;
  }

  // ── Connect + the §10.3 validation pipeline ──────────────────────────────

  Future<_ConnectOutcome> _connectAndValidate(
    SpoonRecord record,
    String remoteId,
    ConnectionRequest req,
    int gen,
  ) async {
    if (gen != _generation) return _ConnectOutcome.superseded;

    // FIX 6 — the radio owes us settle time before this address is usable.
    await _awaitRadioSettle(remoteId);
    if (gen != _generation) return _ConnectOutcome.superseded;

    final nonce = 'n$gen-${DateTime.now().microsecondsSinceEpoch}';
    final session = _Session(
      generation: gen,
      nonce: nonce,
      remoteId: remoteId,
      record: record,
    );
    _session = session;
    _lastAttempted = remoteId;
    _lastBiteCount = null; // a fresh link sets its own bite baseline
    final startedAt = DateTime.now();

    _setState(SpoonState.connecting);
    _log('connect ${record.spoonSerial} @ $remoteId (${req.reason.name})');

    final connected = Completer<bool>();
    _pendingLinkUp = connected;
    session.link = _transport
        .connect(remoteId, timeout: BleConstants.directConnectTimeout)
        .listen((s) {
      // Rule 3 — a callback from a superseded generation is discarded. But
      // "discarded" must not mean "silently swallowed while someone is
      // awaiting it": dropping the `connected` event here left this future
      // pending forever, so _run never returned, the queued request was never
      // drained, and the UI sat on "connecting" until the app was killed.
      if (session.generation != _generation) {
        if (!connected.isCompleted) connected.complete(false);
        return;
      }
      switch (s) {
        case BleLinkState.connected:
          session.linkWasUp = true;
          if (!connected.isCompleted) connected.complete(true);
        case BleLinkState.disconnected:
          if (!connected.isCompleted) {
            connected.complete(false);
          } else {
            _onUnexpectedDisconnect(session);
          }
        case BleLinkState.connecting:
        case BleLinkState.disconnecting:
          break;
      }
    }, onError: (Object e) {
      _log('link error $e');
      if (!connected.isCompleted) connected.complete(false);
    });

    // Hard ceiling. Every path above should complete this, but a connect that
    // hangs must never be able to wedge the coordinator — that failure mode is
    // invisible to the user except as a spinner that never resolves.
    final ok = await connected.future.timeout(
      BleConstants.directConnectTimeout + const Duration(seconds: 5),
      onTimeout: () {
        _log('connect to $remoteId produced no link state — giving up');
        return false;
      },
    );
    if (identical(_pendingLinkUp, connected)) _pendingLinkUp = null;
    if (session.generation != _generation) return _ConnectOutcome.superseded;
    if (!ok) {
      await _teardown(DisconnectReason.connectTimeout);
      _setState(SpoonState.idle, reason: DisconnectReason.connectTimeout);
      return _ConnectOutcome.transient;
    }
    _log('link up in ${DateTime.now().difference(startedAt).inMilliseconds}ms');

    _setState(SpoonState.connected);

    // §10.3 — discovery first, with a timeout, because edge case #44 is a
    // link that connects and then discovers nothing forever.
    _setState(SpoonState.discovering);
    try {
      await _unlessAborted(_transport
          .discoverServices(remoteId)
          .timeout(BleConstants.discoveryTimeout));
    } catch (e) {
      _log('discovery failed: $e');
      await _teardown(DisconnectReason.serviceMissing);
      _setState(SpoonState.idle, reason: DisconnectReason.serviceMissing);
      return _ConnectOutcome.transient;
    }
    if (session.generation != _generation) return _ConnectOutcome.superseded;

    await _unlessAborted(_transport.requestMtu(remoteId));
    if (session.generation != _generation) return _ConnectOutcome.superseded;

    // §10.3 identity → epoch → ownership, then protocol.
    _setState(SpoonState.validatingIdentity);
    final reading = await _readIdentity(session);
    if (session.generation != _generation) return _ConnectOutcome.superseded;

    if (reading == null) {
      // Edge case #45 — a structural read failure is not a transport blip we
      // should hammer; it is a spoon that cannot prove who it is.
      await _teardown(DisconnectReason.gattError);
      _setState(SpoonState.idle, reason: DisconnectReason.gattError);
      return _ConnectOutcome.transient;
    }

    _setState(SpoonState.authenticating);
    final auth =
        _authenticator.validateKnownSpoon(saved: record, reading: reading);
    if (!auth.isAuthorized) {
      // Rule 8 — permanent. Quarantine, never retry.
      _log('auth rejected ${record.spoonSerial}: $auth');
      if (auth.result == AuthResult.requiresReclaim &&
          reading.isClaimed == false) {
        _resetSpoonAt[record.spoonSerial] = remoteId;
      }
      await _teardown(auth.reason ?? DisconnectReason.identityMismatch);
      _setState(
        switch (auth.result) {
          AuthResult.requiresReclaim => SpoonState.requiresReclaim,
          AuthResult.unclaimed => SpoonState.unclaimed,
          _ => SpoonState.quarantined,
        },
        reason: auth.reason,
      );
      return _ConnectOutcome.permanent;
    }

    _setState(SpoonState.validatingProtocol);
    final proto = _authenticator.validateProtocol(reading);
    if (!proto.isAuthorized) {
      await _teardown(DisconnectReason.protocolIncompatible);
      _setState(SpoonState.incompatible,
          reason: DisconnectReason.protocolIncompatible);
      return _ConnectOutcome.permanent;
    }

    // ── Encryption, BEFORE subscribing ───────────────────────────────────
    // The spoon answers identity and owner status over an open link, then says
    // nothing at all on the telemetry characteristic until L2 encryption is up.
    // Subscribing first and waiting is therefore guaranteed to time out on an
    // unbonded link — and because the GATT connection genuinely is established,
    // the spoon's own display says "connected" for the whole of it while the
    // app cycles connecting → awaiting → timeout → retry. Bond first.
    final encrypted = await _ensureEncryptedLink(session, reading);
    if (encrypted != null) return encrypted;

    if (!await _subscribeAndAwaitFirstPacket(session)) {
      // Either the first packet never came (transient — the link is gone and
      // torn down) or the session was superseded mid-subscribe.
      return session.generation != _generation
          ? _ConnectOutcome.superseded
          : _ConnectOutcome.transient;
    }

    // Design fix #14 — the locator cache is written only now, because only now
    // has this address been PROVEN to carry this identity (edge case #59).
    await _registry.updateAfterValidation(
      record.spoonSerial,
      bleRemoteId: remoteId,
      lastConnectedAt: DateTime.now(),
      firmwareVersion: reading.firmwareVersion,
      protocolVersion: reading.protocolMajor,
      // Capability is re-asserted from the DEVICE on every validated connect,
      // so a spoon saved with a wrong name-derived flag self-corrects the
      // first time it connects to capability-reporting firmware. Null (old
      // firmware) leaves the stored flag untouched.
      hasHeater: reading.declaredHasHeater,
    );
    if (session.generation != _generation) return _ConnectOutcome.superseded;

    _commands.bindSession(
      spoonSerial: session.serial ?? remoteId,
      generation: session.generation,
      nonce: session.nonce,
    );

    // Rule 9 — backoff resets HERE and nowhere else.
    _backoffIndex = 0;
    _lastReason = null;
    _mealGuard.onMealSpoonRecovered();
    _lastLiveSerial = record.spoonSerial;
    _setState(SpoonState.streaming);
    _log('STREAMING ${record.spoonSerial} in '
        '${DateTime.now().difference(startedAt).inMilliseconds}ms');
    _startReclaimMonitor();
    unawaited(_dropStrayLinks(keep: remoteId));
    return _ConnectOutcome.streaming;
  }

  /// Rule 1 at the OS: close every GATT link that is not the live session.
  Future<void> _dropStrayLinks({required String keep}) async {
    try {
      final open = await _transport.alreadyConnectedRemoteIds();
      for (final id in open) {
        if (id == keep) continue;
        _log('Rule 1: closing extra OS link $id');
        await _transport.disconnectDevice(id);
      }
    } catch (e) {
      _log('drop stray links failed: $e');
    }
  }

  /// Open a link for the Add-Spoon flow and wait for it to come up.
  ///
  /// Factored out because clearing a stale bond drops the link, and the claim
  /// then has to rebuild it without making the user tap Add again.
  Future<_Session?> _claimReconnect(String bleRemoteId) async {
    await _awaitRadioSettle(bleRemoteId);
    final session = _Session(
      generation: _generation,
      nonce: 'claim-${DateTime.now().microsecondsSinceEpoch}',
      remoteId: bleRemoteId,
    );
    _session = session;
    _lastAttempted = bleRemoteId;
    _setState(SpoonState.connecting);

    final connected = Completer<bool>();
    _pendingLinkUp = connected;
    session.link = _transport
        .connect(bleRemoteId, timeout: BleConstants.userConnectTimeout)
        .listen((s) {
      if (session.generation != _generation) {
        if (!connected.isCompleted) connected.complete(false);
        return;
      }
      if (s == BleLinkState.connected) {
        session.linkWasUp = true;
        if (!connected.isCompleted) connected.complete(true);
      } else if (s == BleLinkState.disconnected && !connected.isCompleted) {
        connected.complete(false);
      }
    }, onError: (Object _) {
      if (!connected.isCompleted) connected.complete(false);
    });

    final linkUp = await connected.future.timeout(
      BleConstants.userConnectTimeout + const Duration(seconds: 5),
      onTimeout: () => false,
    );
    if (identical(_pendingLinkUp, connected)) _pendingLinkUp = null;
    if (!linkUp) return null;
    if (session.generation != _generation) return null;

    _setState(SpoonState.discovering);
    try {
      await _transport
          .discoverServices(bleRemoteId)
          .timeout(BleConstants.discoveryTimeout);
    } catch (e) {
      _log('claim: discovery failed $e');
      return null;
    }
    return session;
  }

  /// Establish the bond and say honestly why it failed.
  ///
  /// ─────────────────────────────────────────────────────────────────────
  /// THE FIRMWARE'S ACTUAL RULE (main.c pairing_accept)
  ///
  ///     if (bond_exists(peer))    -> allow
  ///     if (owner_bond_present)   -> REJECT, latch PAIR_REJECTED
  ///     else                      -> allow
  ///
  /// So a pairing is refused in exactly one situation: the spoon already holds
  /// an owner bond and this phone is not it. Only a 6-second physical
  /// long-hold on the spoon clears that.
  ///
  /// WHICH MEANS: deleting OUR side of the bond while the spoon still holds
  /// ITS side is the one action guaranteed to make a working spoon
  /// unpairable. The phone then has no key, the spoon still has an owner, and
  /// every future attempt hits the reject branch. An earlier version of this
  /// code did exactly that as a "self-heal" and bricked pairing until someone
  /// long-held the pad.
  ///
  /// So [BleTransport.clearBond] is called ONLY when the spoon reports NO
  /// owner — the genuine stale-key case, where the spoon was reset and this
  /// phone is still offering a dead LTK.
  ///
  /// PAIR_REJECTED is cleared on every connect (main.c line ~2730), so it is a
  /// real per-link fact — but it is corroboration, not the primary signal.
  /// ownerPresent and peerBonded are computed live from this connection and
  /// are what the decision is built on.
  /// ─────────────────────────────────────────────────────────────────────
  Future<_BondOutcome> _establishBond(_Session session) async {
    // Abortable: this read can legitimately wait up to a minute for a pairing
    // prompt, and a tap on another spoon must not queue behind it.
    final encrypted =
        await _unlessAborted(_transport.ensureEncryptedLink(session.remoteId));
    if (session.generation != _generation) return _BondOutcome.superseded;
    if (encrypted == true) return _BondOutcome.bonded;

    // Ask the spoon what it thinks, over the open link that still works.
    final after = await _readOwnerFlags(session);
    if (session.generation != _generation) return _BondOutcome.superseded;

    // A read that FAILED is not a spoon reporting "no owner" — it is a spoon
    // we could not ask, most often because Android dropped the ACL when the
    // pairing failed. Defaulting that to false sent the code down the
    // clear-our-bond branch on no evidence at all, which is precisely how a
    // working spoon becomes unpairable. Unknown means retry, never destroy.
    if (after == null) {
      _log('owner status unreadable after a failed bond — treating as '
          'transient, NOT clearing any bond');
      return _BondOutcome.incomplete;
    }

    final ownerPresent = after.ownerPresent;
    final peerBonded = after.peerBonded;

    if (ownerPresent && !peerBonded) {
      // The spoon belongs to a different phone and its single-owner policy
      // will refuse this one forever. Nothing the app can do — and above all,
      // do NOT touch our own bond store here.
      return _BondOutcome.spoonOwnedByAnother;
    }

    if (!ownerPresent) {
      // The spoon has no owner at all, yet encryption failed. If this phone
      // holds a leftover key for a spoon that has been reset, clearing it is
      // safe and usually fixes it — the spoon has nothing to stay in sync
      // with. Ask FIRST, though: telling someone to forget a device that was
      // never in their Bluetooth list wastes their time and hides the real
      // fault.
      final phoneHasKey = await _transport.isBonded(session.remoteId);
      if (session.generation != _generation) return _BondOutcome.superseded;

      if (phoneHasKey && _bondHealAttempted.add(session.remoteId)) {
        final cleared = await _transport.clearBond(session.remoteId);
        _log('spoon has NO owner but this phone holds a key — '
            '${cleared ? "cleared it, retrying" : "could not clear it"}');
        if (cleared) return _BondOutcome.retryAfterBondCleared;
        return _BondOutcome.phoneRefused;
      }

      if (phoneHasKey) return _BondOutcome.phoneRefused;

      // Free spoon, no key on this phone, and pairing still failed. Both ends
      // are willing and the handshake itself is refusing — the ends disagree
      // about the security level pairing has to reach.
      _log('spoon is unowned and this phone holds no key, yet pairing failed '
          '— the two ends disagree on pairing requirements');
      return _BondOutcome.pairingIncompatible;
    }

    // ownerPresent && peerBonded: we ARE the owner and the bond is on both
    // sides. Whatever went wrong is transient — a busy stack, an unanswered
    // prompt, a dropped link mid-handshake. Retry; never delete the bond.
    return _BondOutcome.incomplete;
  }

  /// Bring the link to the encryption level the firmware demands.
  ///
  /// Returns null when the link is usable; otherwise the outcome the caller
  /// must propagate.
  ///
  /// ONLY THE SPOON'S OWN REPORT MAKES A FAILURE PERMANENT. That distinction is
  /// the whole point of reading owner status over the open link: a spoon that
  /// belongs to somebody else refuses every bond forever and retrying is
  /// pointless, but a bond that merely did not complete — a busy Android
  /// stack, a prompt the user has not tapped yet, a bond attempted while the
  /// app was in the background where Android shows a notification instead of a
  /// dialog — is ordinary transient failure. Treating those as permanent parks
  /// the spoon in requiresReclaim, where nothing retries and the user has to
  /// go and fix an app that was never actually broken.
  Future<_ConnectOutcome?> _ensureEncryptedLink(
      _Session session, SpoonIdentityReading reading) async {
    // Already encrypted and owned by us — firmware said so over the open link.
    if (reading.isOwnedByThisPhone == true && reading.isSecured == true) {
      return null;
    }

    _setState(SpoonState.authenticating);
    final outcome = await _establishBond(session);
    if (session.generation != _generation) return _ConnectOutcome.superseded;

    switch (outcome) {
      case _BondOutcome.bonded:
        // Firmware integration note, Android step 4: rediscover services AFTER
        // a NEW bond. Handles discovered over the open link can be stale once
        // the link is encrypted, and a stale handle fails at the moment it is
        // used — during subscribe, where it looks like a spoon that will not
        // stream rather than like a cache problem.
        //
        // Only after a new bond, though. When the spoon already reported this
        // phone as its owner, the bond and the GATT cache that goes with it
        // pre-date this link, and a second full discovery on every reconnect
        // was up to a second and a half of pure delay. A handle that turns out
        // stale anyway still recovers: a subscribe error triggers the
        // controlled rediscovery in _recoverSubscription.
        if (reading.isOwnedByThisPhone != true) {
          try {
            await _unlessAborted(_transport
                .discoverServices(session.remoteId)
                .timeout(BleConstants.discoveryTimeout));
          } catch (e) {
            _log('post-bond rediscovery failed: $e');
          }
        }
        return session.generation == _generation
            ? null
            : _ConnectOutcome.superseded;

      case _BondOutcome.superseded:
        return _ConnectOutcome.superseded;

      case _BondOutcome.spoonOwnedByAnother:
        // Only a 6-second physical long hold on the spoon can clear this.
        _log('encryption refused: ${session.serial} belongs to another phone');
        await _teardown(DisconnectReason.ownershipMismatch);
        _setState(SpoonState.busy, reason: DisconnectReason.ownershipMismatch);
        return _ConnectOutcome.permanent;

      case _BondOutcome.phoneRefused:
        _log('encryption refused: phone-side pairing rejected for '
            '${session.serial}');
        await _teardown(DisconnectReason.ownershipMismatch);
        _setState(SpoonState.requiresReclaim,
            reason: DisconnectReason.ownershipMismatch);
        return _ConnectOutcome.permanent;

      case _BondOutcome.pairingIncompatible:
        _log('pairing requirements incompatible with ${session.serial}');
        await _teardown(DisconnectReason.firmwareIncompatible);
        _setState(SpoonState.incompatible,
            reason: DisconnectReason.firmwareIncompatible);
        return _ConnectOutcome.permanent;

      case _BondOutcome.retryAfterBondCleared:
      case _BondOutcome.incomplete:
        // removeBond drops the link, and an unfinished bond deserves another
        // go. Either way the ordinary retry path rebuilds and pairs fresh.
        _log('bond not established for ${session.serial} '
            '(${outcome.name}) — retrying');
        await _teardown(DisconnectReason.connectTimeout);
        _setState(SpoonState.recovering,
            reason: DisconnectReason.connectTimeout);
        return _ConnectOutcome.transient;
    }
  }

  /// Attach the 10 Hz bulk telemetry characteristic (f00d0002).
  ///
  /// The listener goes on BEFORE notifications start so the first packet cannot
  /// be missed, and `telemetry.start()` arms the deadline first for the same
  /// reason (§10.4, Rule 2).
  void _attachBulkTelemetry(_Session session) {
    _telemetry.start();
    unawaited(session.telemetry?.cancel());
    session.telemetry = _transport
        .subscribe(session.remoteId, BleConstants.telemetryCharacteristicUuid)
        .listen((data) {
      if (session.generation != _generation) return;
      if (!_rawTelemetry.isClosed) _rawTelemetry.add(data);
      _telemetry.handlePacket(data);
      _observeBiteCount(_biteCountIn(data));
    }, onError: (Object e) {
      if (session.generation != _generation) return;
      _log('telemetry stream error: $e');
      unawaited(_recoverSubscription(session, DisconnectReason.servicesReset));
    });
  }

  /// Drop the 10 Hz stream and keep only the low-rate event notify.
  ///
  /// This is the firmware's own instruction: "iOS background: subscribe to
  /// f00d0007 only — do not leave bulk 10 Hz CCC on in background." Ten
  /// notifications a second that nothing is rendering is pure battery cost on
  /// both platforms.
  ///
  /// The stale watchdog is stopped with it, and that is not incidental: events
  /// arrive on change and otherwise only every 30 s, so an 8 s stale timeout
  /// would fire against a perfectly healthy link and drive a resubscribe loop
  /// in the background — the exact opposite of what dropping the stream is for.
  /// The link itself stays up, so the session remains STREAMING.
  Future<void> _enterLowPowerStream() async {
    if (_foreground) return;
    final session = _session;
    if (session == null || session.telemetry == null) return;
    if (_state != SpoonState.streaming) return;
    // Eating right now: keep the full stream — that is the data the product
    // exists for. The eating timer drops it once the bites stop.
    if (_eatingRecently) {
      _log('background: bites still coming — keeping the 10 Hz stream');
      _armBackgroundEatingTimer();
      return;
    }
    // iOS keeps the process alive for bluetooth-central only while a notify
    // CCC is on. If f00d0007 never subscribed, dropping bulk would leave the
    // link silent and iOS would suspend it — the "app running, spoon not
    // connected" screenshot. Keep 10 Hz in that degraded case.
    if (session.events == null) {
      _log('background: keeping bulk stream (no event CCC)');
      return;
    }
    _telemetry.stop();
    final sub = session.telemetry;
    session.telemetry = null;
    try {
      await sub?.cancel().timeout(_cancelTimeout);
    } catch (e) {
      _log('background: dropping bulk stream failed $e');
    }
    _log('background: bulk telemetry off, events only');
    unawaited(_dropStrayLinks(keep: session.remoteId));
  }

  /// Restore the 10 Hz stream — on return to the foreground, or in the
  /// background once the user starts eating.
  void _exitLowPowerStream() {
    final session = _session;
    if (session == null || session.telemetry != null) return;
    if (_state != SpoonState.streaming) return;
    _log('${_foreground ? "foreground" : "background, eating"}: '
        'bulk telemetry back on');
    _attachBulkTelemetry(session);
  }

  bool get _eatingRecently {
    final at = _lastBiteIncreaseAt;
    return at != null &&
        DateTime.now().difference(at) < BleConstants.backgroundEatingWindow;
  }

  /// Bite count from a telemetry batch or heartbeat header, or null when it
  /// is absent or withheld on an unencrypted link.
  static int? _biteCountIn(List<int> raw) {
    const offset = TelemetryPacketLayout.biteCountOffset;
    if (raw.length < offset + 2) return null;
    final value = raw[offset] | (raw[offset + 1] << 8);
    return value == TelemetryPacketLayout.biteCountWithheld ? null : value;
  }

  /// The spoon's own bite counter is the one signal that reaches us in the
  /// background (event notify, within ~2 s of a bite). When it goes UP while
  /// the 10 Hz stream is off, the user is eating with the phone put away —
  /// the one moment continuous IMU data matters — so the stream comes back.
  void _observeBiteCount(int? count) {
    if (count == null) return;
    final previous = _lastBiteCount;
    _lastBiteCount = count;
    // A lower value is a spoon reboot resetting the counter, not eating.
    if (previous == null || count <= previous) return;
    _lastBiteIncreaseAt = DateTime.now();
    if (_foreground) return;
    _exitLowPowerStream();
    _armBackgroundEatingTimer();
  }

  /// While backgrounded with the stream kept on for eating, check every 30 s
  /// and go back to events-only once the bites have stopped.
  void _armBackgroundEatingTimer() {
    if (_backgroundEatingTimer?.isActive ?? false) return;
    _backgroundEatingTimer =
        Timer.periodic(const Duration(seconds: 30), (timer) {
      if (_disposed || _foreground || _session == null) {
        timer.cancel();
        return;
      }
      if (_eatingRecently) return;
      timer.cancel();
      unawaited(_enterLowPowerStream());
    });
  }

  /// §10.4 + Rule 2 — subscribe, then wait for a real packet before READY.
  Future<bool> _subscribeAndAwaitFirstPacket(_Session session) async {
    _setState(SpoonState.subscribing);

    _attachBulkTelemetry(session);

    // §33 / edge case #52 — a firmware update rewrites the GATT database and
    // every cached characteristic handle with it. The platform reports this
    // explicitly, so it no longer has to be inferred from a subscribe error.
    await session.servicesReset?.cancel();
    session.servicesReset =
        _transport.servicesReset(session.remoteId).listen((_) {
      if (session.generation != _generation) return;
      _log('services changed — rediscovering');
      unawaited(_recoverSubscription(session, DisconnectReason.servicesReset));
    }, onError: (Object e) => _log('servicesReset stream unavailable: $e'));

    // Event characteristic. Best-effort: older firmware has no f00d0007, and
    // its absence must not stop the session reaching STREAMING — it only means
    // the heater rail bit is unavailable, which the heater UI already handles.
    await session.events?.cancel();
    session.events = _transport
        .subscribe(session.remoteId, BleConstants.eventCharacteristicUuid)
        .listen((data) {
      if (session.generation != _generation) return;
      if (!_events.isClosed) _events.add(data);
      _observeBiteCount(SpoonEventPacket.tryParse(data)?.biteCount);
    }, onError: (Object e) => _log('event stream unavailable: $e'));

    // §19.2 — only once firmware exposes an ACK characteristic.
    final ackUuid = BleConstants.commandAckCharacteristicUuid;
    if (ackUuid != null) {
      await session.ack?.cancel();
      session.ack =
          _transport.subscribe(session.remoteId, ackUuid).listen((data) {
        if (session.generation != _generation) return;
        _commands.onAckReceived(data);
      }, onError: (Object e) => _log('ack stream error $e'));
    }

    _setState(SpoonState.awaitingFirstTelemetry);
    final gotFirst =
        await _unlessAborted(_telemetry.awaitFirstTelemetry()) ?? false;
    if (session.generation != _generation) return false;
    if (!gotFirst) {
      // Edge case #47 — connected, subscribed, silent. On this firmware that
      // is usually an unencrypted link (see SpoonOwnerFlags), so it is a real
      // failure, not a slow start.
      await _teardown(DisconnectReason.firstTelemetryTimeout);
      _setState(SpoonState.idle,
          reason: DisconnectReason.firstTelemetryTimeout);
      return false;
    }
    return true;
  }

  /// §18.3 / §33 — one controlled resubscribe before a full teardown.
  Future<void> _recoverSubscription(
      _Session session, DisconnectReason reason) async {
    if (session.generation != _generation) return;
    if (session.resubscribeUsed) {
      _log('resubscribe already used — tearing down ($reason)');
      _onUnexpectedDisconnect(session);
      return;
    }
    session.resubscribeUsed = true;
    _log('controlled resubscribe after ${reason.name}');

    // Commands must not be dispatched against handles we are about to
    // replace (§33 "pause command dispatch").
    _commands.invalidateSession(StateError('BLE services reset'));
    _telemetry.stop();
    _telemetry.reset();
    await session.telemetry?.cancel();
    session.telemetry = null;
    await session.events?.cancel();
    session.events = null;
    await session.servicesReset?.cancel();
    session.servicesReset = null;

    _setState(SpoonState.discovering, reason: reason);
    try {
      await _transport
          .discoverServices(session.remoteId)
          .timeout(BleConstants.discoveryTimeout);
    } catch (e) {
      _log('rediscovery failed: $e');
      _onUnexpectedDisconnect(session);
      return;
    }
    if (session.generation != _generation) return;

    if (!await _subscribeAndAwaitFirstPacket(session)) return;
    if (session.generation != _generation) return;

    _commands.bindSession(
      spoonSerial: session.serial ?? session.remoteId,
      generation: session.generation,
      nonce: session.nonce,
    );
    _setState(SpoonState.streaming);
  }

  /// §10.3 — read the spoon's own account of who it is.
  ///
  /// This firmware's stable identity IS the 8-byte hwinfo device id, so serial
  /// and publicDeviceId are the same value; [claimSpoon] is the only writer of
  /// records and writes both from this read, which keeps the authenticator's
  /// comparison honest rather than tautological.
  Future<SpoonIdentityReading?> _readIdentity(_Session session) async {
    String? publicId;
    try {
      final bytes = await _unlessAborted(_transport
          .readCharacteristic(
              session.remoteId, BleConstants.identityCharacteristicUuid)
          .timeout(BleConstants.identityReadTimeout));
      if (bytes == null) return null; // aborted: the caller sees superseded
      publicId = productIdFromGattBytes(bytes);
    } catch (e) {
      _log('identity read failed: $e');
      return null;
    }
    if (publicId == null || publicId.isEmpty) {
      _log('identity read returned no usable device id');
      return null;
    }

    final owner = await _readOwnerFlags(session);

    return SpoonIdentityReading(
      spoonSerial: publicId,
      publicDeviceId: publicId,
      isClaimed: owner?.ownerPresent,
      isOwnedByThisPhone: owner?.peerBonded,
      pairRejected: owner?.pairRejected,
      repairHold6s: owner?.repairHold6s,
      isSecured: owner?.secured,
      declaredHasHeater: owner?.heaterCapability,
    );
  }

  /// Read f00d0006. Unencrypted and optional: older firmware does not expose
  /// it, and a null answer must STAY null so the authenticator skips the
  /// ownership gate instead of inventing a verdict (§2).
  ///
  /// Readable on exactly the links that are broken, which is the point — it is
  /// how the app can explain a silent spoon instead of guessing.
  Future<SpoonOwnerFlags?> _readOwnerFlags(_Session session) async {
    try {
      final bytes = await _unlessAborted(_transport
          .readCharacteristic(
              session.remoteId, BleConstants.ownerStatusCharacteristicUuid)
          .timeout(BleConstants.identityReadTimeout));
      if (bytes == null) return null;
      final owner = SpoonOwnerFlags.tryParse(bytes);
      if (owner != null) _log('owner status: $owner');
      return owner;
    } catch (e) {
      _log('owner status unavailable: $e');
      return null;
    }
  }

  Future<void> _writeCommand(dynamic command) async {
    final session = _session;
    if (session == null) throw StateError('no session');
    await _transport.writeCharacteristic(
      session.remoteId,
      BleConstants.commandCharacteristicUuid,
      (command.payload as List<int>),
    );
  }

  /// FIX 6 — Samsung/Xiaomi need ~2 s after a GATT close before the SAME
  /// address will connect again (status 133); iOS gets a short breath. Only
  /// the remainder is paid, so a slow validation path costs nothing extra,
  /// and an abort (the user tapped another spoon) cuts it short.
  Future<void> _awaitRadioSettle(String remoteId) async {
    final closedAt = _lastLinkClosedAt;
    if (closedAt == null) return;
    final required = _lastLinkRemoteId == remoteId
        ? _transport.sameDeviceReopenDelay
        : _transport.gattReleaseDelay;
    final waited = DateTime.now().difference(closedAt);
    final remaining = required - waited;
    if (remaining <= Duration.zero) return;
    _log('radio settle ${remaining.inMilliseconds}ms before $remoteId');
    await _pause(remaining);
  }

  // ── Teardown (§16 ordering) ──────────────────────────────────────────────

  /// FIX 1 — every piece of state that other code reads is cleared
  /// SYNCHRONOUSLY, before the first await. Only the actual stream cancels are
  /// asynchronous, and each is guarded so a throwing cancel cannot leave the
  /// session looking alive.
  Future<void> _teardown(DisconnectReason reason,
      {bool keepMealGuard = false}) async {
    _generation++; // Rule 3 — invalidate every in-flight callback first.
    _retryTimer?.cancel();
    _retryTimer = null;

    final session = _session;
    if (session == null) return;

    _session = null;
    _commands.invalidateSession(reason);
    _telemetry.stop();
    _setState(SpoonState.disconnecting, reason: reason);
    if (!keepMealGuard && !reason.isIntentional) {
      _mealGuard.onMealSpoonDisconnected();
    }

    if (session.linkWasUp) {
      _lastLinkRemoteId = session.remoteId;
      _lastLinkClosedAt = DateTime.now();
      // NOT _lastLiveSerial: a link that came up and was then refused (a reset
      // spoon, another owner) is not the user's live spoon, and recording it
      // here sent every later resume and standby after the refused one.
      // _connectAndValidate sets it once a session actually streams.
    }

    // Send LL_TERMINATE immediately. Waiting for notify-unsubscribe to do it
    // is what made A→B switch sit on "disconnecting" for seconds.
    unawaited(
        _transport.disconnectDevice(session.remoteId).catchError((_) {}));

    // Cancel in parallel. Sequential 3 s timeouts on five streams made a
    // spoon switch wait up to 15 s before the next connect even started.
    // A user switch only needs the radio free, not a graceful CCC teardown.
    final cancelTimeout = reason == DisconnectReason.userSwitch
        ? const Duration(milliseconds: 400)
        : _cancelTimeout;
    final cancels = <Future<void>>[
      for (final sub in [
        session.telemetry,
        session.events,
        session.servicesReset,
        session.ack,
        session.link,
      ])
        if (sub != null)
          sub.cancel().timeout(cancelTimeout).then<void>((_) {},
              onError: (Object e, StackTrace _) {
            _log('teardown cancel failed $e');
          }),
    ];
    if (cancels.isNotEmpty) await Future.wait(cancels);
  }

  void _onUnexpectedDisconnect(_Session session) {
    if (session.generation != _generation) return;
    final serial = session.serial;
    _droppedSerial = serial;
    _droppedDeliberately =
        _transport.droppedDeliberately(session.remoteId) ?? false;
    final teardown = _teardown(DisconnectReason.connectionLost);
    final afterTeardown = _generation;

    // §16 — a spoon mid-forget must never be reconnected by a disconnect
    // callback that was already in flight when the user tapped Forget.
    if (serial != null && _forgetting.contains(serial)) {
      _setState(SpoonState.forgotten, reason: DisconnectReason.userForget);
      return;
    }
    final mealSpoon =
        _mealGuard.isMealActive && serial == _mealGuard.mealSpoonSerial;
    if (!mealSpoon) {
      _setState(SpoonState.recovering, reason: DisconnectReason.connectionLost);
    }

    // The retry — and above all a background standby arm — must not go in
    // until the dead session is fully torn down. Its link-stream cancel sends
    // a disconnect, and flutter_blue_plus's disconnect() also cancels any
    // PENDING connection to the same address: arming first let that late
    // disconnect kill the arm while the coordinator went on believing it was
    // armed, so a spoon that dropped in the background never came back.
    unawaited(teardown.then((_) {
      // Someone else (resume, a tap, forget) took over while we tore down.
      if (_disposed || _generation != afterTeardown) return;
      _reconnectAfterDrop(serial);
    }));
  }

  void _reconnectAfterDrop(String? serial) {
    // Rule 5 / §12 — during a meal, retry ONLY the meal spoon, within budget.
    if (_mealGuard.isMealActive && serial == _mealGuard.mealSpoonSerial) {
      if (_mealGuard.checkBudgetAndPauseIfExpired()) {
        _setState(SpoonState.blockedByMealGuard,
            reason: DisconnectReason.mealReconnectExpired);
        return;
      }
      _mealGuard.recordReconnectAttempt();
      _scheduleRetry(
        ConnectionRequest(
          reason: ConnectionRequestReason.reconnectSameMealSpoon,
          targetSerial: serial,
        ),
        DisconnectReason.connectionLost,
      );
      return;
    }
    _scheduleRetry(
      ConnectionRequest(reason: ConnectionRequestReason.fallback),
      DisconnectReason.connectionLost,
    );
  }

  void _onTelemetryStale() {
    final session = _session;
    if (session == null) return;
    // §18.3 — a GATT link can be up while the application stream is dead. Try
    // one controlled resubscribe before spending a full reconnect on it.
    _setState(SpoonState.stale, reason: DisconnectReason.staleTelemetry);
    unawaited(_recoverSubscription(session, DisconnectReason.staleTelemetry));
  }

  void _onFirstTelemetryTimeout() {
    // A link that came up but never produced a first packet is dead weight:
    // it holds the radio and the session while delivering nothing. Setting
    // `recovering` and stopping — which is what this used to do — left the
    // coordinator parked on "Reconnecting…" with no retry armed, and only the
    // 60s runtime watchdog ever dug it out. Tear the dead session down and
    // arm the retry here, so recovery starts at the backoff and not a minute
    // later.
    final serial = _session?.serial;
    _setState(SpoonState.recovering,
        reason: DisconnectReason.firstTelemetryTimeout);

    unawaited(() async {
      await _teardown(DisconnectReason.firstTelemetryTimeout);
      if (_disposed) return;

      // Rule 5 / §12 — during a meal the retry stays addressed to the meal
      // spoon and spends the meal budget, exactly as an unexpected disconnect
      // does. Falling back to "any spoon" mid-meal is what Rule 5 forbids.
      if (_mealGuard.isMealActive && serial == _mealGuard.mealSpoonSerial) {
        if (_mealGuard.checkBudgetAndPauseIfExpired()) {
          _setState(SpoonState.blockedByMealGuard,
              reason: DisconnectReason.mealReconnectExpired);
          return;
        }
        _mealGuard.recordReconnectAttempt();
        _scheduleRetry(
          ConnectionRequest(
            reason: ConnectionRequestReason.reconnectSameMealSpoon,
            targetSerial: serial,
          ),
          DisconnectReason.firstTelemetryTimeout,
        );
        return;
      }

      _scheduleRetry(
        ConnectionRequest(reason: ConnectionRequestReason.fallback),
        DisconnectReason.firstTelemetryTimeout,
      );
    }());
  }

  void _onMealInterrupted(String spoonSerial) {
    _log('meal on $spoonSerial paused — reconnect budget spent');
    onMealPaused?.call(spoonSerial);
  }

// ── Passive standby (§11 tail) ───────────────────────────────────────────
  //
  // The active backoff ladder tops out at 30s and then retries FOREVER. In the
  // foreground that is fine — the user is watching and a scan every 30s is the
  // price of being responsive. In the background it is the wrong trade twice
  // over: it burns battery scanning for a spoon that may be switched off for
  // hours, and it does not even work, because a dozing process does not run
  // Dart timers, so the one mechanism paying the cost is also the one most
  // likely to be frozen.
  //
  // Standby hands the problem to the OS instead: one pending connection for
  // the preferred saved spoon. The platform wakes us when that spoon
  // advertises. Arming every saved spoon at once was how two GATT links
  // appeared "connected" at once.
  //
  // Rule 1 starts here: the OS pending-connect is itself a GATT client.
  // Arming every saved spoon lets Android/iOS bring TWO peripherals up at
  // once — the "2 spoons connected" bug. Arm exactly one: meal, last-live,
  // primary, then most recently used.

  bool get _inStandby => _standby.isNotEmpty;

  String? _locatorOf(SpoonRecord r) {
    final id = r.bleRemoteId;
    if (id == null || id.isEmpty) return null;
    return id;
  }

  SpoonRecord? _standbyRecord() {
    bool usable(SpoonRecord? r) =>
        r != null &&
        r.enabled &&
        !_forgetting.contains(r.spoonSerial) &&
        _locatorOf(r) != null;

    SpoonRecord? pick(Iterable<SpoonRecord> pool) {
      final list = pool.where(usable).toList();
      if (list.isEmpty) return null;
      final mealSerial = _mealGuard.mealSpoonSerial;
      if (mealSerial != null) {
        for (final r in list) {
          if (r.spoonSerial == mealSerial) return r;
        }
      }
      final primary = list.where((r) => r.isPrimary);
      if (primary.isNotEmpty) return primary.first;
      list.sort((a, b) {
        final byTime = (b.lastConnectedAt ?? DateTime(0))
            .compareTo(a.lastConnectedAt ?? DateTime(0));
        return byTime != 0 ? byTime : a.spoonSerial.compareTo(b.spoonSerial);
      });
      return list.first;
    }

    final all = _registry.enabled;
    // Rule 5 — during a meal the one standby slot belongs to the meal spoon.
    final mealSerial = _mealGuard.mealSpoonSerial;
    if (mealSerial != null) {
      final meal = _registry.byId(mealSerial);
      if (usable(meal)) return meal;
    }
    // A spoon that SWITCHED ITSELF OFF (clean terminate) is not coming back
    // soon, so the slot goes to another saved spoon and background failover
    // still works. One that only timed out — walked out of range — is the
    // user's own spoon and the one most likely to reappear, so it keeps the
    // slot. Preferring another spoon after ANY drop meant the user's spoon
    // never reconnected in the background after a range loss.
    if (_droppedSerial != null && _droppedDeliberately) {
      final other = pick(all.where((r) => r.spoonSerial != _droppedSerial));
      if (other != null) return other;
    }
    if (_lastLiveSerial != null) {
      final last = _registry.byId(_lastLiveSerial!);
      if (usable(last)) return last;
    }
    return pick(all);
  }

  Future<void> _enterStandby() async {
    if (_disposed) return;
    if (_state == SpoonState.streaming) return;

    final record = _standbyRecord();
    final locator = record == null ? null : _locatorOf(record);
    if (record == null || locator == null) return;

    final gen = _generation;
    if (_standby.length == 1 && _standby.containsKey(locator)) {
      // Already armed for this spoon — re-assert instead of trusting it.
      // Arming is idempotent at the OS, and an arm that something else
      // cancelled underneath us must not be believed forever: that is how
      // background reconnect stayed dead after the disconnect race.
      await _exitStandby(disarm: false);
    } else if (_inStandby) {
      await _exitStandby();
    }
    if (_disposed || gen != _generation || _state == SpoonState.streaming) {
      return;
    }

    _retryTimer?.cancel();
    _retryTimer = null;
    _standbyResolving = false;
    _selector.abandon();
    unawaited(_scanSub?.cancel());
    _scanSub = null;
    unawaited(_transport.stopScan());

    _log('standby: arming OS reconnect for ${record.spoonSerial} @ $locator');
    _standby[locator] = _transport.armAutoConnect(locator).listen(
      (state) {
        if (state == BleLinkState.connected) {
          unawaited(_onStandbyLinkUp(locator, record.spoonSerial));
        }
      },
      onError: (Object e) => _log('standby arm error on $locator: $e'),
    );
  }

  /// Tear standby down. [disarm] false detaches the listeners but leaves the
  /// OS pending connections in place — used when a normal request is about to
  /// take ownership of one of them.
  Future<void> _exitStandby({bool disarm = true, String? keep}) async {
    if (_standby.isEmpty) return;
    final entries = Map<String, StreamSubscription<BleLinkState>>.from(_standby);
    _standby.clear();
    _standbyResolving = false;

    for (final entry in entries.entries) {
      try {
        await entry.value.cancel();
      } catch (e) {
        _log('standby cancel failed: $e');
      }
      if (disarm && entry.key != keep) {
        await _transport.cancelAutoConnect(entry.key);
      }
    }
    _log('standby: disarmed');
  }

  Future<void> _onStandbyLinkUp(String locator, String? serial) async {
    if (_disposed || _standbyResolving) return;
    _standbyResolving = true;
    _log('standby: $locator came up — promoting to a real session');

    // Keep the winner's pending connection and link intact; drop the others so
    // Rule 1 (one active spoon) still holds before any session work starts.
    await _exitStandby(keep: locator);

    if (_disposed) return;
    // The meal's own spoon came back by itself. The reconnect budget exists to
    // stop ACTIVE retries hammering the radio; a link the OS already made
    // costs nothing, and refusing it would strand a live link with no session.
    if (serial != null && serial == _mealGuard.mealSpoonSerial) {
      _mealGuard.onMealSpoonRecovered();
    }
    await request(ConnectionRequest(
      reason: ConnectionRequestReason.fallback,
      targetSerial: serial,
    ));
  }

  // ── Retry (§11, Rule 9) ──────────────────────────────────────────────────

  void _scheduleRetry(ConnectionRequest req, DisconnectReason reason) {
    if (_disposed) return;
    // Rule 8 — permanent failures never enter the retry loop. This asks about
    // THIS failure, not the last one ever seen: a sticky check would leave the
    // app unable to retry anything for the rest of the run after one
    // quarantine.
    if (reason.isPermanent) {
      _log('no retry: ${reason.name} is permanent');
      return;
    }
    if (_state.isTerminal) return;
    if (_adapter != BleAdapterState.ready) return;

    // Background: arm OS pending-connect first. A Dart timer will not run on
    // iOS, and on Android a scan racing autoConnect drops the link. Only if
    // there is no locator to arm do we fall through to the backoff scan.
    //
    // During a meal too: standby arms the meal's spoon (Rule 5 holds), and a
    // Dart retry timer is exactly what does not run while iOS has the app
    // suspended — a mid-meal drop with the phone locked reconnected nothing.
    if (!_foreground && _backgroundUsesOsStandby) {
      final gen = _generation;
      unawaited(() async {
        await _enterStandby();
        if (_disposed || _inStandby || gen != _generation) return;
        _armRetryTimer(req, reason);
      }());
      return;
    }

    _armRetryTimer(req, reason);
  }

  void _armRetryTimer(ConnectionRequest req, DisconnectReason reason) {
    var backoff = BleConstants.fallbackBackoff[
        _backoffIndex.clamp(0, BleConstants.fallbackBackoff.length - 1)];
    // With the user watching, the wait IS the time it takes to notice a spoon
    // that was just switched on — keep it inside the firmware's 30 s
    // fast-advertising window.
    if (_foreground && backoff > BleConstants.foregroundBackoffCap) {
      backoff = BleConstants.foregroundBackoffCap;
    }
    if (_backoffIndex < BleConstants.fallbackBackoff.length - 1) {
      _backoffIndex++;
    }

    _log('retry ${req.reason.name} in ${backoff.inSeconds}s (${reason.name})');
    _retryTimer?.cancel();
    _retryTimer = Timer(backoff, () {
      // Note FIX 2: this timer is best-effort only. A frozen process will not
      // run it — recovery must also be reachable from an explicit request()
      // (resume, adapter on, user action), which cancels this timer.
      unawaited(request(req));
    });
  }

  // ── Primary reclaim (§13, §8.7) ──────────────────────────────────────────

  void _startReclaimMonitor() {
    if (_disposed || _reclaimTimer != null) return;
    _reclaimTimer =
        Timer.periodic(BleConstants.reclaimScanInterval, (_) => unawaited(_reclaimTick()));
  }

  void _stopReclaimMonitor() {
    _reclaimTimer?.cancel();
    _reclaimTimer = null;
    _reclaim.reset();
  }

  /// §37 — reclaim never scans while a healthy fallback is streaming in the
  /// background, and never during a meal. Every gate is asked before the radio
  /// is touched, not after.
  Future<void> _reclaimTick() async {
    if (_disposed || _busy) return;
    if (_state != SpoonState.streaming) return;

    final primary = _registry.primary;
    final active = activeSpoon?.spoonSerial;
    if (!_reclaim.shouldRunReclaimScan(
      appInForeground: _foreground,
      mealActive: _mealGuard.isMealActive,
      primarySerial: primary?.spoonSerial,
      activeSerial: active,
    )) {
      return;
    }
    if (primary == null || !primary.enabled) return;

    // A short, low-duty look for the primary. It must outlast
    // primaryReclaimGrace or the grace could never be satisfied.
    final gen = _generation;
    var seen = false;
    final sub = _transport.scan(filterByService: !_foreground).listen((s) {
      if (gen != _generation) return;
      _publishSighting(s);
      if (s.publicDeviceId.isEmpty) return;
      if (_registry.byPublicDeviceId(s.publicDeviceId)?.spoonSerial !=
          primary.spoonSerial) {
        return;
      }
      seen = true;
      _reclaim.observePrimary(isStable: s.rssi > BleConstants.rssiStable);
    }, onError: (Object e) => _log('reclaim scan error $e'));

    await Future<void>.delayed(BleConstants.reclaimScanWindow);
    await sub.cancel();
    await _transport.stopScan();
    if (gen != _generation || _disposed) return;
    if (!seen) _reclaim.onPrimaryMissing();

    final verdict = _reclaim.evaluate(
      primarySerial: primary.spoonSerial,
      activeSerial: activeSpoon?.spoonSerial,
      mealActive: _mealGuard.isMealActive,
      coordinatorBusy: _busy,
    );
    if (verdict != ReclaimBlockReason.allowed) {
      _log('reclaim blocked: ${verdict.name}');
      return;
    }

    _log('reclaiming primary ${primary.spoonSerial}');
    await request(ConnectionRequest(
      reason: ConnectionRequestReason.primaryReclaim,
      targetSerial: primary.spoonSerial,
    ));
  }

  // ── Public actions ───────────────────────────────────────────────────────

  /// User explicitly picked a spoon. Highest priority (§6) and it records a
  /// manual override so primary reclaim will not fight the choice (§13).
  ///
  /// [mealSwitchConfirmed] must come from a real user confirmation — Rule 5
  /// allows a different spoon during a meal only after one.
  Future<SwitchOutcome> selectSpoon(
    String spoonSerial, {
    bool mealSwitchConfirmed = false,
  }) async {
    _switchMissSerial = null;
    _resetSpoonAt.remove(spoonSerial);
    _reclaim.recordManualOverride(spoonSerial);
    final req = ConnectionRequest(
      reason: ConnectionRequestReason.manualConfirmed,
      targetSerial: spoonSerial,
      mealSwitchConfirmed: mealSwitchConfirmed,
    );
    final done = Completer<void>();
    _requestDone[req] = done;
    await request(req);
    // A tap that arrives while other work is running is only queued, and
    // request() returns at once — answering then said "pending", so the
    // screen never told the user the spoon was not nearby. Wait (bounded)
    // until THIS tap has actually run.
    if (!done.isCompleted) {
      await done.future.timeout(const Duration(seconds: 20), onTimeout: () {});
    }
    _requestDone.remove(req);
    if (_switchMissSerial == spoonSerial) {
      _switchMissSerial = null;
      // The choice did not happen, so it must not keep outranking the primary.
      _reclaim.clearManualOverride();
      return SwitchOutcome.notNearby;
    }
    if (_resetSpoonAt.containsKey(spoonSerial)) {
      _reclaim.clearManualOverride();
      return SwitchOutcome.needsRepair;
    }
    return activeSpoon?.spoonSerial == spoonSerial
        ? SwitchOutcome.streaming
        : SwitchOutcome.pending;
  }

  /// Whether [spoonSerial] was found reset and is waiting for the user to
  /// confirm pairing it again.
  bool needsRepair(String spoonSerial) => _resetSpoonAt.containsKey(spoonSerial);

  /// Pair a saved spoon again after it was reset and reports no owner.
  ///
  /// ONLY from an explicit user confirmation, never automatically: §15 is
  /// right that silently re-bonding a spoon reset to be handed on would be
  /// wrong. With the user saying "yes, this is still my spoon" it is exactly
  /// what Add Spoon does — through the same claim path — keeping the saved
  /// name, primary flag and heater setting, and caching the new address.
  Future<ClaimResult> reclaimSavedSpoon(String spoonSerial) async {
    final record = _registry.byId(spoonSerial);
    if (record == null) {
      return const ClaimResult(ClaimOutcome.connectFailed,
          detail: 'This spoon is no longer saved.');
    }
    final at = _resetSpoonAt[spoonSerial] ?? record.bleRemoteId;
    if (at == null) {
      return const ClaimResult(ClaimOutcome.connectFailed,
          detail: 'Could not find the spoon — bring it closer and try again.');
    }
    final result = await claimSpoon(
      bleRemoteId: at,
      displayName: record.displayName,
      makePrimary: record.isPrimary,
      hasHeater: record.hasHeater,
    );
    if (result.isSuccess) _resetSpoonAt.remove(spoonSerial);
    return result;
  }

  /// FIX 5 — after an explicit disconnect the radio is free, so re-evaluate
  /// immediately instead of leaving the other spoon un-armed.
  Future<void> disconnect() async {
    await _teardown(DisconnectReason.userSwitch);
    _setState(SpoonState.idle);
    await request(ConnectionRequest(reason: ConnectionRequestReason.fallback));
  }

  /// §16 Forget — the ORDER is the design, not a preference.
  ///
  /// Disable first so nothing can re-select the spoon, invalidate the session
  /// so in-flight callbacks are inert, tear the link down, and only then remove
  /// the record. Removing first is the documented race: a disconnect callback
  /// arrives against a registry that no longer knows the spoon and schedules a
  /// reconnect for it anyway (edge case #42).
  Future<void> forgetSpoon(String spoonSerial) async {
    _log('forget $spoonSerial');
    _forgetting.add(spoonSerial);
    try {
      await _registry.disable(spoonSerial);

      final wasActive = _session?.serial == spoonSerial;
      if (wasActive) {
        _abortOperation();
        await _teardown(DisconnectReason.userForget);
      }

      // Disarm before the record is gone, while its locator is still known —
      // a forgotten spoon that keeps an OS pending connection would reconnect
      // itself later with nothing in the registry to explain it.
      final forgottenLocator = _registry.byId(spoonSerial)?.bleRemoteId;
      if (forgottenLocator != null && _standby.containsKey(forgottenLocator)) {
        await _standby.remove(forgottenLocator)?.cancel();
        await _transport.cancelAutoConnect(forgottenLocator);
      }

      await _registry.remove(spoonSerial);
      _reclaim.clearManualOverride();
      // A forgotten spoon must not survive as a resume preference, or
      // onAppResumed would address a record that no longer exists and _run
      // would dead-end on "not a connectable record" instead of falling back.
      if (_lastLiveSerial == spoonSerial) _lastLiveSerial = null;

      if (_mealGuard.mealSpoonSerial == spoonSerial) _mealGuard.endMeal();

      if (wasActive) {
        // FIX 5 — the radio is free; give the remaining spoons a chance
        // instead of leaving the app dark (edge case #43 is the inactive
        // case, which correctly does nothing here).
        _setState(SpoonState.idle, reason: DisconnectReason.userForget);
        await request(
            ConnectionRequest(reason: ConnectionRequestReason.fallback));
      }
    } finally {
      _forgetting.remove(spoonSerial);
    }
  }

  // ── §14 Add / Claim a new spoon ──────────────────────────────────────────

  /// §14 — provisioning scan. Unknown devices ARE returned here, and ONLY
  /// here: Rule 7 keeps them out of every automatic path, so discovering a
  /// stranger's spoon can never turn into connecting to one.
  ///
  /// Does not connect to anything. The user picks from the result and the app
  /// calls [claimSpoon].
  Future<List<ScoredCandidate>> scanForNewSpoons({
    Duration? window,
    void Function(List<ScoredCandidate> candidates)? onCandidateFound,
  }) async {
    if (_adapter != BleAdapterState.ready) return const [];
    // Only a pairing the USER started is protected. Skipping whenever the
    // state merely read "connecting" is how a stale state from an aborted
    // attempt put "Connecting to your spoon…" over "No new devices found" —
    // for a spoon that was not even there — until the 60 s watchdog.
    if (_userOperationActive) {
      _log('provisioning scan skipped (pairing in progress)');
      return const [];
    }
    if (_busy) {
      _abortOperation();
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }
    // Whatever the abort left half-open is dead: nothing is running on it.
    if (_session != null && _state != SpoonState.streaming) {
      await _teardown(DisconnectReason.userSwitch, keepMealGuard: true);
    }
    final keepStreaming = _state == SpoonState.streaming;
    _busy = true;
    final gen = _generation;
    try {
      _selector.beginCollection(SelectionContext(
        mode: SelectionMode.provisioning,
        knownSpoons: _registry.all,
      ));
      if (!keepStreaming) _setState(SpoonState.scanning);

      await _scanSub?.cancel();
      // Add Spoon always runs with the user watching, so it scans UNFILTERED:
      // a spoon on older firmware, or one whose scan response has not arrived
      // yet, still has to appear in that list.
      _scanSub = _transport.scan().listen((s) {
        if (gen != _generation) return;
        if (!s.looksLikeSpoon) return;
        _publishSighting(s);
        _selector.observe(
          bleRemoteId: s.remoteId,
          publicDeviceId: s.publicDeviceId,
          rssi: s.rssi,
          displayName: s.name,
        );
        onCandidateFound?.call(_selector.rankedCandidates());
      }, onError: (Object e) => _log('provisioning scan error $e'));

      await Future<void>.delayed(
          window ?? BleConstants.provisioningScanWindow);

      final ranked = _selector.rankedCandidates();
      await _scanSub?.cancel();
      _scanSub = null;
      await _transport.stopScan();
      _selector.abandon();
      if (!keepStreaming && gen == _generation) {
        _setState(SpoonState.idle);
      }
      _log('provisioning scan found ${ranked.length} candidate(s)'
          '${keepStreaming ? " (session kept streaming)" : ""}');
      return ranked;
    } finally {
      _busy = false;
      _userOperationActive = false;
      // The scan stood automatic reconnect down; hand it back. It listens
      // before connecting, so this cannot put "Connecting…" on screen for a
      // spoon that is not here — and a saved spoon the scan just heard is
      // connected at once. Before, nothing reconnected until the watchdog.
      final pending = _pendingRequest;
      _pendingRequest = null;
      if (!_disposed) {
        if (pending != null) {
          // A tap that arrived during the scan was only queued — nothing else
          // drains it here, so it would have been lost. Run it now.
          unawaited(request(pending));
        } else if (_state != SpoonState.streaming &&
            _registry.enabled.isNotEmpty) {
          unawaited(request(
              ConnectionRequest(reason: ConnectionRequestReason.fallback)));
        }
      }
    }
  }

  /// §14 — connect to a chosen device, prove its identity, and save it.
  ///
  /// A spoon already owned by another account is rejected with no record
  /// written and no telemetry read (edge case #25). On success the record is
  /// saved and the coordinator connects to it through the ordinary validated
  /// path, so a claimed spoon and a restored one reach STREAMING by exactly
  /// the same code.
  Future<ClaimResult> claimSpoon({
    required String bleRemoteId,
    String? displayName,
    bool makePrimary = false,
    bool? hasHeater,
  }) async {
    // The adapter may not have resolved yet — the user can tap Add Spoon a
    // second after opening the app, long before the first adapter callback.
    // Failing fast there reads as "Bluetooth is off" when it is simply not
    // answered yet, so wait for a real answer before deciding.
    if (_adapter != BleAdapterState.ready) {
      _adapter = await _transport.waitForResolvedAdapter();
    }
    if (_adapter != BleAdapterState.ready) {
      _applyAdapterState(_adapter);
      return ClaimResult(
        ClaimOutcome.connectFailed,
        detail: _adapter == BleAdapterState.poweredOff
            ? 'Bluetooth is off — turn it on and try again.'
            : 'Bluetooth is not available on this phone.',
      );
    }
    _busy = true;
    _userOperationActive = true;
    try {
      // Stand down anything automatic first, so the claim starts from a quiet
      // radio rather than racing a reconnect for a different spoon.
      _abortOperation();
      _retryTimer?.cancel();
      _retryTimer = null;
      await _teardown(DisconnectReason.userSwitch, keepMealGuard: true);
      final gen = _generation;
      await _awaitRadioSettle(bleRemoteId);

      var session = await _claimReconnect(bleRemoteId);
      if (session == null || gen != _generation) {
        await _teardown(DisconnectReason.connectTimeout);
        _setState(SpoonState.idle, reason: DisconnectReason.connectTimeout);
        return const ClaimResult(ClaimOutcome.connectFailed);
      }

      // Our OWN teardowns bump the generation, so the supersede check is
      // re-based whenever the claim deliberately rebuilds the link. Otherwise
      // a self-heal the app chose to do reads as somebody cancelling the
      // claim, and the user is told "pairing was interrupted" about it.
      var currentGen = session.generation;

      _setState(SpoonState.validatingIdentity);
      final reading = await _readIdentity(session);
      if (currentGen != _generation) {
        _setState(SpoonState.idle, reason: DisconnectReason.userSwitch);
        return const ClaimResult(ClaimOutcome.connectFailed,
            detail: 'Pairing was interrupted — please try again.');
      }
      if (reading == null) {
        await _teardown(DisconnectReason.identityMismatch);
        _setState(SpoonState.idle, reason: DisconnectReason.identityMismatch);
        return const ClaimResult(ClaimOutcome.identityUnreadable);
      }

      final verdict = _authenticator.validateForClaim(reading);
      if (!verdict.isAuthorized) {
        // §14 — no auto-save, no telemetry, no retry storm.
        await _teardown(DisconnectReason.deviceBusy);
        _setState(SpoonState.busy, reason: DisconnectReason.ownershipMismatch);
        return ClaimResult(ClaimOutcome.alreadyClaimedByOther,
            detail: verdict.detail);
      }

      // Take ownership NOW, while the user is standing in the Add-Spoon flow
      // and a pairing prompt makes sense to them.
      //
      // This is not optional: the spoon only records an owner when a bond is
      // created, and the ordinary connect path refuses to stream from a spoon
      // that reports no owner (§15 — that is what a factory reset looks like).
      // Saving the record without bonding would therefore produce a spoon that
      // is saved, looks paired, and is permanently blocked the moment the user
      // leaves this screen.
      _setState(SpoonState.authenticating);
      var bond = await _establishBond(session);

      // If a stale bond was deleted, the link died with it. Reconnect once and
      // pair fresh — from the user's point of view the Add-Spoon tap is still
      // in progress, and making them tap again for a problem the app just fixed
      // itself would be absurd.
      if (bond == _BondOutcome.retryAfterBondCleared) {
        _log('claim: retrying after clearing the stale bond');
        await _teardown(DisconnectReason.connectTimeout, keepMealGuard: true);
        final retried = await _claimReconnect(bleRemoteId);
        if (retried == null) {
          _setState(SpoonState.idle, reason: DisconnectReason.connectTimeout);
          return const ClaimResult(
            ClaimOutcome.connectFailed,
            detail: 'The spoon dropped while re-pairing — please try again.',
          );
        }
        session = retried;
        currentGen = session.generation;
        bond = await _establishBond(session);
      }

      if (currentGen != _generation && bond != _BondOutcome.bonded) {
        _setState(SpoonState.idle, reason: DisconnectReason.userSwitch);
        return const ClaimResult(ClaimOutcome.connectFailed,
            detail: 'Pairing was interrupted — please try again.');
      }

      if (bond != _BondOutcome.bonded) {
        await _teardown(DisconnectReason.ownershipMismatch);
        _setState(
          bond == _BondOutcome.spoonOwnedByAnother
              ? SpoonState.busy
              : SpoonState.idle,
          reason: DisconnectReason.ownershipMismatch,
        );
        return ClaimResult(
          bond == _BondOutcome.spoonOwnedByAnother
              ? ClaimOutcome.alreadyClaimedByOther
              : ClaimOutcome.connectFailed,
          detail: switch (bond) {
            _BondOutcome.spoonOwnedByAnother =>
              'This spoon is paired to another phone. Hold its pad for '
                  '6 seconds to release it, then add it again.',
            _BondOutcome.phoneRefused =>
              'Your phone is holding an old pairing for this spoon. Forget '
                  '"iSpoon Pro" in system Bluetooth settings, then try again.',
            _BondOutcome.pairingIncompatible =>
              'This spoon refuses the pairing its own firmware asks for. It '
                  'needs a firmware update — no phone can pair with it as it '
                  'is.',
            _ => 'Pairing did not complete — please try again.',
          },
        );
      }

      // Serial and publicDeviceId are the same hwinfo id on this firmware
      // (see _readIdentity); writing both from the same proven read is what
      // keeps the authenticator's later comparison meaningful.
      final record = SpoonRecord(
        spoonSerial: reading.spoonSerial,
        publicDeviceId: reading.publicDeviceId,
        bleRemoteId: bleRemoteId,
        displayName: displayName ?? 'iSpoon',
        claimEpoch: reading.claimEpoch ?? 0,
        isPrimary: makePrimary || _registry.all.isEmpty,
        // Precedence: what the DEVICE declares, then what the caller resolved
        // (stored flag or, on old firmware, the user's answer), then the name
        // as a last resort. The device is first because it is the only source
        // that cannot be wrong — the name guess silently mislabels any
        // renamed spoon.
        hasHeater: reading.declaredHasHeater ??
            hasHeater ??
            (displayName ?? '').toLowerCase().contains('pro'),
        firmwareVersion: reading.firmwareVersion,
        protocolVersion: reading.protocolMajor,
        lastConnectedAt: DateTime.now(),
      );
      await _registry.upsert(record);
      if (record.isPrimary) await _registry.setPrimary(record.spoonSerial);
      _log('claimed ${record.spoonSerial} (primary: ${record.isPrimary})');

      // §14 "disconnect or transition to normal active session" — transition,
      // via the ordinary path so nothing about a fresh claim is special-cased.
      await _teardown(DisconnectReason.userSwitch, keepMealGuard: true);
      _busy = false;
      _userOperationActive = false;
      await selectSpoon(record.spoonSerial);
      return ClaimResult(ClaimOutcome.claimed, record: record);
    } finally {
      _busy = false;
      _userOperationActive = false;
      // Whatever queued behind the claim now gets its turn.
      final pending = _pendingRequest;
      _pendingRequest = null;
      if (pending != null && !_disposed) unawaited(request(pending));
    }
  }

  // ── Meal lifecycle (§12) ─────────────────────────────────────────────────

  /// Binds the meal to the spoon that is actually streaming. Refuses if none
  /// is — a meal with no spoon has nothing to protect and would block every
  /// later connection with a serial that never appears.
  bool startMeal() {
    final serial = activeSpoon?.spoonSerial;
    if (serial == null) return false;
    _mealGuard.startMeal(serial);
    _log('meal started on $serial');
    return true;
  }

  void endMeal() {
    _mealGuard.endMeal();
    _log('meal ended');
    if (_state == SpoonState.blockedByMealGuard) {
      _setState(SpoonState.idle);
      unawaited(request(
          ConnectionRequest(reason: ConnectionRequestReason.fallback)));
    }
  }

  /// §12.2 — the user was asked and chose to continue on a different spoon.
  Future<void> confirmMealSwitch(String spoonSerial) async {
    if (_mealGuard.policy == MealSwitchPolicy.strict) {
      // Strict mode ends the meal here; the meal layer starts a new one once
      // the new spoon is streaming. Segmented mode keeps the meal and lets the
      // analytics layer open a new segment.
      _mealGuard.endMeal();
    }
    await selectSpoon(spoonSerial, mealSwitchConfirmed: true);
  }

  // ── App lifecycle (§20, §21, §37) ────────────────────────────────────────

  /// FIX 4 — on resume prefer the spoon that was actually live.
  ///
  /// [lastLiveSerial] is a preference, not a filter: a spoon that was
  /// streaming moments ago already outranks the others through the §9.3
  /// "used <10 min" row, so passing it does not strand the user when only the
  /// other saved spoon is in range.
  Future<void> onAppResumed({String? lastLiveSerial}) async {
    _foreground = true;
    _backgroundEatingTimer?.cancel();
    _backgroundEatingTimer = null;
    // Standby is a background-only trade. With the user watching, go back to
    // the fast active path.
    await _exitStandby();
    _adapter = await _transport.waitForResolvedAdapter();
    if (!_applyAdapterState(_adapter)) return;
    _startReclaimMonitor();
    if (_state == SpoonState.streaming) {
      _exitLowPowerStream();
      return;
    }
    await request(ConnectionRequest(
      reason: ConnectionRequestReason.resumeRecovery,
      targetSerial: lastLiveSerial,
    ));
  }

  /// §37 — keep a live link; if there is none, hand one saved spoon to the OS
  /// so iOS/Android can reconnect without Dart timers (which freeze in bg).
  void onAppPaused() {
    _foreground = false;
    _stopReclaimMonitor();
    if (_state == SpoonState.streaming) {
      unawaited(_enterLowPowerStream());
      return;
    }
    // An in-flight foreground scan is delivered nothing on iOS once the app
    // is backgrounded (empty service list). Waiting it out is a dead 8 s and
    // then "spoon not connected". Abort and arm reconnect immediately.
    if (_busy || _state.isConnectHandshake || _state == SpoonState.scanning) {
      _abortOperation();
    }
    unawaited(_armBackgroundReconnect());
  }

  /// OS pending-connect when we have a locator; otherwise a service-filtered
  /// scan. Never both — Android drops a connect that races a scan.
  ///
  /// Runs during a meal as well: both standby and the fallback request are
  /// addressed to the meal's spoon, so Rule 5 holds.
  Future<void> _armBackgroundReconnect() async {
    if (_disposed || _state == SpoonState.streaming) return;
    if (_backgroundUsesOsStandby) {
      await _enterStandby();
      if (_disposed || _inStandby) return;
    }
    final mealSerial =
        _mealGuard.isMealActive ? _mealGuard.mealSpoonSerial : null;
    await request(ConnectionRequest(
      reason: mealSerial != null
          ? ConnectionRequestReason.reconnectSameMealSpoon
          : ConnectionRequestReason.fallback,
      targetSerial: mealSerial ?? _lastLiveSerial,
    ));
  }

  /// §16 — tear down the live session. [wipeRegistry] is only for account
  /// deletion; ordinary logout keeps this user's spoon list on disk.
  Future<void> onLogout({bool wipeRegistry = false}) async {
    _abortOperation();
    _stopReclaimMonitor();
    await _teardown(DisconnectReason.userLogout);
    _mealGuard.endMeal();
    _reclaim.clearManualOverride();
    if (wipeRegistry) await _registry.clear();
    _setState(SpoonState.idle);
  }

  @override
  void dispose() {
    _disposed = true;
    _retryTimer?.cancel();
    _reclaimTimer?.cancel();
    _backgroundEatingTimer?.cancel();
    // Armed pending connections outlive the Dart object unless disarmed, so a
    // disposed coordinator would leave the OS holding links nothing owns.
    unawaited(_exitStandby());
    unawaited(_adapterSub?.cancel());
    unawaited(_scanSub?.cancel());
    unawaited(_teardown(DisconnectReason.userLogout));
    unawaited(_sightings.close());
    unawaited(_rawTelemetry.close());
    unawaited(_events.close());
    _telemetry.dispose();
    _commands.dispose();
    unawaited(_transport.dispose());
    super.dispose();
  }
}
