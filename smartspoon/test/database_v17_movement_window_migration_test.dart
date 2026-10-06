// v17 widens bites.tremor_window_ms from 30 s to 60 s. SQLite cannot alter a
// CHECK, so the table is rebuilt — and a rebuild of the table holding every
// bite a patient ever recorded has to be proven non-destructive before it
// ships. This runs against the production DDL (DatabaseService.createBitesTable)
// rather than a copy that can drift.
import 'package:flutter_test/flutter_test.dart';
import 'package:smartspoon/core/services/database_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// The v16-shaped bites table: identical to the current one but capped at 30 s.
const String createBitesTableV16 = '''
  CREATE TABLE bites (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    meal_uuid       TEXT    NOT NULL,
    timestamp       TEXT    NOT NULL,
    sequence_number INTEGER NOT NULL,
    tremor_magnitude REAL CHECK (tremor_magnitude IS NULL OR (tremor_magnitude >= 0 AND tremor_magnitude <= 3)),
    tremor_frequency REAL CHECK (tremor_frequency IS NULL OR (tremor_frequency > 0 AND tremor_frequency <= 20)),
    tremor_confidence REAL CHECK (tremor_confidence IS NULL OR (tremor_confidence >= 0 AND tremor_confidence <= 1)),
    tremor_window_ms INTEGER CHECK (tremor_window_ms IS NULL OR (tremor_window_ms >= 3000 AND tremor_window_ms <= 30000)),
    steady_pct      REAL CHECK (steady_pct IS NULL OR (steady_pct >= 0 AND steady_pct <= 100)),
    food_temp_c     REAL,
    is_valid        INTEGER DEFAULT 1,
    is_synced       INTEGER DEFAULT 0,
    CHECK ((tremor_confidence IS NULL) = (tremor_window_ms IS NULL)),
    CHECK (tremor_magnitude IS NOT NULL OR (tremor_frequency IS NULL AND tremor_confidence IS NULL AND tremor_window_ms IS NULL))
  )
''';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Database db;

  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await db.execute(createBitesTableV16);
    // Three rows spanning what a v16 database can hold.
    await db.insert('bites', {
      'meal_uuid': 'm1', 'timestamp': '2026-09-01T12:00:00Z', 'sequence_number': 0,
      'tremor_magnitude': 0.4, 'tremor_frequency': 5.1,
      'tremor_confidence': 0.8, 'tremor_window_ms': 30000,
      'steady_pct': 86.7, 'food_temp_c': 41.2, 'is_valid': 1, 'is_synced': 1,
    });
    await db.insert('bites', {
      'meal_uuid': 'm1', 'timestamp': '2026-09-01T12:00:10Z', 'sequence_number': 1,
      'tremor_magnitude': 0.2, 'tremor_confidence': 0.5, 'tremor_window_ms': 5000,
      'is_valid': 1, 'is_synced': 0,
    });
    // An unmeasured bite: every movement column null.
    await db.insert('bites', {
      'meal_uuid': 'm2', 'timestamp': '2026-09-01T13:00:00Z', 'sequence_number': 0,
      'is_valid': 1, 'is_synced': 0,
    });
  });

  tearDown(() async => db.close());

  test('v16 rejects the reading a 60 s rolling window produces', () async {
    await expectLater(
      db.insert('bites', {
        'meal_uuid': 'm1', 'timestamp': '2026-09-01T12:01:00Z',
        'sequence_number': 9, 'tremor_magnitude': 0.4,
        'tremor_confidence': 0.9, 'tremor_window_ms': 60000,
      }),
      throwsA(isA<DatabaseException>()),
      reason: 'this is the write that aborted the bite+meal transaction',
    );
  });

  test('the rebuild keeps every row, its id and its values', () async {
    final before = await db.query('bites', orderBy: 'id');
    await _rebuild(db);
    final after = await db.query('bites', orderBy: 'id');

    expect(after, hasLength(before.length));
    for (var i = 0; i < before.length; i++) {
      for (final key in const [
        'id', 'meal_uuid', 'timestamp', 'sequence_number',
        'tremor_magnitude', 'tremor_frequency', 'tremor_confidence',
        'tremor_window_ms', 'steady_pct', 'food_temp_c', 'is_valid', 'is_synced',
      ]) {
        expect(after[i][key], before[i][key], reason: 'row $i, column $key');
      }
    }
  });

  test('after the rebuild a 60 s reading is accepted', () async {
    await _rebuild(db);
    await db.insert('bites', {
      'meal_uuid': 'm1', 'timestamp': '2026-09-01T12:01:00Z',
      'sequence_number': 9, 'tremor_magnitude': 0.4,
      'tremor_confidence': 0.9, 'tremor_window_ms': 60000, 'steady_pct': 91.0,
    });
    final row = (await db.query('bites',
        where: 'sequence_number = ?', whereArgs: [9])).single;
    expect(row['tremor_window_ms'], 60000);
    expect(row['steady_pct'], 91.0);
  });

  test('the widened bound still rejects nonsense', () async {
    await _rebuild(db);
    for (final ms in [2999, 60001, 300000]) {
      await expectLater(
        db.insert('bites', {
          'meal_uuid': 'm1', 'timestamp': '2026-09-01T12:02:00Z',
          'sequence_number': 100 + ms % 7, 'tremor_magnitude': 0.4,
          'tremor_confidence': 0.9, 'tremor_window_ms': ms,
        }),
        throwsA(isA<DatabaseException>()),
        reason: '$ms is outside the contract',
      );
    }
  });
}

/// The copy step of DatabaseService._rebuildBitesTableV17, against the real
/// production DDL so a drift in that constant fails this test.
Future<void> _rebuild(Database db) async {
  await db.execute('ALTER TABLE bites RENAME TO bites_old_v17');
  await db.execute(DatabaseService.createBitesTable);
  await db.execute('''
    INSERT INTO bites (id, meal_uuid, timestamp, sequence_number,
                       tremor_magnitude, tremor_frequency, tremor_confidence,
                       tremor_window_ms, steady_pct, food_temp_c,
                       is_valid, is_synced)
    SELECT id, meal_uuid, timestamp, sequence_number,
           tremor_magnitude, tremor_frequency, tremor_confidence,
           CASE WHEN tremor_window_ms IS NULL THEN NULL
                WHEN tremor_window_ms > 60000 THEN 60000
                WHEN tremor_window_ms < 3000 THEN 3000
                ELSE tremor_window_ms END,
           steady_pct, food_temp_c, is_valid, is_synced
    FROM bites_old_v17
  ''');
  await db.execute('DROP TABLE bites_old_v17');
}
