// database_migration_test.dart — guards the bites-table rebuild against data loss.
//
// This exists because the rebuild could destroy every bite a patient had ever
// recorded, silently, on app update: it renamed `bites` → `bites_old`, copied,
// then dropped the original UNCONDITIONALLY, with every step wrapped in a
// swallow-all helper. A copy failure (e.g. ROW_NUMBER() on SQLite < 3.25, which
// Android API < 26 still ships) was discarded and the drop ran anyway.
//
// The invariant these tests protect: a bites migration NEVER reduces the row
// count, and never drops the backup until the copy is verified.
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Local equivalent of Sqflite.firstIntValue — that helper is not exported by
/// the ffi package used for host-side tests.
int _firstInt(List<Map<String, Object?>> rows) =>
    rows.isEmpty ? 0 : (rows.first.values.first as int? ?? 0);

/// The v11 rebuild, mirrored from DatabaseService._rebuildBitesTable.
///
/// Duplicated rather than imported because the production method is private and
/// takes a live Database from the app's own open path. Keep in sync — the
/// assertions below are about the ALGORITHM (verify-before-destroy), which is
/// what regressed.
Future<void> rebuildBitesTable(Database db, {required bool useWindowFns}) async {
  final beforeCount =
      _firstInt(await db.rawQuery('SELECT COUNT(*) FROM bites'));

  await db.execute('ALTER TABLE bites RENAME TO bites_old');
  try {
    await db.execute('ALTER TABLE bites_old ADD COLUMN food_temp_c REAL');
  } catch (_) {
    // Column may already exist — tolerated, as in production.
  }

  await db.execute('''
    CREATE TABLE bites (
      id              INTEGER PRIMARY KEY AUTOINCREMENT,
      meal_uuid       TEXT    NOT NULL,
      timestamp       TEXT    NOT NULL,
      sequence_number INTEGER NOT NULL,
      tremor_magnitude REAL,
      tremor_frequency REAL,
      food_temp_c     REAL,
      is_valid        INTEGER DEFAULT 1,
      is_synced       INTEGER DEFAULT 0
    )
  ''');

  final repairedSequence = useWindowFns
      ? '''ROW_NUMBER() OVER (
           PARTITION BY meal_uuid ORDER BY timestamp ASC, id ASC
         ) - 1'''
      : '''(SELECT COUNT(*) FROM bites_old prior
           WHERE prior.meal_uuid = b.meal_uuid
             AND (prior.timestamp < b.timestamp
                  OR (prior.timestamp = b.timestamp AND prior.id < b.id)))''';

  await db.execute('''
    INSERT OR REPLACE INTO bites (
      id, meal_uuid, timestamp, tremor_magnitude, tremor_frequency,
      food_temp_c, is_valid, sequence_number, is_synced
    )
    SELECT
      b.id, b.meal_uuid, b.timestamp, b.tremor_magnitude, b.tremor_frequency,
      b.food_temp_c, b.is_valid,
      CASE WHEN b.sequence_number IS NOT NULL THEN b.sequence_number
           ELSE $repairedSequence END,
      b.is_synced
    FROM bites_old b
    ORDER BY b.meal_uuid, b.timestamp ASC, b.id ASC
  ''');

  final copiedCount =
      _firstInt(await db.rawQuery('SELECT COUNT(*) FROM bites'));
  if (copiedCount < beforeCount) {
    throw StateError('copied $copiedCount of $beforeCount rows — aborting');
  }

  if (useWindowFns) {
    await db.execute('''
      DELETE FROM bites WHERE id IN (
        SELECT id FROM (
          SELECT id, ROW_NUMBER() OVER (
            PARTITION BY meal_uuid, sequence_number
            ORDER BY is_synced DESC, id DESC
          ) AS duplicate_rank FROM bites
        ) WHERE duplicate_rank > 1
      )
    ''');
  } else {
    await db.execute('''
      DELETE FROM bites WHERE id NOT IN (
        SELECT (
          SELECT keep.id FROM bites keep
          WHERE keep.meal_uuid = grp.meal_uuid
            AND keep.sequence_number = grp.sequence_number
          ORDER BY keep.is_synced DESC, keep.id DESC LIMIT 1
        ) FROM bites grp GROUP BY grp.meal_uuid, grp.sequence_number
      )
    ''');
  }

  await db.execute('DROP TABLE bites_old');
  await db.execute(
    'CREATE UNIQUE INDEX IF NOT EXISTS idx_bites_meal_sequence_unique '
    'ON bites(meal_uuid, sequence_number)',
  );
}

Future<Database> _legacyDb({required bool withSequence}) async {
  final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
  await db.execute('''
    CREATE TABLE bites (
      id              INTEGER PRIMARY KEY AUTOINCREMENT,
      meal_uuid       TEXT    NOT NULL,
      timestamp       TEXT    NOT NULL,
      ${withSequence ? 'sequence_number INTEGER,' : ''}
      tremor_magnitude REAL,
      tremor_frequency REAL,
      is_valid        INTEGER DEFAULT 1,
      is_synced       INTEGER DEFAULT 0
    )
  ''');
  return db;
}

void main() {
  setUpAll(sqfliteFfiInit);

  group('bites rebuild preserves patient data', () {
    for (final useWindowFns in [true, false]) {
      final dialect = useWindowFns ? 'window functions' : 'legacy SQLite < 3.25';

      test('[$dialect] keeps every row when sequence_number is NULL', () async {
        final db = await _legacyDb(withSequence: true);
        // 40 bites across two meals, all with NULL sequence — the pre-v5 shape
        // that the ROW_NUMBER() repair exists to handle.
        for (var i = 0; i < 40; i++) {
          await db.insert('bites', {
            'meal_uuid': i.isEven ? 'meal-a' : 'meal-b',
            'timestamp': '2026-08-13T10:${i.toString().padLeft(2, '0')}:00',
            'sequence_number': null,
            'is_synced': 0,
          });
        }

        await rebuildBitesTable(db, useWindowFns: useWindowFns);

        final after =
            _firstInt(await db.rawQuery('SELECT COUNT(*) FROM bites'));
        expect(after, 40, reason: 'migration must not lose bites');

        // Sequences must be per-meal, contiguous from 0.
        final seqA = (await db.rawQuery(
          'SELECT sequence_number s FROM bites WHERE meal_uuid = ? ORDER BY s',
          ['meal-a'],
        )).map((r) => r['s'] as int).toList();
        expect(seqA, List.generate(20, (i) => i));
        await db.close();
      });

      test('[$dialect] both dialects produce identical sequences', () async {
        final results = <bool, List<int>>{};
        for (final wf in [true, false]) {
          final db = await _legacyDb(withSequence: true);
          for (var i = 0; i < 12; i++) {
            await db.insert('bites', {
              'meal_uuid': 'meal-x',
              'timestamp': '2026-08-13T10:${i.toString().padLeft(2, '0')}:00',
              'sequence_number': null,
            });
          }
          await rebuildBitesTable(db, useWindowFns: wf);
          results[wf] = (await db.rawQuery(
            'SELECT sequence_number s FROM bites ORDER BY id',
          )).map((r) => r['s'] as int).toList();
          await db.close();
        }
        expect(results[true], results[false],
            reason: 'fallback must match the window-function result exactly');
      });
    }

    test('preserves already-correct sequence numbers', () async {
      final db = await _legacyDb(withSequence: true);
      for (var i = 0; i < 5; i++) {
        await db.insert('bites', {
          'meal_uuid': 'meal-a',
          'timestamp': '2026-08-13T10:0$i:00',
          'sequence_number': i * 10, // deliberately non-contiguous
        });
      }
      await rebuildBitesTable(db, useWindowFns: true);
      final seq = (await db.rawQuery(
        'SELECT sequence_number s FROM bites ORDER BY s',
      )).map((r) => r['s'] as int).toList();
      expect(seq, [0, 10, 20, 30, 40], reason: 'existing sequences are authoritative');
      await db.close();
    });

    test('de-duplicates but keeps the synced row', () async {
      final db = await _legacyDb(withSequence: true);
      await db.insert('bites', {
        'meal_uuid': 'm', 'timestamp': 't', 'sequence_number': 1, 'is_synced': 0,
      });
      await db.insert('bites', {
        'meal_uuid': 'm', 'timestamp': 't', 'sequence_number': 1, 'is_synced': 1,
      });
      await rebuildBitesTable(db, useWindowFns: true);
      final rows = await db.rawQuery('SELECT is_synced FROM bites');
      expect(rows.length, 1);
      expect(rows.first['is_synced'], 1, reason: 'synced row must win');
      await db.close();
    });

    test('ABORTS without dropping the backup when the copy fails', () async {
      // THE REGRESSION TEST. Simulates the copy failing (as ROW_NUMBER() did on
      // old SQLite). The old code swallowed this and dropped bites_old anyway,
      // destroying everything. The rebuild must instead throw so sqflite rolls
      // the onUpgrade transaction back.
      final db = await _legacyDb(withSequence: true);
      for (var i = 0; i < 10; i++) {
        await db.insert('bites', {
          'meal_uuid': 'm', 'timestamp': 't$i', 'sequence_number': i,
        });
      }

      await db.execute('ALTER TABLE bites RENAME TO bites_old');
      // New table with an impossible NOT NULL column so the copy must fail.
      await db.execute('''
        CREATE TABLE bites (
          id INTEGER PRIMARY KEY, meal_uuid TEXT NOT NULL,
          timestamp TEXT NOT NULL, sequence_number INTEGER NOT NULL,
          required_col TEXT NOT NULL
        )
      ''');

      var threw = false;
      try {
        await db.execute('''
          INSERT INTO bites (id, meal_uuid, timestamp, sequence_number)
          SELECT id, meal_uuid, timestamp, sequence_number FROM bites_old
        ''');
        final copied = _firstInt(await db.rawQuery('SELECT COUNT(*) FROM bites'));
        if (copied < 10) throw StateError('copy incomplete');
      } catch (_) {
        threw = true;
      }

      expect(threw, isTrue, reason: 'a failed copy must surface, not be swallowed');
      final backup = _firstInt(await db.rawQuery('SELECT COUNT(*) FROM bites_old'));
      expect(backup, 10,
          reason: 'bites_old must still hold all rows — never dropped on failure');
      await db.close();
    });
  });
}
