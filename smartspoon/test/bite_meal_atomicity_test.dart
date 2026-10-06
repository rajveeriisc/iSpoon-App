// bite_meal_atomicity_test.dart — bites and their owning meal row commit together.
//
// This exists because bites were written and committed BEFORE the `meals` row
// that owns them, with an aggregate query in between. If the app was killed in
// that window — precisely when it is most likely to be killed, mid-meal in the
// background — the bites sat on disk under a meal_uuid with no `meals` row.
// Every read path joins through `meals`, so those bites were invisible: never
// shown to the patient, never uploaded, never recoverable.
//
// The invariant these tests protect: after any outcome, the bites for a meal
// exist if and only if the meal row does.
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// The atomic write, mirrored from DatabaseService.insertBitesAndUpsertMeal.
///
/// Duplicated rather than imported because the production method resolves a
/// live Database through the app's own open path. Keep in sync — the assertion
/// below is about ATOMICITY, which is what regressed.
Future<Map<String, Object?>> insertBitesAndUpsertMeal(
  Database db, {
  required List<Map<String, Object?>> bites,
  required String mealUuid,
  required Map<String, Object?> Function(Map<String, Object?> stats) buildMeal,
}) async {
  return db.transaction((txn) async {
    if (bites.isNotEmpty) {
      final batch = txn.batch();
      for (final bite in bites) {
        batch.insert('bites', bite,
            conflictAlgorithm: ConflictAlgorithm.replace);
      }
      await batch.commit(noResult: true);
    }

    final rows = await txn.rawQuery('''
      SELECT COUNT(*) AS total_bites,
             AVG(tremor_magnitude) AS avg_tremor_magnitude
      FROM bites WHERE meal_uuid = ? AND is_valid = 1
    ''', [mealUuid]);
    final stats = {
      'total_bites': (rows.first['total_bites'] as num?)?.toInt() ?? 0,
      'avg_tremor_magnitude':
          (rows.first['avg_tremor_magnitude'] as num?)?.toDouble() ?? 0.0,
    };

    await txn.insert('meals', buildMeal(stats),
        conflictAlgorithm: ConflictAlgorithm.replace);
    return stats;
  });
}

Future<Database> _db() async {
  final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
  await db.execute('''
    CREATE TABLE meals (
      id          INTEGER PRIMARY KEY AUTOINCREMENT,
      uuid        TEXT    NOT NULL UNIQUE,
      meal_type   TEXT    NOT NULL,
      total_bites INTEGER DEFAULT 0
    )
  ''');
  await db.execute('''
    CREATE TABLE bites (
      id              INTEGER PRIMARY KEY AUTOINCREMENT,
      meal_uuid       TEXT    NOT NULL,
      timestamp       TEXT    NOT NULL,
      sequence_number INTEGER NOT NULL,
      tremor_magnitude REAL,
      is_valid        INTEGER DEFAULT 1,
      UNIQUE (meal_uuid, sequence_number)
    )
  ''');
  return db;
}

List<Map<String, Object?>> _bites(String uuid, int n, {int from = 0}) =>
    List.generate(n, (i) => {
          'meal_uuid': uuid,
          'timestamp': '2026-08-13T12:${(from + i).toString().padLeft(2, '0')}:00',
          'sequence_number': from + i,
          'tremor_magnitude': 1.0,
          'is_valid': 1,
        });

Future<int> _count(Database db, String table, String uuid) async =>
    (await db.rawQuery(
      'SELECT COUNT(*) c FROM $table WHERE ${table == 'meals' ? 'uuid' : 'meal_uuid'} = ?',
      [uuid],
    )).first['c']! as int;

void main() {
  setUpAll(sqfliteFfiInit);

  group('bite + meal atomicity', () {
    test('commits bites and the meal row together', () async {
      final db = await _db();
      final stats = await insertBitesAndUpsertMeal(
        db,
        bites: _bites('m1', 5),
        mealUuid: 'm1',
        buildMeal: (s) => {
          'uuid': 'm1', 'meal_type': 'Lunch', 'total_bites': s['total_bites'],
        },
      );

      expect(stats['total_bites'], 5);
      expect(await _count(db, 'bites', 'm1'), 5);
      expect(await _count(db, 'meals', 'm1'), 1);
      await db.close();
    });

    test('ROLLS BACK the bites when the meal write fails', () async {
      // THE REGRESSION TEST. Previously the bites were already committed by the
      // time the meal write ran, so a failure here orphaned them permanently.
      final db = await _db();

      await expectLater(
        insertBitesAndUpsertMeal(
          db,
          bites: _bites('m1', 5),
          mealUuid: 'm1',
          // meal_type is NOT NULL — this write must fail.
          buildMeal: (s) => {'uuid': 'm1', 'meal_type': null},
        ),
        throwsA(isA<DatabaseException>()),
      );

      expect(await _count(db, 'bites', 'm1'), 0,
          reason: 'orphaned bites must not survive a failed meal write');
      expect(await _count(db, 'meals', 'm1'), 0);
      await db.close();
    });

    test('stats see the new bites inside the transaction', () async {
      // The meal row must be built from the post-insert count; reading before
      // the batch would persist a total_bites that is always one tick stale.
      final db = await _db();
      await insertBitesAndUpsertMeal(
        db,
        bites: _bites('m1', 3),
        mealUuid: 'm1',
        buildMeal: (s) => {
          'uuid': 'm1', 'meal_type': 'Lunch', 'total_bites': s['total_bites'],
        },
      );

      final meal = (await db.query('meals', where: 'uuid = ?', whereArgs: ['m1'])).first;
      expect(meal['total_bites'], 3,
          reason: 'meal row must reflect the bites committed alongside it');
      await db.close();
    });

    test('accumulates across successive batches', () async {
      final db = await _db();
      for (var batch = 0; batch < 3; batch++) {
        await insertBitesAndUpsertMeal(
          db,
          bites: _bites('m1', 4, from: batch * 4),
          mealUuid: 'm1',
          buildMeal: (s) => {
            'uuid': 'm1', 'meal_type': 'Lunch', 'total_bites': s['total_bites'],
          },
        );
      }
      expect(await _count(db, 'bites', 'm1'), 12);
      expect(await _count(db, 'meals', 'm1'), 1, reason: 'upsert, not insert');
      final meal = (await db.query('meals', where: 'uuid = ?', whereArgs: ['m1'])).first;
      expect(meal['total_bites'], 12);
      await db.close();
    });

    test('an empty bite list still upserts the meal row', () async {
      // endSession-style flush: no new bites, but the meal must still persist.
      final db = await _db();
      await insertBitesAndUpsertMeal(
        db,
        bites: const [],
        mealUuid: 'm1',
        buildMeal: (s) => {
          'uuid': 'm1', 'meal_type': 'Dinner', 'total_bites': s['total_bites'],
        },
      );
      expect(await _count(db, 'meals', 'm1'), 1);
      expect(await _count(db, 'bites', 'm1'), 0);
      await db.close();
    });

    test('re-sent bites do not duplicate', () async {
      // A retried tick can resend the same sequence numbers.
      final db = await _db();
      for (var i = 0; i < 2; i++) {
        await insertBitesAndUpsertMeal(
          db,
          bites: _bites('m1', 5),
          mealUuid: 'm1',
          buildMeal: (s) => {
            'uuid': 'm1', 'meal_type': 'Lunch', 'total_bites': s['total_bites'],
          },
        );
      }
      expect(await _count(db, 'bites', 'm1'), 5,
          reason: 'UNIQUE(meal_uuid, sequence_number) + REPLACE dedupes');
      await db.close();
    });
  });
}
