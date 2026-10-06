// spoon_models.dart — the BLE layer's shared vocabulary.
//
// Follows "Smart Spoon BLE Final Production Design v3.0" §4, §5, §6 and §8.1.
// Every module in lib/ble/ speaks in these types; nothing here imports a BLE
// package, so the vocabulary stays independent of flutter_reactive_ble.
library;

/// Design §4. The full pipeline, not a boolean.
///
/// Rule 2: **connected is not READY**. Only [streaming] may be treated as
/// usable by the meal/UI/command layers.
enum SpoonState {
  unknown,
  permissionDenied,
  unsupported,
  bluetoothOff,

  idle,
  scanning,
  found,
  connecting,
  connected,
  discovering,
  validatingIdentity,
  authenticating,
  validatingProtocol,
  subscribing,
  awaitingFirstTelemetry,
  streaming,

  stale,
  recovering,
  disconnecting,
  blockedByMealGuard,
  requiresReclaim,
  incompatible,
  busy,
  unclaimed,
  forgotten,
  quarantined,
  error,
}

extension SpoonStateX on SpoonState {
  /// The ONLY state the meal/UI/command layer may act on (Rule 2).
  bool get isUsable => this == SpoonState.streaming;

  /// A link exists at GATT level, but it is not necessarily usable.
  bool get hasLink => const {
        SpoonState.connected,
        SpoonState.discovering,
        SpoonState.validatingIdentity,
        SpoonState.authenticating,
        SpoonState.validatingProtocol,
        SpoonState.subscribing,
        SpoonState.awaitingFirstTelemetry,
        SpoonState.streaming,
        SpoonState.stale,
      }.contains(this);

  /// Connect/validate handshake — a scan must not steal the radio or the
  /// session state, or the UI drops to "Connecting…" / "Scan paused" and a
  /// retry opens a second GATT link.
  bool get isConnectHandshake => const {
        SpoonState.connecting,
        SpoonState.connected,
        SpoonState.discovering,
        SpoonState.validatingIdentity,
        SpoonState.authenticating,
        SpoonState.validatingProtocol,
        SpoonState.subscribing,
        SpoonState.awaitingFirstTelemetry,
        SpoonState.recovering,
      }.contains(this);

  /// Work is in flight; the coordinator is busy.
  bool get isTransitional => const {
        SpoonState.scanning,
        SpoonState.found,
        SpoonState.connecting,
        SpoonState.discovering,
        SpoonState.validatingIdentity,
        SpoonState.authenticating,
        SpoonState.validatingProtocol,
        SpoonState.subscribing,
        SpoonState.awaitingFirstTelemetry,
        SpoonState.recovering,
        SpoonState.disconnecting,
      }.contains(this);

  /// Rule 8: these never auto-retry. They need user action or new firmware.
  bool get isTerminal => const {
        SpoonState.incompatible,
        SpoonState.quarantined,
        SpoonState.unclaimed,
        SpoonState.requiresReclaim,
        SpoonState.forgotten,
        SpoonState.unsupported,
      }.contains(this);
}

/// Design §5.
///
/// Power-off and out-of-range cannot be distinguished from BLE alone, so the
/// `*Suspected` members are INFERRED UI reasons, never asserted facts.
enum DisconnectReason {
  unknown,
  userSwitch,
  userForget,
  userLogout,
  adapterOff,
  permissionLost,
  connectionLost,
  outOfRangeSuspected,
  powerOffSuspected,
  lowBatterySuspected,
  connectTimeout,
  gattError,
  serviceMissing,
  identityMismatch,
  ownershipMismatch,
  claimEpochMismatch,
  firmwareIncompatible,
  protocolIncompatible,
  subscribeFailed,
  firstTelemetryTimeout,
  staleTelemetry,
  deviceBusy,
  notFound,
  mealReconnectExpired,
  servicesReset,
}

extension DisconnectReasonX on DisconnectReason {
  /// Rule 8 — permanent failures must not enter a retry loop.
  bool get isPermanent => const {
        DisconnectReason.identityMismatch,
        DisconnectReason.ownershipMismatch,
        DisconnectReason.claimEpochMismatch,
        DisconnectReason.firmwareIncompatible,
        DisconnectReason.protocolIncompatible,
        DisconnectReason.userForget,
        DisconnectReason.userLogout,
      }.contains(this);

  /// Deliberate teardowns that must NOT count as failures for backoff.
  bool get isIntentional => const {
        DisconnectReason.userSwitch,
        DisconnectReason.userForget,
        DisconnectReason.userLogout,
      }.contains(this);
}

/// Design §6. Higher [priority] wins when requests collide.
enum ConnectionRequestReason {
  manualConfirmed,
  reconnectSameMealSpoon,
  startupRestore,
  adapterRecovery,
  resumeRecovery,
  startup,
  fallback,
  primaryReclaim,
}

extension ConnectionRequestReasonX on ConnectionRequestReason {
  int get priority => switch (this) {
        ConnectionRequestReason.manualConfirmed => 1000,
        ConnectionRequestReason.reconnectSameMealSpoon => 900,
        ConnectionRequestReason.startupRestore => 800,
        ConnectionRequestReason.adapterRecovery => 700,
        ConnectionRequestReason.resumeRecovery => 650,
        ConnectionRequestReason.startup => 600,
        ConnectionRequestReason.fallback => 500,
        ConnectionRequestReason.primaryReclaim => 400,
      };
}

/// A request to make some spoon the active one.
///
/// Design §6: a later low-priority background fallback must never overwrite a
/// pending user request.
class ConnectionRequest {
  ConnectionRequest({
    required this.reason,
    this.targetSerial,
    this.mealSwitchConfirmed = false,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  final ConnectionRequestReason reason;

  /// Null means "coordinator picks", per the selection algorithm.
  final String? targetSerial;

  /// Rule 5 / §12.2 — the user was shown "this will interrupt your meal" and
  /// said yes. Only this flag may move an active meal onto a different spoon;
  /// nothing in the automatic paths is allowed to set it, which is why it is a
  /// field on the request rather than a mode on the coordinator.
  final bool mealSwitchConfirmed;

  final DateTime createdAt;

  int get priority => reason.priority;

  /// Whether this request should replace [other].
  ///
  /// Higher priority always wins. On a TIE the NEWER request wins, and that
  /// matters: two taps on two different spoons are both `manualConfirmed`
  /// (1000), and with a strict `>` the second tap was discarded as "outranked"
  /// — so the app connected to whichever spoon the user had tapped FIRST and
  /// ignored the one they actually wanted. A later request of equal rank
  /// carries the more recent intention, so it takes precedence.
  bool supersedes(ConnectionRequest? other) {
    if (other == null) return true;
    if (priority != other.priority) return priority > other.priority;
    return createdAt.isAfter(other.createdAt);
  }

  @override
  String toString() =>
      'ConnectionRequest(${reason.name}, target: ${targetSerial ?? "auto"}, '
      'priority: $priority${mealSwitchConfirmed ? ", mealSwitchConfirmed" : ""})';
}

/// Design §8.1 — non-secret device metadata. The ownership token belongs in
/// secure storage, never here.
class SpoonRecord {
  SpoonRecord({
    required this.spoonSerial,
    required this.publicDeviceId,
    this.bleRemoteId,
    this.displayName = 'iSpoon',
    this.claimEpoch = 0,
    this.isPrimary = false,
    this.priority = 0,
    this.enabled = true,
    this.hasHeater = false,
    this.firmwareVersion,
    this.protocolVersion,
    this.lastConnectedAt,
    this.lastRssi,
  });

  /// Design §1.2 — the PERMANENT identity. Never the BLE name, MAC, remoteId,
  /// RSSI or scan order.
  final String spoonSerial;
  final String publicDeviceId;

  /// Platform locator only — a cache, not an identity. iOS rotates it.
  String? bleRemoteId;

  String displayName;

  /// Design §15 — a factory reset keeps the serial and bumps this.
  int claimEpoch;

  bool isPrimary;
  int priority;
  bool enabled;

  /// Built-in heater: iSpoon Pro = true, iSpoon basic = false.
  /// This is a product attribute, not identity, and must never be inferred
  /// from the BLE short name (firmware advertises `iSpoon` in the primary AD).
  bool hasHeater;

  String? firmwareVersion;
  int? protocolVersion;
  DateTime? lastConnectedAt;
  int? lastRssi;

  /// Rule 7 — only known AND enabled spoons may be auto-connected.
  bool get isAutoConnectCandidate => enabled;

  /// True when [id] is this spoon, under any of the identifiers the app
  /// uses: serial, advertised public id, or cached platform locator.
  bool refersTo(String id) {
    if (id.isEmpty) return false;
    return spoonSerial == id ||
        publicDeviceId == id ||
        bleRemoteId == id;
  }

  /// Every id the UI or live-data maps may have used for this spoon.
  Set<String> get identityKeys => {
        if (spoonSerial.isNotEmpty) spoonSerial,
        if (publicDeviceId.isNotEmpty) publicDeviceId,
        if (bleRemoteId != null && bleRemoteId!.isNotEmpty) bleRemoteId!,
      };

  Map<String, dynamic> toJson() => {
        'spoonSerial': spoonSerial,
        'publicDeviceId': publicDeviceId,
        'bleRemoteId': bleRemoteId,
        'displayName': displayName,
        'claimEpoch': claimEpoch,
        'isPrimary': isPrimary,
        'priority': priority,
        'enabled': enabled,
        'hasHeater': hasHeater,
        'firmwareVersion': firmwareVersion,
        'protocolVersion': protocolVersion,
        'lastConnectedAt': lastConnectedAt?.toIso8601String(),
        'lastRssi': lastRssi,
      };

  factory SpoonRecord.fromJson(Map<String, dynamic> j) => SpoonRecord(
        spoonSerial: j['spoonSerial'] as String? ?? '',
        publicDeviceId: j['publicDeviceId'] as String? ?? '',
        bleRemoteId: j['bleRemoteId'] as String?,
        displayName: j['displayName'] as String? ?? 'iSpoon',
        claimEpoch: (j['claimEpoch'] as num?)?.toInt() ?? 0,
        isPrimary: j['isPrimary'] as bool? ?? false,
        priority: (j['priority'] as num?)?.toInt() ?? 0,
        enabled: j['enabled'] as bool? ?? true,
        hasHeater: j['hasHeater'] as bool? ??
            (j['displayName'] as String? ?? '')
                .toLowerCase()
                .contains('pro'),
        firmwareVersion: j['firmwareVersion'] as String?,
        protocolVersion: (j['protocolVersion'] as num?)?.toInt(),
        lastConnectedAt: DateTime.tryParse(
            j['lastConnectedAt'] as String? ?? ''),
        lastRssi: (j['lastRssi'] as num?)?.toInt(),
      );
}

/// Whether a live BLE session is the spoon the UI is asking about.
///
/// Home and Bluetooth manager key cards by `SavedBleDevice.id` (usually the
/// cached remote id, sometimes the serial). The coordinator keys the session
/// by the current GATT address. Those must be treated as one spoon.
bool sessionRefersTo({
  required String queryId,
  String? sessionRemoteId,
  SpoonRecord? sessionRecord,
}) {
  if (queryId.isEmpty) return false;
  if (sessionRemoteId != null && sessionRemoteId == queryId) return true;
  if (sessionRecord != null && sessionRecord.refersTo(queryId)) return true;
  return false;
}

/// Collapse serial / public id / cached address of the same spoon so Home
/// and Bluetooth manager never render one physical spoon as two connected
/// rows (Rule 1).
List<String> uniqueSpoonDisplayIds({
  required Iterable<String> ids,
  required Iterable<SpoonRecord> records,
}) {
  final out = <String>[];
  final claimed = <String>{};
  for (final id in ids) {
    if (id.isEmpty) continue;
    SpoonRecord? rec;
    for (final r in records) {
      if (r.refersTo(id)) {
        rec = r;
        break;
      }
    }
    final canonical = rec == null
        ? id
        : (rec.bleRemoteId != null && rec.bleRemoteId!.isNotEmpty
            ? rec.bleRemoteId!
            : rec.spoonSerial);
    if (claimed.add(canonical)) out.add(canonical);
  }
  return out;
}

/// A spoon seen in the CURRENT scan. Design §9: never score against results
/// carried over from a previous scan.
class SpoonCandidate {
  SpoonCandidate({
    required this.bleRemoteId,
    required this.publicDeviceId,
    required this.displayName,
    required int rssi,
    DateTime? firstSeen,
  })  : _rssiEma = rssi.toDouble(),
        lastRssi = rssi,
        firstSeen = firstSeen ?? DateTime.now(),
        lastSeen = DateTime.now(),
        seenCount = 1;

  final String bleRemoteId;
  String publicDeviceId;
  String displayName;
  final DateTime firstSeen;

  DateTime lastSeen;
  int seenCount;
  int lastRssi;
  double _rssiEma;

  /// Smoothed RSSI — one unusually strong packet must not decide anything.
  double get rssiEma => _rssiEma;

  void observe(int rssi) {
    seenCount++;
    lastRssi = rssi;
    lastSeen = DateTime.now();
    // EMA with alpha 0.4: recent samples lead, single spikes do not dominate.
    _rssiEma = _rssiEma + 0.4 * (rssi - _rssiEma);
  }

  void updateMetadata({String? publicDeviceId, String? displayName}) {
    if (publicDeviceId != null && publicDeviceId.isNotEmpty) {
      this.publicDeviceId = publicDeviceId;
    }
    if (displayName != null && displayName.isNotEmpty && displayName != 'iSpoon') {
      this.displayName = displayName;
    }
  }

  /// Design §9.2 — repeated sightings or strong nearby signal, recent, and not too weak.
  bool get isStable => isStableFor(isForeground: true);

  /// Stability, judged against what the platform will actually deliver.
  ///
  /// In the foreground both platforms report every advertisement, so demanding
  /// two sightings (or one strong one) is a cheap way to reject a spoon that
  /// blipped past at the edge of range.
  ///
  /// In the background that same rule is unsatisfiable on iOS: CoreBluetooth
  /// forces `allowDuplicates = NO`, so the app is handed exactly ONE
  /// advertisement per peripheral no matter how long the scan runs. seenCount
  /// can never reach 2, and a spoon at a perfectly healthy -78 dBm fails the
  /// single-sighting escape hatch too — so background selection rejected every
  /// candidate and reported "no stable eligible candidate" forever. Android's
  /// background scans are throttled to a similar effect.
  ///
  /// One sighting is enough there because it is not the only guard: Rule 7 has
  /// already dropped anything that is not a known, enabled, saved spoon, the
  /// freshness window still applies, and the too-weak floor still applies. The
  /// discarded requirement was only ever noise rejection, and background is
  /// precisely where we cannot afford it.
  bool isStableFor({required bool isForeground}) {
    final enoughSightings = isForeground
        ? (seenCount >= BleCandidateThresholds.minSightings ||
            (seenCount >= 1 && _rssiEma > BleCandidateThresholds.stable))
        : seenCount >= 1;
    return enoughSightings &&
        DateTime.now().difference(lastSeen) <=
            BleCandidateThresholds.freshness &&
        _rssiEma > BleCandidateThresholds.tooWeak;
  }
}

/// Kept separate so [SpoonCandidate] does not import the constants file and
/// create a cycle; values mirror [BleConstants].
class BleCandidateThresholds {
  BleCandidateThresholds._();
  static const int minSightings = 2;
  static const Duration freshness = Duration(seconds: 4);
  static const int tooWeak = -90;
  static const int stable = -75;
}

/// Result of validating a connected spoon's identity/ownership (design §8.2).
enum AuthResult { authorized, requiresReclaim, ownershipMismatch, unclaimed }


/// Design §2 / §14 — the spoon's own answer to "do you already have an owner,
/// and is it this phone?", decoded from the unencrypted owner-status
/// characteristic (f00d0006).
///
/// Byte 0 is a bit mask, byte 1 the last Zephyr `bt_security_err`. The bit
/// layout is firmware's, mirrored here so lib/ble/ stays free of the legacy
/// service layer; the canonical constants live beside the GATT table in
/// `features/devices/domain/services/smart_spoon_ble_service.dart` and the two
/// must be changed together.
///
/// This matters because the failure it describes is otherwise unreadable: a
/// spoon that already belongs to someone else connects, subscribes, and then
/// stays silent forever, because notifications need an encrypted link and the
/// single-owner firmware refuses to bond with a second phone.
class SpoonOwnerFlags {
  const SpoonOwnerFlags({
    required this.ownerPresent,
    required this.peerBonded,
    required this.pairRejected,
    required this.secured,
    required this.repairHold6s,
    required this.rejectReason,
    this.capsValid = false,
    this.declaredHasHeater = false,
  });

  static const int _ownerPresent = 1 << 0;
  static const int _peerBonded = 1 << 1;
  static const int _pairRejected = 1 << 2;
  static const int _secured = 1 << 3;
  static const int _repairHold6s = 1 << 4;
  static const int _capsValid = 1 << 5;
  static const int _hasHeater = 1 << 6;

  /// Returns null for an empty read, which is how older firmware without
  /// f00d0006 presents — deliberately distinct from "no owner".
  static SpoonOwnerFlags? tryParse(List<int> bytes) {
    if (bytes.isEmpty) return null;
    final f = bytes[0];
    return SpoonOwnerFlags(
      ownerPresent: f & _ownerPresent != 0,
      peerBonded: f & _peerBonded != 0,
      pairRejected: f & _pairRejected != 0,
      secured: f & _secured != 0,
      repairHold6s: f & _repairHold6s != 0,
      rejectReason: bytes.length > 1 ? bytes[1] : 0,
      capsValid: f & _capsValid != 0,
      declaredHasHeater: f & _hasHeater != 0,
    );
  }

  final bool ownerPresent;
  final bool peerBonded;
  final bool pairRejected;
  final bool secured;
  final bool repairHold6s;
  final int rejectReason;

  /// Whether this firmware reports capability bits at all. Firmware older than
  /// the capability bits leaves bits 5/6 clear, which is indistinguishable
  /// from "no heater" — so [heaterCapability] must stay null there rather than
  /// reporting false and stripping heater controls off a real Pro spoon.
  final bool capsValid;

  /// Raw bit 6. Only meaningful when [capsValid]; read [heaterCapability].
  final bool declaredHasHeater;

  /// The device's own answer to "do I have a heater", or null if this firmware
  /// cannot say. Null means fall back to name detection / asking the user;
  /// non-null must be trusted over both, because the device knows and a
  /// renamed spoon defeats name parsing.
  bool? get heaterCapability => capsValid ? declaredHasHeater : null;

  /// Edge case #25 — the spoon belongs to another account. No app-side retry
  /// can fix it; only a 6-second physical long-hold on the spoon can.
  bool get needsPhysicalRepair => repairHold6s || (ownerPresent && !peerBonded);

  @override
  String toString() => 'owner=$ownerPresent peerBonded=$peerBonded '
      'rejected=$pairRejected secured=$secured hold6s=$repairHold6s '
      'reason=$rejectReason caps=$capsValid heater=$heaterCapability';
}
