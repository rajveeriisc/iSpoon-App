// spoon_runtime.dart — the single object the APP talks to about spoons.
//
// The connection layer below it is deliberately narrow and rule-bound: the
// coordinator owns the radio (§8.4), the registry owns what is saved, the
// telemetry session owns packet integrity, the command queue owns writes. None
// of them is shaped like something a screen wants to render.
//
// This is that shape. It is a read model plus a small set of intents: the
// device list, the live sensor values, the heater state, the pairing diagnosis,
// and the handful of actions a user can take. It holds no BLE logic of its own
// — every decision still belongs to the module underneath, and this file is not
// allowed to start a scan, open a link or write a characteristic by itself.
//
// ─────────────────────────────────────────────────────────────────────────
// ONE BEHAVIOUR CHANGE, STATED PLAINLY
// The services this replaces were multi-device: they subscribed to every
// connected spoon at once and merged the streams. The design document is
// explicit that this is wrong (Rule 1, MAX_ACTIVE_READY_SPOONS = 1) because
// two live spoons cannot be attributed to one meal. So the per-device maps
// below hold at most ONE live entry, and `connectedDeviceIds` returns zero or
// one id. Saved spoons still all appear in the device list; only streaming is
// exclusive.
// ─────────────────────────────────────────────────────────────────────────
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';

import 'package:smartspoon/ble/ble_platform_bridge.dart';
import 'package:smartspoon/ble/candidate_selector.dart';
import 'package:smartspoon/ble/connection_coordinator.dart';
import 'package:smartspoon/ble/constants.dart';
import 'package:smartspoon/ble/device_authenticator.dart';
import 'package:smartspoon/ble/device_registry.dart';
import 'package:smartspoon/ble/meal_session_guard.dart';
import 'package:smartspoon/ble/models/command_models.dart';
import 'package:smartspoon/ble/models/runtime_models.dart';
import 'package:smartspoon/ble/models/spoon_models.dart';
import 'package:smartspoon/ble/primary_reclaim_monitor.dart';
import 'package:smartspoon/ble/telemetry_session.dart';
import 'package:smartspoon/features/devices/domain/heater_command.dart';
import 'package:smartspoon/features/devices/domain/services/device_cloud_service.dart';
import 'package:smartspoon/features/devices/domain/services/smart_spoon_ble_service.dart';

ConnectionCoordinator _buildCoordinator() => ConnectionCoordinator(
      registry: DeviceRegistry(),
      authenticator: DeviceAuthenticator(),
      mealGuard: MealSessionGuard(),
      reclaimMonitor: PrimaryReclaimMonitor(),
    );

/// Live, app-facing view of the spoon system.
class SpoonRuntime extends ChangeNotifier {
  static SpoonRuntime? _instance;

  /// App-wide singleton, matching the previous BleService/McuBleService
  /// factories so auth and startup can bind without a BuildContext.
  factory SpoonRuntime() => _instance ??= SpoonRuntime._();

  SpoonRuntime._() : _coordinator = _buildCoordinator() {
    _wire();
  }

  /// Tests inject a coordinator and do not replace the app singleton.
  SpoonRuntime.forTest(ConnectionCoordinator coordinator)
      : _coordinator = coordinator {
    _wire();
  }

  final ConnectionCoordinator _coordinator;

  void _wire() {
    _coordinator.addListener(_onCoordinatorChanged);
    _sightingSub = _coordinator.sightings.listen(_onSighting);
    _rawSub = _coordinator.rawTelemetry.listen(_onRawTelemetry);
    _eventSub = _coordinator.events.listen(_onEventPacket);
    _packetSub = _coordinator.telemetry.packets.listen(_onTelemetryPacket);
  }

  StreamSubscription<BleSighting>? _sightingSub;
  StreamSubscription<List<int>>? _rawSub;
  StreamSubscription<List<int>>? _eventSub;
  StreamSubscription<TelemetryPacket>? _packetSub;

  final StreamController<List<McuSensorData>> _batches =
      StreamController<List<McuSensorData>>.broadcast();

  // Per-device state. At most one live entry (see the header note), but keyed
  // by device so a screen showing a specific spoon asks about that spoon
  // rather than about "the connected one".
  final Map<String, int> _battery = <String, int>{};
  final Map<String, double> _temperature = <String, double>{};
  final Map<String, int> _biteCount = <String, int>{};
  final Map<String, int> _eventFlags = <String, int>{};
  final Map<String, McuSensorData> _latestSample = <String, McuSensorData>{};
  final Map<String, HeaterStatus> _heater = <String, HeaterStatus>{};
  final Map<String, SpoonPairingIssue> _pairingIssue =
      <String, SpoonPairingIssue>{};

  /// Transient scan state, keyed by platform locator. Never persisted — a
  /// cached RSSI is a lie the moment the scan stops.
  final Map<String, _Sighting> _seen = <String, _Sighting>{};

  /// Unknown spoons from the most recent Add-Spoon scan (§14). Deliberately
  /// separate from the saved list: Rule 7 means an unknown device is not a
  /// lesser saved device, it is a different thing entirely.
  List<ScoredCandidate> _discovered = const <ScoredCandidate>[];

  /// Heater capability chosen before claim (Add Spoon / Home quick-connect).
  final Map<String, bool> _pendingCapabilities = <String, bool>{};

  final List<String> _rawLog = <String>[];
  String? _ownerId;

  // Heater command bookkeeping. The firmware event flags are the truth about
  // the rail; these only cover the lag between writing a command and the next
  // event packet.
  final Map<String, bool> _commandedOn = <String, bool>{};
  final Map<String, int> _commandedSetpoint = <String, int>{};
  final Map<String, DateTime> _commandedAt = <String, DateTime>{};

  /// Firmware force-shuts an un-targeted rail after this long, whatever the app
  /// asked for. Downgrading our own optimism at the same moment is what makes
  /// the heater UI's timeout message truthful.
  static const Duration _noTargetMaxRuntime = Duration(minutes: 10);

  DateTime? _lastPacketAt;
  List<int>? _lastRawPacket;
  int _receivedPackets = 0;
  int _packetsThisSecond = 0;
  int _bytesThisSecond = 0;
  double _packetsPerSecond = 0;
  double _dataRate = 0;
  DateTime _rateWindowStart = DateTime.now();
  bool _scanning = false;
  bool _disposed = false;

  DeviceRegistry get _registry => _coordinator.registry;

  // ── Adapter / permissions ────────────────────────────────────────────────

  BleAdapterState get adapterState => _coordinator.adapterState;
  bool get isBluetoothOn => adapterState == BleAdapterState.ready;
  bool get adapterResolved => adapterState != BleAdapterState.unknown;

  /// §34 — the four outcomes stay distinct. "Bluetooth is off" and "you denied
  /// the permission" need different words and different buttons.
  BlePermissionResult get permissionState => switch (adapterState) {
        BleAdapterState.ready => BlePermissionResult.granted,
        BleAdapterState.unauthorized => BlePermissionResult.permanentlyDenied,
        BleAdapterState.poweredOff => BlePermissionResult.bluetoothOff,
        BleAdapterState.unsupported => BlePermissionResult.denied,
        BleAdapterState.unknown => BlePermissionResult.denied,
      };

  // ── Connection state ─────────────────────────────────────────────────────

  SpoonState get connectionState => _coordinator.state;
  DisconnectReason? get lastDisconnectReason =>
      _coordinator.lastDisconnectReason;

  /// Rule 2 — only a streaming spoon counts as connected. A GATT link that
  /// never delivers a packet is not "connected" to a user.
  bool get isConnected => _coordinator.state == SpoonState.streaming;

  SpoonRecord? get _sessionRecord {
    final remote = _coordinator.activeRemoteId;
    if (remote == null) return null;
    return _coordinator.activeSpoon ?? _recordFor(remote);
  }

  /// Display id for the live session: the same id SavedBleDevice uses.
  String? get sessionDisplayId {
    final rec = _sessionRecord;
    if (rec != null) return _locatorOf(rec);
    return _coordinator.activeRemoteId;
  }

  String? get connectedDeviceId => isConnected ? sessionDisplayId : null;

  bool isConnectedTo(String deviceId) => sessionRefersTo(
        queryId: deviceId,
        sessionRemoteId: isConnected ? _coordinator.activeRemoteId : null,
        sessionRecord: isConnected ? _sessionRecord : null,
      );

  bool isDeviceConnected(String deviceId) => isConnectedTo(deviceId);

  /// GATT is up (or coming up) for this spoon — including preparing.
  bool isLinkingTo(String deviceId) {
    if (_coordinator.activeRemoteId == null) return false;
    if (!_coordinator.state.hasLink &&
        _coordinator.state != SpoonState.connecting) {
      return false;
    }
    return sessionRefersTo(
      queryId: deviceId,
      sessionRemoteId: _coordinator.activeRemoteId,
      sessionRecord: _sessionRecord,
    );
  }

  List<String> get connectedDeviceIds {
    final id = connectedDeviceId;
    return id == null ? const <String>[] : <String>[id];
  }

  List<String> get subscribedDeviceIds => connectedDeviceIds;

  /// At most one id (Rule 1). Saved serial + live BLE address collapse here.
  List<String> get linkedDisplayIds => uniqueSpoonDisplayIds(
        ids: [
          for (final d in previousDevices)
            if (isConnectedTo(d.id) || isLinkingTo(d.id)) d.id,
          if (sessionDisplayId != null &&
              (isConnectedTo(sessionDisplayId!) ||
                  isLinkingTo(sessionDisplayId!)))
            sessionDisplayId!,
        ],
        records: _registry.all,
      );

  /// Saved spoons plus the in-progress session so Home never goes blank
  /// while a link is up but the registry id has not been rewritten yet.
  /// Serial and BLE address of the SAME spoon collapse to one row.
  List<String> get visibleDeviceIds => uniqueSpoonDisplayIds(
        ids: [
          for (final d in previousDevices) d.id,
          ?sessionDisplayId,
        ],
        records: _registry.all,
      );

  // ── Device list ──────────────────────────────────────────────────────────

  /// Every saved spoon, as the list renders it.
  List<SavedBleDevice> get previousDevices =>
      _registry.all.map(_viewOf).toList(growable: false);

  SavedBleDevice? getDeviceById(String deviceId) {
    for (final r in _registry.all) {
      if (_locatorOf(r) == deviceId || r.spoonSerial == deviceId) {
        return _viewOf(r);
      }
    }
    return null;
  }

  /// §14 — unknown spoons found by the last Add-Spoon scan.
  List<SavedBleDevice> get discoveredDevices => _discovered
      .map((c) => SavedBleDevice(
            id: c.candidate.bleRemoteId,
            name: c.candidate.displayName,
            lastConnected: DateTime.now(),
            lastRssi: c.candidate.lastRssi,
            lastSeenAt: c.candidate.lastSeen,
            hasHeater: _pendingCapabilities[c.candidate.bleRemoteId] ??
                SavedBleDevice.detectHeater(c.candidate.displayName),
            productId: c.candidate.publicDeviceId.isEmpty
                ? null
                : c.candidate.publicDeviceId,
          ))
      .toList(growable: false);

  /// Discovered spoons that are not already saved.
  List<SavedBleDevice> get unpairedNearbyDevices {
    final knownIds = <String>{
      for (final r in _registry.all) ...[
        r.spoonSerial,
        r.publicDeviceId,
        if (r.bleRemoteId != null) r.bleRemoteId!,
      ],
    };
    return discoveredDevices
        .where((d) => !knownIds.contains(d.id) && !knownIds.contains(d.productId))
        .toList(growable: false);
  }

  /// The one place the device list's label is decided.
  DeviceUiState getDeviceUiState(String deviceId) {
    if (!isBluetoothOn) return DeviceUiState.bluetoothOff;

    if (isConnectedTo(deviceId)) return DeviceUiState.connected;

    // A link that came up but has not proven itself yet (Rule 2). The user sees
    // "Preparing…", which is the honest word for it.
    if (isLinkingTo(deviceId)) {
      final s = _coordinator.state;
      if (s.hasLink) return DeviceUiState.preparing;
      if (s == SpoonState.connecting) return DeviceUiState.connecting;
    }

    // A link that came up and then refused to deliver data is the one thing
    // `error` means. Everything else is just "not here".
    if (_pairingIssue[deviceId] != null &&
        _pairingIssue[deviceId] != SpoonPairingIssue.none) {
      return DeviceUiState.error;
    }

    final seen = _sightingFor(deviceId);
    if (seen != null &&
        DateTime.now().difference(seen.at) < BleConstants.availabilityTimeout) {
      return DeviceUiState.available;
    }
    return DeviceUiState.unavailable;
  }

  _Sighting? _sightingFor(String deviceId) {
    final direct = _seen[deviceId];
    if (direct != null) return direct;
    final rec = _recordFor(deviceId);
    if (rec == null) return null;
    for (final key in rec.identityKeys) {
      final hit = _seen[key];
      if (hit != null) return hit;
    }
    return null;
  }

  // ── Live values ──────────────────────────────────────────────────────────

  int get batteryLevel => batteryLevelFor(connectedDeviceId ?? '');
  int batteryLevelFor(String deviceId) => _liveInt(_battery, deviceId);
  int batteryPercentFor(String deviceId) => batteryLevelFor(deviceId);

  double get temperature => temperatureFor(connectedDeviceId ?? '');
  double temperatureFor(String deviceId) => _liveDouble(_temperature, deviceId);

  int get hardwareBiteCount => hardwareBiteCountFor(connectedDeviceId ?? '');
  int hardwareBiteCountFor(String deviceId) => _liveInt(_biteCount, deviceId);

  /// Null means "firmware has not told us", which is NOT zero bites — the
  /// distinction matters because firmware withholds the count on an
  /// unencrypted link.
  int? get hardwareBiteCountOrNull =>
      hardwareBiteCountOrNullFor(connectedDeviceId ?? '');
  int? hardwareBiteCountOrNullFor(String deviceId) =>
      _liveNullableInt(_biteCount, deviceId);

  McuSensorData? get currentData =>
      _liveValue(_latestSample, connectedDeviceId ?? '');
  DateTime? get lastPacketTime => _lastPacketAt;
  List<int>? get lastRawPacket => _lastRawPacket;

  int get receivedPackets => _receivedPackets;
  double get packetsPerSecond => _packetsPerSecond;
  double get dataRate => _dataRate;
  List<String> get rawDataLog => List<String>.unmodifiable(_rawLog);

  /// The merged sample stream the tremor / motion / bite services consume.
  Stream<List<McuSensorData>> get sensorBatchStream => _batches.stream;

  TelemetryStats get telemetryStats => _coordinator.telemetry.stats;

  // ── Heater ───────────────────────────────────────────────────────────────

  HeaterStatus? get heaterStatus => heaterStatusFor(connectedDeviceId ?? '');
  HeaterStatus? heaterStatusFor(String deviceId) =>
      _liveValue(_heater, deviceId);

  bool deviceHasHeater(String deviceId) {
    // The SAVED record wins once it exists, because ConnectionCoordinator
    // writes the capability the DEVICE declared (owner-status capability bits)
    // into it on every validated connect.
    //
    // This used to return true whenever a pending value was true, which let a
    // provisional name-derived guess outrank the device's own answer: a
    // no-heater spoon that happened to be named "...Pro" would keep showing
    // heater controls forever, since the pending entry is never re-checked
    // against the record. Pending is now only a fallback for the window
    // before any record exists.
    final record = getDeviceById(deviceId);
    if (record != null) return record.hasHeater;
    return _pendingCapabilities[deviceId] ?? false;
  }

  bool get connectedDeviceHasHeater {
    final id = connectedDeviceId;
    if (id == null) return false;
    return deviceHasHeater(id);
  }

  /// Send a heater command. `targetTemp <= 0` means OFF.
  ///
  /// Design §19.3: heater safety must never depend on the phone. A `true`
  /// return means the bytes were written, NOT that the spoon is heating — the
  /// rail bit in the next event packet is the only proof of that, and it is
  /// what [HeaterStatus.railOn] reports.
  Future<bool> setHeaterParameters(
    int targetTemp,
    int maxTemp, {
    String? deviceId,
  }) async {
    final id = deviceId ?? connectedDeviceId;
    if (id == null || !isConnected) return false;

    // NO capability gate here. The previous one required either a saved
    // hasHeater flag, or the heater rail to ALREADY be on, or a maintain
    // request to already be in flight — the last two being circular: the rail
    // cannot come on until this command is sent, and this command refused to
    // send until the rail was on. The saved flag was the only escape, and it
    // is derived from the advertised name, which is the SHORT name "iSpoon" in
    // the primary advertisement — "iSpoon Pro" only arrives in the scan
    // response. A spoon saved before that response landed had hasHeater=false
    // and silently dropped every heater command for the life of the record.
    //
    // The firmware validates the command grammar itself and a unit with no
    // rail simply has nothing to switch, so attempting the write is safe and
    // the honest thing to do: report what the spoon says, do not pre-guess it.
    final queue = _coordinator.commands;
    final serial = queue.boundSerial;
    final nonce = queue.boundNonce;
    if (serial == null || nonce == null) return false;

    final on = targetTemp > 0;
    final result = await queue.enqueue(SpoonCommand(
      commandId: queue.nextCommandId(),
      spoonSerial: serial,
      connectionGeneration: queue.boundGeneration,
      sessionNonce: nonce,
      payload: heaterCommandBytes(targetTemp),
      type: on ? 'heater.on' : 'heater.off',
      // §19.2 — a heater command must land now or not at all. An ON that
      // arrives thirty seconds late is a burn hazard, not a late success.
      ttlClass: CommandTtlClass.immediate,
      safetyCritical: true,
    ));

    if (result.isSuccess) {
      _putLive(_commandedOn, id, on);
      _putLive(_commandedSetpoint, id, on ? targetTemp : 0);
      _putLive(_commandedAt, id, DateTime.now());
      _refreshHeater(id);
      _notify();
    }
    return result.isSuccess;
  }

  /// Flip the spoon's screen polarity and persist it on the device.
  ///
  /// [inverted] true drives the panel's INVON mode, which is what the glass
  /// variant that renders the dark theme as white-on-black needs. Firmware
  /// stores the choice, so this is a one-time fix per spoon.
  Future<bool> setPanelInverted(bool inverted, {String? deviceId}) async {
    final id = deviceId ?? connectedDeviceId;
    if (id == null || !isConnected) return false;

    final queue = _coordinator.commands;
    final serial = queue.boundSerial;
    final nonce = queue.boundNonce;
    if (serial == null || nonce == null) return false;

    final result = await queue.enqueue(SpoonCommand(
      commandId: queue.nextCommandId(),
      spoonSerial: serial,
      connectionGeneration: queue.boundGeneration,
      sessionNonce: nonce,
      payload: panelInvertBytes(inverted: inverted),
      type: 'panel.invert',
      // Cosmetic and persisted by firmware — it is fine if it lands late.
      ttlClass: CommandTtlClass.durable,
      idempotent: true,
    ));
    debugPrint('🖥️ BLE: panel invert ${inverted ? 1 : 0} → ${result.status.name}');
    return result.isSuccess;
  }

  // ── Pairing diagnosis ────────────────────────────────────────────────────

  SpoonPairingIssue pairingIssueFor(String deviceId) =>
      _liveValue(_pairingIssue, deviceId) ?? SpoonPairingIssue.none;

  /// True when the spoon is linked but will never deliver data unaided.
  bool isAuthRejected(String deviceId) =>
      pairingIssueFor(deviceId) != SpoonPairingIssue.none;

  String? repairHintFor(String deviceId) {
    switch (pairingIssueFor(deviceId)) {
      case SpoonPairingIssue.spoonOwnedByOther:
        return 'This spoon is paired to another phone. Hold its button for '
            '6 seconds to release it, then try again.';
      case SpoonPairingIssue.stalePhoneBond:
        return 'Your phone is holding an old pairing for this spoon. Forget '
            '"iSpoon Pro" in system Bluetooth settings, then try again.';
      case SpoonPairingIssue.spoonWasReset:
        return 'This spoon was reset and no longer remembers this phone. '
            'Tap Retry to pair it again.';
      case SpoonPairingIssue.none:
        return null;
    }
  }

  /// What the connection is doing right now, in words a user can read. Null
  /// once the spoon is streaming — there is nothing left to explain.
  String? prepareStepFor(String deviceId) {
    if (!isLinkingTo(deviceId) && !isConnectedTo(deviceId)) return null;
    return switch (_coordinator.state) {
      SpoonState.connecting => 'Connecting…',
      SpoonState.connected => 'Linked — negotiating…',
      SpoonState.discovering => 'Discovering services…',
      SpoonState.validatingIdentity => 'Checking spoon identity…',
      SpoonState.authenticating => 'Pairing…',
      SpoonState.validatingProtocol => 'Checking firmware…',
      SpoonState.subscribing => 'Subscribing to sensors…',
      SpoonState.awaitingFirstTelemetry => 'Waiting for sensor data…',
      SpoonState.stale => 'Sensor data stopped — recovering…',
      SpoonState.recovering => 'Reconnecting…',
      _ => null,
    };
  }

  // ── Intents ──────────────────────────────────────────────────────────────

  bool get isScanning => _scanning;

  /// True while a connect/validate handshake owns the radio. The manager
  /// must show this instead of "Scan paused".
  bool get isConnectHandshake => _coordinator.state.isConnectHandshake;

  /// §14 Add Spoon. Returns when the scan window closes; results are in
  /// [discoveredDevices].
  Future<void> startScan({Duration? timeout}) async {
    if (_scanning) return;
    if (isConnectHandshake) {
      _notify();
      return;
    }
    _scanning = true;
    _notify();
    try {
      _discovered = await _coordinator.scanForNewSpoons(
        window: timeout,
        onCandidateFound: (candidates) {
          _discovered = candidates;
          _notify();
        },
      );
    } finally {
      _scanning = false;
      _notify();
    }
  }

  Future<void> stopScan() async {
    // The coordinator owns the radio; its scan ends with its own window. This
    // exists so a screen can drop out of scanning UI without reaching past the
    // coordinator to the radio (§8.4).
    _scanning = false;
    _notify();
  }

  /// Re-evaluate and connect to the best available spoon.
  Future<void> refresh() => _coordinator.request(
        ConnectionRequest(reason: ConnectionRequestReason.startup),
      );

  /// Legacy MCU subscribe entry. The coordinator already subscribes during
  /// connect; this reconnects if this screen opened before STREAMING.
  Future<void> subscribeToDevice(String deviceId) async {
    if (isConnectedTo(deviceId)) return;
    await reconnectSavedDevice(deviceId);
  }

  /// The user picked a saved spoon. Says what happened, so the screen can
  /// explain a spoon that is not nearby or was reset instead of spinning.
  Future<SwitchOutcome> reconnectSavedDevice(String deviceId) async {
    if (isConnectedTo(deviceId)) return SwitchOutcome.streaming;
    final record = _recordFor(deviceId);
    if (record == null) return SwitchOutcome.pending;
    // Already known to be reset: ask the user straight away instead of
    // spending another connect attempt to be told the same thing.
    if (_coordinator.needsRepair(record.spoonSerial)) {
      return SwitchOutcome.needsRepair;
    }
    if (isLinkingTo(deviceId) &&
        getDeviceUiState(deviceId) != DeviceUiState.error) {
      return SwitchOutcome.pending;
    }
    return _coordinator.selectSpoon(record.spoonSerial);
  }

  /// Pair a saved spoon again after it was reset — only after the user
  /// confirmed it (see [ConnectionCoordinator.reclaimSavedSpoon]).
  Future<ClaimResult> repairSavedDevice(String deviceId) async {
    final record = _recordFor(deviceId);
    if (record == null) {
      return const ClaimResult(ClaimOutcome.connectFailed,
          detail: 'This spoon is no longer saved.');
    }
    final result = await _coordinator.reclaimSavedSpoon(record.spoonSerial);
    if (result.isSuccess) {
      _putLive(_pairingIssue, deviceId, SpoonPairingIssue.none);
    }
    _notify();
    return result;
  }

  /// Case 4.2 — the user confirms switching to another spoon during an active meal.
  Future<void> confirmMealSwitch(String deviceId) async {
    final record = _recordFor(deviceId);
    final serial = record?.spoonSerial ?? deviceId;
    await _coordinator.confirmMealSwitch(serial);
  }

  /// §14 — claim an unknown spoon found by [startScan].
  Future<ClaimResult> connectToDevice(
    String deviceId, {
    String? displayName,
    bool makePrimary = false,
  }) async {
    final existing = _recordFor(deviceId);
    if (existing != null) {
      // Already saved: this is a reconnect, and it must say what happened. It
      // used to report "claimed" unconditionally, so tapping a saved spoon that
      // was switched off told the user "Connected to iSpoon Pro".
      final outcome = await reconnectSavedDevice(deviceId);
      return switch (outcome) {
        SwitchOutcome.streaming ||
        SwitchOutcome.pending =>
          ClaimResult(ClaimOutcome.claimed, record: existing),
        SwitchOutcome.notNearby => const ClaimResult(
            ClaimOutcome.connectFailed,
            detail: "This spoon isn't nearby or is switched off. Wake it "
                '(double-tap), keep it close, and try again.',
          ),
        SwitchOutcome.needsRepair => const ClaimResult(
            ClaimOutcome.connectFailed,
            detail: 'This spoon was reset. Tap it on the Home screen to pair '
                'it again.',
          ),
      };
    }
    final result = await _coordinator.claimSpoon(
      bleRemoteId: deviceId,
      displayName: displayName,
      makePrimary: makePrimary,
      hasHeater: _pendingCapabilities.remove(deviceId),
    );
    if (result.isSuccess) {
      try {
        await SmartSpoonBleService().onDevicePaired(deviceId);
        SmartSpoonBleService().notifyDevicesChanged(
          previousDevices.map((d) => d.id).toList(),
          preferredId: deviceId,
        );
      } catch (e) {
        debugPrint('⚠️ BLE: FGS pairing hook failed: $e');
      }

      // Register the spoon against the signed-in account. Best effort and
      // deliberately not awaited into the result: pairing works offline, and a
      // backend that is down must never stop a spoon from being usable.
      final record = result.record;
      if (record != null) {
        unawaited(DeviceCloudService.registerPairedSpoon(
          productId: record.publicDeviceId,
          firmwareVersion: record.firmwareVersion,
          displayName: record.displayName,
        ));
      }
    }
    _notify();
    return result;
  }

  Future<void> disconnectDevice(String deviceId) async {
    if (!isConnectedTo(deviceId) && !isLinkingTo(deviceId)) return;
    await _coordinator.disconnect();
  }

  /// §16 — order matters, and the coordinator owns it.
  Future<void> forgetDevice(String deviceId) async {
    final record = _recordFor(deviceId);
    if (record == null) return;
    await _coordinator.forgetSpoon(record.spoonSerial);
    _clearDeviceState(deviceId);
    try {
      await SmartSpoonBleService().onDeviceForgotten(deviceId);
    } catch (e) {
      debugPrint('⚠️ BLE: FGS forget hook failed: $e');
    }
    _notify();
  }

  Future<void> removeSavedDevice(String deviceId) => forgetDevice(deviceId);

  Future<void> renameDevice(String deviceId, String newName) async {
    final record = _recordFor(deviceId);
    if (record == null) return;
    final trimmed = newName.trim();
    await _registry.updateAfterValidation(
      record.spoonSerial,
      displayName: trimmed.isEmpty ? null : trimmed,
    );
    _notify();
  }

  /// Record whether this spoon has a heater. Safe to call before claim — the
  /// flag is applied when the record is written.
  Future<void> setDeviceCapability(String deviceId, bool hasHeater) async {
    _pendingCapabilities[deviceId] = hasHeater;
    final record = _recordFor(deviceId);
    if (record != null) {
      await _registry.updateAfterValidation(
        record.spoonSerial,
        hasHeater: hasHeater,
      );
    }
    _notify();
  }

  /// One shared start-up: every caller awaits the SAME future, so nobody gets
  /// past this before the coordinator has loaded its registry and resolved
  /// the adapter.
  ///
  /// This used to set a flag and return early to every caller after the
  /// first — while the first was still inside `_coordinator.initialize`. The
  /// start-up auto-connect then reached the coordinator with the adapter still
  /// `unknown`, the request was dropped, and on a bad launch nothing connected
  /// until the 60 s watchdog noticed.
  Future<void> initialize() => _initialization ??= _initializeOnce();

  Future<void>? _initialization;

  Future<void> _initializeOnce() async {
    await _coordinator.initialize(autoConnect: false);
    _startConnectionWatchdog();
    _notify();
  }

  Timer? _watchdog;

  /// Periodic self-heal: if spoons are saved, the adapter is ready and nothing
  /// is connected or being connected, ask for a connection.
  ///
  /// The coordinator already retries after a failure it SAW. This covers the
  /// case it never saw — a startup path that stalled before it reached the
  /// radio at all. That has happened on a background cold start, where the
  /// process was alive with a healthy foreground service and had simply never
  /// asked for a connection, so no retry timer existed to recover it. A
  /// coordinator that is idle with saved spoons and a working adapter is
  /// always wrong; this notices within a minute regardless of the cause.
  void _startConnectionWatchdog() {
    _watchdog?.cancel();
    _watchdog = Timer.periodic(const Duration(seconds: 60), (_) {
      if (_disposed) return;
      if (_coordinator.isBusy || isConnected) return;
      // An armed OS reconnect IS the connection attempt — passive, and the
      // only one that works while the app is off screen. A request here
      // disarmed it to run an active connect + scan instead, every time the
      // app was briefly woken in the background (push, fetch), and each of
      // those failures cost the spoon its fast path.
      if (_coordinator.isInStandby) return;
      if (_coordinator.adapterState != BleAdapterState.ready) return;
      if (_coordinator.state.isTerminal) return;
      if (_registry.enabled.isEmpty) return;
      if (_coordinator.mealGuard.isPaused) return;

      debugPrint('🐕 BLE watchdog: saved spoons, adapter ready, nothing '
          'connected — requesting a connection');
      unawaited(_coordinator.request(
        ConnectionRequest(reason: ConnectionRequestReason.fallback),
      ));
    });
  }

  /// Scope saved spoons to [userId]. Reloads that user's registry.
  Future<void> bindOwner(String? userId) async {
    final next = userId?.trim() ?? '';
    if (_ownerId == next) return;
    if (_ownerId != null && _ownerId!.isNotEmpty) {
      await _coordinator.onLogout(wipeRegistry: false);
      _clearAllDeviceState();
      _seen.clear();
      _discovered = const [];
    }
    _ownerId = next;
    await _registry.bindOwner(next.isEmpty ? null : next);
    _notify();
    if (_registry.enabled.isNotEmpty &&
        !isConnected &&
        _coordinator.activeRemoteId == null) {
      unawaited(autoConnectToLastDevice());
    }
  }

  /// Drop live links. [wipeStore] is account deletion only.
  Future<void> detachOwner({required bool wipeStore}) async {
    await _coordinator.onLogout(wipeRegistry: wipeStore);
    _clearAllDeviceState();
    _seen.clear();
    _discovered = const [];
    _pendingCapabilities.clear();
    if (!wipeStore) {
      await _registry.bindOwner(null);
    }
    _ownerId = null;
    _notify();
  }

  Future<void> onLogout() => detachOwner(wipeStore: false);

  /// Cold-start / login reconnect. Always [ConnectionCoordinator.request]
  /// with [ConnectionRequestReason.startupRestore] — never a direct connect.
  Future<void> autoConnectToLastDevice() async {
    await initialize();
    final perms = await checkAndRequestPermissions();
    if (perms != BlePermissionResult.granted) return;
    // Start-up asks for this from more than one place (bindOwner and
    // AppSetupService). A second startupRestore arriving while the first is
    // still running outranks it by recency and ABORTS it — the connect then
    // restarts from scratch. Nothing is gained by that, so drop the duplicate.
    if (_coordinator.isBusy || isConnected) return;
    await _coordinator.request(
      ConnectionRequest(reason: ConnectionRequestReason.startupRestore),
    );
  }

  Future<BlePermissionResult> checkAndRequestPermissions() async {
    try {
      if (Platform.isAndroid) {
        // CHECK before requesting. permission_handler's request() needs an
        // Activity to attach its dialog to; when Android restarts this app in
        // the background there isn't one, and the call can simply never
        // return — which stranded the whole auto-connect path behind an await
        // that would never complete. The process stayed alive with a valid
        // foreground service and did absolutely nothing.
        //
        // Already-granted is the normal case after first run, so checking
        // first also skips a pointless round trip.
        final scanStatus = await Permission.bluetoothScan.status;
        final connectStatus = await Permission.bluetoothConnect.status;
        if (scanStatus.isGranted && connectStatus.isGranted) {
          return BlePermissionResult.granted;
        }
        if (!_coordinator.isForeground) {
          // No UI to prompt with. Say so honestly and let the next resume ask.
          debugPrint('🔐 BLE: permissions missing and app is backgrounded — '
              'deferring the request until the user is looking');
          return BlePermissionResult.denied;
        }

        final results = await [
          Permission.bluetoothScan,
          Permission.bluetoothConnect,
          Permission.location,
        ].request().timeout(
          const Duration(seconds: 30),
          onTimeout: () => <Permission, PermissionStatus>{},
        );
        final scanOk = results[Permission.bluetoothScan]?.isGranted ?? false;
        final connOk = results[Permission.bluetoothConnect]?.isGranted ?? false;
        final permanent =
            (results[Permission.bluetoothScan]?.isPermanentlyDenied ?? false) ||
                (results[Permission.bluetoothConnect]?.isPermanentlyDenied ??
                    false);
        if (scanOk && connOk) return BlePermissionResult.granted;
        return permanent
            ? BlePermissionResult.permanentlyDenied
            : BlePermissionResult.denied;
      }
      if (adapterState == BleAdapterState.unknown) {
        await Future<void>.delayed(const Duration(milliseconds: 400));
      }
      return permissionState;
    } catch (e) {
      debugPrint('❌ BLE: permission check failed: $e');
      return BlePermissionResult.denied;
    }
  }

  void suspend() {
    _coordinator.onAppPaused();
  }

  Future<void> resume() async {
    // The last spoon that STREAMED — not whatever was last attempted, which
    // after a refused switch is the spoon that just said no.
    await _coordinator.onAppResumed(
      lastLiveSerial: _coordinator.lastLiveSerial,
    );
    _notify();
  }

  Future<void> setAppInForeground(bool foreground) async {
    if (foreground) {
      await resume();
    } else {
      suspend();
    }
  }

  // ── Ingest ───────────────────────────────────────────────────────────────

  void _onCoordinatorChanged() {
    unawaited(SmartSpoonBleService().updateKeepAliveNotification(
      connected: _coordinator.state == SpoonState.streaming,
    ));
    final live = _coordinator.activeRemoteId;
    if (live != null) _refreshHeater(live);
    // The diagnosis has to be attached to the spoon the coordinator was
    // TRYING to reach, not to the live one — every failure path tears the
    // session down before setting the state that explains the failure, so by
    // now there is no live session to hang it on.
    final attempted = live ?? _coordinator.lastAttemptedRemoteId;
    if (attempted != null) _syncPairingIssue(attempted);
    _notify();
  }

  void _syncPairingIssue(String deviceId) {
    switch (_coordinator.state) {
      case SpoonState.busy:
        _putLive(_pairingIssue, deviceId, SpoonPairingIssue.spoonOwnedByOther);
        break;
      case SpoonState.unclaimed:
        _putLive(_pairingIssue, deviceId, SpoonPairingIssue.spoonWasReset);
        break;
      case SpoonState.requiresReclaim:
        // Two different faults land here. A spoon that answered "no owner"
        // was reset and only needs pairing again; a pairing the PHONE refused
        // is the stale-bond case, fixed in system Bluetooth settings. Telling
        // the reset case to go and forget the spoon sent users to a settings
        // page that could not help them.
        _putLive(
          _pairingIssue,
          deviceId,
          _coordinator.lastDisconnectReason ==
                  DisconnectReason.claimEpochMismatch
              ? SpoonPairingIssue.spoonWasReset
              : SpoonPairingIssue.stalePhoneBond,
        );
        break;
      case SpoonState.streaming:
        _putLive(_pairingIssue, deviceId, SpoonPairingIssue.none);
        break;
      default:
        if (_coordinator.lastDisconnectReason ==
            DisconnectReason.ownershipMismatch) {
          _putLive(
            _pairingIssue,
            deviceId,
            SpoonPairingIssue.spoonOwnedByOther,
          );
        }
    }
  }

  void _onSighting(BleSighting s) {
    final sight = _Sighting(rssi: s.rssi, at: DateTime.now());
    _seen[s.remoteId] = sight;
    final pid = s.publicDeviceId;
    if (pid.isNotEmpty) {
      _seen[pid] = sight;
      final record = _registry.byPublicDeviceId(pid);
      if (record != null) {
        for (final key in record.identityKeys) {
          _seen[key] = sight;
        }
      }
    }
    _notify();
  }

  void _onTelemetryPacket(TelemetryPacket packet) {
    final id = _coordinator.activeRemoteId;
    if (id == null) return;

    _lastPacketAt = packet.receivedAt;
    _countPacket(packet.rawLength);

    if (packet.batteryPercent != null) {
      _putLive(_battery, id, packet.batteryPercent!);
    }
    if (packet.temperatureC != null) {
      _putLive(_temperature, id, packet.temperatureC!);
    }
    if (packet.biteCount != null) _applyBiteCount(id, packet.biteCount!);

    if (packet.samples.isNotEmpty) {
      final temp = _temperature[id] ?? 0.0;
      // The batch header carries one temperature for all ten samples; the
      // device timestamps are relative to the first, so the wall clock is
      // anchored at receipt minus the batch duration.
      final firstWall = packet.receivedAt.subtract(
        Duration(
          milliseconds: TelemetryPacketLayout.nominalPacketPeriodMs -
              TelemetryPacketLayout.samplePeriodMs,
        ),
      );
      final batch = <McuSensorData>[
        for (final s in packet.samples)
          McuSensorData(
            accelX: s.ax,
            accelY: s.ay,
            accelZ: s.az,
            gyroX: s.gx,
            gyroY: s.gy,
            gyroZ: s.gz,
            temperature: temp,
            deviceId: id,
            timestamp: firstWall.add(Duration(milliseconds: s.offsetMs)),
          ),
      ];
      _putLive(_latestSample, id, batch.last);
      if (!_batches.isClosed) _batches.add(batch);
    }

    _refreshHeater(id);
    _notifyLive();
  }

  /// The 9-byte low-power heartbeat, which [TelemetrySession] correctly refuses
  /// to treat as a telemetry packet but which still carries real readings.
  void _onRawTelemetry(List<int> raw) {
    _lastRawPacket = raw;
    if (raw.length != SpoonHeartbeat.length) return;
    final id = _coordinator.activeRemoteId;
    if (id == null) return;
    final beat = SpoonHeartbeat.tryParse(raw);
    if (beat == null) return;
    _countPacket(raw.length);
    _putLive(_battery, id, beat.batteryPercent);
    if (beat.temperatureC != null) {
      _putLive(_temperature, id, beat.temperatureC!);
    }
    if (beat.biteCount != null) _applyBiteCount(id, beat.biteCount!);
    _lastPacketAt = DateTime.now();
    _refreshHeater(id);
    _notifyLive();
  }

  void _onEventPacket(List<int> raw) {
    final id = _coordinator.activeRemoteId;
    if (id == null) return;
    final event = SpoonEventPacket.tryParse(raw);
    if (event == null) return;

    _lastRawPacket = raw;
    _countPacket(raw.length);
    _putLive(_battery, id, event.batteryPercent);
    if (event.temperatureC != null) {
      _putLive(_temperature, id, event.temperatureC!);
    }
    if (event.biteCount != null) _applyBiteCount(id, event.biteCount!);
    _putLive(_eventFlags, id, event.flags);
    _lastPacketAt = DateTime.now();
    if (eventFlagsHasHeater(event.flags) ||
        eventFlagsHasHeaterReq(event.flags)) {
      unawaited(_upgradeHeaterCapability(id));
    }
    _refreshHeater(id);
    // Coalesced like the other packet paths: firmware sends this stream at
    // telemetry rate while the app is backgrounded, and 200 ms of latency on a
    // heater indicator is imperceptible next to the rebuild cost.
    _notifyLive();
  }

  Future<void> _upgradeHeaterCapability(String deviceId) async {
    if (deviceHasHeater(deviceId)) return;
    _pendingCapabilities[deviceId] = true;
    final record = _recordFor(deviceId);
    if (record == null) return;
    await _registry.updateAfterValidation(
      record.spoonSerial,
      hasHeater: true,
    );
  }

  /// The hardware counter is absolute and monotonic. A value that goes
  /// backwards means the spoon rebooted, so the baseline is dropped rather than
  /// recorded as the user un-eating several bites.
  void _applyBiteCount(String deviceId, int count) {
    final last = _liveNullableInt(_biteCount, deviceId);
    if (last != null && count < last) {
      for (final key in _keysFor(deviceId)) {
        _biteCount.remove(key);
      }
    }
    _putLive(_biteCount, deviceId, count);
  }

  void _countPacket(int bytes) {
    _receivedPackets++;
    _packetsThisSecond++;
    _bytesThisSecond += bytes;
    final raw = _lastRawPacket;
    if (raw != null) {
      final hex = raw
          .take(24)
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join(' ');
      _rawLog.add('${DateTime.now().toIso8601String()}  $hex');
      if (_rawLog.length > 20) _rawLog.removeAt(0);
    }
    final elapsed = DateTime.now().difference(_rateWindowStart);
    if (elapsed >= const Duration(seconds: 1)) {
      final secs = elapsed.inMilliseconds / 1000.0;
      _packetsPerSecond = _packetsThisSecond / secs;
      _dataRate = _bytesThisSecond / secs;
      _packetsThisSecond = 0;
      _bytesThisSecond = 0;
      _rateWindowStart = DateTime.now();
    }
  }

  void _refreshHeater(String deviceId) {
    var commandedOn = _liveValue(_commandedOn, deviceId) ?? false;
    final setpoint = _liveInt(_commandedSetpoint, deviceId);
    final temp = temperatureFor(deviceId);
    final commandedAt = _liveValue(_commandedAt, deviceId);

    // Not a guess — a fact about firmware: once this long has passed since an
    // un-targeted ON, the safety thread has already shut the rail off. Saying
    // otherwise would leave the UI claiming heat that is not there.
    var timedOut = false;
    if (commandedOn && commandedAt != null && setpoint <= 0) {
      if (DateTime.now().difference(commandedAt) >= _noTargetMaxRuntime) {
        timedOut = true;
        commandedOn = false;
      }
    }

    final flags = _liveNullableInt(_eventFlags, deviceId);
    final maintainOn = heaterMaintainShown(
      eventFlags: flags,
      commandedOn: commandedOn,
      commandedAt: commandedAt,
    );
    final railOn = heaterRailShownOn(
      eventFlags: flags,
      commandedOn: commandedOn,
    );

    _putLive(_heater, deviceId, HeaterStatus(
      mode: !maintainOn
          ? HeaterMode.off
          : (setpoint > 0 ? HeaterMode.setpoint : HeaterMode.manual),
      setpointC: setpoint,
      tempC: temp,
      railOn: railOn,
      maintainOn: maintainOn,
      fault: false,
      timeout: timedOut,
      lowBattery: batteryLevelFor(deviceId) < 10,
      ntcOk: flags == null ? true : eventFlagsHasNtcOk(flags),
      vbusPresent: flags != null && eventFlagsHasVbus(flags),
      receivedAt: DateTime.now(),
    ));
  }

  // ── Helpers ──────────────────────────────────────────────────────────────

  /// The id every screen shows for a saved spoon. The cached locator when there
  /// is one, otherwise the stable serial — never empty, because an empty id
  /// makes two different spoons compare equal in a list.
  String _locatorOf(SpoonRecord r) => r.bleRemoteId ?? r.spoonSerial;

  SpoonRecord? _recordFor(String deviceId) {
    for (final r in _registry.all) {
      if (r.refersTo(deviceId)) return r;
    }
    return null;
  }

  Iterable<String> _keysFor(String deviceId) {
    final keys = <String>{if (deviceId.isNotEmpty) deviceId};
    final rec = _recordFor(deviceId);
    if (rec != null) {
      keys.addAll(rec.identityKeys);
    } else if (sessionRefersTo(
      queryId: deviceId,
      sessionRemoteId: _coordinator.activeRemoteId,
      sessionRecord: _sessionRecord,
    )) {
      final live = _sessionRecord;
      if (live != null) keys.addAll(live.identityKeys);
      final remote = _coordinator.activeRemoteId;
      if (remote != null) keys.add(remote);
    }
    return keys.where((k) => k.isNotEmpty);
  }

  int _liveInt(Map<String, int> map, String deviceId) =>
      _liveNullableInt(map, deviceId) ?? 0;

  int? _liveNullableInt(Map<String, int> map, String deviceId) {
    for (final key in _keysFor(deviceId)) {
      final value = map[key];
      if (value != null) return value;
    }
    return null;
  }

  double _liveDouble(Map<String, double> map, String deviceId) {
    for (final key in _keysFor(deviceId)) {
      final value = map[key];
      if (value != null) return value;
    }
    return 0.0;
  }

  T? _liveValue<T>(Map<String, T> map, String deviceId) {
    for (final key in _keysFor(deviceId)) {
      final value = map[key];
      if (value != null) return value;
    }
    return null;
  }

  void _putLive<T>(Map<String, T> map, String deviceId, T value) {
    for (final key in _keysFor(deviceId)) {
      map[key] = value;
    }
  }

  SavedBleDevice _viewOf(SpoonRecord r) {
    final id = _locatorOf(r);
    final seen = _seen[id];
    return SavedBleDevice(
      id: id,
      name: r.displayName,
      lastConnected: r.lastConnectedAt ?? DateTime.now(),
      firmwareVersion: r.firmwareVersion,
      batteryLevel: _battery[id],
      lastSeenAt: seen?.at,
      lastRssi: seen?.rssi ?? r.lastRssi,
      hasHeater: r.hasHeater,
      autoConnect: r.enabled,
      productId: r.publicDeviceId.isEmpty ? null : r.publicDeviceId,
    );
  }

  void _clearDeviceState(String deviceId) {
    _battery.remove(deviceId);
    _temperature.remove(deviceId);
    _biteCount.remove(deviceId);
    _eventFlags.remove(deviceId);
    _latestSample.remove(deviceId);
    _heater.remove(deviceId);
    _pairingIssue.remove(deviceId);
    _commandedOn.remove(deviceId);
    _commandedSetpoint.remove(deviceId);
    _commandedAt.remove(deviceId);
    _seen.remove(deviceId);
  }

  void _clearAllDeviceState() {
    for (final id in _battery.keys.toList()) {
      _clearDeviceState(id);
    }
    _battery.clear();
    _temperature.clear();
    _biteCount.clear();
    _eventFlags.clear();
    _latestSample.clear();
    _heater.clear();
    _pairingIssue.clear();
  }

  void _notify() {
    if (_disposed) return;
    _coalesceTimer?.cancel();
    _coalesceTimer = null;
    _coalescePending = false;
    notifyListeners();
  }

  Timer? _coalesceTimer;
  bool _coalescePending = false;

  /// Notify at most every [_uiCoalesceWindow], for updates that arrive at
  /// packet rate.
  ///
  /// This used to be two notifiers: a low-frequency one for the device list and
  /// a ~10 Hz one for sensor data. Merging them into a single runtime also
  /// merged their notification rates, so a widget that only cares about which
  /// spoons are saved began rebuilding ten times a second. Telemetry-driven
  /// updates are coalesced here; state changes still notify immediately,
  /// because a connection state that arrives late is a UI that lies.
  ///
  /// The sample stream ([sensorBatchStream]) is untouched — analytics still
  /// see every packet.
  void _notifyLive() {
    if (_disposed || _coalescePending) return;
    _coalescePending = true;
    _coalesceTimer = Timer(_uiCoalesceWindow, () {
      _coalescePending = false;
      _coalesceTimer = null;
      if (!_disposed) notifyListeners();
    });
  }

  /// 5 Hz. Fast enough that a temperature readout feels live, slow enough that
  /// a device list is not rebuilt on every notification packet.
  static const Duration _uiCoalesceWindow = Duration(milliseconds: 200);

  @override
  void dispose() {
    _disposed = true;
    // This object is an app-wide singleton, but it is ALSO handed to a
    // ChangeNotifierProvider, and Provider disposes what it is given. Clearing
    // the slot means the next SpoonRuntime() builds a live instance instead of
    // handing back a corpse with every subscription cancelled — which on a hot
    // restart or a provider rebuild is a spoon that silently never reconnects.
    if (identical(_instance, this)) _instance = null;
    _coalesceTimer?.cancel();
    _coalesceTimer = null;
    _watchdog?.cancel();
    _watchdog = null;
    _coordinator.removeListener(_onCoordinatorChanged);
    unawaited(_sightingSub?.cancel());
    unawaited(_rawSub?.cancel());
    unawaited(_eventSub?.cancel());
    unawaited(_packetSub?.cancel());
    unawaited(_batches.close());
    super.dispose();
  }
}

class _Sighting {
  const _Sighting({required this.rssi, required this.at});
  final int rssi;
  final DateTime at;
}
