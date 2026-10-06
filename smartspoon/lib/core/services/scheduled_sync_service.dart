// scheduled_sync_service.dart — OS-scheduled background cloud sync (WorkManager).
//
// callbackDispatcher is the top-level WorkManager entry point (runs in its own
// background isolate): it re-initializes Firebase, then calls
// SyncService.syncIfNeeded() and reports success so the OS can retry if data
// remains. ScheduledSyncService.initializeScheduledSync() registers the periodic
// task — every 15 min in test mode (SMARTSPOON_TEST_SYNC), otherwise once daily
// at 11 PM with exponential backoff. Also exposes cancel + manual-trigger.
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:workmanager/workmanager.dart';
import 'package:smartspoon/firebase_options.dart';
import 'sync_service.dart';

/// Background task callback - MUST be top-level function
@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    if (kDebugMode) print('Background sync task started: $task');

    try {
      WidgetsFlutterBinding.ensureInitialized();
      if (Firebase.apps.isEmpty) {
        await Firebase.initializeApp(
          options: DefaultFirebaseOptions.currentPlatform,
        );
      }
      final syncService = SyncService();
      final synced = await syncService.syncIfNeeded();
      final hasRemainingData = await syncService.hasUnsyncedData();

      if (kDebugMode) {
        print(
          synced
              ? 'Background sync completed successfully'
              : hasRemainingData
              ? 'Background sync incomplete; requesting retry'
              : 'Background sync skipped because no data needs syncing',
        );
      }

      return Future.value(!hasRemainingData);
    } catch (e) {
      if (kDebugMode) print('Background sync failed: $e');
      return Future.value(false);
    }
  });
}

class ScheduledSyncService {
  static const bool _testMode = bool.fromEnvironment(
    'SMARTSPOON_TEST_SYNC',
    defaultValue: false,
  );
  static const String _uniqueName = _testMode
      ? 'test-sync-15min'
      : 'daily-sync-11pm';
  static const String _taskName = 'syncTask';

  /// Initialize scheduled sync - call this once on app startup
  static Future<void> initializeScheduledSync() async {
    if (kDebugMode) print('Initializing scheduled sync service...');

    try {
      // Initialize Workmanager
      await Workmanager().initialize(callbackDispatcher);

      if (_testMode) {
        // TEST: run at the platform minimum cadence with no initial delay.
        await Workmanager().registerPeriodicTask(
          _uniqueName,
          _taskName,
          frequency: const Duration(minutes: 15),
          initialDelay: Duration.zero,
          constraints: Constraints(networkType: NetworkType.connected),
        );
        if (kDebugMode) print('TEST: Sync scheduled every 15 minutes');
      } else {
        // PRODUCTION: run once a day at 11 PM
        final now = DateTime.now();
        var targetTime = DateTime(now.year, now.month, now.day, 23, 0);
        if (now.isAfter(targetTime)) {
          targetTime = targetTime.add(const Duration(days: 1));
        }
        final initialDelay = targetTime.difference(now);

        await Workmanager().registerPeriodicTask(
          _uniqueName,
          _taskName,
          frequency: const Duration(hours: 24),
          initialDelay: initialDelay,
          constraints: Constraints(networkType: NetworkType.connected),
          backoffPolicy: BackoffPolicy.exponential,
          backoffPolicyDelay: const Duration(minutes: 15),
        );
        if (kDebugMode) print('Production: daily sync scheduled at 11 PM');
      }

      if (kDebugMode) print('Scheduled sync registered successfully');
    } catch (e) {
      if (kDebugMode) print('Failed to initialize scheduled sync: $e');
    }
  }

  /// Cancel scheduled sync
  static Future<void> cancelScheduledSync() async {
    await Workmanager().cancelByUniqueName(_uniqueName);
    if (kDebugMode) print('Scheduled sync cancelled');
  }

  /// Manually trigger sync (for testing)
  static Future<void> triggerManualSync() async {
    if (kDebugMode) print('Triggering manual sync...');
    final syncService = SyncService();
    await syncService.syncIfNeeded();
  }
}
