// app_setup_service.dart — one-shot startup wiring + app-lifecycle coordinator.
//
// BLE: ConnectionCoordinator on the MAIN isolate is the only radio authority
// (design §8.4). The Android foreground service is process keep-alive only.
// It does not open a GATT client. If the process dies, the next launch
// reconnects through ConnectionCoordinator.request(startupRestore).
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:smartspoon/core/services/scheduled_sync_service.dart';
import 'package:smartspoon/core/services/sync_service.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:smartspoon/ble/spoon_runtime.dart';
import 'package:smartspoon/features/devices/domain/services/smart_spoon_ble_service.dart';
import 'package:smartspoon/features/notifications/domain/services/notification_service.dart';
import 'package:smartspoon/features/notifications/domain/services/funny_notification_service.dart';
import 'package:smartspoon/features/notifications/domain/services/smart_reminder_service.dart';

/// AppSetupService — initializes background services at app startup and
/// coordinates BLE foreground/background transitions via [WidgetsBindingObserver].
///
/// Call [initializeBackgroundServices] once in main() before runApp().
class AppSetupService {
  static void initializeBackgroundServices() {
    final observer = _AppLifecycleObserver();
    WidgetsBinding.instance.addObserver(observer);
    observer._startPeriodicSync();
    Future.microtask(() async {
      // The spoon connection starts FIRST, and is not awaited. Starting the
      // foreground service can put a system dialog on screen (the
      // battery-optimisation exemption) and waits for the user to answer it;
      // auto-connect used to queue behind that dialog, so on those launches
      // the spoon did not even start connecting until the user tapped
      // something. Connecting does not depend on the service.
      try {
        await SpoonRuntime().bindOwner(FirebaseAuth.instance.currentUser?.uid);
        // Routes through ConnectionCoordinator.request(startupRestore) — not a
        // coordinator bypass. Meal guard, backoff and reclaim stay in charge.
        unawaited(SpoonRuntime().autoConnectToLastDevice().catchError(
              (Object e) => debugPrint('[Setup] startupRestore failed: $e'),
            ));
        debugPrint('[Setup] Coordinator startupRestore requested');
      } catch (e) {
        debugPrint('[Setup] startupRestore failed: $e');
      }

      try {
        await SmartSpoonBleService().startBackgroundMonitoring();
        debugPrint('[Setup] Android FGS keep-alive started');
      } catch (e) {
        debugPrint(
          '[Setup] SmartSpoonBleService.startBackgroundMonitoring() failed: $e',
        );
      }

      try {
        await NotificationService().initialize();
        debugPrint('[Setup] NotificationService initialized');
      } catch (e) {
        debugPrint('[Setup] NotificationService.initialize() failed: $e');
      }

      try {
        if (kDebugMode) {
          await FunnyNotificationService().start();
          debugPrint('[Setup] FunnyNotificationService started (debug)');
        } else {
          await FunnyNotificationService().stop();
        }
      } catch (e) {
        debugPrint('[Setup] FunnyNotificationService setup failed: $e');
      }

      try {
        await ScheduledSyncService.initializeScheduledSync();
        debugPrint('[Setup] ScheduledSyncService initialized');
      } catch (e) {
        debugPrint(
          '[Setup] ScheduledSyncService.initializeScheduledSync() failed: $e',
        );
      }

      try {
        await SmartReminderService().start();
        debugPrint('[Setup] SmartReminderService started');
      } catch (e) {
        debugPrint('[Setup] SmartReminderService.start() failed: $e');
      }
    });
  }
}

class _AppLifecycleObserver extends WidgetsBindingObserver {
  DateTime? _lastSyncAttempt;
  Timer? _periodicSyncTimer;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      SpoonRuntime().resume();
      unawaited(SmartSpoonBleService().ensureServiceRunning());
      _triggerSyncOnResume();
      _startPeriodicSync();
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      // Keep a live GATT link (event-only). If none, arm OS auto-connect for
      // ONE saved spoon so iOS bluetooth-central can reconnect without Dart
      // timers. Do not call resume() — that used to connect while backgrounding.
      SpoonRuntime().suspend();
      unawaited(SmartSpoonBleService().onAppBackgrounded());
      _stopPeriodicSync();
    } else if (state == AppLifecycleState.detached) {
      // Process is going away. Do not hand GATT to another isolate (§8.4).
      SpoonRuntime().suspend();
    }
  }

  void _startPeriodicSync() {
    if (!kDebugMode) return;
    _periodicSyncTimer?.cancel();
    _periodicSyncTimer = Timer.periodic(const Duration(minutes: 5), (_) {
      debugPrint('[Sync] 5-minute periodic sync triggered');
      SyncService().syncIfNeeded();
    });
    debugPrint('[Sync] 5-minute periodic sync timer started');
  }

  void _stopPeriodicSync() {
    _periodicSyncTimer?.cancel();
    _periodicSyncTimer = null;
  }

  void _triggerSyncOnResume() {
    final now = DateTime.now();
    if (_lastSyncAttempt != null &&
        now.difference(_lastSyncAttempt!).inMinutes < 5) {
      return;
    }
    _lastSyncAttempt = now;
    SyncService().syncIfNeeded();
  }
}
