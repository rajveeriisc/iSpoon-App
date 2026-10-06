// sync_response_and_bite_rollback_test.dart — H9 (response parsing) and H7
// (optimistic-write rollback arithmetic).
//
// Both fixes live inline inside larger, stateful methods (SyncService's HTTP
// upload loop; UnifiedDataService's BLE packet handler) that pull in Firebase
// Auth, http.Client and the live SQLite path — none of which this test suite
// currently mocks. Rather than skip coverage, each fix's LOGIC is mirrored
// here as a small pure function/state machine, exactly as
// database_migration_test.dart and meal_sync_concurrency_test.dart already do
// for the DB-side fixes. Keep in sync with the production code if it changes.
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';

// ─── H9 ─────────────────────────────────────────────────────────────────────
// Mirrors the response-parsing guard added in SyncService._pushUnsyncedData.
//
// Previously: `(responseData['data']?['meal'] ?? responseData['meal'])['id']`
// — unguarded. A 2xx response (the row IS committed server-side) with any
// shape other than exactly {data:{meal:{id:...}}} or {meal:{id:...}} threw,
// landing in the generic catch and silently re-POSTing the same meal forever.
dynamic parseServerMealId(String body) {
  dynamic responseData;
  try {
    responseData = jsonDecode(body);
  } on FormatException {
    return null;
  }
  final mealJson = responseData is Map
      ? (responseData['data'] is Map
            ? responseData['data']['meal']
            : responseData['meal'])
      : null;
  return mealJson is Map ? mealJson['id'] : null;
}

// ─── H7 ─────────────────────────────────────────────────────────────────────
// Mirrors the optimistic-update / rollback arithmetic in
// UnifiedDataService._onTremorUpdate around uncommittedBites and
// lastHardwareBiteCount. The invariant: a failed write must leave the session
// exactly as if the batch had never been attempted, so the NEXT tick's delta
// naturally re-includes it — no permanent loss, no double count.
class BiteSession {
  int uncommittedBites = 0;
  int lastHardwareBiteCount = 0;
}

class OptimisticBiteBatch {
  OptimisticBiteBatch(this.session, this.newBites, this.currentHwCount)
    : previousHwBiteCount = session.lastHardwareBiteCount {
    session.uncommittedBites += newBites;
    session.lastHardwareBiteCount = currentHwCount;
  }

  final BiteSession session;
  final int newBites;
  final int currentHwCount;
  final int previousHwBiteCount;

  void commit() {
    session.uncommittedBites = (session.uncommittedBites - newBites).clamp(
      0,
      9999,
    );
  }

  void rollback() {
    session.uncommittedBites = (session.uncommittedBites - newBites).clamp(
      0,
      9999,
    );
    session.lastHardwareBiteCount = previousHwBiteCount;
  }
}

void main() {
  group('H9 — server meal-id response parsing', () {
    test('parses the primary {data:{meal:{id}}} shape', () {
      expect(
        parseServerMealId(jsonEncode({
          'data': {'meal': {'id': 42}},
        })),
        42,
      );
    });

    test('parses the compatibility {meal:{id}} shape', () {
      expect(parseServerMealId(jsonEncode({'meal': {'id': 7}})), 7);
    });

    test('THE REGRESSION: empty object returns null, does not throw', () {
      expect(parseServerMealId('{}'), isNull);
    });

    test('data present but not a map returns null, does not throw', () {
      expect(parseServerMealId(jsonEncode({'data': 'unexpected'})), isNull);
    });

    test('data.meal missing returns null, does not throw', () {
      expect(parseServerMealId(jsonEncode({'data': <String, dynamic>{}})), isNull);
    });

    test('top-level response is not even a map — does not throw', () {
      // The old code did responseData['data'] unconditionally; a bare JSON
      // string or number here used to throw a NoSuchMethodError.
      expect(parseServerMealId(jsonEncode('unexpected string')), isNull);
      expect(parseServerMealId(jsonEncode(42)), isNull);
    });

    test('non-JSON body returns null, does not throw', () {
      expect(parseServerMealId('not json at all'), isNull);
    });
  });

  group('H7 — optimistic bite-count rollback', () {
    test('commit(): buffer drains, hw anchor stays advanced', () {
      final session = BiteSession()
        ..uncommittedBites = 3
        ..lastHardwareBiteCount = 100;

      final batch = OptimisticBiteBatch(session, 5, 105);
      expect(session.uncommittedBites, 8); // 3 + 5, shown immediately
      expect(session.lastHardwareBiteCount, 105);

      batch.commit();
      expect(session.uncommittedBites, 3, reason: 'drains back to pre-batch');
      expect(
        session.lastHardwareBiteCount,
        105,
        reason: 'DB has the data — anchor stays advanced',
      );
    });

    test('THE REGRESSION: rollback() restores the hw anchor too', () {
      // Previously only the buffer would have been (or wasn't) restored;
      // lastHardwareBiteCount stayed at currentHwCount regardless of outcome,
      // permanently excluding this batch from every future delta.
      final session = BiteSession()..lastHardwareBiteCount = 100;

      final batch = OptimisticBiteBatch(session, 5, 105);
      batch.rollback();

      expect(session.uncommittedBites, 0);
      expect(
        session.lastHardwareBiteCount,
        100,
        reason: 'must return to pre-batch so the batch re-enters the next delta',
      );
    });

    test('a failed batch is fully recovered by the next successful tick', () {
      final session = BiteSession()..lastHardwareBiteCount = 100;

      // Tick 1: hw count is 105 (5 new bites), write fails.
      OptimisticBiteBatch(session, 5, 105).rollback();
      expect(session.lastHardwareBiteCount, 100);

      // Tick 2: hw count is now 112 (7 more arrived). Delta must be computed
      // from the ROLLED-BACK anchor, recovering all 12 — none lost, none
      // double-counted.
      const nextHwCount = 112;
      final recoveredNewBites = nextHwCount - session.lastHardwareBiteCount;
      expect(recoveredNewBites, 12, reason: '5 lost + 7 new, all recovered');

      OptimisticBiteBatch(session, recoveredNewBites, nextHwCount).commit();
      expect(session.uncommittedBites, 0);
      expect(session.lastHardwareBiteCount, 112);
    });

    test('uncommittedBites never goes negative across repeated failures', () {
      final session = BiteSession();
      for (var i = 0; i < 3; i++) {
        OptimisticBiteBatch(session, 2, i * 2).rollback();
      }
      expect(session.uncommittedBites, 0);
    });
  });
}
