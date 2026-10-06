// meal_sync_concurrency_test.dart — guards markMealSynced's compare-and-set.
//
// This exists because a finalized meal could be permanently orphaned in the
// cloud. markMealSynced used an unconditional `WHERE uuid = ?`, so with the
// 5-minute periodic sync running mid-meal:
//
//   t0  sync reads meal   {total_bites: 20, ended_at: null}
//   t1  POST in flight...
//   t2  endSession writes {total_bites: 61, ended_at: 12:41}
//   t3  POST returns  → markMealSynced flips is_synced = 1
//
// The row never reappears in getUnsyncedMeals, so the server keeps the partial
// 20-bite meal with ended_at = NULL forever. The patient's record is wrong and
// nothing ever retries.
//
// The invariant these tests protect: a meal is only marked synced if it still
// looks exactly as it did when the upload started.
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// The compare-and-set UPDATE, mirrored from DatabaseService.markMealSynced.
///
/// Duplicated rather than imported because the production method resolves a
/// live Database through the app's own open path. Keep in sync — the assertions
/// below are about the PREDICATE, which is what regressed.
Future<bool> markMealSynced(
  Database db,
  String uuid,
  dynamic serverId, {
  int? expectedTotalBites,
  String? expectedEndedAt,
}) async {
  final int? safeServerId =
      (serverId is int) ? serverId : int.tryParse(serverId?.toString() ?? '');

  var where = 'uuid = ?';
  final args = <Object?>[uuid];
  if (expectedTotalBites != null) {
    where += ' AND total_bites = ?';
    args.add(expectedTotalBites);
  }
  // IFNULL so a NULL ended_at compares equal to a NULL expectation — SQL
  // `NULL = NULL` is NULL, which would silently never match.
  where += " AND IFNULL(ended_at, '') = IFNULL(?, '')";
  args.add(expectedEndedAt);

  final rows = await db.update(
    'meals',
    {'is_synced': 1, 'server_id': ?safeServerId, 'dirty': 0},
    where: where,
    whereArgs: args,
  );
  return rows > 0;
}

Future<Database> _mealsDb() async {
  final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
  await db.execute('''
    CREATE TABLE meals (
      id          INTEGER PRIMARY KEY AUTOINCREMENT,
      uuid        TEXT    NOT NULL UNIQUE,
      total_bites INTEGER DEFAULT 0,
      ended_at    TEXT,
      server_id   INTEGER,
      is_synced   INTEGER DEFAULT 0,
      dirty       INTEGER DEFAULT 0
    )
  ''');
  return db;
}

Future<Map<String, Object?>> _row(Database db, String uuid) async =>
    (await db.query('meals', where: 'uuid = ?', whereArgs: [uuid])).first;

void main() {
  setUpAll(sqfliteFfiInit);

  group('markMealSynced compare-and-set', () {
    test('marks synced when the row is unchanged', () async {
      final db = await _mealsDb();
      await db.insert('meals',
          {'uuid': 'm1', 'total_bites': 20, 'ended_at': null, 'dirty': 1});

      final applied = await markMealSynced(db, 'm1', 42,
          expectedTotalBites: 20, expectedEndedAt: null);

      expect(applied, isTrue);
      final row = await _row(db, 'm1');
      expect(row['is_synced'], 1);
      expect(row['server_id'], 42);
      expect(row['dirty'], 0);
      await db.close();
    });

    test('REFUSES when bites changed mid-flight', () async {
      // THE REGRESSION TEST. The upload carried 20 bites; endSession has since
      // written 61. Marking this synced strands the 61-bite meal forever.
      final db = await _mealsDb();
      await db.insert('meals',
          {'uuid': 'm1', 'total_bites': 20, 'ended_at': null, 'dirty': 1});

      // endSession lands while the POST is in flight.
      await db.update('meals', {'total_bites': 61, 'ended_at': '2026-08-13T12:41:00'},
          where: 'uuid = ?', whereArgs: ['m1']);

      final applied = await markMealSynced(db, 'm1', 42,
          expectedTotalBites: 20, expectedEndedAt: null);

      expect(applied, isFalse, reason: 'stale upload must not claim the row');
      final row = await _row(db, 'm1');
      expect(row['is_synced'], 0,
          reason: 'row must stay unsynced so the next cycle re-uploads it');
      expect(row['total_bites'], 61, reason: 'the final data must survive');
      await db.close();
    });

    test('REFUSES when only ended_at changed', () async {
      // Bite count can be identical while the meal transitions from in-progress
      // to finalized — ended_at is the only tell, so it must be in the predicate.
      final db = await _mealsDb();
      await db.insert('meals',
          {'uuid': 'm1', 'total_bites': 20, 'ended_at': null});
      await db.update('meals', {'ended_at': '2026-08-13T12:41:00'},
          where: 'uuid = ?', whereArgs: ['m1']);

      final applied = await markMealSynced(db, 'm1', 42,
          expectedTotalBites: 20, expectedEndedAt: null);

      expect(applied, isFalse);
      expect((await _row(db, 'm1'))['is_synced'], 0);
      await db.close();
    });

    test('a NULL ended_at matches a NULL expectation', () async {
      // Guards the IFNULL wrapper. With a bare `ended_at = ?` this returns
      // false for EVERY in-progress meal, so nothing would ever sync.
      final db = await _mealsDb();
      await db.insert('meals',
          {'uuid': 'm1', 'total_bites': 5, 'ended_at': null});

      expect(
        await markMealSynced(db, 'm1', 1,
            expectedTotalBites: 5, expectedEndedAt: null),
        isTrue,
        reason: 'SQL NULL = NULL is NULL — IFNULL must bridge it',
      );
      await db.close();
    });

    test('matches a non-null ended_at exactly', () async {
      final db = await _mealsDb();
      await db.insert('meals', {
        'uuid': 'm1', 'total_bites': 61, 'ended_at': '2026-08-13T12:41:00',
      });

      expect(
        await markMealSynced(db, 'm1', 7,
            expectedTotalBites: 61, expectedEndedAt: '2026-08-13T12:41:00'),
        isTrue,
      );
      expect((await _row(db, 'm1'))['server_id'], 7);
      await db.close();
    });

    test('a non-integer server id does not clobber an existing server_id', () async {
      // The backend has returned string ids; int.tryParse yields null for junk.
      // The entry must then be OMITTED, not written as NULL over a good value.
      final db = await _mealsDb();
      await db.insert('meals', {
        'uuid': 'm1', 'total_bites': 3, 'ended_at': null, 'server_id': 99,
      });

      final applied = await markMealSynced(db, 'm1', 'not-a-number',
          expectedTotalBites: 3, expectedEndedAt: null);

      expect(applied, isTrue);
      final row = await _row(db, 'm1');
      expect(row['server_id'], 99, reason: 'must not null out a known server id');
      expect(row['is_synced'], 1);
      await db.close();
    });

    test('a string server id is coerced to int', () async {
      final db = await _mealsDb();
      await db.insert('meals',
          {'uuid': 'm1', 'total_bites': 3, 'ended_at': null});

      await markMealSynced(db, 'm1', '451',
          expectedTotalBites: 3, expectedEndedAt: null);

      expect((await _row(db, 'm1'))['server_id'], 451);
      await db.close();
    });

    test('never touches a different meal', () async {
      final db = await _mealsDb();
      await db.insert('meals',
          {'uuid': 'm1', 'total_bites': 5, 'ended_at': null});
      await db.insert('meals',
          {'uuid': 'm2', 'total_bites': 5, 'ended_at': null});

      await markMealSynced(db, 'm1', 1,
          expectedTotalBites: 5, expectedEndedAt: null);

      expect((await _row(db, 'm2'))['is_synced'], 0);
      await db.close();
    });
  });
}
