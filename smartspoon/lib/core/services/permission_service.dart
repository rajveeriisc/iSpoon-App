// permission_service.dart — first-launch runtime permission flow.
//
// requestIfNeeded() shows a one-time rationale dialog (Bluetooth + notifications)
// then requests the platform permissions: on Android it asks for
// bluetoothScan/Connect and notification (and deep-links to Settings if
// permanently denied); on iOS it relies on CoreBluetooth's own prompt via
// flutter_blue_plus (deliberately NOT requesting locationAlways). A
// SharedPreferences flag ensures the user is asked only once, ever.
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Handles first-launch permission requests for Android and iOS.
///
/// Call [PermissionService.requestIfNeeded] once from the first authenticated
/// screen (HomePage). The dialog is shown only on the very first launch;
/// every subsequent app open is a no-op.
class PermissionService {
  /// Legacy "we already asked" flag. No longer consulted: it recorded that a
  /// dialog was SHOWN, which is not the same question as whether the app can
  /// actually use Bluetooth, and gating on it got both cases wrong at once.
  /// Left declared only to document what the old key was.
  // ignore: unused_field
  static const String _legacyPrefKey = 'permissions_requested_v1';

  /// When the user last declined — either "Not Now" or the OS dialog itself.
  static const String _declinedAtKey = 'permissions_declined_at_v1';

  /// How long a decline is respected before the app may ask again. Long enough
  /// not to nag, short enough that a user who changes their mind is not stuck.
  static const Duration _declineBackoff = Duration(days: 7);

  /// Show the explanation dialog and request all required permissions.
  ///
  /// Safe to call on every app open. The gate is the REAL permission status,
  /// not a "have we asked yet" flag, because the flag version failed in both
  /// directions:
  ///
  ///   * "Not Now" returned early WITHOUT setting the flag, so the dialog came
  ///     back on every single launch, forever — the nagging the user sees.
  ///   * Tapping "Grant Permissions" and then DENYING the OS dialog set the
  ///     flag to true, so the app never asked again and background BLE was
  ///     silently broken for good — the one case where re-asking is justified
  ///     was the one case it suppressed.
  ///
  /// Asking the platform instead is self-correcting: it needs no migration,
  /// survives logout, reinstall and a cleared flag, and cannot drift from
  /// reality.
  static Future<void> requestIfNeeded(BuildContext context) async {
    if (await _alreadyUsable()) return; // Nothing to ask for.

    final prefs = await SharedPreferences.getInstance();

    // A dialog cannot lift a permanent denial — only Settings can — so showing
    // one every launch is pure noise. The Devices screen already offers an
    // "Open Settings" path for this state.
    if (await Permission.bluetoothConnect.isPermanentlyDenied) return;

    final declinedAt = prefs.getInt(_declinedAtKey);
    if (declinedAt != null) {
      final since = DateTime.now()
          .difference(DateTime.fromMillisecondsSinceEpoch(declinedAt));
      if (since < _declineBackoff) return;
    }

    if (!context.mounted) return;

    final proceed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text(
          'Enable Smart Spoon Monitoring',
          style: TextStyle(fontWeight: FontWeight.w700, fontSize: 18),
        ),
        content: Text(
          'To keep your Smart Spoon connected and sending data continuously — '
          'even when the screen is off — we need a few permissions:\n\n'
          '${Platform.isAndroid ? '• Bluetooth (connect to your spoon)\n'
              '• Notifications (background status alerts)\n' : ''}'
          '${Platform.isIOS ? '• Bluetooth (connect & receive data in background)\n' : ''}'
          '\nWe ask only once. You can change this anytime in Settings.',
          style: const TextStyle(fontSize: 14, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Not Now'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Grant Permissions'),
          ),
        ],
      ),
    );

    if (proceed != true) {
      // Record the decline so "Not Now" backs off instead of reappearing on
      // every launch.
      await prefs.setInt(
          _declinedAtKey, DateTime.now().millisecondsSinceEpoch);
      return;
    }

    if (Platform.isAndroid) {
      await _requestAndroid();
    } else if (Platform.isIOS) {
      await _requestIos();
    }

    // Stamp the attempt either way. If it was granted, [_alreadyUsable] is the
    // gate from here on and this value is never read again; if the OS dialog
    // was denied, the user gets the backoff rather than being asked on every
    // launch OR locked out permanently.
    await prefs.setInt(_declinedAtKey, DateTime.now().millisecondsSinceEpoch);
  }

  /// Whether the app can already do what the dialog would ask for.
  ///
  /// Only scan + connect are load-bearing. Notifications are a nice-to-have
  /// for the background-status message and must never hold the BLE prompt
  /// hostage; on iOS CoreBluetooth prompts itself on first use.
  static Future<bool> _alreadyUsable() async {
    if (!Platform.isAndroid) return false;
    try {
      final scan = await Permission.bluetoothScan.status;
      final connect = await Permission.bluetoothConnect.status;
      return scan.isGranted && connect.isGranted;
    } catch (_) {
      return false;
    }
  }

  // ── Android ──────────────────────────────────────────────────────────────

  static Future<void> _requestAndroid() async {
    // 1. Bluetooth (Android 12+ = API 31+)
    await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
    ].request();

    // 2. Notifications (Android 13+ = API 33+)
    if (await Permission.notification.isDenied) {
      await Permission.notification.request();
    }

    // 3. If permanently denied, guide user to Settings
    final btConnect = await Permission.bluetoothConnect.status;
    if (btConnect.isPermanentlyDenied) {
      await openAppSettings();
    }
  }

  // ── iOS ──────────────────────────────────────────────────────────────────

  static Future<void> _requestIos() async {
    // Bluetooth is prompted by flutter_blue_plus on the first scan
    // (NSBluetoothAlwaysUsageDescription). Do not request locationAlways.
    if (await Permission.notification.isDenied) {
      await Permission.notification.request();
    }
  }
}
