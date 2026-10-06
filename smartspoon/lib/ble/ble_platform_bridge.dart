// ble_platform_bridge.dart — the ONLY file in lib/ble/ that imports a BLE
// package.
//
// Follows design §7 (architecture: BlePlatformBridge sits under the
// coordinator) and §31's note that platform auto-connect behaviour must be
// isolated inside the bridge.
//
// WHY THIS FILE EXISTS
// Every flutter_blue_plus type (BluetoothDevice, ScanResult, Guid,
// BluetoothConnectionState) stops here and is translated into the
// package-neutral vocabulary in lib/ble/models/. The layer was first written
// against flutter_reactive_ble; keeping the package behind this one file is
// what made the move to flutter_blue_plus a one-file change, and it is what
// lets the coordinator's rules run in CI against a fake radio.
//
// PLATFORM QUIRKS ENCODED HERE — each of these cost real debugging on real
// hardware. Do not "simplify" them without re-testing on Samsung/Xiaomi and
// a physical iPhone:
//
//   • Android cannot scan and connect at the same time. A scan running during
//     a connect makes the connection stream report an immediate disconnect.
//   • Android GATT client slots are limited; open connection streams for other
//     devices must be cancelled AND given ~1 s to release before connecting.
//   • Samsung/Xiaomi GATT teardown takes ~2 s. An overlapping connect to the
//     SAME address inside that window fails with status 133.
//   • flutter_blue_plus's disconnect() also cancels any PENDING connection to
//     that address — including an autoConnect standby arm. A disconnect sent
//     late, for a link that is already gone, silently kills whatever arm was
//     made after it. See [BlePlatformBridge.connect].
//   • The spoon's PRIMARY advertisement carries the 128-bit service UUID
//     (firmware main.c: BT_DATA_UUID128_ALL in ad[]), while the 8-byte Device
//     ID travels in the SCAN RESPONSE manufacturer data. So the scan MUST be
//     service-filtered — iOS delivers no results at all to a backgrounded app
//     scanning with an empty service list — and the Dart side must tolerate a
//     first result that has no manufacturer data yet, re-emitting once the
//     scan response arrives.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'package:smartspoon/ble/constants.dart';
// Pure Dart, no BLE/Flutter types — the canonical manufacturer-data layout for
// this product lives there and must not be duplicated (design §1.3).
import 'package:smartspoon/features/devices/domain/spoon_identity.dart';

/// Adapter power/authorisation state, kept distinct from "off".
///
/// Design §34 and edge cases #30/#31: an unauthorised adapter or an iOS
/// adapter that has not resolved yet must NOT be reported to the user as
/// "Bluetooth is off". The doc lists collapsing these as bug #19.
enum BleAdapterState { unknown, unsupported, unauthorized, poweredOff, ready }

/// One advertisement sighting, package-neutral.
class BleSighting {
  const BleSighting({
    required this.remoteId,
    required this.name,
    required this.rssi,
    required this.serviceUuids,
    required this.manufacturerData,
  });

  final String remoteId;
  final String name;
  final int rssi;
  final List<String> serviceUuids;
  final Uint8List manufacturerData;

  /// Design §1.3 / edge case #20 — the STABLE advertised identity, parsed from
  /// manufacturer data (company 0xFFFF, type 0x01, 8-byte hwinfo device id).
  ///
  /// Empty when this advertisement carries no stable id. Callers must not
  /// substitute [remoteId]: §1.2 forbids using the platform locator as an
  /// identity, and doing so silently defeats the registry match after iOS
  /// rotates it.
  String get publicDeviceId => parseIspoonProductId(manufacturerData) ?? '';

  /// Design §1.3 — does this advertisement look like a Smart Spoon at all?
  ///
  /// The service UUID is in the PRIMARY advertisement (firmware main.c,
  /// BT_DATA_UUID128_ALL in ad[]), so a filtered scan matches it; the Device
  /// ID arrives later in the scan response. Foreground scans are unfiltered
  /// (older firmware, DFU mode), and filtering here keeps the tens-per-second
  /// Android scan callbacks for other devices out of the selector.
  bool get looksLikeSpoon =>
      publicDeviceId.isNotEmpty ||
      name.toLowerCase().contains('ispoon') ||
      serviceUuids.any((u) =>
          u.toLowerCase() == BleConstants.spoonServiceUuid.toLowerCase());
}

/// Link-level connection state, package-neutral.
enum BleLinkState { connecting, connected, disconnecting, disconnected }

/// The radio surface the [ConnectionCoordinator] is allowed to touch.
///
/// Design §7 puts FlutterBluePlus/native under the coordinator; this is that
/// boundary written down. It exists for two reasons:
///
///   1. The coordinator owns the hardest logic in the app (generations, meal
///      safety, reclaim, backoff) and none of it can be tested against a real
///      radio. A seam lets the whole §36 edge-case matrix run in CI.
///   2. §22 anticipates a package migration. Only [BlePlatformBridge]
///      implements this, so a migration rewrites one file.
///
/// Every method is package-neutral: no Uuid, no DiscoveredDevice, no
/// ConnectionStateUpdate crosses it.
abstract class BleTransport {
  BleAdapterState get adapterState;
  Stream<BleAdapterState> get adapterStates;
  Future<BleAdapterState> waitForResolvedAdapter({Duration timeout});

  /// Start scanning.
  ///
  /// [filterByService] asks the platform to match the Smart Spoon service UUID
  /// in the controller. It is REQUIRED in the background on iOS — a
  /// backgrounded app scanning with an empty service list is delivered
  /// nothing — and deliberately OFF in the foreground, where an unfiltered
  /// scan also finds a spoon running older firmware, one in DFU mode, or one
  /// whose advertisement is malformed. Dart-side identity matching runs either
  /// way, so the filter only ever changes what the radio bothers to report.
  Stream<BleSighting> scan({bool filterByService});
  Future<void> stopScan();

  Stream<BleLinkState> connect(String remoteId, {Duration? timeout});

  /// Hand a reconnect to the OS and stop spending our own battery on it.
  ///
  /// Unlike [connect] this returns immediately and never times out: the
  /// platform keeps a passive, zero-cost pending connection and establishes
  /// the link the moment the peripheral advertises again — even while the app
  /// process is dozing and no Dart timer would fire. That is the only
  /// mechanism that survives a spoon being switched off for hours.
  ///
  /// Cancelling the returned stream detaches the listener but deliberately
  /// does NOT drop the link, so an armed device that has just connected can be
  /// handed to the normal session pipeline without a disconnect/reconnect
  /// round trip. Use [cancelAutoConnect] to actually disarm one.
  Stream<BleLinkState> armAutoConnect(String remoteId);

  /// Disarm an [armAutoConnect] and drop the link if it has come up.
  Future<void> cancelAutoConnect(String remoteId);

  /// Delay required before re-opening a link to the SAME address.
  Duration get sameDeviceReopenDelay;

  /// Delay required after freeing OTHER devices' GATT slots.
  Duration get gattReleaseDelay;

  /// Edge case #44 — GATT connects but discovery hangs. The caller applies
  /// [BleConstants.discoveryTimeout]; this must not block forever.
  Future<void> discoverServices(String remoteId);

  /// Bring the link up to the encryption level this firmware requires before
  /// it will send any sensor notification.
  ///
  /// The spoon publishes its identity and owner status over an OPEN link, then
  /// stays completely silent on the telemetry characteristic until L2
  /// encryption is established. So a link can be "connected" on the spoon's own
  /// display while the app sees nothing at all — which is exactly what a
  /// missing bond looks like from the outside, and why this step cannot be
  /// left to whatever the OS decides to do on first subscribe.
  ///
  /// Returns true when the link is (or already was) encrypted.
  Future<bool> ensureEncryptedLink(String remoteId);

  /// §33 — firmware update rewrote the GATT database, so every cached
  /// characteristic handle is stale. Empty on platforms that cannot report it.
  Stream<void> servicesReset(String remoteId);

  Future<List<int>> readCharacteristic(String remoteId, String charUuid);
  Future<void> writeCharacteristic(
    String remoteId,
    String charUuid,
    List<int> value, {
    bool withResponse,
  });
  Stream<List<int>> subscribe(String remoteId, String charUuid);
  Future<int> requestMtu(String remoteId, {int mtu});

  /// Design §32 — devices this app already holds open (iOS state restoration,
  /// Android service handoff), so startup adopts instead of duplicating.
  Future<List<String>> alreadyConnectedRemoteIds();

  /// Whether THIS phone currently holds a bond for [remoteId].
  ///
  /// Without it the app cannot tell "your phone has a stale key" from "your
  /// phone has no key at all", and it told users to go and forget a device
  /// that was never in their Bluetooth settings.
  Future<bool> isBonded(String remoteId);

  /// Delete this phone's stored bond for [remoteId], so the next attempt pairs
  /// fresh instead of presenting a dead key.
  ///
  /// Returns false when the platform will not allow it — then, and only then,
  /// the user has to clear it in system Bluetooth settings.
  Future<bool> clearBond(String remoteId);

  /// Close a link this coordinator did not open.
  ///
  /// §32 step 6: a leftover connection is not harmless. It holds one of a
  /// phone's small number of GATT client slots, it keeps that spoon showing
  /// "connected" on its own display while the app ignores it, and a second
  /// live link is a straight violation of Rule 1.
  Future<void> disconnectDevice(String remoteId);

  /// Whether [remoteId]'s last disconnect was the SPOON closing the link —
  /// switched off (firmware sends a clean terminate before System OFF) — as
  /// opposed to a supervision timeout (walked out of range). Null when the
  /// platform did not say.
  ///
  /// The two want opposite reconnect choices: a spoon that walked out of range
  /// is coming back and should keep the one standby slot; a spoon that was
  /// switched off is not, and the slot is better spent on another saved spoon.
  bool? droppedDeliberately(String remoteId);

  Future<void> dispose();
}

/// Translates flutter_blue_plus into this layer's vocabulary.
class BlePlatformBridge implements BleTransport {
  BlePlatformBridge();

  StreamSubscription<List<ScanResult>>? _scanSub;

  /// Incremented per scan. Only the newest scan may stop the radio.
  int _scanEpoch = 0;

  // ── Adapter ──────────────────────────────────────────────────────────────

  BleAdapterState _mapStatus(BluetoothAdapterState s) {
    switch (s) {
      case BluetoothAdapterState.on:
        return BleAdapterState.ready;
      case BluetoothAdapterState.off:
        return BleAdapterState.poweredOff;
      case BluetoothAdapterState.unauthorized:
        return BleAdapterState.unauthorized;
      case BluetoothAdapterState.unavailable:
        return BleAdapterState.unsupported;
      case BluetoothAdapterState.unknown:
      case BluetoothAdapterState.turningOn:
      case BluetoothAdapterState.turningOff:
        return BleAdapterState.unknown;
    }
  }

  @override
  BleAdapterState get adapterState => _mapStatus(FlutterBluePlus.adapterStateNow);

  @override
  Stream<BleAdapterState> get adapterStates =>
      FlutterBluePlus.adapterState.map(_mapStatus);

  /// Design §10.1 / edge case #31: wait for a RESOLVED adapter state before
  /// running any connection logic. iOS starts at `unknown`, and treating that
  /// as "off" produced a false "Bluetooth is off" screen at every cold start.
  @override
  Future<BleAdapterState> waitForResolvedAdapter({
    Duration timeout = const Duration(seconds: 10),
  }) async {
    if (adapterState != BleAdapterState.unknown) return adapterState;
    try {
      return await adapterStates
          .firstWhere((s) => s != BleAdapterState.unknown)
          .timeout(timeout);
    } on TimeoutException {
      debugPrint('⚠️ BLE bridge: adapter never resolved — treating as unknown');
      return BleAdapterState.unknown;
    }
  }

  // ── Scanning ─────────────────────────────────────────────────────────────

  bool get isScanning => FlutterBluePlus.isScanningNow;

  /// Scan, filtered to the Smart Spoon service.
  ///
  /// The filter is not an optimisation. CoreBluetooth silently returns nothing
  /// to a backgrounded app that scans with an empty service list, so without it
  /// an iOS app can never rediscover a spoon that dropped while it was in the
  /// background — the case this whole layer exists to survive. On Android it
  /// also moves the match into the controller's hardware filter instead of
  /// waking the app for every beacon in the room.
  ///
  /// Identity is still decided in Dart afterwards: the service UUID says "this
  /// is a Smart Spoon", never "this is YOUR Smart Spoon" (§1.2).
  @override
  Stream<BleSighting> scan({bool filterByService = false}) {
    // Each scan owns its own subscription. The previous version kept one
    // shared `_scanSub` and stopped "the" scan on cancel, so tearing down an
    // old scan killed whichever scan happened to be current — a reclaim sweep
    // ending would silently shoot down the connection scan that replaced it,
    // and the device list would simply stay empty.
    StreamSubscription<List<ScanResult>>? sub;
    var stopped = false;

    // Ownership token. Cancelling MY subscription is always right; stopping
    // the radio is only right while I am still the scan that started it.
    // Without this, an old scan's teardown reaches past a newer one and stops
    // the platform scan the newer one is depending on — the same bug as the
    // shared subscription, one level down.
    final myEpoch = ++_scanEpoch;

    Future<void> stopThisScan() async {
      if (stopped) return;
      stopped = true;
      final mine = sub;
      sub = null;
      if (identical(_scanSub, mine)) _scanSub = null;
      try {
        await mine?.cancel();
      } catch (_) {}

      if (myEpoch != _scanEpoch) return; // a newer scan owns the radio now

      try {
        if (FlutterBluePlus.isScanningNow) await FlutterBluePlus.stopScan();
      } catch (e) {
        debugPrint('⚠️ BLE bridge: stopScan failed $e');
      }
      if (Platform.isAndroid) {
        // The radio needs to settle before a connect, or the connection stream
        // reports an instant disconnect.
        await Future<void>.delayed(BleConstants.postScanSettle);
      }
    }

    final controller = StreamController<BleSighting>(
      onCancel: stopThisScan,
    );

    Uint8List getManufacturerData(Map<int, List<int>> map) {
      if (map.isEmpty) return Uint8List(0);
      final entry = map.entries.firstWhere(
        (e) => e.key == 0xFFFF,
        orElse: () => map.entries.first,
      );
      final key = entry.key;
      final val = entry.value;
      final buf = BytesBuilder();
      buf.addByte(key & 0xFF);
      buf.addByte((key >> 8) & 0xFF);
      buf.add(val);
      return buf.toBytes();
    }

    // Emit a sighting per advertisement, not once per device. The candidate
    // selector needs repeated sightings to call a device stable (§9.2); one
    // emission per device would leave every candidate at seenCount 1 and
    // nothing would ever be selected.
    final Map<String, DateTime> lastSeen = {};
    final Map<String, int> lastMfgLen = {};

    void attach() {
      sub = FlutterBluePlus.onScanResults.listen(
        (results) {
          for (final r in results) {
            final id = r.device.remoteId.str;
            final ts = r.timeStamp;
            final mfg =
                getManufacturerData(r.advertisementData.manufacturerData);
            final prevMfgLen = lastMfgLen[id] ?? 0;
            final newMfgLen = mfg.length;

            // Unseen, a newer advertisement, or the scan response finally
            // brought the manufacturer data (which carries the Device ID).
            final isNew = !lastSeen.containsKey(id);
            final isFresher = !isNew && ts.isAfter(lastSeen[id]!);
            final gainedMfg = prevMfgLen == 0 && newMfgLen > 0;
            if (!isNew && !isFresher && !gainedMfg) continue;

            lastSeen[id] = ts;
            lastMfgLen[id] = newMfgLen;

            final name = r.advertisementData.advName.isNotEmpty
                ? r.advertisementData.advName
                : r.device.platformName;

            if (controller.isClosed) return;
            controller.add(BleSighting(
              remoteId: id,
              name: name,
              rssi: r.rssi,
              serviceUuids: r.advertisementData.serviceUuids
                  .map((u) => u.toString())
                  .toList(),
              manufacturerData: mfg,
            ));
          }
        },
        onError: (Object e) {
          debugPrint('❌ BLE bridge: scan error $e');
          if (!controller.isClosed) controller.addError(e);
        },
      );
      _scanSub = sub;
    }

    // startScan throws if one is already running, and the old code neither
    // awaited it nor stopped the previous scan first — so the throw was logged
    // and the caller was handed a stream that never emitted anything.
    unawaited(() async {
      try {
        if (FlutterBluePlus.isScanningNow) {
          await FlutterBluePlus.stopScan();
        }
        if (stopped || controller.isClosed || myEpoch != _scanEpoch) return;
        attach();
        await FlutterBluePlus.startScan(
          withServices: filterByService
              ? [Guid(BleConstants.spoonServiceUuid)]
              : const <Guid>[],
          continuousUpdates: true,
          // lowPower (5 s interval) misses the spoon's 500–600 ms slow
          // advertisements. The FGS is already running — use lowLatency so a
          // background rediscover scan actually sees the device.
          androidScanMode: AndroidScanMode.lowLatency,
        );
      } catch (e) {
        debugPrint('❌ BLE bridge: startScan failed $e');
        if (!controller.isClosed) controller.addError(e);
      }
    }());

    return controller.stream;
  }

  @override
  Future<void> stopScan() async {
    // A deliberate "stop scanning now" from the coordinator. Claiming the epoch
    // means any scan still tearing down in the background will not stop the
    // radio again underneath a scan started right after this one.
    _scanEpoch++;
    final sub = _scanSub;
    _scanSub = null;
    try {
      await sub?.cancel();
      if (FlutterBluePlus.isScanningNow) await FlutterBluePlus.stopScan();
    } catch (e) {
      debugPrint('⚠️ BLE bridge: stopScan failed $e');
    }
    if (sub != null && Platform.isAndroid) {
      await Future<void>.delayed(BleConstants.postScanSettle);
    }
  }

  // ── Connection ───────────────────────────────────────────────────────────

  /// Open a connection stream to [remoteId].
  ///
  /// Uses an explicit `connectToDevice` (not a platform auto-connect intent):
  /// design §31 notes that leaving several uncontrolled auto-connect intents
  /// alive creates ghost reconnects and makes single-active-spoon ownership
  /// impossible to enforce. The coordinator is the only reconnect authority.
  @override
  Stream<BleLinkState> connect(
    String remoteId, {
    Duration? timeout,
  }) {
    final device = BluetoothDevice.fromId(remoteId);
    StreamSubscription? stateSub;

    // Set once this link has reported disconnected, or failed to come up.
    // From then on there is nothing left to close — and closing it anyway is
    // harmful: flutter_blue_plus's disconnect() also cancels any PENDING
    // connection to the same address, which is exactly what the standby arm
    // made right after a drop is. That late disconnect used to land a moment
    // after the arm, cancel it, and leave the coordinator believing it was
    // still armed — so a spoon that dropped in the background never came back.
    var linkDown = false;

    // Cancelling the stream disconnects a link that is still up or still
    // connecting — the contract the ConnectionCoordinator relies on.
    final controller = StreamController<BleLinkState>(
      onCancel: () async {
        await stateSub?.cancel();
        if (linkDown) return;
        try {
          // queue: false — flutter_blue_plus runs one operation at a time, and a
          // queued disconnect waits behind the very connect it is meant to cancel,
          // up to that connect's full 10 s timeout. On the phone that showed as
          // "teardown cancel failed … Future not completed" and a 10–17 s stall
          // before the next spoon was even tried. Cancelling an in-progress
          // connection is exactly what the package documents this flag for.
          await device.disconnect(queue: false);
        } catch (e) {
          debugPrint('⚠️ BLE bridge: disconnect failed $e');
        }
      },
    );

    bool connectFinished = false;

    void markConnected() {
      if (!connectFinished) {
        connectFinished = true;
        if (!controller.isClosed) controller.add(BleLinkState.connected);
      }
    }

    if (device.isConnected) {
      markConnected();
    } else {
      device.connect(
        timeout: timeout ?? BleConstants.directConnectTimeout,
        autoConnect: false,
      ).then((_) {
        markConnected();
      }).catchError((Object e) {
        if (device.isConnected) {
          markConnected();
        } else {
          debugPrint('⚠️ BLE bridge: connect call failed $e');
          // flutter_blue_plus already cancelled a timed-out attempt itself.
          linkDown = true;
          if (!controller.isClosed) controller.add(BleLinkState.disconnected);
        }
      });
    }

    stateSub = device.connectionState.listen((s) {
      if (controller.isClosed) return;
      if (s == BluetoothConnectionState.connected) {
        markConnected();
      } else if (s == BluetoothConnectionState.disconnected && connectFinished) {
        linkDown = true;
        controller.add(BleLinkState.disconnected);
      }
    }, onError: (e) {
      if (!controller.isClosed) controller.addError(e);
    });

    return controller.stream;
  }

  @override
  Stream<BleLinkState> armAutoConnect(String remoteId) {
    final device = BluetoothDevice.fromId(remoteId);
    StreamSubscription? stateSub;

    // No disconnect in onCancel — see the seam's doc. Disarming is explicit.
    final controller = StreamController<BleLinkState>(
      onCancel: () async {
        await stateSub?.cancel();
      },
    );

    stateSub = device.connectionState.listen((s) {
      if (controller.isClosed) return;
      if (s == BluetoothConnectionState.connected) {
        controller.add(BleLinkState.connected);
      } else if (s == BluetoothConnectionState.disconnected) {
        controller.add(BleLinkState.disconnected);
      }
    }, onError: (e) {
      if (!controller.isClosed) controller.addError(e);
    });

    if (device.isConnected) {
      if (!controller.isClosed) controller.add(BleLinkState.connected);
    } else {
      // mtu MUST be null here: flutter_blue_plus asserts that mtu and
      // autoConnect are incompatible, and an assert would take the app down in
      // debug. The MTU is negotiated by the session pipeline afterwards.
      device
          .connect(autoConnect: true, mtu: null)
          .catchError((Object e) {
        debugPrint('⚠️ BLE bridge: arm autoConnect failed for $remoteId: $e');
      });
    }

    return controller.stream;
  }

  @override
  Future<void> cancelAutoConnect(String remoteId) async {
    try {
      // disconnect() is what clears flutter_blue_plus's autoConnect flag for
      // this device; without it the OS keeps the pending connection forever.
      await BluetoothDevice.fromId(remoteId).disconnect(queue: false);
    } catch (e) {
      debugPrint('⚠️ BLE bridge: disarm autoConnect failed for $remoteId: $e');
    }
  }

  /// Delay a caller must wait after cancelling a link before re-opening one to
  /// the SAME address. Encodes the Samsung/Xiaomi and iOS quirks.
  @override
  Duration get sameDeviceReopenDelay => Platform.isIOS
      ? BleConstants.streamReopenDelayIos
      : BleConstants.sameDeviceTeardownAndroid;

  /// Delay after freeing OTHER devices' GATT slots.
  @override
  Duration get gattReleaseDelay => Platform.isIOS
      ? const Duration(milliseconds: 400)
      : BleConstants.gattReleaseAndroid;

  // ── GATT operations ──────────────────────────────────────────────────────

  Future<BluetoothCharacteristic?> _findChar(String remoteId, String charUuid) async {
    final device = BluetoothDevice.fromId(remoteId);
    var services = device.servicesList;
    if (services.isEmpty) {
      try {
        services = await device.discoverServices();
      } catch (_) {}
    }
    for (var s in services) {
      if (s.uuid.toString().toLowerCase() == BleConstants.spoonServiceUuid.toLowerCase()) {
        for (var c in s.characteristics) {
          if (c.uuid.toString().toLowerCase() == charUuid.toLowerCase()) {
            return c;
          }
        }
      }
    }
    return null;
  }

  @override
  Future<List<int>> readCharacteristic(String remoteId, String charUuid) async {
    final c = await _findChar(remoteId, charUuid);
    if (c == null) throw Exception('Characteristic not found');
    return await c.read();
  }

  @override
  Future<void> writeCharacteristic(
    String remoteId,
    String charUuid,
    List<int> value, {
    bool withResponse = true,
  }) async {
    final c = await _findChar(remoteId, charUuid);
    if (c == null) throw Exception('Characteristic not found');
    await c.write(value, withoutResponse: !withResponse);
  }

  /// Subscribe to a notify characteristic.
  ///
  /// Design §10.4: the caller must attach its listener to this stream BEFORE
  /// notifications actually start, or the first packet can be lost — and READY
  /// depends on the first packet (Rule 2).
  @override
  Stream<List<int>> subscribe(String remoteId, String charUuid) {
    final controller = StreamController<List<int>>();

    // Held so the notification listener can be cancelled, and so onCancel does
    // not have to go looking for the characteristic again.
    //
    // WHY THIS MATTERS: `onValueReceived` is a filtered view of ONE global
    // platform stream, not a per-characteristic stream. A listener that is
    // never cancelled therefore survives the session that created it, and
    // every reconnect adds another — so after an afternoon of background
    // reconnects each incoming packet runs through a stack of dead listeners.
    StreamSubscription<List<int>>? valueSub;
    BluetoothCharacteristic? subscribed;

    _findChar(remoteId, charUuid).then((c) async {
      if (c == null) {
        if (!controller.isClosed) {
          controller.addError(Exception('Characteristic not found'));
        }
        return;
      }
      subscribed = c;
      // Design §10.4 — listener BEFORE notifications start, or the first
      // packet can be lost, and READY depends on it (Rule 2).
      valueSub = c.onValueReceived.listen((value) {
        if (!controller.isClosed) controller.add(value);
      });
      if (controller.isClosed) {
        // Cancelled while we were finding the characteristic.
        await valueSub?.cancel();
        return;
      }
      await c.setNotifyValue(true);
    }).catchError((Object e) {
      if (!controller.isClosed) controller.addError(e);
    });

    controller.onCancel = () async {
      await valueSub?.cancel();
      valueSub = null;
      final c = subscribed;
      subscribed = null;
      if (c == null) return;
      try {
        // Best effort: on a link that is already gone this throws, and that is
        // fine — the CCCD died with the connection. Never re-discover here;
        // teardown must not start fresh GATT traffic.
        await c.setNotifyValue(false);
      } catch (_) {}
    };

    return controller.stream;
  }

  /// Force GATT service discovery and wait for it.
  ///
  /// Design §10.3 puts "discover services" before any identity read, and edge
  /// case #44 is a GATT link that connects but whose discovery never returns.
  @override
  Future<void> discoverServices(String remoteId) async {
    final device = BluetoothDevice.fromId(remoteId);
    await device.discoverServices();
  }

  /// Establish the encrypted link the firmware requires before it notifies.
  ///
  /// Android: bonding is explicit and observable, so it is done and awaited
  /// here. Doing it lazily — letting the first subscribe fail with
  /// GATT_INSUFFICIENT_AUTHENTICATION and hoping the stack repairs itself — is
  /// what produced "the spoon says connected but the app says connecting":
  /// the link really was up, the app really was subscribed, and the spoon
  /// simply never spoke.
  ///
  /// iOS: CoreBluetooth pairs implicitly on first access to an encrypted
  /// characteristic and exposes no bond API, so there is nothing to drive from
  /// here and the subscribe itself triggers the pairing prompt.
  /// Bring the link to the encryption the firmware requires.
  ///
  /// The trigger is a READ of the hardware-revision characteristic, because
  /// that is what the firmware designates for it: f00d0005 is permission-gated
  /// on ENCRYPT + LESC, so touching it makes the OS start Just Works pairing
  /// and the read only returns once the link is actually encrypted. That makes
  /// it both the trigger and the proof, in one operation.
  ///
  /// It is also the only route on iOS, where CoreBluetooth has no pair() API —
  /// an Android-only createBond() path silently left every iPhone unbonded,
  /// subscribed, and waiting for telemetry that firmware would never send.
  ///
  /// On Android, if the read fails we additionally ask for an explicit bond and
  /// try once more: some OEM stacks will not start pairing off a read alone.
  @override
  Future<bool> ensureEncryptedLink(String remoteId) async {
    if (await _readTriggersEncryption(remoteId)) return true;

    if (!Platform.isAndroid) return false;

    try {
      debugPrint('🔐 BLE bridge: encrypted read failed — asking for a bond');
      // Returns immediately when the bond already exists; otherwise waits for
      // the handshake and throws if it does not complete.
      await BluetoothDevice.fromId(remoteId)
          .createBond(timeout: BleConstants.bondTimeout.inSeconds);
    } on TimeoutException {
      debugPrint('⚠️ BLE bridge: bonding timed out for $remoteId');
      return false;
    } catch (e) {
      // A refusal is information, not a crash: the spoon enforces a
      // single-owner policy and rejects every peer that is not its owner.
      debugPrint('⚠️ BLE bridge: bonding failed for $remoteId: $e');
      return false;
    }

    return _readTriggersEncryption(remoteId);
  }

  /// Read the encrypt-gated characteristic. Success means the link is
  /// encrypted; that is the whole point of choosing this characteristic.
  Future<bool> _readTriggersEncryption(String remoteId) async {
    try {
      await readCharacteristic(
        remoteId,
        BleConstants.hwRevisionCharacteristicUuid,
      ).timeout(BleConstants.bondTimeout);
      debugPrint('🔐 BLE bridge: link encrypted (hw-rev read succeeded)');
      return true;
    } catch (e) {
      debugPrint('ℹ️ BLE bridge: hw-rev read not yet possible: $e');
      return false;
    }
  }

  @override
  Stream<void> servicesReset(String remoteId) =>
      BluetoothDevice.fromId(remoteId).onServicesReset;

  /// Negotiate a larger MTU. The telemetry packet is 129 bytes, so the default
  /// 23-byte ATT MTU is not enough.
  @override
  Future<int> requestMtu(String remoteId, {int mtu = 247}) async {
    try {
      if (Platform.isAndroid) {
        final device = BluetoothDevice.fromId(remoteId);
        await device.requestMtu(mtu);
        return device.mtuNow;
      }
      return 23; // iOS handles MTU natively
    } catch (e) {
      debugPrint('⚠️ BLE bridge: MTU request failed $e');
      return 23;
    }
  }

  /// Design §32: adopt devices this app already has connected (iOS state
  /// restoration, Android service handoff) instead of starting a duplicate
  /// connection.
  @override
  Future<List<String>> alreadyConnectedRemoteIds() async {
    return FlutterBluePlus.connectedDevices.map((d) => d.remoteId.str).toList();
  }

  @override
  Future<bool> isBonded(String remoteId) async {
    if (!Platform.isAndroid) return false; // iOS exposes no bond state at all
    try {
      final state = await BluetoothDevice.fromId(remoteId)
          .bondState
          .first
          .timeout(const Duration(seconds: 3));
      return state == BluetoothBondState.bonded;
    } catch (e) {
      debugPrint('ℹ️ BLE bridge: bond state unavailable for $remoteId: $e');
      return false;
    }
  }

  /// Android only, and best effort: the platform's `removeBond()` is a hidden
  /// API that flutter_blue_plus reaches by reflection, and Android's non-SDK
  /// restrictions block it on some versions and vendor builds. When it works
  /// the user never leaves the app; when it does not we fall back to telling
  /// them to forget the spoon in system settings, which is the only remaining
  /// route.
  @override
  Future<bool> clearBond(String remoteId) async {
    if (!Platform.isAndroid) return false;
    try {
      await BluetoothDevice.fromId(remoteId).removeBond();
      debugPrint('🔐 BLE bridge: cleared stale bond for $remoteId');
      return true;
    } catch (e) {
      debugPrint('ℹ️ BLE bridge: cannot clear bond for $remoteId: $e');
      return false;
    }
  }

  @override
  Future<void> disconnectDevice(String remoteId) async {
    try {
      // Also cancels a connect still in progress — without queueing behind it.
      await BluetoothDevice.fromId(remoteId).disconnect(queue: false);
    } catch (e) {
      debugPrint('⚠️ BLE bridge: disconnect $remoteId failed $e');
    }
  }

  /// iOS: CBError.peripheralDisconnected (7) — "the peripheral disconnected
  /// from us" — is the spoon's own terminate; CBError.connectionTimeout (6)
  /// is range loss. Android: HCI 0x13 (19, remote user terminated) versus
  /// 0x08 (8, supervision timeout).
  @override
  bool? droppedDeliberately(String remoteId) {
    final code = BluetoothDevice.fromId(remoteId).disconnectReason?.code;
    if (code == null) return null;
    if (Platform.isIOS) {
      if (code == 7) return true;
      if (code == 6) return false;
      return null;
    }
    if (Platform.isAndroid) {
      if (code == 19) return true;
      if (code == 8) return false;
      return null;
    }
    return null;
  }

  @override
  Future<void> dispose() async {
    await _scanSub?.cancel();
    _scanSub = null;
  }
}
