// system_settings_service.dart — deep links into OS settings screens.
//
// Thin wrapper over the `smartspoon/system_settings` MethodChannel implemented
// in MainActivity.kt. Exists because some BLE failures can ONLY be resolved in
// system settings: Android gives apps no API to delete their own Bluetooth
// bond (BluetoothDevice.removeBond is @hide), so when the OS is holding a
// stale bond for a spoon the user has to forget it by hand. The least we can
// do is put them on the right screen.
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class SystemSettingsService {
  SystemSettingsService._();

  static const MethodChannel _channel =
      MethodChannel('smartspoon/system_settings');

  /// Opens the system Bluetooth settings screen.
  ///
  /// Returns false when the platform has no such screen to open (iOS, or an
  /// OEM build that hides the activity) so callers can fall back to showing
  /// the manual instructions instead of silently doing nothing.
  static Future<bool> openBluetoothSettings() async {
    if (!Platform.isAndroid) return false;
    try {
      final ok = await _channel.invokeMethod<bool>('openBluetoothSettings');
      return ok ?? false;
    } catch (e) {
      debugPrint('⚠️ SystemSettings: openBluetoothSettings failed: $e');
      return false;
    }
  }
}
