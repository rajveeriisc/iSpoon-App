// constants.dart — single source of truth for the BLE layer's UUIDs, timings
// and thresholds.
//
// Follows "Smart Spoon BLE Final Production Design v3.0" §26, adapted to this
// product:
//
//   - UUIDs are the REAL f00d* family this firmware exposes. The design doc's
//     8f3a* values are explicitly placeholders ("Replace every placeholder
//     UUID with your production UUID").
//   - Timings that already have hard-won platform reasons behind them are
//     carried over from BleTimings rather than replaced with the doc's generic
//     numbers. Those reasons are recorded next to each value — do not "tidy"
//     them without re-testing on real Samsung/Xiaomi hardware.
library;

class BleConstants {
  BleConstants._();

  // ── GATT (firmware f00d* family) ─────────────────────────────────────────
  static const String spoonServiceUuid =
      'f00d0001-1234-5678-9abc-def012345678';

  /// Bulk telemetry notify: battery, temperature, timestamp, bite count and
  /// 10 IMU samples per packet.
  static const String telemetryCharacteristicUuid =
      'f00d0002-1234-5678-9abc-def012345678';

  /// Command write. ASCII envelopes today ("ON 45", "OFF", "INV 1").
  static const String commandCharacteristicUuid =
      'f00d0003-1234-5678-9abc-def012345678';

  /// Stable product identity, readable without encryption.
  static const String identityCharacteristicUuid =
      'f00d0004-1234-5678-9abc-def012345678';

  /// Hardware revision — requires an ENCRYPTED + LESC link.
  ///
  /// This is the firmware's designated pairing trigger: "Hardware revision
  /// still requires an encrypted link and is the characteristic used to start
  /// LESC Just Works." Reading it is what makes the OS begin Just Works
  /// pairing, and it is the ONLY way to trigger it on iOS, where CoreBluetooth
  /// exposes no pair() API at all.
  static const String hwRevisionCharacteristicUuid =
      'f00d0005-1234-5678-9abc-def012345678';

  /// Owner / pairing status, readable without encryption.
  static const String ownerStatusCharacteristicUuid =
      'f00d0006-1234-5678-9abc-def012345678';

  /// Event notify (heater rail bit, charge state, faults).
  static const String eventCharacteristicUuid =
      'f00d0007-1234-5678-9abc-def012345678';

  // ── NOT YET IN FIRMWARE ──────────────────────────────────────────────────
  // Design §18/§19 need these. They are declared so the app layer can be
  // written against the final contract, and every read of them must tolerate
  // absence. See [FirmwareCapabilities].
  //
  //   protocolCharacteristicUuid   — protocol major/minor
  //   commandAckCharacteristicUuid — application-level command ACK
  //
  // Until firmware exposes them, the coordinator degrades gracefully:
  // protocol validation is skipped (assumed compatible) and commands complete
  // optimistically on write instead of on ACK.
  static const String? protocolCharacteristicUuid = null;
  static const String? commandAckCharacteristicUuid = null;

  // ── Scan / candidate selection (design §9) ───────────────────────────────
  /// Collect candidates before committing, so the primary spoon is not lost to
  /// whichever saved spoon happens to advertise first (design §9.1).
  static const Duration candidateCollectionWindow =
      Duration(milliseconds: 2500);
  static const Duration scanTimeout = Duration(seconds: 8);

  /// A single strong RSSI packet is not evidence (design §9.2).
  static const int minCandidateSightings = 2;
  static const Duration candidateFreshness = Duration(milliseconds: 1500);
  static const int rssiTooWeak = -90;
  static const int rssiStable = -75;

  // ── Connection / validation ──────────────────────────────────────────────
  /// nRF52840/Zephyr can need up to ~30 s for the security handshake on a
  /// FIRST bond, so a user-initiated connect must wait longer than the generic
  /// 10 s in the design doc.
  static const Duration userConnectTimeout = Duration(seconds: 32);
  static const Duration directConnectTimeout = Duration(seconds: 10);
  static const Duration discoveryTimeout = Duration(seconds: 10);

  /// Design §10.4 / §18.3: READY only after a real packet.
  static const Duration firstTelemetryTimeout = Duration(seconds: 5);
  static const Duration telemetryStaleTimeout = Duration(seconds: 8);

  // ── Platform quirks (carried over — each cost real debugging) ────────────
  /// Android cannot scan and connect at once; the radio needs to settle.
  static const Duration postScanSettle = Duration(milliseconds: 500);

  /// Android needs this to release GATT client slots after cancelling streams.
  /// Only pay it when something was actually cancelled.
  static const Duration gattReleaseAndroid = Duration(milliseconds: 1000);

  /// Samsung/Xiaomi GATT teardown takes ~2 s; an overlapping connect to the
  /// same MAC inside that window fails with status 133.
  static const Duration sameDeviceTeardownAndroid = Duration(seconds: 2);

  /// iOS: a short breath between cancelling a peripheral and connecting to it
  /// again.
  ///
  /// This was 5 s — a workaround for flutter_reactive_ble's
  /// ConnectTaskController, which asserted when a connect stream was re-opened
  /// too soon. flutter_blue_plus has no such controller (it serialises
  /// connect/disconnect behind its own mutex), so the old value was a flat 5 s
  /// added to every same-spoon reconnect on iPhone and bought nothing.
  static const Duration streamReopenDelayIos = Duration(milliseconds: 300);
  static const Duration streamReopenDelayAndroid = Duration(seconds: 2);

  // ── Retry / recovery (design §11) ────────────────────────────────────────
  /// 2 → 4 → 8 → 16 → 30 → 30… Reset ONLY after first valid telemetry
  /// (design Rule 9), never at the start of a request.
  static const List<Duration> fallbackBackoff = [
    Duration(seconds: 2),
    Duration(seconds: 4),
    Duration(seconds: 8),
    Duration(seconds: 16),
    Duration(seconds: 30),
  ];

  /// Longest wait between attempts while the user is looking at the app.
  ///
  /// Nothing scans between attempts, so this wait IS how long it takes to
  /// notice a spoon that has just been switched on — and the firmware only
  /// fast-advertises for the first 30 s after power-on. A 30 s gap in the
  /// foreground regularly missed that window. The full ladder still applies in
  /// the background, where battery matters and iOS uses OS standby instead.
  static const Duration foregroundBackoffCap = Duration(seconds: 8);

  /// Manual switch: how long to listen for the tapped spoon BEFORE letting go
  /// of the one that is streaming. A spoon that is on advertises every
  /// ~0.55 s (every 20–30 ms in its first 30 s), so this is several chances;
  /// the check ends the moment the spoon is heard.
  static const Duration switchPresenceWindow = Duration(seconds: 3);

  /// A sighting this recent counts as "the spoon is here" without listening
  /// again before connecting. Short: a spoon can be switched off in a second.
  static const Duration recentlyHeardWindow = Duration(seconds: 5);

  /// How long after the last bite the 10 Hz stream stays on in the background.
  ///
  /// The background normally runs on the low-rate event stream only. While the
  /// spoon's bite counter is moving the user is eating, which is exactly when
  /// the full IMU stream (tremor, motion analysis) matters — so it stays on
  /// until this long passes without a new bite.
  static const Duration backgroundEatingWindow = Duration(minutes: 3);

  // ── Meal / primary policy (design §12, §13) ──────────────────────────────
  static const Duration mealReconnectBudget = Duration(seconds: 20);
  static const int mealReconnectMaxAttempts = 4;
  static const Duration primaryReclaimGrace = Duration(seconds: 7);
  static const Duration manualOverrideCooldown = Duration(minutes: 30);

  /// How long a resume waits for the spoon the background isolate was
  /// streaming from before letting the others try.
  static const Duration resumePreferWindow = Duration(seconds: 12);

  /// §8.7 / §37 — reclaim is a battery cost with no user-facing urgency, so it
  /// runs on a slow foreground-only cadence. The window must exceed
  /// [primaryReclaimGrace] or the grace could never be met inside one scan.
  static const Duration reclaimScanInterval = Duration(seconds: 60);
  static const Duration reclaimScanWindow = Duration(seconds: 9);

  /// §14 — the Add Spoon scan. Longer than [candidateCollectionWindow]: the
  /// user is holding the spoon and watching a list fill in, so completeness
  /// beats latency here.
  static const Duration provisioningScanWindow = Duration(seconds: 6);

  /// How long after its last advertisement a saved spoon still counts as "in
  /// range" in the device list. Longer than a scan window on purpose: the list
  /// must not flicker between Available and Unavailable between scans.
  static const Duration availabilityTimeout = Duration(seconds: 15);

  /// Android bonding. Generous because a FIRST bond on nRF52840/Zephyr shows a
  /// system pairing dialog and runs a full LE Secure Connections handshake —
  /// the clock includes however long the user takes to find and tap it. The
  /// spoon reads "connected" on its own display throughout, so cutting this
  /// short is exactly what makes the app disagree with the spoon.
  ///
  /// Costs nothing on reconnects: an existing bond returns immediately.
  static const Duration bondTimeout = Duration(seconds: 60);

  /// §10.3 — a single GATT read during validation. Short on purpose: a read
  /// that hangs is edge case #45, and the recovery is teardown, not patience.
  static const Duration identityReadTimeout = Duration(seconds: 8);

  // ── Commands (design §19) ────────────────────────────────────────────────
  static const Duration commandTimeout = Duration(seconds: 5);
  static const Duration commandDefaultTtl = Duration(seconds: 10);
  static const int commandQueueMaxDepth = 32;

  // ── Protocol compatibility (design §26) ──────────────────────────────────
  /// The doc's placeholder accepted any non-empty version, which was listed as
  /// bug #30. Firmware does not expose a protocol characteristic yet, so this
  /// is enforced only when [FirmwareCapabilities.hasProtocolCharacteristic].
  static const int protocolMajorSupported = 2;

  static bool isProtocolCompatible(int major) =>
      major == protocolMajorSupported;
}

/// What the connected firmware can actually do.
///
/// The design assumes a richer GATT than this firmware currently exposes
/// (claim epoch, protocol characteristic, command ACK, telemetry sequence
/// numbers, session nonce). Rather than pretend those exist, the coordinator
/// asks this object and degrades deliberately — so the day firmware adds them,
/// only this file and the readers change.
class FirmwareCapabilities {
  const FirmwareCapabilities({
    this.hasProtocolCharacteristic = false,
    this.hasCommandAck = false,
    this.hasTelemetrySequence = false,
    this.hasSessionNonce = false,
    this.hasClaimEpoch = false,
  });

  /// What today's firmware supports. Every flag false = fully degraded mode.
  static const current = FirmwareCapabilities();

  final bool hasProtocolCharacteristic;
  final bool hasCommandAck;
  final bool hasTelemetrySequence;
  final bool hasSessionNonce;
  final bool hasClaimEpoch;

  /// Design §15 factory-reset detection is impossible without a claim epoch.
  bool get canDetectFactoryReset => hasClaimEpoch;

  /// Design §19.2 stale-command rejection needs firmware-side validation.
  bool get canRejectStaleCommands => hasSessionNonce;
}
