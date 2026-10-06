import 'dart:convert';
import 'package:smartspoon/core/utils/temperature_format.dart';

/// Apply Settings must only WRITE. Re-reading the encrypt-gated HW-rev char
/// on every Apply races Android GATT (10 Hz notify + encrypted read) and
/// drops the link → "Connection Error". Pairing belongs in subscribe.
/// Firmware 2.2.20+ arms the TPS rail on a connected GATT ON (same as the
/// ST-Link heater poke). Do not pair again from Apply.
const bool heaterWriteNeedsEncryptProbe = false;

/// Firmware RX grammar (write-with-response, ASCII, max 8 bytes):
///   `OFF` | `ON` | `ON NN` where NN is 30–70.
String heaterCommandPayload(int targetTemp) {
  if (targetTemp <= 0) {
    return 'OFF';
  }
  final clamped = targetTemp.clamp(30, 70);
  return 'ON $clamped';
}

/// Exact wire bytes. Do not use String.codeUnits (UTF-16).
List<int> heaterCommandBytes(int targetTemp) =>
    utf8.encode(heaterCommandPayload(targetTemp));

/// Panel polarity, `INV 0` / `INV 1` on the same RX characteristic.
///
/// Two glass variants ship on this product. One paints 0x0000 as black, the
/// other natively inverts and paints it WHITE — so the same dark-theme build
/// comes out as white background with black text on the second variant. The
/// firmware persists this setting, so it is sent once per spoon and survives
/// reboots.
List<int> panelInvertBytes({required bool inverted}) =>
    utf8.encode('INV ${inverted ? 1 : 0}');

/// Event notify flags (offset 6), matching firmware EVT_FLAG_*.
const int kEvtFlagVbus = 0x01;
const int kEvtFlagCharging = 0x02;
const int kEvtFlagNtcOk = 0x04;
const int kEvtFlagImuOk = 0x08;
const int kEvtFlagMeal = 0x10;
const int kEvtFlagHeater = 0x20;
const int kEvtFlagHeaterReq = 0x40;

/// Firmware re-heats when food drops this far below the target.
const double kHeaterHysteresisC = 5.0;

bool eventFlagsHasVbus(int flags) => (flags & kEvtFlagVbus) != 0;
bool eventFlagsHasNtcOk(int flags) => (flags & kEvtFlagNtcOk) != 0;
bool eventFlagsHasHeater(int flags) => (flags & kEvtFlagHeater) != 0;
bool eventFlagsHasHeaterReq(int flags) => (flags & kEvtFlagHeaterReq) != 0;

/// Display/app "heater rail" follows the spoon flame bit, never the last
/// successful GATT write. Write ACK only means the command was received.
bool heaterRailShownOn({int? eventFlags, bool commandedOn = false}) {
  if (eventFlags == null) return false;
  return eventFlagsHasHeater(eventFlags);
}

/// User maintain session: firmware bit 6, or a command just sent (event lag).
bool heaterMaintainShown({
  int? eventFlags,
  bool commandedOn = false,
  DateTime? commandedAt,
  DateTime? now,
}) {
  if (commandedOn) {
    if (commandedAt == null) return true;
    final age = (now ?? DateTime.now()).difference(commandedAt);
    if (age < const Duration(seconds: 3)) return true;
  }
  if (eventFlags != null) {
    return eventFlagsHasHeaterReq(eventFlags);
  }
  return commandedOn;
}

enum HeaterUiPhase { off, heating, holding, pausedUsb, fault }

HeaterUiPhase heaterUiPhase({
  required bool maintainOn,
  required bool railOn,
  bool vbusPresent = false,
  bool fault = false,
}) {
  if (fault) return HeaterUiPhase.fault;
  if (!maintainOn) return HeaterUiPhase.off;
  if (vbusPresent) return HeaterUiPhase.pausedUsb;
  if (railOn) return HeaterUiPhase.heating;
  return HeaterUiPhase.holding;
}

String heaterUiStatusLabel(HeaterUiPhase phase, int targetC) {
  switch (phase) {
    case HeaterUiPhase.off:
      return 'Off';
    case HeaterUiPhase.heating:
      return targetC > 0 ? 'Heating to $targetC°C' : 'Heating';
    case HeaterUiPhase.holding:
      return targetC > 0 ? 'Holding $targetC°C' : 'On';
    case HeaterUiPhase.pausedUsb:
      return 'Unplug USB';
    case HeaterUiPhase.fault:
      return 'Fault';
  }
}

/// Live food temperature for people, not a leftover average.
String formatLiveTempC(double tempC, {required bool ntcOk}) {
  if (!ntcOk || tempC <= 0 || tempC > 120) return '—';
  return formatSpoonTempWithUnit(tempC);
}

/// Whether the app may send a heater RX command to this device.
///
/// Firmware advertises the short name `iSpoon` in the 31-byte primary AD, so
/// [SavedBleDevice.detectHeater] (looks for "pro") is false until scan-response
/// or a saved capability is present. A live MCU GATT subscription is enough
/// proof this is the product service — skip-on-name was dropping ON entirely.
bool allowHeaterWrite({
  required bool savedHasHeater,
  required String deviceName,
  required bool mcuSubscribed,
}) {
  if (savedHasHeater) return true;
  final name = deviceName.toLowerCase();
  if (name.contains('pro')) return true;
  return mcuSubscribed;
}
