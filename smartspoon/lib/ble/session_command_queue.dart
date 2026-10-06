// session_command_queue.dart — serialized, session-bound application writes.
//
// Follows "Smart Spoon BLE Final Production Design v3.0" §8.6 (responsibilities),
// §19.1/§19.2/§19.3 (command safety), Rule 3 (generation is authoritative),
// Rule 4 (commands are bound to a session) and edge cases #54–#58.
//
// WHY THIS MODULE EXISTS
// ----------------------
// A characteristic write is not a function call. It is handed to the OS BLE
// stack, which owns it from that moment on. Two consequences shape everything
// below:
//
//   1. Writes must be serialized. flutter_reactive_ble / CoreBluetooth /
//      Android GATT all serialise badly under concurrent writes — the second
//      write either errors or silently replaces the first. So exactly ONE
//      command is in flight at a time, and the rest wait in a bounded queue.
//
//   2. Completion must be observable. The v2 queue was fire-and-forget, which
//      the design lists as bug #24 ("command completion was not observable by
//      the caller and had no application-level ACK/timeout contract").
//      [enqueue] therefore returns a `Future<CommandResult>` that ALWAYS
//      completes exactly once, with a status the caller can branch on.
//
// WHAT THIS MODULE CANNOT DO (design §19.1 — read this before trusting it)
// -----------------------------------------------------------------------
// This queue controls commands *before* they enter the native BLE stack.
// Once [CommandWriter] has been invoked, the write is gone: no Dart code can
// recall it, cancel it, or prevent the peripheral from executing it. Session
// invalidation half a millisecond later does not un-heat a spoon.
//
// So the app-side session checks here are a *filter*, not a guarantee. Real
// protection for stale commands must come from firmware validating
// sessionNonce + commandId (§19.2), which today's firmware does not do — see
// [FirmwareCapabilities.canRejectStaleCommands]. And heater safety must never
// depend on the phone at all (§19.3: firmware owns max temperature, max ON
// time, thermal runaway cutoff, comms watchdog, default-OFF after fault).
//
// This module makes that gap *loud* instead of hiding it:
//   - a successful write without an ACK channel completes as
//     [CommandStatus.written], never [CommandStatus.acknowledged], so
//     `CommandResult.isConfirmed` stays false;
//   - every safety-critical command that finishes unconfirmed is reported to
//     [UnconfirmedSafetyCriticalReporter] together with whether it may already
//     have reached the device, so the app layer can verify out-of-band (read
//     back the heater rail bit from the event characteristic) instead of
//     assuming success.
//
// This file is deliberately BLE-package independent: the actual write is
// injected as a callback, so the queue is unit-testable with no radio and no
// new pubspec dependency.
library;

import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'constants.dart';
import 'models/command_models.dart';

/// Performs the real characteristic write. Injected so this module stays
/// independent of flutter_reactive_ble (design §7 layering) and testable.
///
/// It must complete when the platform reports the write finished, and throw
/// on failure. It is never called concurrently with itself.
typedef CommandWriter = Future<void> Function(SpoonCommand command);

/// Gate for edge case #58 — "heater command during stale session: command
/// layer blocks because not STREAMING/authorized". Rule 2: connected is NOT
/// ready; only `SpoonState.streaming` may be acted on. The coordinator passes
/// a closure over its own state so the queue never has to know about states.
///
/// Checked at enqueue AND again immediately before the write.
typedef CommandGate = bool Function();

/// Optional coalescing hook for edge case #57 ("bounded queue +
/// backpressure/coalescing").
///
/// Coalescing is NOT done automatically: [SpoonCommand] carries no coalescing
/// key, and `type` alone is not a safe one — the queue cannot tell "the newest
/// brightness wins" from an ordered sequence that must all land. So the caller
/// decides. Return true when [incoming] makes still-queued [pending]
/// pointless; [pending] then completes with [CommandStatus.rejected].
///
/// Only commands that have not started yet can be superseded (§19.1).
typedef CommandSupersedes = bool Function(
  SpoonCommand pending,
  SpoonCommand incoming,
);

/// Parses a raw ACK notification into [CommandAck]. Return null if the payload
/// is not a recognisable ACK — unparseable frames are logged and dropped, they
/// never complete a command.
typedef CommandAckParser = CommandAck? Function(List<int> payload);

/// Called whenever a `safetyCritical` command completes without a real
/// firmware ACK (design §19.1/§19.3).
///
/// [mayHaveReachedDevice] is the honest bit: true means the write was already
/// handed to the OS stack, so the spoon may be executing it right now even
/// though the app gave up. The app layer should then verify state out-of-band
/// (event characteristic) or send a compensating OFF — not assume either way.
typedef UnconfirmedSafetyCriticalReporter = void Function(
  SpoonCommand command,
  CommandResult result, {
  required bool mayHaveReachedDevice,
});

/// Injected logger; the BLE layer does not pick a logging package (design §38).
typedef CommandQueueLogger = void Function(String message);

/// A parsed application-level ACK (design §19.2).
class CommandAck {
  const CommandAck({
    required this.commandId,
    required this.accepted,
    this.payload = const [],
    this.reason,
  });

  final int commandId;

  /// False for an explicit NACK — firmware saw the command and refused it
  /// (replayed commandId, wrong nonce, not allowed in current safety state).
  final bool accepted;

  final List<int> payload;
  final String? reason;

  @override
  String toString() =>
      'CommandAck(#$commandId ${accepted ? "ACK" : "NACK"}'
      '${reason != null ? " $reason" : ""})';
}

/// Placeholder parser for the ACK characteristic firmware does not expose yet.
///
/// Today's command envelope is ASCII ("ON 45", "OFF", "INV 1"), so the assumed
/// ACK shape is ASCII too: `ACK <commandId> [detail]` or
/// `NACK <commandId> [reason]`. This is a GUESS — when firmware lands the real format, either
/// replace this function or inject a parser via the constructor. Nothing else
/// in the queue depends on the wire format.
CommandAck? defaultAckParser(List<int> payload) {
  if (payload.isEmpty) return null;
  final text = latin1.decode(payload, allowInvalid: true).trim();
  if (text.isEmpty) return null;

  final parts = text.split(RegExp(r'\s+'));
  final verb = parts.first.toUpperCase();
  final accepted = switch (verb) {
    'ACK' => true,
    'NACK' => false,
    _ => null,
  };
  if (accepted == null || parts.length < 2) return null;

  final id = int.tryParse(parts[1]);
  if (id == null) return null;

  return CommandAck(
    commandId: id,
    accepted: accepted,
    payload: payload,
    reason: parts.length > 2 ? parts.sublist(2).join(' ') : null,
  );
}

/// One queued command plus everything needed to finish it exactly once.
class _PendingCommand {
  _PendingCommand(this.command, this.sessionEpoch);

  final SpoonCommand command;

  /// Which internal session this was accepted under. Distinct from the
  /// coordinator's `connectionGeneration`: it also ticks on invalidate, so a
  /// rebind to the same generation still discards everything (Rule 3).
  final int sessionEpoch;

  final Completer<CommandResult> completer = Completer<CommandResult>();

  /// Attempts made. Only idempotent commands ever exceed 1 (design §8.6).
  int attempts = 0;

  /// Set immediately BEFORE the write call. Once true, §19.1 applies: the
  /// command is beyond recall and may execute on the spoon regardless of what
  /// this queue reports to the caller.
  bool handedToOsStack = false;

  /// Completed by [SessionCommandQueue.onAckReceived] on the future ACK path.
  Completer<CommandAck>? ackWaiter;

  bool get isCompleted => completer.isCompleted;
}

/// Outcome of a single write attempt, before retry policy is applied.
typedef _Attempt = ({
  CommandStatus status,
  Object? error,
  List<int>? ackPayload,
});

/// Serializes application writes for exactly one BLE session (design §8.6).
///
/// Lifecycle, driven by the ConnectionCoordinator:
///
/// ```text
/// STREAMING reached      -> bindSession(serial, generation, nonce)
/// disconnect / switch    -> invalidateSession()
/// coordinator disposed   -> dispose()
/// ```
///
/// Plain class on purpose — no ChangeNotifier, no Flutter import. The UI never
/// listens to this; it awaits [enqueue] and branches on [CommandResult].
class SessionCommandQueue {
  SessionCommandQueue({
    required CommandWriter write,
    FirmwareCapabilities capabilities = FirmwareCapabilities.current,
    CommandGate? canWrite,
    CommandSupersedes? supersedes,
    CommandAckParser ackParser = defaultAckParser,
    UnconfirmedSafetyCriticalReporter? onUnconfirmedSafetyCritical,
    CommandQueueLogger? log,
    int maxAttemptsForIdempotent = 2,
  })  : _write = write,
        _capabilities = capabilities,
        _canWrite = canWrite,
        _supersedes = supersedes,
        _ackParser = ackParser,
        _onUnconfirmed = onUnconfirmedSafetyCritical,
        _log = log ?? _noLog,
        _maxAttemptsForIdempotent =
            maxAttemptsForIdempotent < 1 ? 1 : maxAttemptsForIdempotent;

  static void _noLog(String _) {}

  final CommandWriter _write;
  final FirmwareCapabilities _capabilities;
  final CommandGate? _canWrite;
  final CommandSupersedes? _supersedes;
  final CommandAckParser _ackParser;
  final UnconfirmedSafetyCriticalReporter? _onUnconfirmed;
  final CommandQueueLogger _log;
  final int _maxAttemptsForIdempotent;

  // ── Bound session (Rule 3 / Rule 4) ──────────────────────────────────────
  String? _serial;
  int _generation = -1;
  String? _nonce;
  int _sessionEpoch = 0;

  // ── Queue state ──────────────────────────────────────────────────────────
  final ListQueue<_PendingCommand> _queue = ListQueue<_PendingCommand>();
  final Map<int, _PendingCommand> _awaitingAck = <int, _PendingCommand>{};
  _PendingCommand? _inFlight;
  bool _pumping = false;
  bool _disposed = false;
  int _nextCommandId = 1;

  // ── Introspection (logging/tests/UI diagnostics, design §38) ─────────────

  bool get hasSession => _serial != null && !_disposed;
  String? get boundSerial => _serial;
  int get boundGeneration => _generation;
  String? get boundNonce => _nonce;

  /// Commands waiting to be written. Excludes the one in flight, so at most
  /// [BleConstants.commandQueueMaxDepth] + 1 commands are outstanding.
  int get pendingDepth => _queue.length;

  bool get isBusy => _inFlight != null;
  int? get inFlightCommandId => _inFlight?.command.commandId;
  bool get isDisposed => _disposed;

  /// True once firmware exposes an ACK characteristic. While false the queue
  /// runs in the degraded mode of §19.2: success means "written", never
  /// "acknowledged".
  bool get isAckMode => _capabilities.hasCommandAck;

  /// Monotonic command ids for this app run (design Rule 4 requires one per
  /// command; firmware replay-detection will require them to be unique).
  int nextCommandId() => _nextCommandId++;

  // ── Session binding ──────────────────────────────────────────────────────

  /// Bind to a live session. Call ONLY once the spoon is actually STREAMING
  /// (Rule 2) and authorized — never at `connected`.
  ///
  /// Any leftovers from the previous session are completed with
  /// [CommandStatus.sessionInvalidated] first: edge case #54, "old queued
  /// command after switch — serial/generation/session nonce rejects it".
  void bindSession({
    required String spoonSerial,
    required int generation,
    required String nonce,
  }) {
    if (_disposed) {
      throw StateError('SessionCommandQueue used after dispose()');
    }
    invalidateSession(StateError('BLE session rebound'));
    _serial = spoonSerial;
    _generation = generation;
    _nonce = nonce;
    _log('cmdq: bound session $spoonSerial gen:$generation '
        'epoch:$_sessionEpoch ack:${isAckMode ? "on" : "degraded"}');
  }

  /// End the session. Every outstanding command completes — nothing is left
  /// hanging, ever, because a hung Future in the meal layer looks exactly like
  /// a spoon that is still heating.
  ///
  /// §19.1 honesty: a command already handed to the OS stack is NOT cancelled
  /// here. It completes as [CommandStatus.sessionInvalidated] and is reported
  /// through [UnconfirmedSafetyCriticalReporter] with
  /// `mayHaveReachedDevice: true`, because the spoon may still execute it.
  void invalidateSession([Object? reason]) {
    _sessionEpoch++;
    _serial = null;
    _generation = -1;
    _nonce = null;

    final cause = reason ?? StateError('BLE session invalidated');

    final drained = _queue.toList(growable: false);
    _queue.clear();
    for (final entry in drained) {
      _complete(entry, CommandStatus.sessionInvalidated, error: cause);
    }

    final flying = _inFlight;
    if (flying != null && !flying.isCompleted) {
      if (flying.handedToOsStack) {
        _log('cmdq: WARNING ${flying.command} was already handed to the OS BLE '
            'stack when the session was invalidated — design §19.1: it cannot '
            'be recalled and may still execute on the spoon.');
      }
      _complete(flying, CommandStatus.sessionInvalidated, error: cause);
      // Unblock the ACK wait so the pump does not idle for the whole timeout.
      final waiter = flying.ackWaiter;
      if (waiter != null && !waiter.isCompleted) {
        waiter.completeError(cause);
      }
    }

    _awaitingAck.clear();
    if (drained.isNotEmpty || flying != null) {
      _log('cmdq: invalidated — dropped ${drained.length} queued'
          '${flying != null ? " + 1 in flight" : ""}');
    }
  }

  /// Permanent teardown. Same guarantees as [invalidateSession]; afterwards
  /// [enqueue] rejects instead of queueing.
  void dispose() {
    if (_disposed) return;
    invalidateSession(StateError('SessionCommandQueue disposed'));
    _disposed = true;
  }

  // ── Enqueue ──────────────────────────────────────────────────────────────

  /// Queue a command and observe its outcome (design §8.6, bug #24).
  ///
  /// The returned future ALWAYS completes, exactly once, and never with an
  /// error — failure is data ([CommandResult.status]), so a caller cannot
  /// forget a try/catch and strand a meal.
  ///
  /// Rejected up front (nothing written) with [CommandStatus.rejected] when
  /// there is no session, the gate is closed (#58), the queue is full (#57
  /// backpressure) or the command id is already outstanding.
  Future<CommandResult> enqueue(SpoonCommand command) {
    if (_disposed) {
      return _immediate(
        command,
        CommandStatus.rejected,
        StateError('SessionCommandQueue disposed'),
      );
    }

    // Rule 4 / TTL / gate. Re-checked before the write too — this is only the
    // cheap early-out so a doomed command never occupies queue depth.
    final rejection = _rejectionFor(command);
    if (rejection != null) {
      return _immediate(command, rejection.status, rejection.error);
    }

    // Unique in-flight ids: ACK matching is by commandId, so two outstanding
    // commands sharing one id would make ACKs ambiguous (§19.2 replay rules).
    if (_isOutstanding(command.commandId)) {
      return _immediate(
        command,
        CommandStatus.rejected,
        StateError('commandId ${command.commandId} is already outstanding'),
      );
    }

    // Optional caller-driven coalescing (#57). Only queued, unstarted
    // commands may be superseded.
    final supersedes = _supersedes;
    if (supersedes != null) {
      final victims = _queue
          .where((e) => !e.isCompleted && supersedes(e.command, command))
          .toList(growable: false);
      for (final victim in victims) {
        _queue.remove(victim);
        _log('cmdq: ${victim.command} superseded by $command');
        _complete(
          victim,
          CommandStatus.rejected,
          error: StateError('superseded by command ${command.commandId}'),
        );
      }
    }

    // Bounded queue (#57). A BLE link drains ~one write per connection
    // interval; an unbounded queue under a flood just converts a UI bug into
    // minutes of stale commands landing on the spoon. Reject instead.
    if (_queue.length >= BleConstants.commandQueueMaxDepth) {
      _log('cmdq: BACKPRESSURE queue full (${_queue.length}) — rejecting '
          '$command');
      return _immediate(
        command,
        CommandStatus.rejected,
        StateError(
          'command queue full (${BleConstants.commandQueueMaxDepth})',
        ),
      );
    }

    final entry = _PendingCommand(command, _sessionEpoch);
    _queue.add(entry);
    unawaited(_pump());
    return entry.completer.future;
  }

  // ── Future ACK path (design §19.2) ───────────────────────────────────────

  /// Feed a notification from the command-ACK characteristic.
  ///
  /// Firmware does not expose one yet ([BleConstants.commandAckCharacteristicUuid]
  /// is null and [FirmwareCapabilities.current.hasCommandAck] is false), so
  /// today this is never called. The whole ACK path is written and wired
  /// behind the capability flag so the day firmware ships it, only the flag
  /// and the subscription change — not this file's logic.
  ///
  /// Unknown, unparseable and late ACKs (for a command that already timed out)
  /// are logged and dropped: they must never resurrect a completed command.
  void onAckReceived(List<int> payload) {
    if (!isAckMode) {
      _log('cmdq: ACK payload received while hasCommandAck=false — ignoring. '
          'Flip FirmwareCapabilities.hasCommandAck when firmware ships it.');
      return;
    }
    final ack = _ackParser(payload);
    if (ack == null) {
      _log('cmdq: unparseable ACK payload (${payload.length} bytes) — dropped');
      return;
    }
    final entry = _awaitingAck.remove(ack.commandId);
    if (entry == null) {
      _log('cmdq: $ack has no outstanding command (late or unknown) — dropped');
      return;
    }
    final waiter = entry.ackWaiter;
    if (waiter != null && !waiter.isCompleted) {
      waiter.complete(ack);
    }
  }

  // ── Pump ─────────────────────────────────────────────────────────────────

  /// One command in flight at a time. The loop re-reads [_queue] each turn, so
  /// an [invalidateSession] during an await simply leaves it empty.
  Future<void> _pump() async {
    if (_pumping) return;
    _pumping = true;
    try {
      while (_queue.isNotEmpty) {
        final entry = _queue.removeFirst();
        // Superseded or session-invalidated while it waited.
        if (entry.isCompleted) continue;
        await _run(entry);
      }
    } finally {
      _pumping = false;
    }
  }

  Future<void> _run(_PendingCommand entry) async {
    _inFlight = entry;
    try {
      while (true) {
        final outcome = await _attempt(entry);

        // invalidateSession() may have completed it mid-await (§19.1).
        if (entry.isCompleted) return;

        if (_shouldRetry(entry, outcome.status)) {
          _log('cmdq: retrying idempotent ${entry.command} after '
              '${outcome.status.name} (attempt ${entry.attempts + 1}/'
              '$_maxAttemptsForIdempotent)');
          continue;
        }

        _complete(
          entry,
          outcome.status,
          error: outcome.error,
          ackPayload: outcome.ackPayload,
        );
        return;
      }
    } finally {
      _awaitingAck.remove(entry.command.commandId);
      _inFlight = null;
    }
  }

  Future<_Attempt> _attempt(_PendingCommand entry) async {
    final command = entry.command;
    entry.attempts++;

    // ── THE check that matters (Rule 3, Rule 4, #54) ──────────────────────
    // Not at enqueue time — HERE, immediately before the write. Everything
    // between enqueue and now is asynchronous: the spoon may have dropped, the
    // user may have switched spoons, the meal may have ended. This is the last
    // instant at which the app still has a say (§19.1).
    final rejection = _rejectionFor(command);
    if (rejection != null) {
      return (
        status: rejection.status,
        error: rejection.error,
        ackPayload: null,
      );
    }
    if (entry.sessionEpoch != _sessionEpoch) {
      return (
        status: CommandStatus.sessionInvalidated,
        error: StateError('session epoch changed while queued'),
        ackPayload: null,
      );
    }

    Completer<CommandAck>? ackWaiter;
    if (isAckMode) {
      ackWaiter = Completer<CommandAck>();
      entry.ackWaiter = ackWaiter;
      _awaitingAck[command.commandId] = entry;
    }

    // One budget covers write + ACK, so a peripheral that accepts the write
    // and then goes quiet still bounds the caller (#56).
    final deadline = DateTime.now().add(BleConstants.commandTimeout);

    try {
      // Point of no return. Past this line §19.1 governs: the OS owns it.
      entry.handedToOsStack = true;
      await _write(command).timeout(BleConstants.commandTimeout);
    } on TimeoutException catch (error) {
      _awaitingAck.remove(command.commandId);
      return (status: CommandStatus.timedOut, error: error, ackPayload: null);
    } catch (error) {
      _awaitingAck.remove(command.commandId);
      return (status: CommandStatus.failed, error: error, ackPayload: null);
    }

    if (ackWaiter == null) {
      // Degraded mode (§19.2): the write completed, and that is ALL we know.
      // Deliberately `written`, not `acknowledged`, so CommandResult.isConfirmed
      // stays false and safety-critical callers cannot mistake it for proof.
      return (status: CommandStatus.written, error: null, ackPayload: null);
    }

    final remaining = deadline.difference(DateTime.now());
    if (remaining <= Duration.zero) {
      _awaitingAck.remove(command.commandId);
      return (
        status: CommandStatus.timedOut,
        error: TimeoutException('no ACK budget left', BleConstants.commandTimeout),
        ackPayload: null,
      );
    }

    try {
      final ack = await ackWaiter.future.timeout(remaining);
      return (
        status: ack.accepted ? CommandStatus.acknowledged : CommandStatus.failed,
        error: ack.accepted ? null : StateError('NACK: ${ack.reason ?? "refused"}'),
        ackPayload: ack.payload,
      );
    } on TimeoutException catch (error) {
      // #56 — ACK never returned. The write itself succeeded, so the command
      // may well have executed; the caller is told `timedOut`, not `written`,
      // because in ACK mode silence is a fault worth surfacing.
      return (status: CommandStatus.timedOut, error: error, ackPayload: null);
    } catch (error) {
      // invalidateSession() error-completed the waiter.
      return (
        status: CommandStatus.sessionInvalidated,
        error: error,
        ackPayload: null,
      );
    } finally {
      _awaitingAck.remove(command.commandId);
      entry.ackWaiter = null;
    }
  }

  // ── Policy helpers ───────────────────────────────────────────────────────

  /// Design §8.6: "optional retries only for idempotent commands".
  ///
  /// A non-idempotent command that timed out may or may not have landed
  /// (§19.1) — repeating it could double-apply. Those fail cleanly instead.
  bool _shouldRetry(_PendingCommand entry, CommandStatus status) {
    final command = entry.command;
    if (!command.idempotent) return false;
    if (entry.attempts >= _maxAttemptsForIdempotent) return false;
    if (status != CommandStatus.failed && status != CommandStatus.timedOut) {
      return false;
    }
    // A retry is a new write: it must still be in-session and in-TTL, which
    // _attempt re-checks anyway. Bailing early keeps the logs honest.
    if (command.isExpired) return false;
    if (entry.sessionEpoch != _sessionEpoch) return false;
    return _rejectionFor(command) == null;
  }

  /// Everything that stops a command from being written, in priority order.
  /// Returns null when the command may go out right now.
  ({CommandStatus status, Object error})? _rejectionFor(SpoonCommand command) {
    final serial = _serial;
    final nonce = _nonce;
    if (serial == null || nonce == null) {
      return (
        status: CommandStatus.rejected,
        error: StateError('no bound BLE session'),
      );
    }

    // Rule 4 / #54 — an old command must never reach a new connection.
    if (!command.isValidFor(
      currentSerial: serial,
      currentGeneration: _generation,
      currentNonce: nonce,
    )) {
      return (
        status: CommandStatus.sessionInvalidated,
        error: StateError(
          'command bound to ${command.spoonSerial}/gen ${command.connectionGeneration}, '
          'session is $serial/gen $_generation',
        ),
      );
    }

    // TTL (§19.2). An expired command is dropped, never written: a heater ON
    // that sat in a queue for 12 s is not what the user asked for any more.
    if (command.isExpired) {
      return (
        status: CommandStatus.expired,
        error: StateError('TTL ${command.ttlClass.name} expired at '
            '${command.expiresAt.toIso8601String()}'),
      );
    }

    // #58 — not STREAMING / not authorized.
    final gate = _canWrite;
    if (gate != null && !gate()) {
      return (
        status: CommandStatus.rejected,
        error: StateError('spoon is not in a state that accepts commands'),
      );
    }

    return null;
  }

  bool _isOutstanding(int commandId) =>
      _inFlight?.command.commandId == commandId ||
      _queue.any((e) => e.command.commandId == commandId && !e.isCompleted);

  // ── Completion ───────────────────────────────────────────────────────────

  Future<CommandResult> _immediate(
    SpoonCommand command,
    CommandStatus status,
    Object? error,
  ) {
    final result = CommandResult(
      commandId: command.commandId,
      status: status,
      error: error,
    );
    _log('cmdq: $command -> ${status.name}${error != null ? " ($error)" : ""}');
    _reportIfUnconfirmed(command, result, mayHaveReachedDevice: false);
    return Future<CommandResult>.value(result);
  }

  /// The single place a command finishes. Idempotent by design: session
  /// invalidation and the pump can race, and completing twice would throw.
  void _complete(
    _PendingCommand entry,
    CommandStatus status, {
    Object? error,
    List<int>? ackPayload,
  }) {
    if (entry.isCompleted) return;

    final result = CommandResult(
      commandId: entry.command.commandId,
      status: status,
      error: error,
      ackPayload: ackPayload,
    );
    _awaitingAck.remove(entry.command.commandId);

    _log('cmdq: ${entry.command} -> ${status.name} '
        '(attempt ${entry.attempts})${error != null ? " $error" : ""}');
    _reportIfUnconfirmed(
      entry.command,
      result,
      mayHaveReachedDevice: entry.handedToOsStack,
    );

    entry.completer.complete(result);
  }

  /// Design §19.1/§19.3 surfacing.
  ///
  /// `written` is a success for ordinary commands and NOT a confirmation for
  /// safety-critical ones. Rather than quietly returning an optimistic result,
  /// the queue tells the app layer every time a safety-critical command ends
  /// unconfirmed — including the case where the write may already have reached
  /// the spoon — so heater state can be verified or forced OFF out-of-band.
  void _reportIfUnconfirmed(
    SpoonCommand command,
    CommandResult result, {
    required bool mayHaveReachedDevice,
  }) {
    if (!command.safetyCritical || result.isConfirmed) return;

    _log('cmdq: SAFETY-CRITICAL $command completed ${result.status.name} '
        'WITHOUT firmware ACK (hasCommandAck=${_capabilities.hasCommandAck}); '
        'mayHaveReachedDevice=$mayHaveReachedDevice — design §19.1: this is '
        'not proof of execution, verify device state independently (§19.3).');

    _onUnconfirmed?.call(
      command,
      result,
      mayHaveReachedDevice: mayHaveReachedDevice,
    );
  }
}
