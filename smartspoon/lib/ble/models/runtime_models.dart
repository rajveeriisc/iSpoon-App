// runtime_models.dart — the vocabulary the APP layer speaks.
//
// lib/ble/models/spoon_models.dart holds the connection layer's own types
// (state machine, disconnect reasons, registry records). This file holds the
// types the UI and the analytics services consume: a saved device as the
// device list renders it, decoded sensor samples, heater state and the
// pairing diagnosis.
//
// They are separate on purpose. The connection layer must be able to change
// how it tracks a session without touching a single screen, and a screen must
// be able to render a device list without knowing what a session generation
// is.
//
// PROVENANCE: every type here was lifted from the legacy ble_service.dart /
// mcu_ble_service.dart with its behaviour intact, because each encodes a
// firmware or product fact that was learned the hard way. Where a value comes
// from firmware (bit positions, packet offsets, sentinels) the comment says so
// — those must change only alongside the firmware.
library;

import 'dart:convert';
import 'dart:math' show sqrt;
import 'dart:typed_data';

import 'package:smartspoon/ble/constants.dart';

// ─────────────────────────────────────────────────────────────────────────
// Sensor samples
// ─────────────────────────────────────────────────────────────────────────

/// One IMU sample, in physical units, as the tremor/motion/bite services want
/// it.
///
/// The BLE layer's own [ImuSample] is deliberately closer to the wire; this is
/// the analytics-facing shape, carrying the wall-clock timestamp and the source
/// spoon so a mixed multi-spoon stream can still be split apart.
class McuSensorData {
  McuSensorData({
    required this.accelX,
    required this.accelY,
    required this.accelZ,
    required this.gyroX,
    required this.gyroY,
    required this.gyroZ,
    required this.temperature,
    this.deviceId = '',
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();

  final double accelX, accelY, accelZ;
  final double gyroX, gyroY, gyroZ;

  /// Mutable: the batch header carries one temperature for all ten samples,
  /// applied after the per-sample decode.
  double temperature;

  final DateTime timestamp;

  /// Source spoon — used to filter a stream that merges several spoons.
  final String deviceId;

  double get accelMagnitude =>
      sqrt(accelX * accelX + accelY * accelY + accelZ * accelZ);
  double get gyroMagnitude =>
      sqrt(gyroX * gyroX + gyroY * gyroY + gyroZ * gyroZ);
  double get linearAccel => (accelMagnitude - 1.0).abs();

  @override
  String toString() =>
      'A(${accelX.toStringAsFixed(3)},${accelY.toStringAsFixed(3)},'
      '${accelZ.toStringAsFixed(3)}) '
      'G(${gyroX.toStringAsFixed(3)},${gyroY.toStringAsFixed(3)},'
      '${gyroZ.toStringAsFixed(3)}) '
      'T:${temperature.toStringAsFixed(2)}°C';
}

// ─────────────────────────────────────────────────────────────────────────
// Firmware event packet (f00d0007)
// ─────────────────────────────────────────────────────────────────────────

/// The 11-byte event notification, firmware version 1.
///
/// This is the ONLY source of the live heater rail bit, so a heater UI that
/// does not consume it can do nothing better than echo back the last command it
/// sent — which is exactly the bug [heaterRailShownOn] exists to prevent.
///
/// Wire layout (little-endian), all offsets firmware's:
/// ```text
///   [0]     version = 1
///   [1]     battery percent
///   [2..3]  temperature ×100, int16, -32768 = unavailable
///   [4..5]  bite count, uint16, 0xFFFF = withheld (unencrypted link)
///   [6]     EVT_FLAG_* bit mask
///   [7..10] device uptime ms, uint32
/// ```
class SpoonEventPacket {
  const SpoonEventPacket({
    required this.batteryPercent,
    required this.temperatureC,
    required this.biteCount,
    required this.flags,
    required this.deviceTimestampMs,
  });

  static const int length = 11;
  static const int version = 1;

  /// Returns null for anything that is not a version-1 event packet, rather
  /// than throwing into a notification stream.
  static SpoonEventPacket? tryParse(List<int> raw) {
    if (raw.length < length) return null;
    if (raw[0] != version) return null;
    final bytes = raw is Uint8List ? raw : Uint8List.fromList(raw);
    final view = ByteData.sublistView(bytes);
    final t100 = view.getInt16(2, Endian.little);
    final bites = view.getUint16(4, Endian.little);
    return SpoonEventPacket(
      batteryPercent: view.getUint8(1),
      temperatureC: t100 == -32768 ? null : t100 / 100.0,
      // 0xFFFF means firmware withheld the count on an unencrypted link. That
      // is not "zero bites" and must never be stored as one.
      biteCount: bites == 0xFFFF ? null : bites,
      flags: view.getUint8(6),
      deviceTimestampMs: view.getUint32(7, Endian.little),
    );
  }

  final int batteryPercent;
  final double? temperatureC;
  final int? biteCount;
  final int flags;
  final int deviceTimestampMs;
}

/// The 9-byte header-only heartbeat the firmware sends on the telemetry
/// characteristic in low-power/background mode: the batch header with no IMU
/// payload behind it.
///
/// Handled separately because [TelemetryPacket] requires a full 129-byte batch
/// and would classify this as malformed — which would make the spoon look dead
/// the moment it saved power.
class SpoonHeartbeat {
  const SpoonHeartbeat({
    required this.batteryPercent,
    required this.temperatureC,
    required this.biteCount,
  });

  static const int length = 9;

  static SpoonHeartbeat? tryParse(List<int> raw) {
    if (raw.length != length) return null;
    final bytes = raw is Uint8List ? raw : Uint8List.fromList(raw);
    final view = ByteData.sublistView(bytes);
    final t100 = view.getInt16(1, Endian.little);
    final bites = view.getUint16(7, Endian.little);
    return SpoonHeartbeat(
      batteryPercent: view.getUint8(0),
      temperatureC: t100 == -32768 ? null : t100 / 100.0,
      biteCount: bites == 0xFFFF ? null : bites,
    );
  }

  final int batteryPercent;
  final double? temperatureC;
  final int? biteCount;
}

// ─────────────────────────────────────────────────────────────────────────
// Heater
// ─────────────────────────────────────────────────────────────────────────

enum HeaterMode { off, manual, setpoint, fault }

/// Heater state for current Spoon firmware.
///
/// [railOn] is the flame — the actual TPS rail, reported by the firmware event
/// flags. [maintainOn] is the user's session: hold at target, re-heat when the
/// food drops [kHeaterHysteresisC] below it. They are genuinely different
/// things and the UI shows both; collapsing them makes the flame flicker in the
/// interface every time the firmware cycles the rail.
class HeaterStatus {
  const HeaterStatus({
    required this.mode,
    required this.setpointC,
    required this.tempC,
    required this.railOn,
    required this.fault,
    required this.timeout,
    required this.lowBattery,
    required this.receivedAt,
    this.maintainOn = false,
    this.ntcOk = true,
    this.vbusPresent = false,
  });

  final HeaterMode mode;
  final int setpointC;
  final double tempC;
  final bool railOn;
  final bool maintainOn;
  final bool fault;
  final bool timeout;
  final bool lowBattery;
  final bool ntcOk;
  final bool vbusPresent;
  final DateTime receivedAt;
}

// ─────────────────────────────────────────────────────────────────────────
// Pairing diagnosis
// ─────────────────────────────────────────────────────────────────────────

/// Why a spoon is connected but cannot establish the encrypted link the
/// firmware requires before it will send any sensor data.
///
/// The two causes need OPPOSITE fixes, and guessing wrong sends the user off to
/// do something useless — so this is decided from the spoon's own unencrypted
/// owner-status report, never from GATT error strings.
enum SpoonPairingIssue {
  none,

  /// The spoon already belongs to a different phone. Its single-owner policy
  /// refuses every other peer. Only a 6-second physical long-hold clears it.
  spoonOwnedByOther,

  /// The spoon is free to bond but the phone's Bluetooth stack still fails the
  /// pairing. In practice the OS is holding a STALE bond: each firmware
  /// re-flash rotates the spoon's identity address, leaving old bonds behind,
  /// and Android then tries a dead LTK instead of pairing fresh.
  ///
  /// Android exposes no public API to delete a bond (`removeBond()` is @hide),
  /// so the user must forget the device in system Bluetooth settings.
  stalePhoneBond,

  /// The spoon was reset (full-erase flash or 6-second hold) and reports NO
  /// owner. Nothing is broken on either side — it only has to be paired again,
  /// which the user confirms with one tap ([SpoonRuntime.repairSavedDevice]).
  spoonWasReset,
}

// ─────────────────────────────────────────────────────────────────────────
// Device list
// ─────────────────────────────────────────────────────────────────────────

/// How a permission request ended.
enum BlePermissionResult {
  granted,

  /// User denied — the UI should show a rationale and offer to re-request.
  denied,

  /// Adapter is powered off. Distinct from a permission denial (§34).
  bluetoothOff,

  /// Permanently denied — show a rationale with an explicit "Open Settings"
  /// button. Deliberately NOT calling openAppSettings() automatically: yanking
  /// the user into Settings without context is poor UX and gets flagged in
  /// review.
  permanentlyDenied,
}

/// Every state the device list can render.
enum DeviceUiState {
  /// Fully usable: link up, validated, subscribed AND streaming real packets.
  /// Anything less is [preparing] — a raw GATT link that never delivers data is
  /// not "Connected" to a user, and labelling it so is what made a spoon look
  /// connected right up to the moment it dropped.
  connected,

  /// Link is up but the spoon is not delivering data yet: MTU, discovery,
  /// bonding or subscribe still in flight. Shown as "Preparing…". If it never
  /// leaves this state the link is up but unusable — most commonly a refused
  /// bond, which [SpoonPairingIssue] then explains.
  preparing,

  /// A connection attempt is in progress.
  connecting,

  /// Advertisement seen recently, not connected.
  available,

  /// Not seen within [BleConstants.availabilityTimeout].
  unavailable,

  /// Bluetooth adapter is disabled.
  bluetoothOff,

  /// A link came up and then refused to deliver data.
  error,
}

/// A spoon as the device list shows it.
///
/// This is a VIEW of a registry record plus live scan/session state, not a
/// second source of truth: [SpoonRuntime] builds these on demand and the
/// registry remains the only thing that persists.
class SavedBleDevice {
  const SavedBleDevice({
    required this.id,
    required this.name,
    required this.lastConnected,
    this.customName,
    this.firmwareVersion,
    this.batteryLevel,
    this.lastSeenAt,
    this.lastRssi,
    this.hasHeater = false,
    this.autoConnect = true,
    this.productId,
  });

  /// Platform locator. A cache, never an identity (§1.2) — [productId] is the
  /// stable one.
  final String id;

  /// BLE-advertised name. Not user-editable.
  final String name;

  /// User-chosen display name. Falls back to [name] when null.
  final String? customName;

  final DateTime lastConnected;
  final String? firmwareVersion;
  final int? batteryLevel;

  /// Most recent advertisement in this app session. Transient — never stored.
  final DateTime? lastSeenAt;
  final int? lastRssi;

  /// Built-in heater: iSpoon Pro = true, iSpoon basic = false.
  final bool hasHeater;

  /// When false, cold start and Home reconnect will not re-enable this spoon.
  final bool autoConnect;

  /// Stable 8-byte hwinfo device id as 16 lowercase hex chars. Survives a
  /// settings-erase reflash that mints a new BLE address (§1.2).
  final String? productId;

  bool get isAvailable =>
      lastSeenAt != null &&
      DateTime.now().difference(lastSeenAt!) < BleConstants.availabilityTimeout;

  /// The name shown in every UI surface.
  String get displayName =>
      (customName != null && customName!.isNotEmpty) ? customName! : name;

  /// Scan RSSI when known. Missing is treated as too weak for the indicator.
  int get rssi => lastRssi ?? -100;

  String get formattedLastConnected {
    final diff = DateTime.now().difference(lastConnected);
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    return '${(diff.inDays / 7).floor()}w ago';
  }

  SavedBleDevice copyWith({
    String? id,
    String? name,
    String? customName,
    DateTime? lastConnected,
    String? firmwareVersion,
    int? batteryLevel,
    DateTime? lastSeenAt,
    int? lastRssi,
    bool? hasHeater,
    bool? autoConnect,
    String? productId,
  }) =>
      SavedBleDevice(
        id: id ?? this.id,
        name: name ?? this.name,
        customName: customName ?? this.customName,
        lastConnected: lastConnected ?? this.lastConnected,
        firmwareVersion: firmwareVersion ?? this.firmwareVersion,
        batteryLevel: batteryLevel ?? this.batteryLevel,
        lastSeenAt: lastSeenAt ?? this.lastSeenAt,
        lastRssi: lastRssi ?? this.lastRssi,
        hasHeater: hasHeater ?? this.hasHeater,
        autoConnect: autoConnect ?? this.autoConnect,
        productId: productId ?? this.productId,
      );

  SavedBleDevice withScanUpdate({required int rssi, required DateTime seenAt}) =>
      copyWith(lastRssi: rssi, lastSeenAt: seenAt);

  /// Unambiguous advertised names only. Firmware's primary AD short name is
  /// `iSpoon` even on Pro hardware, so that string is NOT proof of Basic.
  static bool detectHeater(String name) {
    final l = name.toLowerCase();
    if (l.contains('pro')) return true;
    if (l.contains('basic')) return false;
    return false;
  }

  /// Ask unless the name clearly says Pro or Basic. `iSpoon` is ambiguous.
  static bool isAmbiguousName(String name) {
    final l = name.trim().toLowerCase();
    if (l.contains('pro') || l.contains('basic')) return false;
    return true;
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        if (customName != null) 'customName': customName,
        'lastConnected': lastConnected.toIso8601String(),
        'hasHeater': hasHeater,
        'autoConnect': autoConnect,
        if (firmwareVersion != null) 'firmwareVersion': firmwareVersion,
        if (batteryLevel != null) 'batteryLevel': batteryLevel,
        if (productId != null) 'productId': productId,
        // lastSeenAt and lastRssi are transient — never stored to disk.
      };

  static SavedBleDevice? fromJsonString(String s) {
    try {
      final m = jsonDecode(s) as Map<String, dynamic>;
      return SavedBleDevice(
        id: m['id'] as String,
        name: m['name'] as String,
        customName: m['customName'] as String?,
        lastConnected: DateTime.parse(m['lastConnected'] as String),
        hasHeater: m['hasHeater'] as bool? ?? detectHeater(m['name'] as String),
        autoConnect: m['autoConnect'] as bool? ?? true,
        firmwareVersion: m['firmwareVersion'] as String?,
        batteryLevel: m['batteryLevel'] as int?,
        productId: m['productId'] as String?,
      );
    } catch (_) {
      return null;
    }
  }
}
