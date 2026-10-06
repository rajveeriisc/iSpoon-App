// command_models.dart — session-bound command envelope.
//
// Follows design §8.6, §19.1 and §19.2.
//
// The central point of §19.1: a Dart queue can drop a command that has not
// started yet, but it CANNOT recall a write already handed to the OS BLE
// stack. So every command carries the session identity that firmware is
// expected to validate. Until firmware does that (see
// FirmwareCapabilities.canRejectStaleCommands) the app-side checks are the
// only defence, and safety-critical commands must not rely on them alone.
library;

/// Why a command finished. Every command completes exactly once.
enum CommandStatus {
  /// Firmware acknowledged it (design §19.2). Only reachable once firmware
  /// exposes an ACK characteristic.
  acknowledged,

  /// Written to the peripheral, but no ACK channel exists to confirm it.
  /// Optimistic — do NOT treat as proof of execution for safety-critical work.
  written,

  /// Expired in the queue before it was written.
  expired,

  /// Its session ended (switch/teardown) before it was written.
  sessionInvalidated,

  /// No ACK within the timeout.
  timedOut,

  /// The write itself failed.
  failed,

  /// Rejected before queueing (not streaming, queue full, unsafe state).
  rejected,
}

extension CommandStatusX on CommandStatus {
  bool get isSuccess =>
      this == CommandStatus.acknowledged || this == CommandStatus.written;

  /// Whether firmware definitely saw it. Only true for a real ACK.
  bool get isConfirmed => this == CommandStatus.acknowledged;
}

/// How long a command stays meaningful (design §19.2 "TTL class").
enum CommandTtlClass {
  /// Must land now or not at all — heater ON, mode switches.
  immediate,

  /// Useful for a few seconds — settings writes.
  shortLived,

  /// Safe whenever it lands — display polarity, cosmetic config.
  durable,
}

extension CommandTtlClassX on CommandTtlClass {
  Duration get ttl => switch (this) {
        CommandTtlClass.immediate => const Duration(seconds: 3),
        CommandTtlClass.shortLived => const Duration(seconds: 10),
        CommandTtlClass.durable => const Duration(seconds: 60),
      };
}

/// One application command, bound to the session that created it.
///
/// Design Rule 4: a command carries spoon serial + connection generation +
/// session nonce + command id + creation time + TTL + expected ACK, so an old
/// command can never affect a new connection.
class SpoonCommand {
  SpoonCommand({
    required this.commandId,
    required this.spoonSerial,
    required this.connectionGeneration,
    required this.sessionNonce,
    required this.payload,
    required this.type,
    this.ttlClass = CommandTtlClass.shortLived,
    this.idempotent = false,
    this.safetyCritical = false,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  final int commandId;
  final String spoonSerial;

  /// Rule 3 — any callback or write from an older generation is ignored.
  final int connectionGeneration;

  /// Firmware-side replay defence once supported; app-side tag until then.
  final String sessionNonce;

  /// Bytes written to the command characteristic.
  final List<int> payload;

  /// Short label for logs/telemetry, e.g. 'heater.on', 'panel.invert'.
  final String type;

  final CommandTtlClass ttlClass;

  /// Only idempotent commands may be retried (design §8.6).
  final bool idempotent;

  /// Design §19.3 — heater safety must never depend on the phone alone. This
  /// flag marks commands whose success must not be assumed from `written`.
  final bool safetyCritical;

  final DateTime createdAt;

  DateTime get expiresAt => createdAt.add(ttlClass.ttl);
  bool get isExpired => DateTime.now().isAfter(expiresAt);

  /// Rule 4 — still addressed to the live session?
  bool isValidFor({
    required String currentSerial,
    required int currentGeneration,
    required String currentNonce,
  }) =>
      spoonSerial == currentSerial &&
      connectionGeneration == currentGeneration &&
      sessionNonce == currentNonce;

  @override
  String toString() =>
      'SpoonCommand($type#$commandId gen:$connectionGeneration '
      '${safetyCritical ? "SAFETY " : ""}ttl:${ttlClass.name})';
}

/// Outcome handed back to the caller. Design §8.6 requires completion to be
/// observable rather than fire-and-forget.
class CommandResult {
  const CommandResult({
    required this.commandId,
    required this.status,
    this.error,
    this.ackPayload,
  });

  final int commandId;
  final CommandStatus status;
  final Object? error;
  final List<int>? ackPayload;

  bool get isSuccess => status.isSuccess;

  /// True only when firmware actually confirmed. Safety-critical callers must
  /// check THIS, not [isSuccess].
  bool get isConfirmed => status.isConfirmed;

  @override
  String toString() =>
      'CommandResult(#$commandId ${status.name}${error != null ? " $error" : ""})';
}
