import 'package:flutter_test/flutter_test.dart';
import 'package:smartspoon/core/models/bite.dart';
import 'package:smartspoon/core/models/cloud_sync_result.dart';
import 'package:smartspoon/core/models/meal.dart';

void main() {
  group('CloudSyncResult messages', () {
    test('exact equality has a distinct no-op message', () {
      const result = CloudSyncResult(status: CloudSyncStatus.upToDate);

      expect(result.completed, isTrue);
      expect(result.totalChanges, 0);
      expect(
        result.userMessage,
        'Local data and cloud data are already identical.',
      );
    });

    test('bite-only restore never says already up to date', () {
      const result = CloudSyncResult(
        status: CloudSyncStatus.updated,
        insertedBites: 7,
      );

      expect(result.userMessage, 'Synced 7 bites from the cloud.');
      expect(result.totalChanges, 7);
    });

    test('partial restore reports skipped records and data safety', () {
      const result = CloudSyncResult(
        status: CloudSyncStatus.partial,
        changedMeals: 2,
        insertedBites: 5,
        skippedRecords: 1,
      );

      expect(result.completed, isFalse);
      expect(result.isFailure, isFalse);
      expect(result.userMessage, contains('1 record could not be verified'));
      expect(result.userMessage, contains('existing data is safe'));
    });

    test('rate limit includes an integer Retry-After value', () {
      const result = CloudSyncResult(
        status: CloudSyncStatus.rateLimited,
        retryAfterSeconds: 42,
      );

      expect(result.isFailure, isTrue);
      expect(result.userMessage, contains('42 seconds'));
    });

    test('every outcome has a non-empty safe message', () {
      for (final status in CloudSyncStatus.values) {
        final result = CloudSyncResult(status: status, skippedRecords: 2);
        expect(result.userMessage.trim(), isNotEmpty, reason: status.name);
      }
    });
  });

  group('sync content equality', () {
    final start = DateTime.parse('2026-07-20T10:00:00Z');

    test('Meal ignores transport metadata and timestamp timezone', () {
      final local = Meal(
        id: 1,
        uuid: 'meal-1',
        serverId: 8,
        userId: 'local-user',
        startedAt: start.toLocal(),
        totalBites: 3,
        tremorIndex: 1.1,
        isSynced: true,
        updatedAt: start,
      );
      final cloud = Meal(
        id: 99,
        uuid: 'meal-1',
        serverId: 20,
        userId: 'other-transport-owner',
        startedAt: start,
        totalBites: 3,
        tremorIndex: 1.1000001,
        dirty: true,
        updatedAt: start.add(const Duration(days: 1)),
      );

      expect(local.hasSameSyncContent(cloud), isTrue);
      expect(local.hasSameSyncContent(cloud.copyWith(totalBites: 4)), isFalse);
    });

    test('Bite compares synchronized measurements but not local ids/flags', () {
      final local = Bite(
        id: 1,
        mealUuid: 'meal-1',
        timestamp: start.toLocal(),
        sequenceNumber: 2,
        tremorMagnitude: 0.8,
        isSynced: false,
      );
      final cloud = Bite(
        id: 50,
        mealUuid: 'meal-1',
        timestamp: start,
        sequenceNumber: 2,
        tremorMagnitude: 0.8000001,
        isSynced: true,
      );

      expect(local.hasSameSyncContent(cloud), isTrue);
      expect(
        local.hasSameSyncContent(
          Bite(
            mealUuid: 'meal-1',
            timestamp: start,
            sequenceNumber: 2,
            tremorMagnitude: 1.4,
          ),
        ),
        isFalse,
      );
    });
  });
}
