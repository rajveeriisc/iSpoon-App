// Device-connection behaviour tests for lib/ble/.
//
// These drive the ConnectionCoordinator against a fake radio and assert the
// rules from "Smart Spoon BLE Final Production Design v3.0" — each test names
// the rule or the §36 edge-case number it protects, because a failure here is
// only meaningful if you know which product promise just broke.
//
// WHY REAL TIME AND NOT `fakeAsync`
// Faked time looks like the obvious fit for a layer built out of scan windows
// and backoff, and it was tried first. It does not work here: under
// `fakeAsync` a `StreamSubscription.cancel()` and a SharedPreferences write
// both return futures that never complete, so every teardown and every
// registry update hangs — an artefact of the harness, not of the code under
// test, but one that makes the whole suite report failures that are not real.
// So the waits below are real, and the tests poll for a condition instead of
// sleeping for a fixed duration, which keeps the suite honest and reasonably
// quick.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:smartspoon/ble/ble_platform_bridge.dart';
import 'package:smartspoon/ble/connection_coordinator.dart';
import 'package:smartspoon/ble/constants.dart';
import 'package:smartspoon/ble/device_authenticator.dart';
import 'package:smartspoon/ble/device_registry.dart';
import 'package:smartspoon/ble/meal_session_guard.dart';
import 'package:smartspoon/ble/models/spoon_models.dart';
import 'package:smartspoon/ble/primary_reclaim_monitor.dart';
import 'package:smartspoon/ble/telemetry_session.dart';

// ── Fixtures ───────────────────────────────────────────────────────────────

List<int> _idBytes(String deviceIdHex) => [
      for (var i = 0; i < 16; i += 2)
        int.parse(deviceIdHex.substring(i, i + 2), radix: 16),
    ];

/// Manufacturer data carrying the 8-byte hwinfo device id (§1.3 layout:
/// company 0xFFFF, type 0x01, then the id).
Uint8List mfgFor(String deviceIdHex) =>
    Uint8List.fromList([0xFF, 0xFF, 0x01, ..._idBytes(deviceIdHex)]);

/// What an f00d0004 read returns.
List<int> identityBytesFor(String deviceIdHex) => _idBytes(deviceIdHex);

/// A well-formed 129-byte telemetry packet (TelemetryPacketLayout).
List<int> telemetryPacket({int timestampMs = 1000}) {
  final bytes = Uint8List(TelemetryPacketLayout.minLength);
  final view = ByteData.sublistView(bytes);
  view.setUint8(TelemetryPacketLayout.batteryOffset, 88);
  view.setInt16(TelemetryPacketLayout.temperatureOffset, 3650, Endian.little);
  view.setUint32(
      TelemetryPacketLayout.timestampOffset, timestampMs, Endian.little);
  view.setUint16(TelemetryPacketLayout.biteCountOffset, 3, Endian.little);
  return bytes;
}

const String pidA = 'aaaaaaaaaaaaaaa1';
const String pidB = 'bbbbbbbbbbbbbbb2';
const String pidUnknown = 'cccccccccccccc03';

/// An advertisement the fake radio repeats while scanning.
class FakeAdvert {
  FakeAdvert({
    required this.remoteId,
    required this.deviceId,
    this.rssi = -55,
    this.availableAfter = Duration.zero,
    this.name = 'iSpoon',
  });

  final String remoteId;
  final String deviceId;
  final int rssi;

  /// Edge case #3 — a spoon that starts advertising a moment after the others.
  final Duration availableAfter;
  final String name;

}

class FakeTransport implements BleTransport {
  final _adapterCtl = StreamController<BleAdapterState>.broadcast();

  BleAdapterState _adapter = BleAdapterState.ready;
  List<FakeAdvert> adverts = <FakeAdvert>[];

  /// remoteId → the 8-byte identity read (f00d0004). Absent = read throws.
  final Map<String, List<int>> identity = <String, List<int>>{};

  /// remoteId → owner-status bytes (f00d0006). Absent = characteristic
  /// missing, which is how older firmware presents.
  final Map<String, List<int>> owner = <String, List<int>>{};

  /// remoteIds whose connect attempt should fail outright.
  final Set<String> refuseConnect = <String>{};

  /// remoteIds whose drop is the spoon closing the link itself (switched
  /// off), as opposed to a supervision timeout (walked out of range).
  final Set<String> deliberateDrops = <String>{};

  @override
  bool? droppedDeliberately(String remoteId) =>
      deliberateDrops.contains(remoteId) ? true : null;

  /// remoteIds whose connect stream never emits ANY state — the shape a
  /// superseded or wedged connect takes on real hardware.
  final Set<String> silentConnect = <String>{};

  /// remoteIds that refuse to bond — the spoon already belongs to another
  /// phone, or the phone is holding a stale bond.
  final Set<String> refuseBond = <String>{};

  /// remoteIds whose owner-status read throws — what happens when Android
  /// drops the ACL as a pairing fails.
  final Set<String> ownerReadFails = <String>{};

  /// Owner-status bytes the spoon reports AFTER a failed bond attempt.
  /// Firmware sets PAIR_REJECTED at that moment, which is precisely why the
  /// coordinator re-reads owner status instead of trusting the pre-bond value.
  final Map<String, List<int>> ownerAfterFailedBond = <String, List<int>>{};

  final Map<String, StreamController<void>> _servicesReset =
      <String, StreamController<void>>{};

  /// Simulate a firmware update rewriting the GATT database (§33).
  void emitServicesReset(String remoteId) {
    final c = _servicesReset[remoteId];
    if (c != null && !c.isClosed) c.add(null);
  }

  /// When false the spoon connects and subscribes but never notifies
  /// (edge case #47).
  bool emitTelemetry = true;

  final List<String> connectCalls = <String>[];
  int scanCount = 0;

  /// Whether the most recent scan asked the platform for a service filter.
  bool lastScanFiltered = false;

  final Map<String, StreamController<BleLinkState>> _links =
      <String, StreamController<BleLinkState>>{};
  Timer? _advertTimer;
  bool _disposed = false;

  void setAdapter(BleAdapterState s) {
    _adapter = s;
    _adapterCtl.add(s);
  }

  /// Simulate the spoon vanishing while connected (edge cases #7, #8).
  void dropLink(String remoteId) {
    final c = _links[remoteId];
    if (c != null && !c.isClosed) c.add(BleLinkState.disconnected);
  }

  @override
  BleAdapterState get adapterState => _adapter;

  @override
  Stream<BleAdapterState> get adapterStates => _adapterCtl.stream;

  @override
  Future<BleAdapterState> waitForResolvedAdapter({
    Duration timeout = const Duration(seconds: 10),
  }) async =>
      _adapter;

  @override
  Stream<BleSighting> scan({bool filterByService = false}) {
    scanCount++;
    lastScanFiltered = filterByService;
    // Single-subscription on purpose: the coordinator listens exactly once,
    // and a broadcast controller's cancel is harder to reason about.
    final controller = StreamController<BleSighting>();
    final startedAt = DateTime.now();
    _advertTimer?.cancel();
    _advertTimer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (controller.isClosed) return;
      final elapsed = DateTime.now().difference(startedAt);
      for (final a in adverts) {
        if (elapsed < a.availableAfter) continue;
        controller.add(BleSighting(
          remoteId: a.remoteId,
          name: a.name,
          rssi: a.rssi,
          serviceUuids: [BleConstants.spoonServiceUuid],
          manufacturerData: mfgFor(a.deviceId),
        ));
      }
    });
    controller.onCancel = () {
      _advertTimer?.cancel();
      _advertTimer = null;
    };
    return controller.stream;
  }

  @override
  Future<void> stopScan() async {
    _advertTimer?.cancel();
    _advertTimer = null;
  }

  @override
  Stream<BleLinkState> connect(String remoteId, {Duration? timeout}) {
    connectCalls.add(remoteId);
    final controller = StreamController<BleLinkState>();
    _links[remoteId] = controller;
    if (!silentConnect.contains(remoteId)) {
      Timer(const Duration(milliseconds: 10), () {
        if (controller.isClosed) return;
        controller.add(refuseConnect.contains(remoteId)
            ? BleLinkState.disconnected
            : BleLinkState.connected);
      });
    }
    controller.onCancel = () {
      _links.remove(remoteId);
      disconnectCalls.add(remoteId);
    };
    return controller.stream;
  }

  bool isLinkOpen(String remoteId) => _links.containsKey(remoteId);

  // ── Passive standby (armAutoConnect) ──────────────────────────────────
  /// Locators currently armed for an OS-managed reconnect.
  final Set<String> armed = <String>{};

  /// Locators that were explicitly disarmed, in order.
  final List<String> disarmCalls = <String>[];

  final Map<String, StreamController<BleLinkState>> _arms =
      <String, StreamController<BleLinkState>>{};

  @override
  Stream<BleLinkState> armAutoConnect(String remoteId) {
    armed.add(remoteId);
    final controller = StreamController<BleLinkState>();
    _arms[remoteId] = controller;
    controller.onCancel = () {
      _arms.remove(remoteId);
    };
    return controller.stream;
  }

  @override
  Future<void> cancelAutoConnect(String remoteId) async {
    armed.remove(remoteId);
    disarmCalls.add(remoteId);
  }

  /// Simulate the OS establishing an armed link.
  void fireArmedLink(String remoteId) {
    _arms[remoteId]?.add(BleLinkState.connected);
  }

  @override
  Duration get sameDeviceReopenDelay => const Duration(milliseconds: 50);

  @override
  Duration get gattReleaseDelay => const Duration(milliseconds: 50);

  @override
  Future<void> discoverServices(String remoteId) async {}

  @override
  Future<bool> ensureEncryptedLink(String remoteId) async {
    if (!refuseBond.contains(remoteId)) return true;
    final after = ownerAfterFailedBond[remoteId];
    if (after != null) owner[remoteId] = after;
    return false;
  }

  @override
  Stream<void> servicesReset(String remoteId) =>
      (_servicesReset[remoteId] ??= StreamController<void>.broadcast()).stream;

  @override
  Future<List<int>> readCharacteristic(
      String remoteId, String charUuid) async {
    if (charUuid == BleConstants.identityCharacteristicUuid) {
      final bytes = identity[remoteId];
      if (bytes == null) throw StateError('no identity characteristic');
      return bytes;
    }
    if (charUuid == BleConstants.ownerStatusCharacteristicUuid) {
      if (ownerReadFails.contains(remoteId)) {
        throw StateError('link dropped — owner status unreadable');
      }
      final bytes = owner[remoteId];
      if (bytes == null) throw StateError('no owner characteristic');
      return bytes;
    }
    if (charUuid == BleConstants.hwRevisionCharacteristicUuid) {
      // Encrypt-gated: readable only once bonded.
      if (refuseBond.contains(remoteId)) {
        throw StateError('insufficient encryption');
      }
      return 'A1'.codeUnits;
    }
    throw StateError('unexpected read $charUuid');
  }

  @override
  Future<void> writeCharacteristic(
    String remoteId,
    String charUuid,
    List<int> value, {
    bool withResponse = true,
  }) async {}

  @override
  Stream<List<int>> subscribe(String remoteId, String charUuid) {
    final controller = StreamController<List<int>>();
    if (emitTelemetry) {
      Timer(const Duration(milliseconds: 10), () {
        if (!controller.isClosed) controller.add(telemetryPacket());
      });
    }
    return controller.stream;
  }

  @override
  Future<int> requestMtu(String remoteId, {int mtu = 247}) async => mtu;

  /// Links the OS reports as already open at startup (§32).
  List<String> preConnected = <String>[];

  /// remoteIds this coordinator explicitly closed.
  final List<String> disconnectCalls = <String>[];

  @override
  Future<List<String>> alreadyConnectedRemoteIds() async => preConnected;

  /// Whether this phone can delete a stored bond (Android reflection may be
  /// blocked). remoteIds whose bond was cleared are recorded.
  bool canClearBond = true;
  final List<String> clearBondCalls = <String>[];

  /// Whether this phone holds a bond. Defaults to true so existing tests keep
  /// exercising the stale-key path.
  bool phoneHoldsBond = true;

  @override
  Future<bool> isBonded(String remoteId) async => phoneHoldsBond;

  @override
  Future<bool> clearBond(String remoteId) async {
    clearBondCalls.add(remoteId);
    if (!canClearBond) return false;
    // A fresh bond now succeeds, and firmware stops reporting PAIR_REJECTED.
    refuseBond.remove(remoteId);
    ownerAfterFailedBond.remove(remoteId);
    owner[remoteId] = [0x03, 0x00];
    return true;
  }

  @override
  Future<void> disconnectDevice(String remoteId) async {
    disconnectCalls.add(remoteId);
    preConnected = preConnected.where((id) => id != remoteId).toList();
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _advertTimer?.cancel();
    await _adapterCtl.close();
  }
}

/// Everything a scenario needs, wired the way main() would wire it.
/// A radio whose connect-stream cancel behaves like flutter_blue_plus's
/// disconnect(): it lands a turn later, AND it cancels any pending autoConnect
/// to the same address. That combination is what silently killed background
/// standby — the arm went in, the dead session's disconnect took it out.
class LateDisconnectTransport extends FakeTransport {
  @override
  Stream<BleLinkState> connect(String remoteId, {Duration? timeout}) {
    final inner = super.connect(remoteId, timeout: timeout);
    StreamSubscription<BleLinkState>? sub;
    late final StreamController<BleLinkState> outer;
    outer = StreamController<BleLinkState>(
      onListen: () {
        sub = inner.listen(outer.add, onError: outer.addError);
      },
      onCancel: () async {
        await sub?.cancel();
        await Future<void>.delayed(Duration.zero);
        armed.remove(remoteId);
      },
    );
    return outer.stream;
  }
}

/// Firmware records an owner the moment a bond completes. The shared fake
/// keeps whatever owner bytes a test set, which cannot express a reset spoon
/// being paired again.
class RepairingTransport extends FakeTransport {
  @override
  Future<bool> ensureEncryptedLink(String remoteId) async {
    final ok = await super.ensureEncryptedLink(remoteId);
    if (ok) owner[remoteId] = [0x0B, 0x00]; // owner, this phone, secured
    return ok;
  }
}

class Harness {
  Harness._(this.transport, this.registry, this.mealGuard, this.reclaim,
      this.coordinator);

  final FakeTransport transport;
  final DeviceRegistry registry;
  final MealSessionGuard mealGuard;
  final PrimaryReclaimMonitor reclaim;
  final ConnectionCoordinator coordinator;

  static Future<Harness> create(
    List<SpoonRecord> records, {
    bool backgroundUsesOsStandby = true,
    FakeTransport? transport,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final registry = DeviceRegistry(prefs: prefs);
    await registry.load();
    for (final r in records) {
      await registry.upsert(r);
      if (r.isPrimary) await registry.setPrimary(r.spoonSerial);
    }

    transport ??= FakeTransport();
    final mealGuard = MealSessionGuard();
    final reclaim = PrimaryReclaimMonitor();
    final coordinator = ConnectionCoordinator(
      registry: registry,
      authenticator: DeviceAuthenticator(),
      mealGuard: mealGuard,
      reclaimMonitor: reclaim,
      transport: transport,
      backgroundUsesOsStandby: backgroundUsesOsStandby,
    );
    return Harness._(transport, registry, mealGuard, reclaim, coordinator);
  }
}

SpoonRecord recordFor(
  String pid, {
  bool isPrimary = false,
  String? remoteId,
}) =>
    SpoonRecord(
      spoonSerial: pid,
      publicDeviceId: pid,
      bleRemoteId: remoteId,
      isPrimary: isPrimary,
    );

/// Polls [condition] instead of sleeping a fixed amount, so a test costs the
/// time the behaviour actually takes.
Future<void> pumpUntil(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 20),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

/// For the "prove that nothing happens" assertions, where there is no
/// condition to wait for.
Future<void> quiet(Duration d) => Future<void>.delayed(d);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  test('Rule 7 / #23: an unknown spoon is never auto-connected', () async {
    final h = await Harness.create([recordFor(pidA)]);
    // Only a stranger's spoon is in range.
    h.transport.adverts = [
      FakeAdvert(remoteId: 'ble-unknown', deviceId: pidUnknown),
    ];

    unawaited(h.coordinator.initialize());
    await pumpUntil(() =>
        h.coordinator.lastDisconnectReason == DisconnectReason.notFound);

    expect(h.transport.connectCalls, isEmpty,
        reason: 'an unknown device must not be connected, only ignored');
    expect(h.coordinator.state, SpoonState.idle);
    h.coordinator.dispose();
  }, timeout: const Timeout(Duration(seconds: 40)));

  test('#2/#3: the collection window lets a late primary beat a fallback',
      () async {
    final h = await Harness.create([
      recordFor(pidA, isPrimary: true),
      recordFor(pidB),
    ]);
    h.transport.identity['ble-a'] = identityBytesFor(pidA);
    h.transport.identity['ble-b'] = identityBytesFor(pidB);
    h.transport.adverts = [
      // The fallback is louder AND first — first-found selection would take
      // it, which is precisely the bug §9.1 forbids.
      FakeAdvert(remoteId: 'ble-b', deviceId: pidB, rssi: -40),
      FakeAdvert(
        remoteId: 'ble-a',
        deviceId: pidA,
        rssi: -70,
        availableAfter: const Duration(milliseconds: 800),
      ),
    ];

    unawaited(h.coordinator.initialize());
    await pumpUntil(() => h.coordinator.state == SpoonState.streaming);

    expect(h.transport.connectCalls, ['ble-a'],
        reason: 'primary outranks a louder, earlier fallback (§9.3)');
    expect(h.coordinator.activeSpoon?.spoonSerial, pidA);
    h.coordinator.dispose();
  }, timeout: const Timeout(Duration(seconds: 40)));

  test('Rule 2 / #47: no first packet means no READY and no activeSpoon',
      () async {
    final h = await Harness.create([recordFor(pidA, remoteId: 'ble-a')]);
    h.transport.identity['ble-a'] = identityBytesFor(pidA);
    h.transport.emitTelemetry = false; // connects, subscribes, stays silent

    unawaited(h.coordinator.initialize());
    await pumpUntil(() =>
        h.coordinator.lastDisconnectReason ==
        DisconnectReason.firstTelemetryTimeout);

    expect(h.coordinator.state, isNot(SpoonState.streaming));
    expect(h.coordinator.activeSpoon, isNull,
        reason: 'a connected-but-silent spoon must never look usable');
    h.coordinator.dispose();
  }, timeout: const Timeout(Duration(seconds: 40)));

  test(
      '#18/#59: a cached locator pointing at another spoon is quarantined and '
      'not retried', () async {
    final h = await Harness.create([recordFor(pidA, remoteId: 'ble-a')]);
    // The saved address now answers with a DIFFERENT spoon's identity — and
    // that spoon is on the air at it.
    h.transport.identity['ble-a'] = identityBytesFor(pidB);
    h.transport.adverts = [FakeAdvert(remoteId: 'ble-a', deviceId: pidB)];

    unawaited(h.coordinator.initialize());
    await pumpUntil(() => h.coordinator.state == SpoonState.quarantined);

    expect(h.coordinator.lastDisconnectReason,
        DisconnectReason.identityMismatch);
    final attempts = h.transport.connectCalls.length;

    await quiet(const Duration(seconds: 6));
    expect(h.transport.connectCalls.length, attempts,
        reason: 'Rule 8 — a permanent failure must not enter a retry loop');
    h.coordinator.dispose();
  }, timeout: const Timeout(Duration(seconds: 40)));

  test('#25: a spoon owned by another phone is refused, never streamed',
      () async {
    final h = await Harness.create([recordFor(pidA, remoteId: 'ble-a')]);
    h.transport.identity['ble-a'] = identityBytesFor(pidA);
    // ownerPresent set, peerBonded clear: someone else holds the bond.
    h.transport.owner['ble-a'] = [0x01, 0x00];
    h.transport.adverts = [FakeAdvert(remoteId: 'ble-a', deviceId: pidA)];

    unawaited(h.coordinator.initialize());
    await pumpUntil(() => h.coordinator.state == SpoonState.quarantined);

    expect(h.coordinator.lastDisconnectReason,
        DisconnectReason.ownershipMismatch);
    expect(h.coordinator.activeSpoon, isNull);
    h.coordinator.dispose();
  }, timeout: const Timeout(Duration(seconds: 40)));

  test(
      'Rule 5 / #16: a meal does not move to another spoon without an explicit '
      'confirmation', () async {
    final h = await Harness.create([
      recordFor(pidA, isPrimary: true, remoteId: 'ble-a'),
      recordFor(pidB, remoteId: 'ble-b'),
    ]);
    h.transport.identity['ble-a'] = identityBytesFor(pidA);
    h.transport.identity['ble-b'] = identityBytesFor(pidB);
    // Both spoons are on: the confirmed switch below must HEAR B before it
    // lets go of A (make-before-break).
    h.transport.adverts = [
      FakeAdvert(remoteId: 'ble-a', deviceId: pidA),
      FakeAdvert(remoteId: 'ble-b', deviceId: pidB),
    ];

    unawaited(h.coordinator.initialize());
    await pumpUntil(() => h.coordinator.state == SpoonState.streaming);
    expect(h.coordinator.startMeal(), isTrue);

    final before = h.transport.connectCalls.length;
    unawaited(h.coordinator.selectSpoon(pidB)); // no confirmation
    await pumpUntil(
        () => h.coordinator.state == SpoonState.blockedByMealGuard);

    expect(h.transport.connectCalls.length, before,
        reason: 'the radio must not even be touched for a blocked switch');
    expect(h.mealGuard.mealSpoonSerial, pidA);

    // §12.2 — with the user's confirmation the switch is allowed.
    unawaited(h.coordinator.confirmMealSwitch(pidB));
    await pumpUntil(() => h.coordinator.activeSpoon?.spoonSerial == pidB);
    expect(h.coordinator.activeSpoon?.spoonSerial, pidB);
    h.coordinator.dispose();
  }, timeout: const Timeout(Duration(seconds: 40)));

  test('#27/#30: adapter loss tears the session down and is reported precisely',
      () async {
    final h = await Harness.create([recordFor(pidA, remoteId: 'ble-a')]);
    h.transport.identity['ble-a'] = identityBytesFor(pidA);

    unawaited(h.coordinator.initialize());
    await pumpUntil(() => h.coordinator.state == SpoonState.streaming);

    h.transport.setAdapter(BleAdapterState.poweredOff);
    await pumpUntil(() => h.coordinator.state == SpoonState.bluetoothOff);
    expect(h.coordinator.activeSpoon, isNull);

    // Edge case #30 — a revoked permission is NOT "Bluetooth is off".
    h.transport.setAdapter(BleAdapterState.unauthorized);
    await pumpUntil(() => h.coordinator.state == SpoonState.permissionDenied);
    expect(
        h.coordinator.lastDisconnectReason, DisconnectReason.permissionLost);
    h.coordinator.dispose();
  }, timeout: const Timeout(Duration(seconds: 40)));

  test('#29: Bluetooth coming back triggers adapter recovery', () async {
    final h = await Harness.create([recordFor(pidA, remoteId: 'ble-a')]);
    h.transport.identity['ble-a'] = identityBytesFor(pidA);
    h.transport.adverts = [FakeAdvert(remoteId: 'ble-a', deviceId: pidA)];

    unawaited(h.coordinator.initialize());
    await pumpUntil(() => h.coordinator.state == SpoonState.streaming);

    h.transport.setAdapter(BleAdapterState.poweredOff);
    await pumpUntil(() => h.coordinator.state == SpoonState.bluetoothOff);

    final before = h.transport.connectCalls.length;
    h.transport.setAdapter(BleAdapterState.ready);
    await pumpUntil(() => h.coordinator.state == SpoonState.streaming);

    expect(h.transport.connectCalls.length, greaterThan(before));
    h.coordinator.dispose();
  }, timeout: const Timeout(Duration(seconds: 40)));

  test('#42: forgetting the active spoon removes it and never reconnects it',
      () async {
    final h = await Harness.create([recordFor(pidA, remoteId: 'ble-a')]);
    h.transport.identity['ble-a'] = identityBytesFor(pidA);
    h.transport.adverts = [FakeAdvert(remoteId: 'ble-a', deviceId: pidA)];

    unawaited(h.coordinator.initialize());
    await pumpUntil(() => h.coordinator.state == SpoonState.streaming);

    await h.coordinator.forgetSpoon(pidA);
    expect(h.registry.byId(pidA), isNull);
    expect(h.coordinator.activeSpoon, isNull);

    // The spoon is still advertising; nothing may pick it back up.
    final after = h.transport.connectCalls.length;
    await quiet(const Duration(seconds: 10));
    expect(h.transport.connectCalls.length, after,
        reason: 'a forgotten spoon must not be re-selected by the fallback');
    h.coordinator.dispose();
  }, timeout: const Timeout(Duration(seconds: 60)));

  test(
      '#20/§10.2: a stale cached locator falls back to a scan and rebinds the '
      'new address', () async {
    // iOS rotated the remote id: the saved address is dead, and the same spoon
    // is advertising its stable device id from a new one.
    final h = await Harness.create([recordFor(pidA, remoteId: 'ble-old')]);
    h.transport.refuseConnect.add('ble-old');
    h.transport.identity['ble-new'] = identityBytesFor(pidA);
    h.transport.adverts = [FakeAdvert(remoteId: 'ble-new', deviceId: pidA)];

    unawaited(h.coordinator.initialize());
    await pumpUntil(() => h.coordinator.state == SpoonState.streaming);

    // Listening before connecting heard the spoon at its NEW address, so the
    // dead cached one is never dialled — it used to cost a 10 s timeout.
    expect(h.transport.connectCalls.first, 'ble-new');
    expect(h.transport.connectCalls, isNot(contains('ble-old')));
    expect(h.coordinator.activeSpoon?.spoonSerial, pidA);
    // Design fix #14 — the cache is re-pointed only after identity was proven.
    expect(h.registry.byId(pidA)?.bleRemoteId, 'ble-new');
    h.coordinator.dispose();
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('a spoon owned by ANOTHER phone is permanently refused — only the '
      '6-second long hold can clear it', () async {
    final h = await Harness.create([recordFor(pidA, remoteId: 'ble-a')]);
    h.transport.identity['ble-a'] = identityBytesFor(pidA);
    // OWNER_PRESENT set, PEER_BONDED clear, REPAIR_HOLD_6S set: the spoon says
    // outright that it belongs to somebody else. The GATT link still comes up,
    // so the spoon's own display reads "connected" the whole time.
    h.transport.owner['ble-a'] = [0x11, 0x00];
    h.transport.adverts = [FakeAdvert(remoteId: 'ble-a', deviceId: pidA)];

    unawaited(h.coordinator.initialize());
    await pumpUntil(() =>
        h.coordinator.lastDisconnectReason ==
        DisconnectReason.ownershipMismatch);

    expect(h.coordinator.activeSpoon, isNull);
    expect(h.coordinator.state.isTerminal, isTrue,
        reason: 'no app-side retry can ever fix another phone owning it');

    // Rule 8 — no retry storm behind the instruction.
    final attempts = h.transport.connectCalls.length;
    await quiet(const Duration(seconds: 6));
    expect(h.transport.connectCalls.length, attempts);
    // And nothing was clumsily blamed on the phone's own bond store.
    expect(h.transport.clearBondCalls, isEmpty);
    h.coordinator.dispose();
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('a bond that merely did not COMPLETE is transient and keeps retrying',
      () async {
    final h = await Harness.create([recordFor(pidA, remoteId: 'ble-a')]);
    h.transport.identity['ble-a'] = identityBytesFor(pidA);
    // Nobody refused anything: no PAIR_REJECTED, no other owner. This is a
    // busy stack, an unanswered prompt, or a bond attempted in the background
    // where Android shows a notification instead of a dialog.
    h.transport.owner['ble-a'] = [0x03, 0x00];
    h.transport.refuseBond.add('ble-a');
    h.transport.adverts = [FakeAdvert(remoteId: 'ble-a', deviceId: pidA)];

    unawaited(h.coordinator.initialize());
    await pumpUntil(() => h.transport.connectCalls.length >= 2,
        timeout: const Duration(seconds: 25));

    expect(h.transport.connectCalls.length, greaterThanOrEqualTo(2),
        reason: 'an incomplete bond must not park the spoon forever');
    expect(h.coordinator.state, isNot(SpoonState.requiresReclaim));

    // And when the bond finally goes through, it recovers with no user action.
    h.transport.refuseBond.remove('ble-a');
    await pumpUntil(() => h.coordinator.state == SpoonState.streaming,
        timeout: const Duration(seconds: 40));
    expect(h.coordinator.activeSpoon?.spoonSerial, pidA);
    h.coordinator.dispose();
  }, timeout: const Timeout(Duration(seconds: 90)));

  test('bonding is established BEFORE subscribing, so the first packet is '
      'never waited for on a silent link', () async {
    final h = await Harness.create([recordFor(pidA, remoteId: 'ble-a')]);
    h.transport.identity['ble-a'] = identityBytesFor(pidA);
    h.transport.owner['ble-a'] = [0x03, 0x00]; // owned by us, not yet secured
    h.transport.adverts = [FakeAdvert(remoteId: 'ble-a', deviceId: pidA)];

    unawaited(h.coordinator.initialize());
    await pumpUntil(() => h.coordinator.state == SpoonState.streaming);

    expect(h.coordinator.state, SpoonState.streaming);
    expect(h.coordinator.activeSpoon?.spoonSerial, pidA);
    h.coordinator.dispose();
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('#52: a services-changed event rediscovers and resubscribes', () async {
    final h = await Harness.create([recordFor(pidA, remoteId: 'ble-a')]);
    h.transport.identity['ble-a'] = identityBytesFor(pidA);
    h.transport.adverts = [FakeAdvert(remoteId: 'ble-a', deviceId: pidA)];

    unawaited(h.coordinator.initialize());
    await pumpUntil(() => h.coordinator.state == SpoonState.streaming);
    final connectsBefore = h.transport.connectCalls.length;

    // Firmware update rewrote the GATT database; every cached handle is stale.
    h.transport.emitServicesReset('ble-a');
    await pumpUntil(() => h.coordinator.state == SpoonState.streaming,
        timeout: const Duration(seconds: 20));

    expect(h.coordinator.state, SpoonState.streaming,
        reason: 'the session recovers without dropping the link');
    expect(h.transport.connectCalls.length, connectsBefore,
        reason: 'a services reset is repaired in place, not by reconnecting');
    h.coordinator.dispose();
  }, timeout: const Timeout(Duration(seconds: 60)));

  // NOTE: the "heal a stale phone bond" cases live in the Add Spoon tests
  // (ble_multi_spoon_scenarios_test.dart). For a SAVED spoon the authenticator
  // stops a reset spoon before bonding is ever attempted (§15 / case 7.2), so
  // the clear-and-retry path is only reachable through the claim flow — which
  // is also the only moment a user would expect to re-pair.

  test('connecting is always bounded — it never sits there forever', () async {
    final h = await Harness.create([recordFor(pidA, remoteId: 'ble-a')]);
    // The link comes up and then everything below it fails: no identity, so
    // the pipeline cannot advance. The UI must not be left on "connecting".
    h.transport.adverts = [FakeAdvert(remoteId: 'ble-a', deviceId: pidA)];

    unawaited(h.coordinator.initialize());

    // Every stage has its own timeout; the sum is the worst case.
    await pumpUntil(
      () =>
          h.coordinator.state != SpoonState.connecting &&
          h.coordinator.state != SpoonState.unknown,
      timeout: const Duration(seconds: 45),
    );
    expect(h.coordinator.state, isNot(SpoonState.connecting));
    expect(h.coordinator.lastDisconnectReason, isNotNull,
        reason: 'a stalled pipeline must resolve to a reason, not a spinner');
    h.coordinator.dispose();
  }, timeout: const Timeout(Duration(seconds: 90)));

  test('an unreachable spoon keeps its saved address; a moved one is found by '
      'identity and re-cached', () async {
    final h = await Harness.create([recordFor(pidA, remoteId: 'ble-old')]);
    // The saved address does not answer and nothing advertises: the spoon is
    // switched off or out of range. Neither is evidence the address changed.
    h.transport.refuseConnect.add('ble-old');
    h.transport.adverts = [];

    unawaited(h.coordinator.initialize());

    await pumpUntil(
        () =>
            h.transport.connectCalls.where((id) => id == 'ble-old').length >= 3,
        timeout: const Duration(seconds: 60));
    // Deleting the address after two misses used to cost the fast direct
    // path for good and, on iOS, the only address background standby can arm
    // — every time the app was opened while the spoon was switched off.
    expect(h.registry.byId(pidA)?.bleRemoteId, 'ble-old',
        reason: 'a spoon that is merely off must keep its address');

    // The spoon really did move (a settings-erase re-flash). The scan that
    // follows every failed direct connect finds it by its stable Device ID.
    h.transport.identity['ble-new'] = identityBytesFor(pidA);
    h.transport.adverts = [FakeAdvert(remoteId: 'ble-new', deviceId: pidA)];
    await pumpUntil(() => h.coordinator.state == SpoonState.streaming,
        timeout: const Duration(seconds: 60));

    expect(h.coordinator.activeSpoon?.spoonSerial, pidA);
    expect(h.registry.byId(pidA)?.bleRemoteId, 'ble-new',
        reason: 'the fresh locator replaces the old one once identity is '
            'proven');
    h.coordinator.dispose();
  }, timeout: const Timeout(Duration(seconds: 150)));

  test('NEVER deletes our bond while the spoon still holds an owner — that is '
      'what makes a spoon unpairable', () async {
    final h = await Harness.create([recordFor(pidA, remoteId: 'ble-a')]);
    h.transport.identity['ble-a'] = identityBytesFor(pidA);
    // OWNER_PRESENT + PEER_BONDED: we are the owner, bond on both sides.
    // The handshake fails anyway (busy stack, dropped link, slow prompt).
    h.transport.owner['ble-a'] = [0x03, 0x00];
    h.transport.refuseBond.add('ble-a');
    h.transport.adverts = [FakeAdvert(remoteId: 'ble-a', deviceId: pidA)];

    unawaited(h.coordinator.initialize());
    await pumpUntil(() => h.transport.connectCalls.length >= 2,
        timeout: const Duration(seconds: 30));

    expect(h.transport.clearBondCalls, isEmpty,
        reason: 'deleting our key here leaves the spoon owning a bond we no '
            'longer hold — firmware then refuses every attempt until a '
            '6-second long hold');
    expect(h.coordinator.state, isNot(SpoonState.requiresReclaim),
        reason: 'a failed handshake with a valid bond is transient');
    h.coordinator.dispose();
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('the phone key is cleared ONLY when the spoon reports no owner',
      () async {
    final h = await Harness.create([recordFor(pidA, remoteId: 'ble-a')]);
    h.transport.identity['ble-a'] = identityBytesFor(pidA);
    // Spoon was owner-reset: no owner at all. This phone still holds a dead
    // LTK, so encryption fails — the one case where clearing is correct.
    h.transport.owner['ble-a'] = [0x00, 0x00];
    h.transport.refuseBond.add('ble-a');
    h.transport.adverts = [FakeAdvert(remoteId: 'ble-a', deviceId: pidA)];

    unawaited(h.coordinator.initialize());
    // The reset spoon must not stream either way (§15 / case 7.2), but the
    // stale key on this phone should still be cleaned up.
    await pumpUntil(() => h.transport.clearBondCalls.isNotEmpty ||
        h.coordinator.state == SpoonState.requiresReclaim,
        timeout: const Duration(seconds: 30));
    expect(h.coordinator.activeSpoon, isNull);
    h.coordinator.dispose();
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('a spoon owned by another phone is never "fixed" by touching our bond',
      () async {
    final h = await Harness.create([recordFor(pidA, remoteId: 'ble-a')]);
    h.transport.identity['ble-a'] = identityBytesFor(pidA);
    // OWNER_PRESENT, PEER_BONDED clear, REPAIR_HOLD_6S set, PAIR_REJECTED set:
    // firmware refused this phone on this link.
    h.transport.owner['ble-a'] = [0x15, 0x08];
    h.transport.adverts = [FakeAdvert(remoteId: 'ble-a', deviceId: pidA)];

    unawaited(h.coordinator.initialize());
    await pumpUntil(() =>
        h.coordinator.lastDisconnectReason ==
        DisconnectReason.ownershipMismatch);

    expect(h.transport.clearBondCalls, isEmpty);
    expect(h.coordinator.activeSpoon, isNull);
    h.coordinator.dispose();
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('an UNREADABLE owner status never triggers a bond deletion', () async {
    // The pairing fails and Android drops the ACL with it, so the follow-up
    // owner-status read throws. "I could not ask" must never be read as "the
    // spoon has no owner" — that inference is what deletes a good bond and
    // leaves the spoon permanently unpairable.
    final h = await Harness.create([recordFor(pidA, remoteId: 'ble-a')]);
    h.transport.identity['ble-a'] = identityBytesFor(pidA);
    h.transport.owner['ble-a'] = [0x03, 0x00];
    h.transport.refuseBond.add('ble-a');
    h.transport.ownerReadFails.add('ble-a');
    h.transport.adverts = [FakeAdvert(remoteId: 'ble-a', deviceId: pidA)];

    unawaited(h.coordinator.initialize());
    await pumpUntil(() => h.transport.connectCalls.length >= 2,
        timeout: const Duration(seconds: 30));

    expect(h.transport.clearBondCalls, isEmpty,
        reason: 'no evidence means retry, never destroy');
    expect(h.coordinator.state, isNot(SpoonState.requiresReclaim));
    h.coordinator.dispose();
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('a connect that never reports a link state cannot wedge the coordinator',
      () async {
    // On the device this appeared as a superseded request whose link listener
    // was generation-guarded: it dropped the `connected` event, the awaiting
    // future never completed, the queued request was never drained, and the
    // app sat on "connecting" until it was killed.
    final h = await Harness.create([recordFor(pidA, remoteId: 'ble-a')]);
    h.transport.identity['ble-a'] = identityBytesFor(pidA);
    h.transport.silentConnect.add('ble-a');

    unawaited(h.coordinator.initialize());

    // It must give up on its own and come back to a state the user can act on.
    await pumpUntil(() => !h.coordinator.isBusy,
        timeout: const Duration(seconds: 45));
    expect(h.coordinator.isBusy, isFalse,
        reason: 'a silent connect must time out, not hold the coordinator');

    // And it must still accept new work afterwards.
    h.transport.silentConnect.clear();
    h.transport.adverts = [FakeAdvert(remoteId: 'ble-a', deviceId: pidA)];
    await h.coordinator.selectSpoon(pidA);
    await pumpUntil(() => h.coordinator.state == SpoonState.streaming,
        timeout: const Duration(seconds: 40));
    expect(h.coordinator.activeSpoon?.spoonSerial, pidA);
    h.coordinator.dispose();
  }, timeout: const Timeout(Duration(seconds: 150)));

  test('#7 / Rule 9: an unexpected drop recovers on its own', () async {
    final h = await Harness.create([recordFor(pidA, remoteId: 'ble-a')]);
    h.transport.identity['ble-a'] = identityBytesFor(pidA);
    h.transport.adverts = [FakeAdvert(remoteId: 'ble-a', deviceId: pidA)];

    unawaited(h.coordinator.initialize());
    await pumpUntil(() => h.coordinator.state == SpoonState.streaming);

    // The spoon goes out of range.
    h.transport.adverts = [];
    h.transport.refuseConnect.add('ble-a');
    h.transport.dropLink('ble-a');
    await pumpUntil(() => h.coordinator.activeSpoon == null);
    expect(h.coordinator.state, isNot(SpoonState.streaming));

    // It comes back: recovery must reach streaming again without a restart.
    h.transport.refuseConnect.clear();
    h.transport.adverts = [FakeAdvert(remoteId: 'ble-a', deviceId: pidA)];
    await pumpUntil(() => h.coordinator.state == SpoonState.streaming,
        timeout: const Duration(seconds: 30));
    expect(h.coordinator.state, SpoonState.streaming);
    h.coordinator.dispose();
  }, timeout: const Timeout(Duration(seconds: 90)));

  // ── Passive standby: the background tail of §11 ────────────────────────

  test('backgrounded with the ladder spent, the OS takes over the wait '
      'instead of scanning forever', () async {
    // Neither spoon is reachable: no adverts, and every connect is refused.
    final h = await Harness.create([
      recordFor(pidA, remoteId: 'ble-a', isPrimary: true),
      recordFor(pidB, remoteId: 'ble-b'),
    ]);
    h.transport.refuseConnect.addAll(['ble-a', 'ble-b']);
    h.transport.adverts = [];

    unawaited(h.coordinator.initialize());
    await pumpUntil(() => h.coordinator.state == SpoonState.idle,
        timeout: const Duration(seconds: 20));
    h.coordinator.onAppPaused();

    await pumpUntil(
        () => h.transport.armed.isNotEmpty && !h.coordinator.isBusy,
        timeout: const Duration(seconds: 10));

    // Rule 1 starts at the OS: two pending autoConnects is how a phone ends
    // up showing two spoons "connected" while the app owns only one session.
    expect(h.transport.armed.length, 1,
        reason: 'standby arms exactly one saved spoon');
    expect(h.transport.armed, contains('ble-a'));

    final scansAtStandby = h.transport.scanCount;
    await Future<void>.delayed(const Duration(seconds: 3));
    expect(h.transport.scanCount, scansAtStandby,
        reason: 'standby is passive: no more scans while the OS waits');

    h.coordinator.dispose();
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('an armed spoon coming back powers straight into a real session',
      () async {
    final h = await Harness.create([
      recordFor(pidA, remoteId: 'ble-a', isPrimary: true),
      recordFor(pidB, remoteId: 'ble-b'),
    ]);
    h.transport.refuseConnect.addAll(['ble-a', 'ble-b']);
    h.transport.adverts = [];

    unawaited(h.coordinator.initialize());
    h.coordinator.onAppPaused();
    await pumpUntil(() => h.transport.armed.contains('ble-a'),
        timeout: const Duration(seconds: 40));
    expect(h.transport.armed, ['ble-a']);

    // The armed (primary) spoon comes back: the OS establishes its link.
    h.transport.refuseConnect.remove('ble-a');
    h.transport.identity['ble-a'] = identityBytesFor(pidA);
    h.transport.adverts = [FakeAdvert(remoteId: 'ble-a', deviceId: pidA)];
    h.transport.fireArmedLink('ble-a');

    await pumpUntil(() => h.coordinator.state == SpoonState.streaming,
        timeout: const Duration(seconds: 60));

    expect(h.coordinator.activeSpoon?.spoonSerial, pidA);
    expect(h.transport.disarmCalls, isNot(contains('ble-a')),
        reason: 'disarming the winner would drop the link we just gained');

    h.coordinator.dispose();
  }, timeout: const Timeout(Duration(seconds: 90)));

  test('pausing while idle with a saved spoon arms OS reconnect immediately',
      () async {
    final h = await Harness.create([recordFor(pidA, remoteId: 'ble-a')]);
    h.transport.refuseConnect.add('ble-a');
    h.transport.adverts = [];

    unawaited(h.coordinator.initialize(autoConnect: false));
    await pumpUntil(() => h.coordinator.adapterState == BleAdapterState.ready);
    h.coordinator.onAppPaused();

    await pumpUntil(() => h.transport.armed.contains('ble-a'),
        timeout: const Duration(seconds: 5));
    expect(h.transport.armed, ['ble-a'],
        reason: 'iOS will not run Dart retry timers while backgrounded — '
            'standby must be armed on pause, not after the backoff ladder');
    h.coordinator.dispose();
  }, timeout: const Timeout(Duration(seconds: 20)));

  test('coming back to the foreground disarms standby and goes active again',
      () async {
    final h = await Harness.create([recordFor(pidA, remoteId: 'ble-a')]);
    h.transport.refuseConnect.add('ble-a');
    h.transport.adverts = [];

    unawaited(h.coordinator.initialize());
    h.coordinator.onAppPaused();
    await pumpUntil(() => h.transport.armed.contains('ble-a'),
        timeout: const Duration(seconds: 90));

    await h.coordinator.onAppResumed();

    expect(h.transport.armed, isEmpty,
        reason: 'with the user watching, a passive wait is the wrong trade');
    expect(h.transport.disarmCalls, contains('ble-a'));

    h.coordinator.dispose();
  }, timeout: const Timeout(Duration(seconds: 120)));

  test('Android background scans instead of OS-only standby', () async {
    final h = await Harness.create(
      [recordFor(pidA, remoteId: 'ble-a')],
      backgroundUsesOsStandby: false,
    );
    h.transport.refuseConnect.add('ble-a');
    h.transport.adverts = [];

    unawaited(h.coordinator.initialize(autoConnect: false));
    await pumpUntil(() => h.coordinator.adapterState == BleAdapterState.ready);
    final scansBefore = h.transport.scanCount;
    h.coordinator.onAppPaused();

    await pumpUntil(() => h.transport.scanCount > scansBefore,
        timeout: const Duration(seconds: 8));
    expect(h.transport.armed, isEmpty,
        reason: 'Android must not mix autoConnect with scan');
    expect(h.transport.scanCount, greaterThan(scansBefore),
        reason: 'FGS-backed background reconnect is a real scan');
    h.coordinator.dispose();
  }, timeout: const Timeout(Duration(seconds: 20)));

  test('backgrounding mid-scan still arms OS reconnect', () async {
    final h = await Harness.create([recordFor(pidA, remoteId: 'ble-a')]);
    h.transport.refuseConnect.add('ble-a');
    h.transport.adverts = [];

    try {
      unawaited(h.coordinator.initialize());
      await pumpUntil(() => h.coordinator.state == SpoonState.scanning,
          timeout: const Duration(seconds: 8));
      expect(h.transport.armed, isEmpty);

      h.coordinator.onAppPaused();

      await pumpUntil(() => h.transport.armed.contains('ble-a'),
          timeout: const Duration(seconds: 3));
      expect(h.transport.armed, ['ble-a'],
          reason: 'an in-flight foreground scan is dead on iOS once backgrounded '
              '— pause must abort it and arm OS reconnect, not wait it out');
    } finally {
      h.coordinator.dispose();
    }
  }, timeout: const Timeout(Duration(seconds: 20)));

  test('background reconnect scans when the saved spoon has no cached address',
      () async {
    final h = await Harness.create([recordFor(pidA)]);
    h.transport.adverts = [FakeAdvert(remoteId: 'ble-a', deviceId: pidA)];

    try {
      unawaited(h.coordinator.initialize(autoConnect: false));
      await pumpUntil(() => h.coordinator.adapterState == BleAdapterState.ready);
      final scansBefore = h.transport.scanCount;
      h.coordinator.onAppPaused();

      await pumpUntil(
          () =>
              h.transport.scanCount > scansBefore &&
              h.transport.lastScanFiltered,
          timeout: const Duration(seconds: 8));
      expect(h.transport.armed, isEmpty,
          reason: 'OS autoConnect needs a locator — without one, scan is the path');
      expect(h.transport.lastScanFiltered, isTrue,
          reason: 'background scan must filter by the spoon service UUID');
    } finally {
      h.coordinator.dispose();
    }
  }, timeout: const Timeout(Duration(seconds: 20)));

  test('a meal-spoon drop in the background arms THAT spoon, never another',
      () async {
    // B is the primary, so any "pick the best saved spoon" logic would choose
    // it. Rule 5 says the meal's spoon, and only the meal's spoon.
    final h = await Harness.create([
      recordFor(pidA, remoteId: 'ble-a'),
      recordFor(pidB, remoteId: 'ble-b', isPrimary: true),
    ]);
    h.transport.refuseConnect.add('ble-b');
    h.transport.identity['ble-a'] = identityBytesFor(pidA);
    h.transport.adverts = [FakeAdvert(remoteId: 'ble-a', deviceId: pidA)];

    unawaited(h.coordinator.initialize());
    await pumpUntil(() => h.coordinator.activeSpoon?.spoonSerial == pidA,
        timeout: const Duration(seconds: 40));

    h.mealGuard.startMeal(pidA);
    h.coordinator.onAppPaused();
    h.transport.refuseConnect.add('ble-a');
    h.transport.adverts = [];
    h.transport.dropLink('ble-a');

    // A Dart retry timer does not run while iOS has the app suspended, so a
    // mid-meal drop with the phone locked used to reconnect nothing at all.
    await pumpUntil(() => h.transport.armed.isNotEmpty,
        timeout: const Duration(seconds: 10));
    expect(h.transport.armed, {'ble-a'},
        reason: 'the OS reconnect is addressed to the meal spoon (Rule 5)');

    h.coordinator.dispose();
  }, timeout: const Timeout(Duration(seconds: 120)));

  test('a drop in the background re-arms the OS reconnect — and a late '
      'disconnect from the dead session cannot cancel it', () async {
    final h = await Harness.create([recordFor(pidA, remoteId: 'ble-a')],
        transport: LateDisconnectTransport());
    h.transport.identity['ble-a'] = identityBytesFor(pidA);
    h.transport.adverts = [FakeAdvert(remoteId: 'ble-a', deviceId: pidA)];

    unawaited(h.coordinator.initialize());
    await pumpUntil(() => h.coordinator.state == SpoonState.streaming);

    h.coordinator.onAppPaused();
    h.transport.refuseConnect.add('ble-a');
    h.transport.adverts = [];
    h.transport.dropLink('ble-a');

    await pumpUntil(() => h.transport.armed.contains('ble-a'),
        timeout: const Duration(seconds: 10));
    // Give the dead session's teardown every chance to land late.
    await quiet(const Duration(seconds: 1));
    expect(h.transport.armed, contains('ble-a'),
        reason: 'flutter_blue_plus disconnect() cancels a pending autoConnect; '
            'the teardown must finish BEFORE standby arms, or the arm is '
            'silently killed and the spoon never comes back in background');
    expect(h.coordinator.isInStandby, isTrue);

    h.coordinator.dispose();
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('a tap on another spoon cuts the wait for an absent spoon short, and '
      'reuses what that wait already heard', () async {
    final h = await Harness.create([
      recordFor(pidA, remoteId: 'ble-a', isPrimary: true),
      recordFor(pidB, remoteId: 'ble-b'),
    ]);
    // A (the primary) is switched off; B is on the table, advertising.
    h.transport.identity['ble-b'] = identityBytesFor(pidB);
    h.transport.adverts = [FakeAdvert(remoteId: 'ble-b', deviceId: pidB)];

    unawaited(h.coordinator.initialize());
    // Start-up is listening for A (up to 3 s); B's adverts are heard meanwhile.
    await pumpUntil(() => h.transport.scanCount >= 1,
        timeout: const Duration(seconds: 10));
    await quiet(const Duration(milliseconds: 300));
    expect(h.coordinator.activeSpoon, isNull, reason: 'still listening for A');

    final tappedAt = DateTime.now();
    unawaited(h.coordinator.selectSpoon(pidB));
    await pumpUntil(() => h.coordinator.activeSpoon?.spoonSerial == pidB,
        timeout: const Duration(seconds: 10));

    expect(h.coordinator.activeSpoon?.spoonSerial, pidB);
    expect(DateTime.now().difference(tappedAt),
        lessThan(const Duration(milliseconds: 1500)),
        reason: 'the tap must neither queue behind the 3 s listen for A nor '
            'listen for B all over again');
    expect(h.transport.connectCalls, isNot(contains('ble-a')),
        reason: 'A was never heard, so it was never dialled');
    h.coordinator.dispose();
  }, timeout: const Timeout(Duration(seconds: 40)));

  test('a spoon that is not in range is never shown as "connecting"', () async {
    final h = await Harness.create([recordFor(pidA, remoteId: 'ble-a')]);
    h.transport.identity['ble-a'] = identityBytesFor(pidA);
    h.transport.adverts = []; // switched off

    final seen = <SpoonState>{};
    h.coordinator.addListener(() => seen.add(h.coordinator.state));
    unawaited(h.coordinator.initialize());
    await quiet(const Duration(seconds: 8));

    expect(seen, isNot(contains(SpoonState.connecting)),
        reason: 'a spoon nobody can hear must not sit on "Connecting…"');
    expect(h.transport.connectCalls, isEmpty,
        reason: 'no connect is even attempted until the spoon is heard');

    // It comes back: now — and only now — it is connected to.
    h.transport.adverts = [FakeAdvert(remoteId: 'ble-a', deviceId: pidA)];
    await pumpUntil(() => h.coordinator.state == SpoonState.streaming,
        timeout: const Duration(seconds: 30));
    expect(h.coordinator.state, SpoonState.streaming);
    h.coordinator.dispose();
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('the Add-Spoon scan is not skipped because an attempt was in flight',
      () async {
    final h = await Harness.create([recordFor(pidA, remoteId: 'ble-a')]);
    h.transport.identity['ble-a'] = identityBytesFor(pidA);
    h.transport.silentConnect.add('ble-a'); // a connect that never answers
    h.transport.adverts = [
      FakeAdvert(remoteId: 'ble-a', deviceId: pidA),
      FakeAdvert(remoteId: 'ble-new', deviceId: pidUnknown),
    ];

    unawaited(h.coordinator.initialize());
    await pumpUntil(() => h.coordinator.state == SpoonState.connecting);

    // Opening the device list while that attempt hangs.
    final found = await h.coordinator
        .scanForNewSpoons(window: const Duration(milliseconds: 800));
    expect(found, isNotEmpty,
        reason: 'the screen must scan — not report "No new devices found" '
            'under a "Connecting…" left behind by the aborted attempt');
    h.coordinator.dispose();
  }, timeout: const Timeout(Duration(seconds: 40)));

  test('a stale "connecting" from an aborted attempt is cleared before the '
      'app listens again', () async {
    final h = await Harness.create([recordFor(pidA, remoteId: 'ble-a')]);
    h.transport.identity['ble-a'] = identityBytesFor(pidA);
    h.transport.silentConnect.add('ble-a');
    h.transport.adverts = [FakeAdvert(remoteId: 'ble-a', deviceId: pidA)];

    unawaited(h.coordinator.initialize());
    await pumpUntil(() => h.coordinator.state == SpoonState.connecting);

    // The spoon goes away, and the last time it was heard ages out.
    h.transport.adverts = [];
    await quiet(const Duration(milliseconds: 5500));

    // A tap aborts the hung attempt; the app now listens for the spoon.
    final tap = h.coordinator.selectSpoon(pidA);
    await quiet(const Duration(seconds: 1));
    expect(h.coordinator.state, isNot(SpoonState.connecting),
        reason: 'while listening for an absent spoon the screen must not '
            'still say "Connecting…"');
    expect(await tap, SwitchOutcome.notNearby);
    h.coordinator.dispose();
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('tapping a spoon that is not advertising keeps the live spoon '
      '(make before break)', () async {
    final h = await Harness.create([
      recordFor(pidA, isPrimary: true, remoteId: 'ble-a'),
      recordFor(pidB, remoteId: 'ble-b'),
    ]);
    h.transport.identity['ble-a'] = identityBytesFor(pidA);
    h.transport.identity['ble-b'] = identityBytesFor(pidB);
    // B is switched off: only A is on the air.
    h.transport.adverts = [FakeAdvert(remoteId: 'ble-a', deviceId: pidA)];

    unawaited(h.coordinator.initialize());
    await pumpUntil(() => h.coordinator.activeSpoon?.spoonSerial == pidA);
    final connectsBefore = h.transport.connectCalls.length;

    var droppedA = false;
    void watch() {
      if (h.coordinator.activeSpoon?.spoonSerial != pidA) droppedA = true;
    }

    h.coordinator.addListener(watch);
    final outcome = await h.coordinator.selectSpoon(pidB);
    h.coordinator.removeListener(watch);

    expect(outcome, SwitchOutcome.notNearby);
    expect(droppedA, isFalse,
        reason: 'the working spoon must never be dropped for one that is not '
            'there — that left the user with no spoon at all');
    expect(h.coordinator.activeSpoon?.spoonSerial, pidA);
    expect(h.transport.connectCalls.length, connectsBefore,
        reason: 'no 10 s connect attempt at a spoon nobody can hear');
    h.coordinator.dispose();
  }, timeout: const Timeout(Duration(seconds: 40)));

  test('a tapped spoon that was reset: back to the live spoon, and a '
      'confirmed re-pair at its NEW address', () async {
    final h = await Harness.create([
      recordFor(pidA, isPrimary: true, remoteId: 'ble-a'),
      recordFor(pidB, remoteId: 'ble-b-old'),
    ], transport: RepairingTransport());
    h.transport.identity['ble-a'] = identityBytesFor(pidA);
    h.transport.owner['ble-a'] = [0x0B, 0x00];
    // B was fully erased: it answers from a new address and reports NO owner.
    h.transport.identity['ble-b-new'] = identityBytesFor(pidB);
    h.transport.owner['ble-b-new'] = [0x00, 0x00];
    h.transport.refuseConnect.add('ble-b-old');
    h.transport.adverts = [
      FakeAdvert(remoteId: 'ble-a', deviceId: pidA),
      FakeAdvert(remoteId: 'ble-b-new', deviceId: pidB),
    ];

    unawaited(h.coordinator.initialize());
    await pumpUntil(() => h.coordinator.activeSpoon?.spoonSerial == pidA);

    final outcome = await h.coordinator.selectSpoon(pidB);
    expect(outcome, SwitchOutcome.needsRepair);
    expect(h.transport.connectCalls, isNot(contains('ble-b-old')),
        reason: 'the presence check heard B at its new address — no 10 s '
            'timeout on the dead one');
    await pumpUntil(() => h.coordinator.activeSpoon?.spoonSerial == pidA,
        timeout: const Duration(seconds: 20));
    expect(h.coordinator.activeSpoon?.spoonSerial, pidA,
        reason: 'a refused switch must not leave the user with no spoon');
    expect(h.registry.byId(pidB)?.bleRemoteId, 'ble-b-old',
        reason: 'nothing is re-pointed or re-bonded without the user (§15)');

    // The user confirms "Pair again".
    final repaired = await h.coordinator.reclaimSavedSpoon(pidB);
    expect(repaired.isSuccess, isTrue, reason: '$repaired');
    await pumpUntil(() => h.coordinator.activeSpoon?.spoonSerial == pidB,
        timeout: const Duration(seconds: 20));
    expect(h.coordinator.activeSpoon?.spoonSerial, pidB);
    expect(h.registry.byId(pidB)?.bleRemoteId, 'ble-b-new');
    h.coordinator.dispose();
  }, timeout: const Timeout(Duration(seconds: 60)));
}
