// smart_spoon_ble_service.dart — Android foreground-service host + GATT constants.
//
// Keeps the app PROCESS alive so ConnectionCoordinator's links survive
// backgrounding. It does not touch Bluetooth itself.
//
// Android: a `connectedDevice` foreground service stops the OS reclaiming the
//   process, so the main isolate's GATT links keep running with the screen off.
// iOS: nothing needed here — the bluetooth-central background mode already
//   keeps the ConnectionCoordinator's connections alive while the process
//   lives.
//
// Also the canonical home of the shared kMcuServiceUuid / kMcuCharUuid /
// owner-status GATT constants.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/widgets.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:smartspoon/ble/device_registry.dart' show DeviceRegistry;

// ─── Product GATT — nRF52840 firmware (per APP_BLE_INTEGRATION.md) ──────────
//   Service    f00d0001  primary product service
//   TX         f00d0002  NOTIFY — 129-byte IMU batch (~10/s)  [foreground only]
//   RX         f00d0003  WRITE-with-response (encrypt) — heater ASCII commands
//   Device ID  f00d0004  READ (open) — 8-byte stable id
//   HW rev     f00d0005  READ (encrypt) — e.g. "A1"
//   Owner      f00d0006  READ (open) — pairing/owner status
//   Event      f00d0007  NOTIFY — 11-byte status (~30s / on change) [background]
// Firmware version comes from standard DIS (0x2A26). OTA uses the standard
// Zephyr SMP service 8d53dc1d-… (handled natively by mcumgr_flutter).
//
// Data now flows via direct connection. No PIN or pairing passkey is required
// by the firmware.
const String kMcuServiceUuid      = 'f00d0001-1234-5678-9abc-def012345678';
const String kMcuCharUuid         = 'f00d0002-1234-5678-9abc-def012345678'; // TX bulk notify
const String kMcuWriteCharUuid    = 'f00d0003-1234-5678-9abc-def012345678'; // RX write
const String kMcuDeviceIdCharUuid = 'f00d0004-1234-5678-9abc-def012345678'; // Device ID (read)
const String kMcuHwRevCharUuid    = 'f00d0005-1234-5678-9abc-def012345678'; // HW rev (read)
const String kMcuEventCharUuid    = 'f00d0007-1234-5678-9abc-def012345678'; // event notify
const String kBasServiceUuid      = '0000180f-0000-1000-8000-00805f9b34fb';
const String kBasLevelCharUuid    = '00002a19-0000-1000-8000-00805f9b34fb';
const String kDisServiceUuid      = '0000180a-0000-1000-8000-00805f9b34fb';
const String kDisFwRevCharUuid    = '00002a26-0000-1000-8000-00805f9b34fb';

/// Owner/pair status — READ with **no encryption required**, so it can be read
/// on a link that has not bonded (and never will, until the user intervenes).
///
/// This is the authoritative answer to "why is this spoon connected but sending
/// nothing". The firmware gates TX notifications on L2 encryption, and its
/// single-owner policy refuses to bond with any phone that is not the stored
/// owner — so a link can sit up forever, subscribed, delivering zero packets.
/// Byte 0 is a bitmask ([kOwnerStat*]), byte 1 the last reject reason.
const String kMcuOwnerStatusCharUuid =
    'f00d0006-1234-5678-9abc-def012345678';

// owner_status byte 0 flags — must match the firmware's OWNER_STAT_* defines.
const int kOwnerStatOwnerPresent  = 1 << 0; // device holds a stored owner bond
const int kOwnerStatPeerBonded    = 1 << 1; // THIS phone is the stored owner
const int kOwnerStatPairRejected  = 1 << 2; // pairing was refused on this link
const int kOwnerStatSecured       = 1 << 3; // L2 encryption active
const int kOwnerStatRepairHold6s  = 1 << 4; // owner present, this peer is not it

// Product capability, declared BY THE DEVICE. Both SKUs advertise the same
// primary-AD short name ("iSpoon") and the same hardware revision ("A1"), so
// nothing on the air told the app which spoon it was talking to. The app had
// to parse the advertised name and, when that was ambiguous, ask the user
// "does this spoon have a heater?" — a question the spoon can answer itself,
// and one that renaming a spoon silently defeated.
//
// kOwnerStatCapsValid is the compatibility key: it separates "the device
// reports NO heater" from "this firmware is too old to say". Without it an old
// Pro spoon reads as a no-heater unit and loses its heater controls.
const int kOwnerStatCapsValid     = 1 << 5; // firmware reports capability bits
const int kOwnerStatHasHeater     = 1 << 6; // unit has a heater rail

/// @deprecated Device ID is READ-only on current firmware (no batch notify).
/// Kept only so old call sites compile; do not subscribe for notifications.
@Deprecated('f00d0004 is Device ID READ, not IMU batch notify')
const String kMcuImuBatchCharUuid = kMcuDeviceIdCharUuid;

/// SharedPreferences key for storing the list of paired spoon device IDs.
const String _kSpoonDeviceIdsKey = 'smart_spoon_ids';

/// When the battery-optimisation exemption was last requested. See
/// [SmartSpoonBleService.ensureBatteryExemption] for why this is rate-limited.
const String _kBatteryAskedAtKey = 'battery_exemption_asked_at_v1';
const Duration _batteryAskBackoff = Duration(days: 14);

// ─── SharedPreferences keys for background→foreground data bridge ─────────
/// Written by background isolate, read by foreground UnifiedDataService.
const String kBgBiteCount = 'bg_bite_count'; // int
const String kBgAvgAccel = 'bg_avg_accel'; // double (average accel magnitude)
const String kBgUpdatedAt = 'bg_updated_at'; // int (millisecondsSinceEpoch)
const String kBgBattery = 'bg_battery'; // int (0–100)
const String kBgTemperature = 'bg_temperature'; // double (°C)

/// SmartSpoonBleService — process-liveness host for Android background BLE.
///
/// Owns the foreground service and the paired-device registry. Owns NO
/// Bluetooth: every connect, scan and subscribe belongs to
/// ConnectionCoordinator (design §8.4).
///
/// Why single-owner: Android grants a GATT client to one owner at a time. When
/// this class ran its own FlutterReactiveBle in the task isolate, one spoon had
/// two would-be owners, arbitrated by a 3-second heartbeat and a "takeover"
/// handshake. The handshake worked by tearing down the background link so the
/// foreground could rebuild it — which is why opening the app dropped a
/// perfectly good connection and showed "reconnecting". Removing the second
/// owner removes the problem rather than managing it.
class SmartSpoonBleService {
  static final SmartSpoonBleService _instance =
      SmartSpoonBleService._internal();
  factory SmartSpoonBleService() => _instance;
  SmartSpoonBleService._internal();

  List<String> _spoonDeviceIds = [];

  // ── Public API ─────────────────────────────────────────────────────────────
  //
  // ⚠️ This service NEVER opens a BLE connection. ConnectionCoordinator is the
  // app's single BLE owner on both platforms. All that lives here is the Android
  // foreground service that keeps the process (and therefore the coordinator's
  // links) alive.
  //
  // It previously ran a second FlutterReactiveBle — in the task isolate on
  // Android and on the main isolate for iOS — plus a 3-second heartbeat and a
  // "takeover" handshake to arbitrate between the two. Two owners of one GATT
  // client is not a thing you can arbitrate reliably; the handshake tore down a
  // live background link every time the app was opened. Single owner removes the
  // problem instead of managing it.

  /// Call once at app startup. Loads the paired-device registry and, on Android,
  /// starts the foreground service that keeps the process resident.
  Future<void> startBackgroundMonitoring() async {
    final prefs = await SharedPreferences.getInstance();
    _spoonDeviceIds = _loadDeviceIds(prefs);

    if (_spoonDeviceIds.isEmpty) {
      // Migrate the legacy single-device key if present.
      final legacy = prefs.getString('smart_spoon_id');
      if (legacy != null && legacy.isNotEmpty) {
        _spoonDeviceIds = [legacy];
        await _saveDeviceIds(prefs, _spoonDeviceIds);
        await prefs.remove('smart_spoon_id');
        debugPrint('🔵 BG: Migrated legacy device ID $legacy');
      } else if (!_hasAnySavedSpoon(prefs)) {
        debugPrint('🔵 BG: No paired devices — foreground service not needed');
        return;
      } else {
        // The registry knows a spoon this key does not — a logout/login cycle
        // wiped it. Start the service anyway: the coordinator is going to
        // reconnect from the registry, and without the FGS that link dies as
        // soon as the app leaves the screen.
        debugPrint('🔵 BG: smart_spoon_ids empty but registry has spoons — '
            'starting FGS from the registry');
      }
    }

    debugPrint(
      '🔵 BG: Keeping process alive for ${_spoonDeviceIds.length} device(s)',
    );
    if (Platform.isAndroid) {
      // Without this the foreground service keeps the notification alive while
      // the OEM still kills the process behind it.
      await ensureBatteryExemption();
      // Register BEFORE starting the service. The isolate's liveness probe is
      // only answerable while this callback is installed, and an unanswered
      // probe is read as "the main isolate is dead" — so a late registration
      // would have the isolate stealing the radio from a perfectly live app.
      // addTaskDataCallback de-duplicates, so repeat calls are harmless.
      FlutterForegroundTask.addTaskDataCallback(_onTaskData);
      await _initAndroidForegroundService();
    }
    // iOS needs nothing here: the bluetooth-central background mode already
    // lets the coordinator's connections survive backgrounding.
  }

  String? lastBackgroundDeviceId;

  /// Ask Android to stop dozing this app, once, and only if it has not been
  /// granted already.
  ///
  /// A `connectedDevice` foreground service is necessary but NOT sufficient on
  /// OEM builds: with battery optimisation still applied, Vivo/Oppo/Xiaomi kill
  /// the process anyway and the GATT link dies with it — which looks to the
  /// user like "the spoon disconnects whenever I close the app". The manifest
  /// has declared REQUEST_IGNORE_BATTERY_OPTIMIZATIONS all along; nothing ever
  /// asked for it.
  ///
  /// Returns true when the app is exempt. Never throws — the exemption is an
  /// improvement, not a precondition.
  Future<bool> ensureBatteryExemption() async {
    if (!Platform.isAndroid) return true;
    try {
      if (await FlutterForegroundTask.isIgnoringBatteryOptimizations) {
        return true;
      }

      // Rate-limited on purpose. This runs on every startBackgroundMonitoring,
      // i.e. every app launch, and the "already exempt" check above is NOT
      // reliable on OEM builds: Vivo/Oppo/Xiaomi keep their own background
      // allow-list, separate from Android's doze whitelist, so a user who has
      // already allowed background running in the OEM settings still reads
      // back as `false` here — forever. Without a limit, that turns into a
      // system dialog on every single launch, which is the fastest way to
      // train someone to deny it permanently.
      final prefs = await SharedPreferences.getInstance();
      final askedAt = prefs.getInt(_kBatteryAskedAtKey);
      if (askedAt != null) {
        final since = DateTime.now()
            .difference(DateTime.fromMillisecondsSinceEpoch(askedAt));
        if (since < _batteryAskBackoff) {
          debugPrint('🔋 BG: exemption not granted, but asked '
              '${since.inDays}d ago — not re-prompting yet');
          return false;
        }
      }
      await prefs.setInt(
          _kBatteryAskedAtKey, DateTime.now().millisecondsSinceEpoch);

      debugPrint('🔋 BG: requesting battery-optimisation exemption');
      await FlutterForegroundTask.requestIgnoreBatteryOptimization();
      final granted =
          await FlutterForegroundTask.isIgnoringBatteryOptimizations;
      debugPrint('🔋 BG: exemption ${granted ? "granted" : "declined"}');
      return granted;
    } catch (e) {
      debugPrint('⚠️ BG: battery-optimisation request failed: $e');
      return false;
    }
  }

  /// Kept for call-site compatibility. The FGS isolate no longer owns GATT
  /// (design §8.4 — ConnectionCoordinator is the only radio authority).
  Future<void> claimBleOwnership() async {}

  /// Kept for call-site compatibility. Process death drops the GATT link;
  /// the next launch reconnects through ConnectionCoordinator.request.
  void releaseBleOwnership({String? activeDeviceId}) {}

  /// Notify the background isolate of the current paired device list and preferred device.
  void notifyDevicesChanged(List<String> deviceIds, {String? preferredId}) {
    if (!Platform.isAndroid) return;
    _spoonDeviceIds = List.from(deviceIds);
    FlutterForegroundTask.sendDataToTask({
      'action': 'devices_changed',
      'ids': deviceIds,
      if (preferredId != null && preferredId.isNotEmpty)
        'preferredId': preferredId,
    });
  }

  /// Notify the background isolate that the user selected a new spoon.
  void notifyPreferredDevice(String deviceId) {
    if (!Platform.isAndroid || deviceId.isEmpty) return;
    FlutterForegroundTask.sendDataToTask({
      'action': 'preferred_changed',
      'preferredId': deviceId,
    });
  }

  void _onTaskData(Object data) {}

  /// Stop the Android foreground service. BLE is untouched — the coordinator
  /// owns it.
  Future<void> stopBackgroundMonitoring() async {
    debugPrint('🔵 BG: Stopping foreground service');
    if (Platform.isAndroid) {
      await FlutterForegroundTask.stopService();
    }
  }

  /// Called when the app is backgrounded. Nothing to do: the foreground service
  /// keeps the process alive, so the coordinator's links simply keep running.
  Future<void> onAppBackgrounded() async {
    debugPrint('🔵 BG: App backgrounded — coordinator keeps its connections');
  }

  /// Keep the Android FGS text honest: "Looking for…" while disconnected made
  /// a live link look like a scan that never finished.
  Future<void> updateKeepAliveNotification({required bool connected}) async {
    if (!Platform.isAndroid) return;
    try {
      if (!await FlutterForegroundTask.isRunningService) return;
      await FlutterForegroundTask.updateService(
        notificationTitle: 'i-Spoon',
        notificationText: connected
            ? 'Connected to your i-Spoon'
            : 'Looking for your i-Spoon…',
      );
    } catch (e) {
      debugPrint('⚠️ Android FGS: update notification failed: $e');
    }
  }

  // ── Android Foreground Service ─────────────────────────────────────────────

  Future<void> _initAndroidForegroundService() async {
    try {
      // Android 12+ rejects startForeground(type: connectedDevice) with a
      // SecurityException unless BLUETOOTH_CONNECT is already granted. This can
      // be reached at cold boot (saved IDs restored from a previous install)
      // before the user has granted BLE permission. Bail out silently —
      // onDevicePaired() and the next ensureServiceRunning() retry once granted.
      final btStatus = await Permission.bluetoothConnect.status;
      if (!btStatus.isGranted) {
        debugPrint(
          '🤖 Android FGS: Skipping start — BLUETOOTH_CONNECT not granted yet',
        );
        return;
      }

      FlutterForegroundTask.init(
        androidNotificationOptions: AndroidNotificationOptions(
          channelId: 'spoon_ble_channel_v2',
          channelName: 'Smart Spoon',
          channelDescription: 'Keeps BLE connection alive in the background',
          channelImportance: NotificationChannelImportance.LOW,
          priority: NotificationPriority.LOW,
        ),
        iosNotificationOptions: const IOSNotificationOptions(
          showNotification: false,
          playSound: false,
        ),
        foregroundTaskOptions: ForegroundTaskOptions(
          eventAction: ForegroundTaskEventAction.repeat(5000),
          // OFF on purpose. A boot start runs ONLY this service's isolate —
          // the app's main engine, and with it the ConnectionCoordinator,
          // never starts — so the phone showed "Looking for your i-Spoon…"
          // after every reboot while nothing at all was looking. The service
          // comes back the first time the app is opened, which is also the
          // first moment anything can actually connect.
          autoRunOnBoot: false,
          allowWakeLock: true,
          allowWifiLock: false,
        ),
      );

      final isRunning = await FlutterForegroundTask.isRunningService;
      if (!isRunning) {
        await FlutterForegroundTask.startService(
          serviceTypes: [ForegroundServiceTypes.connectedDevice],
          notificationTitle: 'i-Spoon',
          notificationText: 'Looking for your i-Spoon…',
          callback: _foregroundEntryPoint,
        );
        debugPrint('🤖 Android FGS: Service started');
      } else {
        debugPrint('🤖 Android FGS: Service already running');
      }
    } catch (e) {
      debugPrint('❌ Android FGS: Failed to start: $e');
    }
  }

  // ── Public API: device pairing hook ──────────────────────────────────────

  /// Call this immediately after a new spoon is paired.
  ///
  /// On Android:
  ///   • Shows the battery-optimisation system dialog ONCE (on first pairing
  ///     only). After that, never auto-shows again — the app guides the user
  ///     through an in-app banner if the service ever stops working.
  ///   • Starts (or refreshes) the foreground service so background BLE begins
  ///     immediately, without waiting for the next app restart.
  ///
  /// On iOS:
  ///   • Starts the CoreBluetooth pending-connect stream for the new device.
  ///
  /// This is the commercial-app pattern used by Fitbit, Oura, and Garmin:
  /// ask for the sensitive permission exactly once, in context (during pairing),
  /// never on cold-start.
  Future<void> onDevicePaired(String deviceId) async {
    // Keep in-memory list in sync so this process can reconnect immediately.
    if (!_spoonDeviceIds.contains(deviceId)) {
      _spoonDeviceIds.add(deviceId);
    }
    final prefs = await SharedPreferences.getInstance();
    await _saveDeviceIds(prefs, _spoonDeviceIds);

    if (Platform.isAndroid) {
      // Start/refresh the FGS so the process stays resident now that there is
      // a device worth staying alive for. Never opens a connection — the
      // coordinator already has one from the pairing that just succeeded.
      await _initAndroidForegroundService();
    }
  }

  /// Remove a spoon from the background registry and stop FGS when empty.
  Future<void> onDeviceForgotten(String deviceId) async {
    _spoonDeviceIds.remove(deviceId);
    final prefs = await SharedPreferences.getInstance();
    await _saveDeviceIds(prefs, _spoonDeviceIds);

    if (_spoonDeviceIds.isEmpty) {
      await stopBackgroundMonitoring();
    }
  }

  // ── Public API: silent service health-check ───────────────────────────────

  /// Silently ensures the Android foreground service is alive.
  /// Call on every app-foreground event. Shows NO dialogs.
  /// If the OS killed the service (aggressive battery saver), this restarts it.
  Future<void> ensureServiceRunning() async {
    if (!Platform.isAndroid) return;
    if (_spoonDeviceIds.isEmpty) {
      // Same divergence as in startBackgroundMonitoring: an empty id list is
      // NOT proof that no spoon is saved, so ask the registry before deciding
      // there is nothing worth staying alive for.
      final prefs = await SharedPreferences.getInstance();
      if (!_hasAnySavedSpoon(prefs)) return;
    }
    try {
      final isRunning = await FlutterForegroundTask.isRunningService;
      if (!isRunning) {
        debugPrint('🤖 Android FGS: Service was killed — restarting silently');
        await _initAndroidForegroundService();
      }
    } catch (e) {
      debugPrint('❌ Android FGS: ensureServiceRunning error: $e');
    }
  }
}

/// The entry point for the background task isolate.
/// Must be a top-level function or a static method annotated with @pragma('vm:entry-point').
@pragma('vm:entry-point')
void _foregroundEntryPoint() {
  WidgetsFlutterBinding.ensureInitialized();
  FlutterForegroundTask.setTaskHandler(SpoonTaskHandler());
}

/// Whether ANY saved spoon exists, according to either store.
///
/// The foreground service used to be gated on `smart_spoon_ids` alone, and that
/// key is not the source of truth — `DeviceRegistry` is. The two diverge for
/// real: logout wipes `smart_spoon_ids` (auth_service._clearLocalUserData) but
/// deliberately KEEPS the registry so the same account still sees its spoons
/// after signing back in. The result was a silent, permanent break — after one
/// logout/login cycle the coordinator still auto-connected (it reads the
/// registry) while this service saw an empty list, skipped the FGS entirely,
/// and let Android kill the process the moment the app was backgrounded. To
/// the user that reads as "it works until I close the app", with nothing in
/// the UI to explain it and no way back except pairing a brand new spoon.
///
/// Reading the registry key directly, rather than importing the BLE layer,
/// keeps this service free of a circular dependency on SpoonRuntime. The key
/// is uid-scoped (`ble_device_registry_v1_<uid>`), so every matching key is
/// checked and the uid does not have to be known here.
bool _hasAnySavedSpoon(SharedPreferences prefs) {
  try {
    final ids = _loadDeviceIds(prefs);
    if (ids.isNotEmpty) return true;

    for (final key in prefs.getKeys()) {
      if (!key.startsWith(DeviceRegistry.storageKey)) continue;
      final raw = prefs.getString(key);
      if (raw == null || raw.isEmpty) continue;
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) continue;
      final records = decoded['records'] as List<dynamic>?;
      if (records != null && records.isNotEmpty) return true;
    }
  } catch (e) {
    debugPrint('BG: saved-spoon probe failed: $e');
  }
  return false;
}

List<String> _loadDeviceIds(SharedPreferences prefs) {
  try {
    final json = prefs.getString(_kSpoonDeviceIdsKey);
    if (json == null || json.isEmpty) return [];
    final list = jsonDecode(json) as List<dynamic>;
    return list.map((e) => e.toString()).toList();
  } catch (_) {
    return [];
  }
}

Future<void> _saveDeviceIds(SharedPreferences prefs, List<String> ids) async {
  await prefs.setString(_kSpoonDeviceIdsKey, jsonEncode(ids));
}

// Keep-alive only. Design §8.4: ConnectionCoordinator on the MAIN isolate is
// the single BLE authority. This isolate must never open a GATT client.
@pragma('vm:entry-point')
class SpoonTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    debugPrint('[BG] FGS keep-alive started ($starter) — no BLE in this isolate');
  }

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  void onReceiveData(Object data) {}

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {}
}
