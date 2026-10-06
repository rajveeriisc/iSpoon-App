// v16 adds the hand-steadiness columns. A migration that touches the tables
// holding every bite a patient ever recorded has to be proven non-destructive
// BEFORE it ships, so this runs the production statements themselves
// (DatabaseService.v16Statements) against a v15-shaped database with data in
// it — not a copy of the SQL that can drift.
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:smartspoon/core/services/database_service.dart';

Future<Database> openV15WithData() async {
  final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
  await db.execute('''
    CREATE TABLE meals (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      uuid TEXT UNIQUE NOT NULL,
      user_id TEXT NOT NULL,
      spoon_key TEXT,
      started_at TEXT NOT NULL,
      meal_type TEXT,
      total_bites INTEGER DEFAULT 0,
      tremor_index INTEGER DEFAULT 0,
      duration_minutes REAL
    )
  ''');
  await db.execute('''
    CREATE TABLE bites (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      meal_uuid TEXT NOT NULL,
      timestamp TEXT NOT NULL,
      sequence_number INTEGER NOT NULL,
      tremor_magnitude REAL,
      tremor_frequency REAL,
      is_valid INTEGER DEFAULT 1
    )
  ''');
  await db.insert('meals', {
    'uuid': 'meal-1',
    'user_id': 'u1',
    'started_at': '2026-09-10T12:00:00.000Z',
    'meal_type': 'Lunch',
    'total_bites': 2,
    'tremor_index': 1,
    'duration_minutes': 11.5,
  });
  for (var i = 1; i <= 2; i++) {
    await db.insert('bites', {
      'meal_uuid': 'meal-1',
      'timestamp': '2026-09-10T12:0$i:00.000Z',
      'sequence_number': i,
      'tremor_magnitude': 0.4,
    });
  }
  return db;
}

Future<void> migrate(Database db) async {
  for (final sql in DatabaseService.v16Statements) {
    await db.execute(sql);
  }
}

void main() {
  sqfliteFfiInit();

  test('keeps every existing row and value', () async {
    final db = await openV15WithData();
    addTearDown(db.close);
    await migrate(db);

    final meals = await db.query('meals');
    final bites = await db.query('bites');
    expect(meals, hasLength(1));
    expect(bites, hasLength(2));
    expect(meals.first['duration_minutes'], 11.5);
    expect(meals.first['total_bites'], 2);
    expect(bites.first['tremor_magnitude'], 0.4);
  });

  test('old rows read as "not measured", never as steady', () async {
    final db = await openV15WithData();
    addTearDown(db.close);
    await migrate(db);

    final meal = (await db.query('meals')).first;
    expect(meal['steady_pct'], isNull, reason: 'null must not become 100 %');
    expect(meal['rhythm_hz'], isNull);
    expect(meal['measured_seconds'], isNull);
    expect(meal['movement_source'], isNull,
        reason: 'a pre-AI-Lab meal must be identifiable as one');
    expect((await db.query('bites')).first['steady_pct'], isNull);
  });

  test('new rows store the numbers the user is shown', () async {
    final db = await openV15WithData();
    addTearDown(db.close);
    await migrate(db);

    await db.insert('meals', {
      'uuid': 'meal-2',
      'user_id': 'u1',
      'started_at': '2026-09-15T12:00:00.000Z',
      'total_bites': 20,
      'steady_pct': 94.5,
      'rhythm_hz': 5.2,
      'measured_seconds': 640,
      'movement_source': 'ai_lab',
    });
    final meal =
        (await db.query('meals', where: 'uuid = ?', whereArgs: ['meal-2'])).first;
    expect(meal['steady_pct'], 94.5);
    expect(meal['rhythm_hz'], 5.2);
    expect(meal['measured_seconds'], 640);
    expect(meal['movement_source'], 'ai_lab');
  });

  test('a second run is refused, which is why production wraps each statement',
      () async {
    final db = await openV15WithData();
    addTearDown(db.close);
    await migrate(db);
    // DatabaseService runs these through _safeExec for exactly this reason:
    // a re-run (partial upgrade, downgrade-then-upgrade) must not abort the
    // whole onUpgrade transaction and leave the user's schema half-migrated.
    await expectLater(migrate(db), throwsA(isA<DatabaseException>()));
  });
}
