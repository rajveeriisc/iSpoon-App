// telemetry_session.dart — telemetry integrity for one connected spoon.
//
// Follows "Smart Spoon BLE Final Production Design v3.0":
//
//   §8.5  TelemetrySession responsibilities: parse header, deduplicate,
//         handle rollover, count gaps, detect stale stream, signal first
//         valid telemetry.
//   §18.2 Sequence rollover — 65534 → 65535 → 0 → 1 MUST be valid, so the
//         comparison is modulo arithmetic, never `newSeq <= oldSeq`.
//   §18.3 Stale connection — a GATT link can be alive while telemetry is
//         dead. This module only *reports* that; §18.3's "resubscribe or
//         full teardown" decision belongs to the ConnectionCoordinator.
//   §10.4 First-notification rule — attach the listener BEFORE
//         setNotifyValue(true). Concretely: call [TelemetrySession.start]
//         first, then subscribe, then feed every notification into
//         [TelemetrySession.handlePacket]. Rule 2 (§3) says connected is not
//         READY; READY is gated on [awaitFirstTelemetry] completing true.
//   §36   Edge cases #47 (first telemetry never arrives), #48 (telemetry
//         stops while GATT stays connected), #49 (duplicate packet),
//         #50 (sequence wraps 65535 → 0), #51 (packet gap).
//
// WHAT THIS MODULE DELIBERATELY DOES NOT DO
//
//   - It never disconnects, resubscribes or changes SpoonState. It emits
//     signals; the coordinator owns recovery policy (§18.3, §36 #47/#48).
//   - It holds no BLE package import, exactly like spoon_models.dart, so it
//     is unit-testable with plain `dart test` and no Flutter binding.
//
// THE PACKET IT ACTUALLY PARSES
//
// Today's firmware (iSpoon Pro batched protocol, see
// features/devices/domain/services/mcu_ble_service.dart) sends 129 bytes,
// little-endian, with NO header of the shape §18.1 recommends: no protocol
// version, no session nonce, no sequence number, no flags, no checksum.
//
//   [0]      battery_pct  uint8      (>100 = unknown)
//   [1-2]    temp_c100    int16 LE   (degC * 100, -32768 = unavailable)
//   [3-6]    ts_ms        uint32 LE  (device uptime of the FIRST sample)
//   [7-8]    bite_count   uint16 LE  (absolute; 0xFFFF = withheld)
//   [9..128] 10 x 12-byte IMU sample:
//              ax, ay, az int16 LE (milli-g, 1000 = 1 g)
//              gx, gy, gz int16 LE (0.1 deg/s per LSB, firmware >= 2.1.11)
//
// So §18.2's ordering is implemented against `ts_ms` in a degraded mode, and
// the sequence path stays behind FirmwareCapabilities.hasTelemetrySequence.
// See [TelemetryOrderingSignal] and [orderingSignal] for the consequences.
library;

import 'dart:async';
import 'dart:typed_data';

import 'constants.dart';

// ─────────────────────────────────────────────────────────────────────────
// §18.2 — rollover-correct comparison helpers.
//
// These are top-level and pure ON PURPOSE: the rollover rule is the single
// most bug-prone line in the whole BLE layer, so it must be unit-testable
// without constructing a session, a timer or a BLE stack.
//
// WHY `%` AND NOT `&`: `& 0xFFFF` only works for a 16-bit space, and
// `& 0xFFFFFFFF` is silently wrong on the web where bitwise operations are
// 32-bit signed. `%` with a positive divisor is non-negative in Dart for
// negative dividends ((-1) % 65536 == 65535), which is exactly the wrap we
// want, and it generalises to any modulus.
// ─────────────────────────────────────────────────────────────────────────

/// uint16 sequence space — the §18.2 example (65534 → 65535 → 0 → 1).
const int kUint16SequenceSpace = 0x10000;

/// uint32 space, used for the firmware's `ts_ms` uptime counter. It wraps
/// after ~49.7 days of continuous uptime; the same modulo maths covers it.
const int kUint32SequenceSpace = 0x100000000;

/// Forward distance from [older] to [newer] inside a wrapping counter.
///
/// 65535 → 0 gives 1, not -65535. This is the primitive every other rule
/// below is built on (§18.2, edge case #50).
int sequenceDelta(int newer, int older, {int space = kUint16SequenceSpace}) =>
    (newer - older) % space;

/// Backward distance — how far [candidate] sits *behind* [reference].
int sequenceBackwardDistance(
  int candidate,
  int reference, {
  int space = kUint16SequenceSpace,
}) =>
    (reference - candidate) % space;

/// True when [candidate] is strictly newer than [reference].
///
/// The design calls out `newSequence <= oldSequence` as WRONG. The correct
/// test is "forward by less than half the space": anything further forward
/// than half the space is indistinguishable from a backward jump, so it is
/// treated as old/out-of-order.
bool isSequenceNewer(
  int candidate,
  int reference, {
  int space = kUint16SequenceSpace,
}) {
  final delta = sequenceDelta(candidate, reference, space: space);
  return delta != 0 && delta < space ~/ 2;
}

/// Exact repeat of the last accepted value (edge case #49).
bool isSequenceDuplicate(
  int candidate,
  int reference, {
  int space = kUint16SequenceSpace,
}) =>
    sequenceDelta(candidate, reference, space: space) == 0;

/// How many packets went missing between two consecutive accepted values
/// (edge case #51). Adjacent values give 0.
int packetsMissingBetween(
  int newer,
  int older, {
  int space = kUint16SequenceSpace,
}) {
  final delta = sequenceDelta(newer, older, space: space);
  return delta <= 1 ? 0 : delta - 1;
}

// ─────────────────────────────────────────────────────────────────────────
// Wire format
// ─────────────────────────────────────────────────────────────────────────

/// Byte offsets and sentinels of the current 129-byte batched packet.
///
/// Kept as named constants rather than magic numbers so that the day
/// firmware adds the §18.1 header, the diff is confined to this class plus
/// a [TelemetrySequenceReader].
class TelemetryPacketLayout {
  TelemetryPacketLayout._();

  static const int batteryOffset = 0;
  static const int temperatureOffset = 1;
  static const int timestampOffset = 3;
  static const int biteCountOffset = 7;
  static const int imuOffset = 9;

  static const int imuSampleBytes = 12;
  static const int samplesPerPacket = 10;

  /// Firmware samples the IMU at 100 Hz and batches 10 of them.
  static const int samplePeriodMs = 10;

  /// Expected wall-clock distance between two consecutive packets. Used as
  /// the yardstick for gap counting in degraded ordering mode (§18.2).
  static const int nominalPacketPeriodMs = samplesPerPacket * samplePeriodMs;

  /// 9 header bytes + 10 * 12 payload bytes = 129.
  static const int minLength =
      imuOffset + (samplesPerPacket * imuSampleBytes);

  /// Firmware writes this when the temperature sensor has no valid reading.
  static const int temperatureUnavailable = -32768;

  /// Firmware withholds bites on an unencrypted link.
  static const int biteCountWithheld = 0xFFFF;

  /// Battery values above this are a sensor/sentinel artefact, not a level.
  static const int batteryMaxPercent = 100;
}

/// Reads a sequence number out of a raw packet, once firmware has one.
///
/// Returning null means "this packet carries no usable sequence", which
/// drops the session back to timestamp ordering for that packet.
typedef TelemetrySequenceReader = int? Function(ByteData view, int lengthBytes);

/// One IMU sample in physical units.
class ImuSample {
  const ImuSample({
    required this.ax,
    required this.ay,
    required this.az,
    required this.gx,
    required this.gy,
    required this.gz,
    required this.offsetMs,
  });

  /// Acceleration in g (wire is milli-g).
  final double ax;
  final double ay;
  final double az;

  /// Angular rate in deg/s (wire is 0.1 deg/s per LSB).
  final double gx;
  final double gy;
  final double gz;

  /// Offset of this sample from the packet's `ts_ms`, in milliseconds.
  final int offsetMs;

  @override
  String toString() => 'ImuSample(+${offsetMs}ms, '
      'a=${ax.toStringAsFixed(3)},${ay.toStringAsFixed(3)},'
      '${az.toStringAsFixed(3)} '
      'g=${gx.toStringAsFixed(1)},${gy.toStringAsFixed(1)},'
      '${gz.toStringAsFixed(1)})';
}

/// A successfully parsed telemetry packet.
class TelemetryPacket {
  TelemetryPacket({
    required this.batteryPercent,
    required this.temperatureC,
    required this.timestampMs,
    required this.biteCount,
    required this.sequence,
    required this.samples,
    required this.receivedAt,
    required this.fingerprint,
    required this.rawLength,
  });

  /// 0..100, or null when firmware reported an implausible value.
  final int? batteryPercent;

  /// Degrees Celsius, or null when the sensor reading was unavailable.
  final double? temperatureC;

  /// Device uptime of the FIRST sample in this batch, in milliseconds.
  final int timestampMs;

  /// Absolute lifetime bite counter, or null when firmware withheld it.
  final int? biteCount;

  /// Null on today's firmware — see [TelemetryOrderingSignal].
  final int? sequence;

  final List<ImuSample> samples;

  /// Host wall clock at receipt. For display/persistence only; ordering and
  /// the stale watchdog use a monotonic clock instead, because wall time can
  /// jump backwards on an NTP correction or a timezone change.
  final DateTime receivedAt;

  /// Cheap content hash, used to tell a true byte-for-byte repeat (#49)
  /// apart from two distinct packets that happen to share a timestamp.
  final int fingerprint;

  final int rawLength;

  bool get hasSequence => sequence != null;

  /// The value ordering decisions are made on (§18.2).
  int get orderingValue => sequence ?? timestampMs;

  /// Modulus that goes with [orderingValue].
  int get orderingSpace =>
      sequence != null ? kUint16SequenceSpace : kUint32SequenceSpace;

  /// Device uptime of sample [index].
  int deviceTimestampMsFor(int index) =>
      timestampMs + (index * TelemetryPacketLayout.samplePeriodMs);

  /// Parses [raw], returning null instead of throwing for anything short or
  /// malformed (§8.5: a bad packet must never take the notification stream
  /// down with an exception).
  static TelemetryPacket? tryParse(
    List<int> raw, {
    TelemetrySequenceReader? sequenceReader,
    DateTime? receivedAt,
  }) {
    // Short buffer: reject. Longer than expected is ACCEPTED and the extra
    // tail ignored, so that a firmware which appends the §18.1 header fields
    // does not brick a shipped app.
    if (raw.length < TelemetryPacketLayout.imuOffset) return null;

    try {
      final bytes = raw is Uint8List ? raw : Uint8List.fromList(raw);
      final view = ByteData.sublistView(bytes);

      final rawBattery = view.getUint8(TelemetryPacketLayout.batteryOffset);
      final battery =
          rawBattery > TelemetryPacketLayout.batteryMaxPercent ? null : rawBattery;

      final t100 = view.getInt16(
        TelemetryPacketLayout.temperatureOffset,
        Endian.little,
      );
      final temperature =
          t100 == TelemetryPacketLayout.temperatureUnavailable
              ? null
              : t100 / 100.0;

      final timestampMs = view.getUint32(
        TelemetryPacketLayout.timestampOffset,
        Endian.little,
      );

      final rawBites = view.getUint16(
        TelemetryPacketLayout.biteCountOffset,
        Endian.little,
      );
      final biteCount =
          rawBites == TelemetryPacketLayout.biteCountWithheld ? null : rawBites;

      final samples = <ImuSample>[];
      if (raw.length >= TelemetryPacketLayout.minLength) {
        for (var i = 0; i < TelemetryPacketLayout.samplesPerPacket; i++) {
          final offset =
              TelemetryPacketLayout.imuOffset + (i * TelemetryPacketLayout.imuSampleBytes);
          samples.add(ImuSample(
            ax: view.getInt16(offset + 0, Endian.little) / 1000.0,
            ay: view.getInt16(offset + 2, Endian.little) / 1000.0,
            az: view.getInt16(offset + 4, Endian.little) / 1000.0,
            gx: view.getInt16(offset + 6, Endian.little) / 10.0,
            gy: view.getInt16(offset + 8, Endian.little) / 10.0,
            gz: view.getInt16(offset + 10, Endian.little) / 10.0,
            offsetMs: i * TelemetryPacketLayout.samplePeriodMs,
          ));
        }
      }

      final sequence = sequenceReader?.call(view, bytes.lengthInBytes);

      return TelemetryPacket(
        batteryPercent: battery,
        temperatureC: temperature,
        timestampMs: timestampMs,
        biteCount: biteCount,
        sequence: sequence == null
            ? null
            : sequence % kUint16SequenceSpace, // keep it inside the space
        samples: List<ImuSample>.unmodifiable(samples),
        receivedAt: receivedAt ?? DateTime.now(),
        fingerprint: _fingerprintOf(bytes),
        rawLength: bytes.lengthInBytes,
      );
    } catch (_) {
      // Defensive: a typed-data view over a hostile/odd buffer must degrade
      // to "malformed", never to an uncaught error inside a notify handler.
      return null;
    }
  }

  /// Web-safe rolling hash (stays well under 2^53, so no silent overflow).
  static int _fingerprintOf(Uint8List bytes) {
    var h = 17;
    for (var i = 0; i < bytes.length; i++) {
      h = (h * 31 + bytes[i]) % 0x7FFFFFFF;
    }
    return h;
  }

  @override
  String toString() => 'TelemetryPacket(ts=${timestampMs}ms, '
      'seq=${sequence ?? "-"}, batt=${batteryPercent ?? "-"}%, '
      'temp=${temperatureC?.toStringAsFixed(2) ?? "-"}C, '
      'bites=${biteCount ?? "-"}, samples=${samples.length})';
}

// ─────────────────────────────────────────────────────────────────────────
// Outcomes, signals and metrics
// ─────────────────────────────────────────────────────────────────────────

/// What [TelemetrySession.handlePacket] did with a notification.
enum TelemetryOutcome {
  /// New, in-order packet. Latest values and the stale watchdog updated.
  accepted,

  /// Accepted after re-baselining because the ordering counter jumped
  /// backwards far enough to mean "the spoon rebooted", or because ordering
  /// had been rejecting packets for too long to still be trusted.
  resynchronised,

  /// Exact repeat of the last accepted packet (edge case #49).
  duplicate,

  /// Older than the last accepted packet — rollover-aware (edge case #50).
  outOfOrder,

  /// Short buffer or unparseable content. Never throws.
  malformed,

  /// Arrived while the session was stopped/disposed. A late notification
  /// from a torn-down subscription (§36 #53) must not resurrect state.
  notRunning,
}

extension TelemetryOutcomeX on TelemetryOutcome {
  /// True when the packet updated the latest values and fed the watchdog.
  bool get isAccepted =>
      this == TelemetryOutcome.accepted ||
      this == TelemetryOutcome.resynchronised;

  /// Rejected for an integrity reason (as opposed to simply not running).
  bool get isRejected =>
      this == TelemetryOutcome.duplicate ||
      this == TelemetryOutcome.outOfOrder ||
      this == TelemetryOutcome.malformed;
}

/// Which signal is being used to order packets.
enum TelemetryOrderingSignal {
  /// Firmware supplies a real sequence number (§18.1/§18.2). Gaps are exact.
  sequence,

  /// Degraded mode: ordering comes from the packet's `ts_ms` uptime field.
  /// Duplicates and out-of-order packets are still caught exactly, but gap
  /// counts are ESTIMATED from elapsed device time, so a firmware batching
  /// hiccup can look like a lost packet.
  deviceTimestamp,
}

/// §18.3 / edge case #48 — telemetry died while the GATT link stayed up.
class TelemetryStaleEvent {
  const TelemetryStaleEvent({
    required this.silentFor,
    required this.hadFirstTelemetry,
    required this.acceptedBefore,
  });

  /// How long since the last ACCEPTED packet.
  final Duration silentFor;

  /// False means the stream never started (edge case #47 territory).
  final bool hadFirstTelemetry;

  /// Packets accepted in this session before it went quiet.
  final int acceptedBefore;

  @override
  String toString() => 'TelemetryStaleEvent(silent for '
      '${silentFor.inMilliseconds}ms after $acceptedBefore packets)';
}

/// Immutable snapshot of the integrity counters (§38 observability).
class TelemetryStats {
  const TelemetryStats({
    required this.accepted,
    required this.duplicates,
    required this.outOfOrder,
    required this.malformed,
    required this.gapEvents,
    required this.estimatedPacketsLost,
    required this.resynchronisations,
    required this.staleEpisodes,
    required this.lastGapSize,
  });

  final int accepted;
  final int duplicates;
  final int outOfOrder;
  final int malformed;

  /// Number of times a discontinuity was observed (edge case #51).
  final int gapEvents;

  /// Sum of the packets those gaps implied.
  final int estimatedPacketsLost;

  final int resynchronisations;
  final int staleEpisodes;
  final int lastGapSize;

  /// lost / (lost + accepted). 0 when nothing has arrived yet.
  double get lossRatio {
    final total = accepted + estimatedPacketsLost;
    return total == 0 ? 0 : estimatedPacketsLost / total;
  }

  @override
  String toString() => 'TelemetryStats(accepted=$accepted, dup=$duplicates, '
      'ooo=$outOfOrder, malformed=$malformed, gaps=$gapEvents/'
      '$estimatedPacketsLost lost, resync=$resynchronisations, '
      'stale=$staleEpisodes, loss=${(lossRatio * 100).toStringAsFixed(2)}%)';
}

// ─────────────────────────────────────────────────────────────────────────
// TelemetrySession
// ─────────────────────────────────────────────────────────────────────────

/// Design §8.5. One instance per connected spoon session; throw it away and
/// build a new one when the session generation changes.
///
/// Usage (§10.4 — order matters):
/// ```dart
/// session.start();                       // arm BEFORE subscribing
/// sub = char.onValueReceived.listen(session.handlePacket);
/// await char.setNotifyValue(true);
/// if (!await session.awaitFirstTelemetry()) { /* #47: reconnect */ }
/// ```
class TelemetrySession {
  TelemetrySession({
    FirmwareCapabilities capabilities = FirmwareCapabilities.current,
    this.staleTimeout = BleConstants.telemetryStaleTimeout,
    this.firstTelemetryTimeout = BleConstants.firstTelemetryTimeout,
    TelemetrySequenceReader? sequenceReader,
    int Function()? monotonicClockMs,
    this.onStale,
    this.onRecovered,
    this.onGap,
    this.onFirstTelemetry,
    this.onFirstTelemetryTimeout,
  })  : _capabilities = capabilities,
        // The sequence path stays behind the capability flag. Passing a
        // reader without the flag does nothing, and setting the flag without
        // a reader degrades to timestamp ordering rather than pretending.
        _sequenceReader =
            capabilities.hasTelemetrySequence ? sequenceReader : null,
        _now = monotonicClockMs ?? _defaultMonotonicMs;

  // ── configuration ──────────────────────────────────────────────────────

  /// §18.3 — "if no valid packet for 8 seconds: state = stale".
  final Duration staleTimeout;

  /// §10.4 / edge case #47 — how long READY may wait for the first packet.
  final Duration firstTelemetryTimeout;

  final FirmwareCapabilities _capabilities;
  final TelemetrySequenceReader? _sequenceReader;

  /// Monotonic milliseconds. Injectable so tests can drive time directly.
  final int Function() _now;

  // ── callbacks (mirroring the §28 reference shape) ──────────────────────

  /// §18.3 fired ONCE per stale episode. This module never disconnects: the
  /// coordinator chooses resubscribe vs. teardown.
  void Function(TelemetryStaleEvent event)? onStale;

  /// Telemetry started flowing again after a stale episode.
  void Function()? onRecovered;

  /// Edge case #51 — called with the number of packets believed lost.
  void Function(int missing)? onGap;

  /// §10.4 Rule 2 — the first VALID packet arrived; READY is now allowed.
  void Function(TelemetryPacket packet)? onFirstTelemetry;

  /// Edge case #47 — no valid packet within [firstTelemetryTimeout].
  void Function()? onFirstTelemetryTimeout;

  // ── mutable session state ──────────────────────────────────────────────

  bool _running = false;
  bool _disposed = false;
  bool _stale = false;

  int? _lastOrderingValue;
  int? _lastFingerprint;
  int? _lastAcceptedAtMs;
  DateTime? _lastPacketAt;

  /// Anti-wedge guard: ordering logic must never permanently silence a live
  /// stream. If firmware restarts its counter in a way the backward-jump
  /// heuristic does not catch, N consecutive rejects force a re-baseline.
  int _consecutiveOrderingRejects = 0;

  TelemetryPacket? _latest;

  int _accepted = 0;
  int _duplicates = 0;
  int _outOfOrder = 0;
  int _malformed = 0;
  int _gapEvents = 0;
  int _packetsLost = 0;
  int _resyncs = 0;
  int _staleEpisodes = 0;
  int _lastGapSize = 0;
  int _orderingCollisions = 0;

  Timer? _staleWatchdog;
  Timer? _firstTelemetryDeadline;
  Completer<bool>? _firstTelemetryCompleter;
  bool _hasFirstTelemetry = false;

  StreamController<TelemetryPacket>? _packetController;
  StreamController<TelemetryStaleEvent>? _staleController;

  // A single process-wide monotonic source. Stopwatch cannot go backwards on
  // an NTP step or a timezone change, unlike DateTime.now().
  static final Stopwatch _processClock = Stopwatch()..start();
  static int _defaultMonotonicMs() => _processClock.elapsedMilliseconds;

  /// A backward jump larger than this many milliseconds of device uptime is
  /// a reboot, not reordering — BLE notifications on one link are ordered,
  /// so genuine reordering is at most a packet or two.
  static const int _rebootBackwardMs = 3000;

  /// Same idea in sequence space: nothing legitimate jumps this far back.
  static const int _sequenceResyncBackward = kUint16SequenceSpace ~/ 8;

  /// ~0.5 s of packets at 10 Hz before we stop trusting our own baseline.
  static const int _maxConsecutiveOrderingRejects = 5;

  /// Keeps one long silence from blowing the loss counter up (§38: metrics
  /// exist to be read, not to overflow after a night on the charger).
  static const int _maxGapPacketsCounted = 1000;

  // ── introspection ──────────────────────────────────────────────────────

  bool get isRunning => _running;
  bool get isDisposed => _disposed;

  /// §18.3 state. Cleared automatically when telemetry resumes.
  bool get isStale => _stale;

  /// §10.4 Rule 2 gate — safe to move to STREAMING/READY.
  bool get hasFirstTelemetry => _hasFirstTelemetry;

  /// Which §18.2 signal is in force. `deviceTimestamp` on today's firmware.
  TelemetryOrderingSignal get orderingSignal => _sequenceReader != null
      ? TelemetryOrderingSignal.sequence
      : TelemetryOrderingSignal.deviceTimestamp;

  /// True while gap counts are estimates rather than exact (see
  /// [TelemetryOrderingSignal.deviceTimestamp]).
  bool get isOrderingDegraded =>
      orderingSignal == TelemetryOrderingSignal.deviceTimestamp;

  /// Whether the firmware this session was built for claims a sequence field.
  bool get firmwareClaimsSequence => _capabilities.hasTelemetrySequence;

  TelemetryPacket? get latestPacket => _latest;
  int? get batteryPercent => _latest?.batteryPercent;
  double? get temperatureC => _latest?.temperatureC;
  int? get biteCount => _latest?.biteCount;

  /// The 10 samples of the most recent accepted packet (empty before one).
  List<ImuSample> get imuSamples => _latest?.samples ?? const <ImuSample>[];

  /// Wall clock of the last accepted packet — for UI/logs only.
  DateTime? get lastPacketAt => _lastPacketAt;

  /// Monotonic silence since the last accepted packet; zero before the first.
  Duration get silentFor {
    final last = _lastAcceptedAtMs;
    if (last == null) return Duration.zero;
    return Duration(milliseconds: _now() - last);
  }

  /// Packets that repeated the ordering value with a different payload.
  /// Always 0 on healthy firmware; a non-zero value means `ts_ms` (or the
  /// sequence number) is not usable as an ordering signal and §18.1's real
  /// header is overdue.
  int get orderingCollisions => _orderingCollisions;

  TelemetryStats get stats => TelemetryStats(
        accepted: _accepted,
        duplicates: _duplicates,
        outOfOrder: _outOfOrder,
        malformed: _malformed,
        gapEvents: _gapEvents,
        estimatedPacketsLost: _packetsLost,
        resynchronisations: _resyncs,
        staleEpisodes: _staleEpisodes,
        lastGapSize: _lastGapSize,
      );

  /// Every accepted packet, in order. Broadcast, so late listeners simply
  /// miss earlier packets — telemetry is a live signal, not a log.
  Stream<TelemetryPacket> get packets =>
      (_packetController ??= StreamController<TelemetryPacket>.broadcast())
          .stream;

  /// §18.3 stale signals. One event per episode.
  Stream<TelemetryStaleEvent> get staleEvents =>
      (_staleController ??= StreamController<TelemetryStaleEvent>.broadcast())
          .stream;

  // ── lifecycle ──────────────────────────────────────────────────────────

  /// Arms the watchdog and the first-telemetry deadline.
  ///
  /// Call this BEFORE `setNotifyValue(true)` (§10.4) so that a packet which
  /// arrives during the subscribe round-trip is counted rather than dropped.
  /// That does mean the [firstTelemetryTimeout] budget includes the subscribe
  /// itself — deliberate: it is the total time-to-READY budget, not just the
  /// wait for the radio.
  ///
  /// Idempotent: calling it on a running session does nothing, so a retry
  /// path cannot silently reset the deadline it is waiting on.
  void start() {
    if (_disposed || _running) return;
    _running = true;
    _clearSessionState();
    _armFirstTelemetryDeadline();
    _armStaleWatchdog();
  }

  /// Stops the timers and settles any pending [awaitFirstTelemetry] future.
  ///
  /// Latest values are KEPT so the UI does not blank during a controlled
  /// resubscribe; use [reset] to clear them. Idempotent.
  void stop() {
    if (!_running) {
      // Still cancel defensively — stop() must be safe from any state.
      _cancelTimers();
      return;
    }
    _running = false;
    _cancelTimers();
    _settleFirstTelemetry(false);
    // Drop the ordering baseline: a value from the old subscription must not
    // be compared against packets from the next one.
    _lastOrderingValue = null;
    _lastFingerprint = null;
    _lastAcceptedAtMs = null;
    _consecutiveOrderingRejects = 0;
    // Rule 2 gate: a stopped session is not READY, so no caller may derive
    // READY from a first packet that belonged to the previous subscription.
    _hasFirstTelemetry = false;
    _stale = false;
  }

  /// Full clear — ordering baseline, counters, latest values and stale flag.
  ///
  /// Use for §18.3's "one controlled resubscribe": the link survives, but
  /// every integrity assumption about the stream must be rebuilt. If the
  /// session is running it is re-armed as a brand-new one.
  void reset() {
    if (_disposed) return;
    final wasRunning = _running;
    _cancelTimers();
    _settleFirstTelemetry(false);
    _clearSessionState();
    _latest = null;
    _lastPacketAt = null;
    _accepted = 0;
    _duplicates = 0;
    _outOfOrder = 0;
    _malformed = 0;
    _gapEvents = 0;
    _packetsLost = 0;
    _resyncs = 0;
    _staleEpisodes = 0;
    _lastGapSize = 0;
    _orderingCollisions = 0;
    if (wasRunning) {
      _armFirstTelemetryDeadline();
      _armStaleWatchdog();
    }
  }

  /// Releases the streams. The session is unusable afterwards; further
  /// packets return [TelemetryOutcome.notRunning]. Safe to call twice.
  Future<void> dispose() async {
    if (_disposed) return;
    stop();
    _disposed = true;
    await _packetController?.close();
    await _staleController?.close();
    _packetController = null;
    _staleController = null;
  }

  // ── §10.4 Rule 2 — first valid telemetry ───────────────────────────────

  /// Completes true on the first VALID packet, false on timeout or on
  /// stop/reset. Never throws and never completes twice, so a coordinator
  /// can `await` it inside its own connect timeout without a second guard.
  ///
  /// Returns false immediately when the session is not running — an unarmed
  /// session has no first packet to wait for.
  Future<bool> awaitFirstTelemetry() {
    if (_hasFirstTelemetry) return Future<bool>.value(true);
    final completer = _firstTelemetryCompleter;
    if (completer == null || !_running) return Future<bool>.value(false);
    return completer.future;
  }

  // ── ingest ─────────────────────────────────────────────────────────────

  /// Feed every notification here. Never throws.
  ///
  /// Returns what happened so the caller can log it (§38); the parsed values
  /// are read from [latestPacket] and the typed getters.
  TelemetryOutcome handlePacket(List<int> raw) {
    if (_disposed || !_running) return TelemetryOutcome.notRunning;

    final packet = TelemetryPacket.tryParse(
      raw,
      sequenceReader: _sequenceReader,
    );
    if (packet == null) {
      _malformed++;
      return TelemetryOutcome.malformed;
    }

    final outcome = _classify(packet);
    switch (outcome) {
      case TelemetryOutcome.accepted:
      case TelemetryOutcome.resynchronised:
        if (outcome == TelemetryOutcome.resynchronised) _resyncs++;
        _commit(packet);
      case TelemetryOutcome.duplicate:
        _duplicates++;
      case TelemetryOutcome.outOfOrder:
        _outOfOrder++;
        _consecutiveOrderingRejects++;
      case TelemetryOutcome.malformed:
      case TelemetryOutcome.notRunning:
        break;
    }
    return outcome;
  }

  /// §18.2 in one place. Everything here is modulo arithmetic; there is no
  /// `<=` comparison anywhere, which is the whole point of the section.
  TelemetryOutcome _classify(TelemetryPacket packet) {
    final last = _lastOrderingValue;
    if (last == null) return TelemetryOutcome.accepted; // first = baseline

    final space = packet.orderingSpace;
    final value = packet.orderingValue;
    final forward = sequenceDelta(value, last, space: space);

    // Edge case #49 — exact repeat of the last accepted ordering value.
    if (forward == 0) {
      // A byte-identical repeat is a plain duplicate notification (a replay
      // after resubscribe, or the stack redelivering). A DIFFERENT payload
      // under the same ordering value is a firmware anomaly: the packet
      // cannot be placed in the stream, so it is still dropped — feeding
      // downstream bite/IMU consumers twice is worse than losing 100 ms —
      // but it is counted separately so it shows up in the logs (§38)
      // instead of hiding inside the duplicate count.
      if (_lastFingerprint != null && packet.fingerprint != _lastFingerprint) {
        _orderingCollisions++;
      }
      return TelemetryOutcome.duplicate;
    }

    // Forward by less than half the space = newer. This is what makes
    // 65534 → 65535 → 0 → 1 valid (edge case #50) and what a naive
    // `newSeq <= oldSeq` gets wrong.
    if (forward < space ~/ 2) {
      _accountGap(forward, packet);
      return TelemetryOutcome.accepted;
    }

    // Backwards. Two sub-cases, and telling them apart matters: a spoon
    // reboot resets both the uptime counter and any sequence number, and if
    // we simply rejected everything below the old value the stream would be
    // silenced for good while the link stayed healthy.
    final backward = space - forward;
    final resyncThreshold = packet.hasSequence
        ? _sequenceResyncBackward
        : _rebootBackwardMs;
    if (backward > resyncThreshold) {
      return TelemetryOutcome.resynchronised;
    }

    // Genuine late/duplicate delivery from the controller.
    if (_consecutiveOrderingRejects + 1 >= _maxConsecutiveOrderingRejects) {
      // Anti-wedge: our baseline is evidently wrong. Trust the radio.
      return TelemetryOutcome.resynchronised;
    }
    return TelemetryOutcome.outOfOrder;
  }

  /// Edge case #51 — count what the discontinuity implies.
  void _accountGap(int forwardDelta, TelemetryPacket packet) {
    int missing;
    if (packet.hasSequence) {
      // Exact: every skipped sequence number is one lost packet.
      missing = forwardDelta - 1;
    } else {
      // Degraded: infer from elapsed device time. Only count when the jump
      // clearly exceeds normal batching jitter (1.5x the nominal period),
      // otherwise ordinary scheduling noise would be logged as data loss.
      const period = TelemetryPacketLayout.nominalPacketPeriodMs;
      if (forwardDelta < (period * 3) ~/ 2) return;
      missing = (forwardDelta / period).round() - 1;
    }
    if (missing <= 0) return;
    if (missing > _maxGapPacketsCounted) missing = _maxGapPacketsCounted;

    _gapEvents++;
    _packetsLost += missing;
    _lastGapSize = missing;
    onGap?.call(missing);
  }

  /// Accepts a packet: updates latest values, feeds the §18.3 watchdog and
  /// releases the §10.4 first-telemetry gate.
  void _commit(TelemetryPacket packet) {
    _lastOrderingValue = packet.orderingValue;
    _lastFingerprint = packet.fingerprint;
    _lastAcceptedAtMs = _now();
    _lastPacketAt = packet.receivedAt;
    _consecutiveOrderingRejects = 0;
    _latest = packet;
    _accepted++;

    if (_stale) {
      // §18.3 recovery is observed here, but acted on by the coordinator.
      _stale = false;
      onRecovered?.call();
    }

    if (!_hasFirstTelemetry) {
      _hasFirstTelemetry = true;
      _firstTelemetryDeadline?.cancel();
      _firstTelemetryDeadline = null;
      _settleFirstTelemetry(true);
      onFirstTelemetry?.call(packet);
    }

    final controller = _packetController;
    if (controller != null && !controller.isClosed) controller.add(packet);
  }

  // ── §18.3 stale watchdog ───────────────────────────────────────────────

  void _armStaleWatchdog() {
    _staleWatchdog?.cancel();
    // Poll at a quarter of the timeout so detection latency stays a
    // fraction of the budget rather than doubling it (the §28 reference's
    // fixed 2 s tick can take 10 s to notice an 8 s outage).
    var tick = Duration(milliseconds: (staleTimeout.inMilliseconds / 4).ceil());
    const floor = Duration(milliseconds: 250);
    if (tick < floor) tick = floor;
    _staleWatchdog = Timer.periodic(tick, (_) => _checkStale());
  }

  void _checkStale() {
    if (!_running || _stale) return;
    final last = _lastAcceptedAtMs;
    // Before the first packet the §10.4 deadline owns the window; firing
    // both signals for the same silence would make edge cases #47 and #48
    // indistinguishable to the coordinator.
    if (last == null) return;

    final silentMs = _now() - last;
    if (silentMs <= staleTimeout.inMilliseconds) return;

    _stale = true;
    _staleEpisodes++;
    final event = TelemetryStaleEvent(
      silentFor: Duration(milliseconds: silentMs),
      hadFirstTelemetry: _hasFirstTelemetry,
      acceptedBefore: _accepted,
    );
    onStale?.call(event);
    final controller = _staleController;
    if (controller != null && !controller.isClosed) controller.add(event);
  }

  // ── §10.4 / #47 first-telemetry deadline ───────────────────────────────

  void _armFirstTelemetryDeadline() {
    _firstTelemetryCompleter = Completer<bool>();
    _firstTelemetryDeadline?.cancel();
    _firstTelemetryDeadline = Timer(firstTelemetryTimeout, () {
      _firstTelemetryDeadline = null;
      if (_hasFirstTelemetry) return;
      _settleFirstTelemetry(false);
      // Edge case #47: the coordinator reconnects. This module does not.
      onFirstTelemetryTimeout?.call();
    });
  }

  void _settleFirstTelemetry(bool value) {
    final completer = _firstTelemetryCompleter;
    if (completer != null && !completer.isCompleted) completer.complete(value);
    if (!value) _firstTelemetryCompleter = null;
  }

  // ── shared teardown helpers ────────────────────────────────────────────

  void _cancelTimers() {
    _staleWatchdog?.cancel();
    _staleWatchdog = null;
    _firstTelemetryDeadline?.cancel();
    _firstTelemetryDeadline = null;
  }

  void _clearSessionState() {
    _lastOrderingValue = null;
    _lastFingerprint = null;
    _lastAcceptedAtMs = null;
    _consecutiveOrderingRejects = 0;
    _hasFirstTelemetry = false;
    _stale = false;
  }

  @override
  String toString() => 'TelemetrySession(running=$_running, '
      'ordering=${orderingSignal.name}, first=$_hasFirstTelemetry, '
      'stale=$_stale, ${stats.toString()})';
}
