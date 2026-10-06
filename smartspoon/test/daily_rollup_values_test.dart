// Every history screen reads the per-day rollup. It is pure SQL, so a wrong
// column or a bad join shows the patient a wrong number rather than throwing —
// which is exactly the kind of bug tests have to catch. This runs the
// production query (DatabaseService.dailySummarySql) against the production
// schema (createMealsTable / createBitesTable) with known data.
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:smartspoon/core/services/database_service.dart';

const _user = 'u1';

Future<Database> seed() async {
  final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
  await db.execute(DatabaseService.createMealsTable);
  await db.execute(DatabaseService.createBitesTable);

  // Today: an AI Lab lunch, 4 bites, measured 600 s, meal 92 % steady.
  await db.insert('meals', {
    'uuid': 'm-ai',
    'user_id': _user,
    'spoon_key': 'spoon-A',
    'started_at': '2026-09-15T12:00:00.000',
    'meal_type': 'Lunch',
    'total_bites': 4,
    'steady_pct': 92.0,
    'rhythm_hz': 5.2,
    'measured_seconds': 600,
    'movement_source': 'ai_lab',
    'duration_minutes': 10.0,
  });
  const steadies = [100.0, 90.0, 80.0, 70.0];
  for (var i = 0; i < steadies.length; i++) {
    await db.insert('bites', {
      'meal_uuid': 'm-ai',
      'timestamp': '2026-09-15T12:0${i + 1}:00.000',
      'sequence_number': i + 1,
      'tremor_magnitude': 0.3,
      'tremor_frequency': 5.2,
      'tremor_confidence': 0.9,
      'tremor_window_ms': 10000,
      'steady_pct': steadies[i],
      'food_temp_c': 40.0,
    });
  }

  // Same day, a second spoon: must NOT leak into spoon-A's totals.
  await db.insert('meals', {
    'uuid': 'm-other',
    'user_id': _user,
    'spoon_key': 'spoon-B',
    'started_at': '2026-09-15T13:00:00.000',
    'meal_type': 'Snack',
    'total_bites': 1,
    'steady_pct': 10.0,
    'measured_seconds': 60,
    'movement_source': 'ai_lab',
    'duration_minutes': 2.0,
  });
  await db.insert('bites', {
    'meal_uuid': 'm-other',
    'timestamp': '2026-09-15T13:01:00.000',
    'sequence_number': 1,
    'tremor_magnitude': 2.5,
    'steady_pct': 10.0,
  });

  // An older meal recorded before the model: no steadiness at all.
  await db.insert('meals', {
    'uuid': 'm-legacy',
    'user_id': _user,
    'spoon_key': 'spoon-A',
    'started_at': '2026-09-14T08:00:00.000',
    'meal_type': 'Breakfast',
    'total_bites': 2,
    'duration_minutes': 5.0,
  });
  for (var i = 0; i < 2; i++) {
    await db.insert('bites', {
      'meal_uuid': 'm-legacy',
      'timestamp': '2026-09-14T08:0${i + 1}:00.000',
      'sequence_number': i + 1,
      'tremor_magnitude': 1.0,
    });
  }
  return db;
}

Future<List<Map<String, Object?>>> rollup(Database db, {String? spoonKey}) =>
    db.rawQuery(
      DatabaseService.dailySummarySql(filterSpoon: spoonKey != null),
      spoonKey == null
          ? [_user, '2026-09-14', '2026-09-16']
          : [_user, '2026-09-14', '2026-09-16', spoonKey],
    );

void main() {
  sqfliteFfiInit();

  test('counts bites and averages steadiness per day', () async {
    final db = await seed();
    addTearDown(db.close);
    final rows = await rollup(db);
    expect(rows, hasLength(2), reason: 'two days of data');

    final today = rows.firstWhere((r) => r['date'] == '2026-09-15');
    expect(today['total_bites'], 5, reason: '4 bites + the other spoon\'s 1');
    expect(today['lunch_bites'], 4);
    expect(today['snack_bites'], 1);
    // Steadiness is the meals' figure weighted by measured time — the same
    // definition the meal row and the AI Lab page use:
    // (92 x 600 + 10 x 60) / 660
    expect(today['avg_steady_pct'], closeTo(84.545454, 1e-5));
    expect(today['measured_seconds'], 660, reason: '600 s + 60 s');
    expect(today['ai_lab_meals'], greaterThan(0));
  });

  test('older days report no steadiness instead of a made-up one', () async {
    final db = await seed();
    addTearDown(db.close);
    final rows = await rollup(db);
    final legacy = rows.firstWhere((r) => r['date'] == '2026-09-14');

    expect(legacy['total_bites'], 2);
    expect(legacy['avg_steady_pct'], isNull,
        reason: 'null must not be read as 100 % steady');
    expect(legacy['measured_seconds'], 0);
    expect(legacy['ai_lab_meals'], 0, reason: 'so the UI can say "older reading"');
    expect((legacy['avg_tremor_magnitude'] as num).toDouble(), closeTo(1.0, 1e-9));
  });

  test('one spoon never shows another spoon\'s numbers', () async {
    final db = await seed();
    addTearDown(db.close);
    final rows = await rollup(db, spoonKey: 'spoon-A');
    final today = rows.firstWhere((r) => r['date'] == '2026-09-15');

    expect(today['total_bites'], 4);
    expect(today['avg_steady_pct'], closeTo(92.0, 1e-9),
        reason: "spoon-A's own meal steadiness");
    expect(today['measured_seconds'], 600, reason: "spoon-B's 60 s excluded");
  });

  test('eating minutes are not multiplied by the bite count', () async {
    // The duration subquery exists because a LEFT JOIN onto bites used to
    // multiply each meal's minutes by how many bites it had.
    final db = await seed();
    addTearDown(db.close);
    final rows = await rollup(db, spoonKey: 'spoon-A');
    final today = rows.firstWhere((r) => r['date'] == '2026-09-15');
    expect((today['total_eating_min'] as num).toDouble(), closeTo(10.0, 1e-9));
  });
}
