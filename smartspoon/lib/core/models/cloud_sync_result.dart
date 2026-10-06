// cloud_sync_result.dart — typed outcome of a cloud restore/sync operation.
//
// `CloudSyncStatus` enumerates every terminal state (updated, upToDate,
// localChangesPending, rateLimited, networkUnavailable, …). `CloudSyncResult`
// wraps that status with counts (scanned/changed meals, inserted bites, kept
// local changes, skipped/repaired records) and derives `completed`, `isFailure`,
// and a localized `userMessage`. Exists because a bare number can't distinguish
// "already identical" from offline, rejected, or partially-restored outcomes.
enum CloudSyncStatus {
  updated,
  upToDate,
  localChangesPending,
  partial,
  notConfigured,
  unauthenticated,
  accountUnavailable,
  rateLimited,
  serviceUnavailable,
  networkUnavailable,
  invalidResponse,
  interrupted,
}

/// Complete, user-safe outcome of a cloud restore.
///
/// A count alone cannot distinguish "already equal" from offline, rejected,
/// partially restored, or local changes deliberately winning a conflict.
class CloudSyncResult {
  const CloudSyncResult({
    required this.status,
    this.scannedMeals = 0,
    this.changedMeals = 0,
    this.insertedBites = 0,
    this.localChangesKept = 0,
    this.skippedRecords = 0,
    this.repairedMeals = 0,
    this.retryAfterSeconds,
    this.detail,
  });

  final CloudSyncStatus status;
  final int scannedMeals;
  final int changedMeals;
  final int insertedBites;
  final int localChangesKept;
  final int skippedRecords;
  final int repairedMeals;
  final int? retryAfterSeconds;
  final String? detail;

  int get totalChanges => changedMeals + insertedBites + repairedMeals;

  bool get completed => switch (status) {
    CloudSyncStatus.updated ||
    CloudSyncStatus.upToDate ||
    CloudSyncStatus.localChangesPending => true,
    _ => false,
  };

  bool get isFailure => switch (status) {
    CloudSyncStatus.notConfigured ||
    CloudSyncStatus.unauthenticated ||
    CloudSyncStatus.accountUnavailable ||
    CloudSyncStatus.rateLimited ||
    CloudSyncStatus.serviceUnavailable ||
    CloudSyncStatus.networkUnavailable ||
    CloudSyncStatus.invalidResponse ||
    CloudSyncStatus.interrupted => true,
    _ => false,
  };

  String get userMessage {
    switch (status) {
      case CloudSyncStatus.updated:
        final mealWord = changedMeals == 1 ? 'meal' : 'meals';
        final biteWord = insertedBites == 1 ? 'bite' : 'bites';
        if (changedMeals > 0 && insertedBites > 0) {
          return 'Synced $changedMeals $mealWord and $insertedBites $biteWord from the cloud.';
        }
        if (changedMeals > 0) {
          return 'Synced $changedMeals $mealWord from the cloud.';
        }
        if (insertedBites > 0) {
          return 'Synced $insertedBites $biteWord from the cloud.';
        }
        return 'Cloud sync completed.';
      case CloudSyncStatus.upToDate:
        return 'Local data and cloud data are already identical.';
      case CloudSyncStatus.localChangesPending:
        return 'Cloud data is up to date here. Local changes are waiting to upload.';
      case CloudSyncStatus.partial:
        return 'Sync restored some data, but $skippedRecords record${skippedRecords == 1 ? '' : 's'} could not be verified. Your existing data is safe.';
      case CloudSyncStatus.notConfigured:
        return 'Cloud sync is not configured in this app build.';
      case CloudSyncStatus.unauthenticated:
        return 'Your session expired. Please sign in again.';
      case CloudSyncStatus.accountUnavailable:
        return 'Your account changed while syncing. Please try again.';
      case CloudSyncStatus.rateLimited:
        final wait = retryAfterSeconds;
        return wait == null
            ? 'Too many sync requests were started. Please wait and try again.'
            : 'Too many sync requests were started. Try again in $wait seconds.';
      case CloudSyncStatus.serviceUnavailable:
        return 'The cloud service is temporarily unavailable. Your local data is safe.';
      case CloudSyncStatus.networkUnavailable:
        return 'Could not reach the cloud. Check your internet connection and try again.';
      case CloudSyncStatus.invalidResponse:
        return 'The cloud returned data the app could not verify. Nothing unsafe was overwritten.';
      case CloudSyncStatus.interrupted:
        return 'Cloud sync was interrupted. Please wait a moment and try again.';
    }
  }
}
