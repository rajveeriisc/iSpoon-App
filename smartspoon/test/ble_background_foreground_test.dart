// Background / foreground verification for the migrated BLE stack.
//
// The connection tests next door prove the coordinator's rules. These prove
// the thing the app actually promises the user: that a spoon which is
// streaming keeps streaming when the app goes away, that coming back does not
// disturb it, and that foreground and background never both try to own the
// radio.
//
// Real time, not fakeAsync — see the note at the top of
// ble_connection_coordinator_test.dart.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:smartspoon/ble/connection_coordinator.dart';
import 'package:smartspoon/ble/constants.dart';
import 'package:smartspoon/ble/device_authenticator.dart';
import 'package:smartspoon/ble/device_registry.dart';
import 'package:smartspoon/ble/meal_session_guard.dart';
import 'package:smartspoon/ble/models/runtime_models.dart';
import 'package:smartspoon/ble/models/spoon_models.dart';
import 'package:smartspoon/ble/primary_reclaim_monitor.dart';
import 'package:smartspoon/ble/spoon_runtime.dart';
import 'package:smartspoon/features/devices/domain/heater_command.dart';

import 'ble_connection_coordinator_test.dart'
    show
        FakeAdvert,
        pidB,
        FakeTransport,
        identityBytesFor,
        pidA,
        pumpUntil,
        recordFor,
        telemetryPacket;

/// A fake radio that tells the telemetry and event characteristics apart, so a
/// test can drive the heater's firmware flags independently of the sensor
/// stream. The shared [FakeTransport] answers every subscribe with telemetry,
/// which is right for connection tests and useless for this one.
class EventAwareTransport extends FakeTransport {
  final Map<String, StreamController<List<int>>> _eventCtl = {};

  /// Push a firmware event packet to the connected spoon.
  void emitEvent(String remoteId, {required int flags, int battery = 77,
      double tempC = 41.5, int bites = 4}) {
    final bytes = Uint8List(SpoonEventPacket.length);
    final view = ByteData.sublistView(bytes);
    view.setUint8(0, SpoonEventPacket.version);
    view.setUint8(1, battery);
    view.setInt16(2, (tempC * 100).round(), Endian.little);
    view.setUint16(4, bites, Endian.little);
    view.setUint8(6, flags);
    view.setUint32(7, 12345, Endian.little);
    _eventCtl[remoteId]?.add(bytes);
  }

  @override
  Stream<List<int>> subscribe(String remoteId, String charUuid) {
    if (charUuid == BleConstants.eventCharacteristicUuid) {
      final c = StreamController<List<int>>();
      _eventCtl[remoteId] = c;
      return c.stream;
    }
    final c = StreamController<List<int>>();
    if (emitTelemetry) {
      Timer(const Duration(milliseconds: 10), () {
        if (!c.isClosed) c.add(telemetryPacket());
      });
    }
    return c.stream;
  }
}

class Rig {
  Rig(this.transport, this.coordinator, this.runtime);

  final EventAwareTransport transport;
  final ConnectionCoordinator coordinator;
  final SpoonRuntime runtime;

  static Future<Rig> create({List<SpoonRecord>? records}) async {
    final prefs = await SharedPreferences.getInstance();
    final registry = DeviceRegistry(prefs: prefs);
    await registry.load();
    for (final r in records ?? [recordFor(pidA, remoteId: 'ble-a')]) {
      await registry.upsert(r);
    }
    final transport = EventAwareTransport();
    final coordinator = ConnectionCoordinator(
      registry: registry,
      authenticator: DeviceAuthenticator(),
      mealGuard: MealSessionGuard(),
      reclaimMonitor: PrimaryReclaimMonitor(),
      transport: transport,
      backgroundUsesOsStandby: true,
    );
    return Rig(transport, coordinator, SpoonRuntime.forTest(coordinator));
  }

  Future<void> reachStreaming() async {
    transport.identity['ble-a'] = identityBytesFor(pidA);
    transport.adverts = [FakeAdvert(remoteId: 'ble-a', deviceId: pidA)];
    unawaited(coordinator.initialize());
    await pumpUntil(() => coordinator.state == SpoonState.streaming);
    expect(coordinator.state, SpoonState.streaming,
        reason: 'setup failed before the behaviour under test');
  }

  void dispose() => coordinator.dispose();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  test('backgrounding keeps the live link — it must not disconnect', () async {
    final rig = await Rig.create();
    await rig.reachStreaming();
    final connectsBefore = rig.transport.connectCalls.length;

    rig.runtime.suspend();
    await Future<void>.delayed(const Duration(seconds: 2));

    expect(rig.coordinator.state, SpoonState.streaming,
        reason: '§37 — the background app keeps whatever link it has');
    expect(rig.runtime.isConnected, isTrue);
    expect(rig.transport.connectCalls.length, connectsBefore,
        reason: 'backgrounding must not re-open the link');
    rig.dispose();
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('returning to the foreground does not disturb a healthy link',
      () async {
    final rig = await Rig.create();
    await rig.reachStreaming();
    final connectsBefore = rig.transport.connectCalls.length;
    final scansBefore = rig.transport.scanCount;

    rig.runtime.suspend();
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await rig.runtime.resume();
    await Future<void>.delayed(const Duration(seconds: 1));

    expect(rig.coordinator.state, SpoonState.streaming);
    expect(rig.transport.connectCalls.length, connectsBefore,
        reason: 'resume must not tear down and rebuild a working session — '
            'that is the bug that made opening the app show "reconnecting"');
    expect(rig.transport.scanCount, scansBefore,
        reason: 'resume must not start a scan while already streaming');
    rig.dispose();
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('a drop while backgrounded is recovered', () async {
    final rig = await Rig.create();
    await rig.reachStreaming();

    rig.runtime.suspend();
    rig.transport.dropLink('ble-a');
    await pumpUntil(() => !rig.runtime.isConnected);
    expect(rig.runtime.isConnected, isFalse);

    // Recovery is OS pending-connect (Dart timers freeze in the background).
    await pumpUntil(() => rig.transport.armed.contains('ble-a'),
        timeout: const Duration(seconds: 10));
    rig.transport.fireArmedLink('ble-a');

    await pumpUntil(() => rig.coordinator.state == SpoonState.streaming,
        timeout: const Duration(seconds: 30));
    expect(rig.coordinator.state, SpoonState.streaming,
        reason: 'a backgrounded app must reconnect on its own');
    rig.dispose();
  }, timeout: const Timeout(Duration(seconds: 90)));

  test('backgrounding a healthy link does not arm a second spoon', () async {
    final rig = await Rig.create(records: [
      recordFor(pidA, isPrimary: true, remoteId: 'ble-a'),
      recordFor(pidB, remoteId: 'ble-b'),
    ]);
    await rig.reachStreaming();

    rig.runtime.suspend();
    await Future<void>.delayed(const Duration(milliseconds: 400));

    expect(rig.coordinator.state, SpoonState.streaming);
    expect(rig.transport.armed, isEmpty,
        reason: 'a live session must not also pending-connect the other spoon');
    expect(rig.runtime.connectedDeviceIds.length, 1);
    rig.dispose();
  }, timeout: const Timeout(Duration(seconds: 40)));

  test('Rule 1 — foreground and background never hold two links at once',
      () async {
    final rig = await Rig.create();
    await rig.reachStreaming();
    final connectsBefore = rig.transport.connectCalls.length;

    // Slam the lifecycle events together, which is what a user switching apps
    // quickly actually produces.
    rig.runtime.suspend();
    unawaited(rig.runtime.resume());
    rig.runtime.suspend();
    unawaited(rig.runtime.resume());
    await Future<void>.delayed(const Duration(seconds: 3));

    expect(rig.runtime.connectedDeviceIds.length, lessThanOrEqualTo(1),
        reason: 'MAX_ACTIVE_READY_SPOONS = 1');
    expect(rig.transport.connectCalls.length, connectsBefore,
        reason: 'lifecycle churn alone must not re-open the link');
    expect(rig.coordinator.state, SpoonState.streaming);
    rig.dispose();
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('refresh() leaves a healthy streaming link alone', () async {
    final rig = await Rig.create();
    await rig.reachStreaming();
    final connectsBefore = rig.transport.connectCalls.length;

    var sawDisconnect = false;
    void watch() {
      if (rig.coordinator.state != SpoonState.streaming) sawDisconnect = true;
    }

    rig.coordinator.addListener(watch);
    await rig.runtime.refresh();
    await Future<void>.delayed(const Duration(seconds: 1));
    rig.coordinator.removeListener(watch);

    // _run short-circuits when the live session already IS what the request
    // asks for. Rebuilding an identical session costs a visible "reconnecting"
    // blip and a gap in the meal data, and buys nothing.
    expect(sawDisconnect, isFalse,
        reason: 'refresh() must not interrupt a working session');
    expect(rig.transport.connectCalls.length, connectsBefore,
        reason: 'no reconnect when the spoon we want is already streaming');
    expect(rig.coordinator.state, SpoonState.streaming);
    rig.dispose();
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('background drops the 10 Hz stream but keeps the link and the events',
      () async {
    final rig = await Rig.create();
    await rig.reachStreaming();
    final connectsBefore = rig.transport.connectCalls.length;

    rig.runtime.suspend();
    await Future<void>.delayed(const Duration(milliseconds: 500));

    // Firmware contract: event-only in the background. The link stays up, so
    // the session is still STREAMING and the app still shows connected.
    expect(rig.coordinator.isBulkStreamActive, isFalse,
        reason: 'nobody is eating — events only');
    expect(rig.coordinator.state, SpoonState.streaming);
    expect(rig.runtime.isConnected, isTrue);
    expect(rig.transport.connectCalls.length, connectsBefore);

    // Events must keep flowing — that is the whole point of keeping f00d0007.
    rig.transport.emitEvent('ble-a',
        flags: kEvtFlagNtcOk, battery: 51, tempC: 39.5, bites: 2);
    await pumpUntil(() => rig.runtime.batteryLevel == 51);
    expect(rig.runtime.batteryLevel, 51);

    // And the stale watchdog must not fire against the low-rate stream: events
    // arrive at most every 30 s, the watchdog trips at 8 s.
    await Future<void>.delayed(const Duration(seconds: 10));
    expect(rig.coordinator.state, SpoonState.streaming,
        reason: 'no stale-driven churn while backgrounded');

    await rig.runtime.resume();
    await pumpUntil(() => rig.coordinator.state == SpoonState.streaming);
    expect(rig.coordinator.state, SpoonState.streaming);
    expect(rig.transport.connectCalls.length, connectsBefore,
        reason: 'restoring the stream must not re-open the link');
    rig.dispose();
  }, timeout: const Timeout(Duration(seconds: 90)));

  test('bites moving in the background bring the 10 Hz stream back', () async {
    final rig = await Rig.create();
    await rig.reachStreaming();

    rig.runtime.suspend();
    await pumpUntil(() => !rig.coordinator.isBulkStreamActive);
    expect(rig.coordinator.isBulkStreamActive, isFalse,
        reason: 'nobody eating — events only, as before');

    // The spoon's own counter goes up (the test packet started it at 3): the
    // user is eating with the phone locked, which is exactly when tremor and
    // motion analysis need the full stream.
    rig.transport.emitEvent('ble-a', flags: kEvtFlagNtcOk, bites: 4);
    await pumpUntil(() => rig.coordinator.isBulkStreamActive);

    expect(rig.coordinator.isBulkStreamActive, isTrue);
    expect(rig.coordinator.state, SpoonState.streaming,
        reason: 'turning the stream back on must not touch the link');
    rig.dispose();
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('tapping a saved spoon in the UI switches to it, and back again',
      () async {
    final rig = await Rig.create(records: [
      recordFor(pidA, isPrimary: true, remoteId: 'ble-a'),
      recordFor(pidB, remoteId: 'ble-b'),
    ]);
    rig.transport.identity['ble-a'] = identityBytesFor(pidA);
    rig.transport.identity['ble-b'] = identityBytesFor(pidB);
    rig.transport.adverts = [
      FakeAdvert(remoteId: 'ble-a', deviceId: pidA),
      FakeAdvert(remoteId: 'ble-b', deviceId: pidB),
    ];

    unawaited(rig.coordinator.initialize());
    await pumpUntil(() => rig.runtime.isConnected);
    expect(rig.coordinator.activeSpoon?.spoonSerial, pidA,
        reason: 'primary wins the initial selection');

    // The device list hands back exactly the ids the rows are keyed by.
    final ids = rig.runtime.previousDevices.map((d) => d.id).toList();
    expect(ids, containsAll(<String>['ble-a', 'ble-b']));

    // Tap spoon B.
    await rig.runtime.reconnectSavedDevice('ble-b');
    await pumpUntil(() => rig.coordinator.activeSpoon?.spoonSerial == pidB,
        timeout: const Duration(seconds: 30));
    expect(rig.runtime.connectedDeviceId, 'ble-b');
    expect(rig.runtime.connectedDeviceIds.length, 1,
        reason: 'Rule 1 — switching must not leave two links up');
    expect(rig.runtime.getDeviceUiState('ble-b'), DeviceUiState.connected);
    expect(rig.runtime.getDeviceUiState('ble-a'),
        isNot(DeviceUiState.connected));

    // Tap the spoon that is ALREADY connected: nothing should happen.
    final connectsBefore = rig.transport.connectCalls.length;
    await rig.runtime.reconnectSavedDevice('ble-b');
    await Future<void>.delayed(const Duration(seconds: 1));
    expect(rig.transport.connectCalls.length, connectsBefore,
        reason: 'tapping the live spoon must not drop and rebuild it');
    expect(rig.coordinator.state, SpoonState.streaming);

    // Tap back to A.
    await rig.runtime.reconnectSavedDevice('ble-a');
    await pumpUntil(() => rig.coordinator.activeSpoon?.spoonSerial == pidA,
        timeout: const Duration(seconds: 30));
    expect(rig.runtime.connectedDeviceId, 'ble-a');
    expect(rig.runtime.connectedDeviceIds.length, 1);
    rig.dispose();
  }, timeout: const Timeout(Duration(seconds: 120)));

  test('heater rail follows the firmware event flag, not the last command',
      () async {
    final rig = await Rig.create();
    await rig.reachStreaming();

    // Firmware reports the rail OFF while a maintain session is requested.
    rig.transport.emitEvent('ble-a', flags: kEvtFlagNtcOk | kEvtFlagHeaterReq);
    await pumpUntil(() => rig.runtime.heaterStatus?.railOn == false);

    final status = rig.runtime.heaterStatus;
    expect(status, isNotNull);
    expect(status!.railOn, isFalse,
        reason: 'the flame must come from the spoon, never from our own write');
    expect(status.ntcOk, isTrue);

    // Now firmware says the rail is live.
    rig.transport.emitEvent('ble-a',
        flags: kEvtFlagNtcOk | kEvtFlagHeater | kEvtFlagHeaterReq);
    await pumpUntil(() => rig.runtime.heaterStatus?.railOn == true);
    expect(rig.runtime.heaterStatus!.railOn, isTrue);
    rig.dispose();
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('the event packet updates battery, temperature and bites', () async {
    final rig = await Rig.create();
    await rig.reachStreaming();

    rig.transport.emitEvent('ble-a',
        flags: kEvtFlagNtcOk, battery: 63, tempC: 38.25, bites: 9);
    await pumpUntil(() => rig.runtime.batteryLevel == 63);

    expect(rig.runtime.batteryLevel, 63);
    expect(rig.runtime.temperature, closeTo(38.25, 0.01));
    expect(rig.runtime.hardwareBiteCount, 9);
    rig.dispose();
  }, timeout: const Timeout(Duration(seconds: 60)));
}
