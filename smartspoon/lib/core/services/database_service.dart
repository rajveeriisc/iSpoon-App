// database_service.dart — local SQLite persistence layer (offline-first store).
//
// Singleton wrapper around sqflite that owns the on-device database: schema
// creation, versioned migrations, and all CRUD/aggregate queries for meals,
// bites, daily_summaries, and cached devices. Everything the app records lands
// here first (source of truth while offline); SyncService later pushes/pulls it
// to the backend. Key methods: insertMeal/insertBites, getUnsyncedMeals/Bites +
// markSynced (sync bookkeeping), getMealStats (per-meal aggregates) and
// getDailySummaries (per-day rollups counted directly from the bites table).
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import 'package:flutter/foundation.dart';
import '../models/meal.dart';
import '../models/bite.dart';

/// Local SQLite database — versioned offline schema.
///
/// Tables:
///   meals             — one row per eating session
///   bites             — one row per detected bite (with tremor + temp readings)
///   daily_summaries   — pre-aggregated per-day cache (replaces daily_analytics,
///                       daily_bite_breakdown, daily_tremor_breakdown)
///   devices           — cached BLE device info
class DatabaseService {
  /// v16 — hand steadiness stored the way the user reads it.
  ///
  /// Until now the only movement record was `tremor_magnitude` (0–3 per bite).
  /// That cannot say how steady a MEAL was, how much of it was actually
  /// measured, or which engine produced the reading — so screens had to guess
  /// (the movement history page inferred "older reading" from a missing
  /// frequency). These columns store what the AI Lab model measures, in the
  /// same units every screen shows.
  ///
  /// All additive and nullable: old rows stay untouched and readable, and a
  /// null `movement_source` marks a pre-AI-Lab row honestly. The migration
  /// test runs these exact statements, so the two cannot drift apart.
  static const List<String> v16Statements = [
    // 0–100: share of the meal's measured time with no repeated rhythm.
    'ALTER TABLE meals ADD COLUMN steady_pct REAL',
    // The repeated rhythm itself, when one was found.
    'ALTER TABLE meals ADD COLUMN rhythm_hz REAL',
    // How much of the meal was actually measured. "94 % steady" from 8 seconds
    // and from 20 minutes are not the same claim.
    'ALTER TABLE meals ADD COLUMN measured_seconds INTEGER',
    // 'ai_lab' for model readings; NULL for everything recorded before it.
    'ALTER TABLE meals ADD COLUMN movement_source TEXT',
    // Steadiness around this one bite, 0–100.
    'ALTER TABLE bites ADD COLUMN steady_pct REAL',
  ];

  /// The `meals` and `bites` DDL, named so tests can build a real schema and
  /// run the production queries against it instead of a hand-copied one.
  static const String createMealsTable = '''
      CREATE TABLE meals (
        id              INTEGER PRIMARY KEY AUTOINCREMENT,
        uuid            TEXT    UNIQUE NOT NULL,
        server_id       INTEGER,
        user_id         TEXT    NOT NULL,
        device_id       TEXT,
        spoon_key       TEXT,
        started_at      TEXT    NOT NULL,
        ended_at        TEXT,
        meal_type       TEXT,
        total_bites     INTEGER DEFAULT 0,
        avg_pace_bpm    REAL,
        tremor_index    INTEGER DEFAULT 0,
        steady_pct      REAL,
        rhythm_hz       REAL,
        measured_seconds INTEGER,
        movement_source TEXT,
        duration_minutes REAL,
        avg_food_temp_c REAL,
        is_synced       INTEGER DEFAULT 0,
        dirty           INTEGER DEFAULT 0,
        created_at      TEXT    DEFAULT (datetime('now')),
        updated_at      TEXT    DEFAULT (datetime('now'))
      )
    ''';

  static const String createBitesTable = '''
      CREATE TABLE bites (
        id              INTEGER PRIMARY KEY AUTOINCREMENT,
        meal_uuid       TEXT    NOT NULL REFERENCES meals(uuid) ON DELETE CASCADE,
        timestamp       TEXT    NOT NULL,
        sequence_number INTEGER NOT NULL,
        tremor_magnitude REAL CHECK (tremor_magnitude IS NULL OR (tremor_magnitude >= 0 AND tremor_magnitude <= 3)),
        tremor_frequency REAL CHECK (tremor_frequency IS NULL OR (tremor_frequency > 0 AND tremor_frequency <= 20)),
        tremor_confidence REAL CHECK (tremor_confidence IS NULL OR (tremor_confidence >= 0 AND tremor_confidence <= 1)),
        tremor_window_ms INTEGER CHECK (tremor_window_ms IS NULL OR (tremor_window_ms >= 3000 AND tremor_window_ms <= 60000)),
        steady_pct      REAL CHECK (steady_pct IS NULL OR (steady_pct >= 0 AND steady_pct <= 100)),
        food_temp_c     REAL,
        is_valid        INTEGER DEFAULT 1,
        is_synced       INTEGER DEFAULT 0,
        CHECK ((tremor_confidence IS NULL) = (tremor_window_ms IS NULL)),
        CHECK (tremor_magnitude IS NOT NULL OR (tremor_frequency IS NULL AND tremor_confidence IS NULL AND tremor_window_ms IS NULL))
      )
    ''';

  /// The per-day rollup every history screen reads, as a string so a test can
  /// run this exact query against a real schema. The numbers it returns —
  /// bites, steadiness, measured seconds — are what the user sees, so a typo
  /// here is a wrong number on screen, not a crash the tests would catch.
  static String dailySummarySql({required bool filterSpoon}) {
    final spoonMainClause = filterSpoon ? ' AND m.spoon_key = ?' : '';
    final spoonSubClause = filterSpoon ? ' AND m2.spoon_key = m.spoon_key' : '';
    final spoonSubClause3 = filterSpoon ? ' AND m3.spoon_key = m.spoon_key' : '';
    final spoonSubClause4 = filterSpoon ? ' AND m4.spoon_key = m.spoon_key' : '';
    return '''
        SELECT
          substr(m.started_at, 1, 10)                                                      AS date,
          COUNT(b.id)                                                                       AS total_bites,
          (SELECT COALESCE(SUM(m2.duration_minutes), 0)
           FROM meals m2
           WHERE m2.user_id = m.user_id
             AND substr(m2.started_at, 1, 10) = substr(m.started_at, 1, 10)$spoonSubClause) AS total_eating_min,
          SUM(CASE WHEN m.meal_type = 'Breakfast' AND b.id IS NOT NULL THEN 1 ELSE 0 END)  AS breakfast_bites,
          SUM(CASE WHEN m.meal_type = 'Lunch'     AND b.id IS NOT NULL THEN 1 ELSE 0 END)  AS lunch_bites,
          SUM(CASE WHEN m.meal_type = 'Dinner'    AND b.id IS NOT NULL THEN 1 ELSE 0 END)  AS dinner_bites,
          SUM(CASE WHEN m.meal_type = 'Snack'     AND b.id IS NOT NULL THEN 1 ELSE 0 END)  AS snack_bites,
          AVG(CASE WHEN b.tremor_magnitude <= 3.0 THEN b.tremor_magnitude END)               AS avg_tremor_magnitude,
          AVG(CASE WHEN b.tremor_confidence >= 0.5 AND b.tremor_window_ms >= 3000 THEN b.tremor_frequency END) AS avg_tremor_frequency,
          COUNT(CASE WHEN b.tremor_confidence >= 0.5 AND b.tremor_window_ms >= 3000 THEN b.tremor_frequency END) AS tremor_rhythmic_count,
          SUM(CASE WHEN b.tremor_magnitude <= 3.0 AND b.tremor_magnitude < 0.6  THEN 1 ELSE 0 END) AS tremor_low_count,
          SUM(CASE WHEN b.tremor_magnitude <= 3.0 AND b.tremor_magnitude >= 0.6 AND b.tremor_magnitude < 1.4 THEN 1 ELSE 0 END) AS tremor_moderate_count,
          SUM(CASE WHEN b.tremor_magnitude <= 3.0 AND b.tremor_magnitude >= 1.4 THEN 1 ELSE 0 END) AS tremor_high_count,
          AVG(b.food_temp_c)                                                                AS avg_food_temp_c,
          -- Steadiness must mean the same thing here as on the meal and in AI
          -- Lab: the share of MEASURED TIME without a repeated rhythm. Taking
          -- it from the meals (weighted by how long each was measured) keeps
          -- the day, the meal and the live reading in agreement; averaging the
          -- per-bite values instead gave a different number for the same day.
          (SELECT CASE WHEN SUM(m4.measured_seconds) > 0
                       THEN SUM(m4.steady_pct * m4.measured_seconds)
                            / SUM(m4.measured_seconds) END
           FROM meals m4
           WHERE m4.user_id = m.user_id
             AND substr(m4.started_at, 1, 10) = substr(m.started_at, 1, 10)
             AND m4.steady_pct IS NOT NULL$spoonSubClause4)                                  AS avg_steady_pct,
          (SELECT COALESCE(SUM(m3.measured_seconds), 0)
           FROM meals m3
           WHERE m3.user_id = m.user_id
             AND substr(m3.started_at, 1, 10) = substr(m.started_at, 1, 10)$spoonSubClause3) AS measured_seconds,
          SUM(CASE WHEN m.movement_source = 'ai_lab' THEN 1 ELSE 0 END)                      AS ai_lab_meals
        FROM meals m
        LEFT JOIN bites b ON b.meal_uuid = m.uuid AND b.is_valid = 1
        WHERE m.user_id = ? AND substr(m.started_at, 1, 10) >= ? AND substr(m.started_at, 1, 10) < ?$spoonMainClause
        GROUP BY substr(m.started_at, 1, 10)
        ORDER BY date ASC
      ''';
  }

  static final DatabaseService _instance = DatabaseService._internal();
  static Database? _database;

  factory DatabaseService() => _instance;
  DatabaseService._internal();

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDatabase();
    return _database!;
  }

  Future<Database> _initDatabase() async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, 'smartspoon.db');

    return await openDatabase(
      path,
      // v17: the per-bite movement window is a rolling reading (<= 60 s), not
      // a meal total — see the v17 block in [_upgradeDb].
      version: 17,
      onCreate: _createDb,
      onUpgrade: _upgradeDb,
    );
  }

  // ==========================================================================
  // SCHEMA CREATION (fresh install)
  // ==========================================================================

  Future<void> _createDb(Database db, int version) async {
    if (kDebugMode) debugPrint('[DB] Creating schema...');

    // -- meals --
    await db.execute(createMealsTable);
    await db.execute(
      'CREATE INDEX idx_meals_started ON meals(started_at DESC)',
    );
    // Per-spoon (per-person) lookups: home cards filter today's meals by the
    // owning spoon's stable key.
    await db.execute(
      'CREATE INDEX idx_meals_spoon ON meals(user_id, spoon_key, started_at DESC)',
    );

    // -- bites --
    await db.execute(createBitesTable);
    await db.execute('CREATE INDEX idx_bites_meal  ON bites(meal_uuid)');
    await db.execute('CREATE INDEX idx_bites_time  ON bites(timestamp DESC)');
    await db.execute(
      'CREATE UNIQUE INDEX idx_bites_meal_sequence_unique ON bites(meal_uuid, sequence_number)',
    );

    // -- daily_summaries (replaces daily_analytics + daily_bite_breakdown + daily_tremor_breakdown) --
    await db.execute('''
      CREATE TABLE daily_summaries (
        user_id              TEXT,
        date                 TEXT,
        total_bites          INTEGER DEFAULT 0,
        total_eating_min     REAL    DEFAULT 0,
        breakfast_bites      INTEGER DEFAULT 0,
        lunch_bites          INTEGER DEFAULT 0,
        dinner_bites         INTEGER DEFAULT 0,
        snack_bites          INTEGER DEFAULT 0,
        avg_tremor_magnitude REAL    DEFAULT 0,
        avg_tremor_frequency REAL    DEFAULT 0,
        tremor_low_count     INTEGER DEFAULT 0,
        tremor_moderate_count INTEGER DEFAULT 0,
        tremor_high_count    INTEGER DEFAULT 0,
        avg_food_temp_c      REAL    DEFAULT 0,
        updated_at           TEXT    DEFAULT (datetime('now')),
        PRIMARY KEY (user_id, date)
      )
    ''');
    await db.execute(
      'CREATE INDEX idx_daily_date ON daily_summaries(date DESC)',
    );

    // -- devices (cached BLE device registry) --
    await db.execute('''
      CREATE TABLE devices (
        id              TEXT PRIMARY KEY,
        user_id         TEXT,
        mac_address_hash TEXT,
        firmware_version TEXT,
        heater_active   INTEGER DEFAULT 0,
        heater_activation_temp REAL DEFAULT 15.0,
        heater_max_temp REAL DEFAULT 40.0,
        last_sync_at    TEXT,
        created_at      TEXT DEFAULT (datetime('now')),
        updated_at      TEXT DEFAULT (datetime('now'))
      )
    ''');

    if (kDebugMode) debugPrint('[DB] schema created successfully.');
  }

  // ==========================================================================
  // MIGRATIONS (existing installs)
  // ==========================================================================

  Future<void> _upgradeDb(Database db, int oldVersion, int newVersion) async {
    if (kDebugMode) debugPrint('[DB] Upgrading $oldVersion → $newVersion');

    // v2: daily_bite_breakdown + daily_tremor_breakdown
    if (oldVersion < 2) {
      await _safeExec(db, '''
        CREATE TABLE IF NOT EXISTS daily_bite_breakdown (
          user_id TEXT, date TEXT,
          breakfast INTEGER DEFAULT 0, lunch INTEGER DEFAULT 0,
          dinner INTEGER DEFAULT 0, snacks INTEGER DEFAULT 0,
          total_bites INTEGER DEFAULT 0, avg_pace_bpm REAL,
          total_duration_min REAL, avg_meal_duration_min REAL,
          is_synced INTEGER DEFAULT 0,
          created_at TEXT DEFAULT (datetime('now')),
          updated_at TEXT DEFAULT (datetime('now')),
          PRIMARY KEY (user_id, date)
        )
      ''', 'v2 daily_bite_breakdown');

      await _safeExec(db, '''
        CREATE TABLE IF NOT EXISTS daily_tremor_breakdown (
          user_id TEXT, date TEXT,
          avg_magnitude REAL, avg_frequency_hz REAL,
          dominant_level TEXT, level_value INTEGER,
          total_tremor_events INTEGER DEFAULT 0,
          is_synced INTEGER DEFAULT 0,
          created_at TEXT DEFAULT (datetime('now')),
          updated_at TEXT DEFAULT (datetime('now')),
          PRIMARY KEY (user_id, date)
        )
      ''', 'v2 daily_tremor_breakdown');
    }

    // v5: remove weight_grams from bites
    if (oldVersion < 5) {
      final cols = await db.rawQuery('PRAGMA table_info(bites)');
      if (cols.any((c) => c['name'] == 'weight_grams')) {
        await _rebuildBitesTable(db);
      }
    }

    // v6: remove peak_magnitude from daily_tremor_breakdown
    // (no-op if table is replaced in v7 below)

    // v7: merge daily_analytics + daily_bite_breakdown + daily_tremor_breakdown
    //     into single daily_summaries; add food_temp_c to bites
    if (oldVersion < 7) {
      // 1. Create new unified daily_summaries
      await _safeExec(db, '''
        CREATE TABLE IF NOT EXISTS daily_summaries (
          user_id              TEXT,
          date                 TEXT,
          total_bites          INTEGER DEFAULT 0,
          total_eating_min     REAL    DEFAULT 0,
          breakfast_bites      INTEGER DEFAULT 0,
          lunch_bites          INTEGER DEFAULT 0,
          dinner_bites         INTEGER DEFAULT 0,
          snack_bites          INTEGER DEFAULT 0,
          avg_tremor_magnitude REAL    DEFAULT 0,
          avg_tremor_frequency REAL    DEFAULT 0,
          tremor_low_count     INTEGER DEFAULT 0,
          tremor_moderate_count INTEGER DEFAULT 0,
          tremor_high_count    INTEGER DEFAULT 0,
          avg_food_temp_c      REAL    DEFAULT 0,
          updated_at           TEXT    DEFAULT (datetime('now')),
          PRIMARY KEY (user_id, date)
        )
      ''', 'v7 create daily_summaries');

      await _safeExec(
        db,
        'CREATE INDEX IF NOT EXISTS idx_daily_date ON daily_summaries(date DESC)',
        'v7 index daily_summaries',
      );

      // 2. Migrate from daily_bite_breakdown (bites & duration data)
      await _safeExec(db, '''
        INSERT OR IGNORE INTO daily_summaries
          (user_id, date, total_bites, total_eating_min,
           breakfast_bites, lunch_bites, dinner_bites, snack_bites)
        SELECT
          user_id, date, total_bites,
          COALESCE(total_duration_min, 0),
          COALESCE(breakfast, 0), COALESCE(lunch, 0),
          COALESCE(dinner, 0),   COALESCE(snacks, 0)
        FROM daily_bite_breakdown
      ''', 'v7 migrate daily_bite_breakdown');

      // 3. Migrate tremor data from daily_tremor_breakdown
      await _safeExec(db, '''
        UPDATE daily_summaries
        SET
          avg_tremor_magnitude = (
            SELECT COALESCE(dtb.avg_magnitude, 0)
            FROM daily_tremor_breakdown dtb
            WHERE dtb.user_id = daily_summaries.user_id
              AND dtb.date    = daily_summaries.date
          ),
          avg_tremor_frequency = (
            SELECT COALESCE(dtb.avg_frequency_hz, 0)
            FROM daily_tremor_breakdown dtb
            WHERE dtb.user_id = daily_summaries.user_id
              AND dtb.date    = daily_summaries.date
          )
        WHERE EXISTS (
          SELECT 1 FROM daily_tremor_breakdown dtb
          WHERE dtb.user_id = daily_summaries.user_id
            AND dtb.date    = daily_summaries.date
        )
      ''', 'v7 migrate tremor into daily_summaries');

      // 4. Add food_temp_c to bites (SQLite ALTER TABLE ADD COLUMN is safe)
      final biteCols = await db.rawQuery('PRAGMA table_info(bites)');
      if (!biteCols.any((c) => c['name'] == 'food_temp_c')) {
        await _safeExec(
          db,
          'ALTER TABLE bites ADD COLUMN food_temp_c REAL',
          'v7 add food_temp_c to bites',
        );
      }

      // 5. Add heater columns to devices if missing
      final devCols = await db.rawQuery('PRAGMA table_info(devices)');
      if (!devCols.any((c) => c['name'] == 'heater_active')) {
        await _safeExec(
          db,
          'ALTER TABLE devices ADD COLUMN heater_active INTEGER DEFAULT 0',
          'v7 heater_active',
        );
        await _safeExec(
          db,
          'ALTER TABLE devices ADD COLUMN heater_activation_temp REAL DEFAULT 15.0',
          'v7 heater_activation_temp',
        );
        await _safeExec(
          db,
          'ALTER TABLE devices ADD COLUMN heater_max_temp REAL DEFAULT 40.0',
          'v7 heater_max_temp',
        );
      }

      // 6. Drop old redundant tables
      await _safeExec(
        db,
        'DROP TABLE IF EXISTS daily_bite_breakdown',
        'v7 drop daily_bite_breakdown',
      );
      await _safeExec(
        db,
        'DROP TABLE IF EXISTS daily_tremor_breakdown',
        'v7 drop daily_tremor_breakdown',
      );
      await _safeExec(
        db,
        'DROP TABLE IF EXISTS daily_analytics',
        'v7 drop daily_analytics',
      );
      await _safeExec(
        db,
        'DROP TABLE IF EXISTS temperature_logs',
        'v7 drop temperature_logs',
      );
    }

    // v8: idempotent safety pass — ensures daily_summaries always exists.
    //     Handles devices where v7 migration silently failed via _safeExec.
    if (oldVersion < 8) {
      await _safeExec(db, '''
        CREATE TABLE IF NOT EXISTS daily_summaries (
          user_id               TEXT,
          date                  TEXT,
          total_bites           INTEGER DEFAULT 0,
          total_eating_min      REAL    DEFAULT 0,
          breakfast_bites       INTEGER DEFAULT 0,
          lunch_bites           INTEGER DEFAULT 0,
          dinner_bites          INTEGER DEFAULT 0,
          snack_bites           INTEGER DEFAULT 0,
          avg_tremor_magnitude  REAL    DEFAULT 0,
          avg_tremor_frequency  REAL    DEFAULT 0,
          tremor_low_count      INTEGER DEFAULT 0,
          tremor_moderate_count INTEGER DEFAULT 0,
          tremor_high_count     INTEGER DEFAULT 0,
          avg_food_temp_c       REAL    DEFAULT 0,
          updated_at            TEXT    DEFAULT (datetime('now')),
          PRIMARY KEY (user_id, date)
        )
      ''', 'v8 ensure daily_summaries');

      await _safeExec(
        db,
        'CREATE INDEX IF NOT EXISTS idx_daily_date ON daily_summaries(date DESC)',
        'v8 index daily_summaries',
      );

      // Also ensure food_temp_c exists on bites (idempotent)
      final biteCols = await db.rawQuery('PRAGMA table_info(bites)');
      if (!biteCols.any((c) => c['name'] == 'food_temp_c')) {
        await _safeExec(
          db,
          'ALTER TABLE bites ADD COLUMN food_temp_c REAL',
          'v8 add food_temp_c to bites',
        );
      }
    }

    // v9: null out corrupt tremor_magnitude rows stored as raw amplitude (> 3.0).
    //     These were written before the amplitude→score fix. Setting to NULL means
    //     AVG() ignores them instead of inflating the tremor index.
    if (oldVersion < 9) {
      await _safeExec(
        db,
        'UPDATE bites SET tremor_magnitude = NULL WHERE tremor_magnitude > 3.0',
        'v9 null corrupt tremor_magnitude',
      );
      if (kDebugMode) {
        debugPrint('[DB] v9: nulled corrupt tremor_magnitude rows.');
      }
    }

    if (oldVersion < 11) {
      await _rebuildBitesTable(db);
      if (kDebugMode) {
        debugPrint('[DB] v11: bite sequence uniqueness enforced.');
      }
    }

    if (oldVersion < 13) {
      final biteCols = await db.rawQuery('PRAGMA table_info(bites)');
      if (!biteCols.any((c) => c['name'] == 'tremor_confidence')) {
        await db.execute('ALTER TABLE bites ADD COLUMN tremor_confidence REAL');
      }
      if (!biteCols.any((c) => c['name'] == 'tremor_window_ms')) {
        await db.execute(
          'ALTER TABLE bites ADD COLUMN tremor_window_ms INTEGER',
        );
      }
      if (kDebugMode) {
        debugPrint('[DB] v13: added tremor measurement-quality metadata.');
      }
    }

    if (oldVersion < 14) {
      await db.execute(
        'UPDATE bites SET tremor_frequency = NULL '
        'WHERE tremor_magnitude IS NULL',
      );
      if (kDebugMode) {
        debugPrint('[DB] v14: repaired movement-frequency consistency.');
      }
    }

    // v15: per-spoon (per-person) data. Add a stable spoon_key to meals so the
    // home cards can show each paired spoon's OWN numbers instead of one global
    // total shared by every spoon. ADDITIVE + non-destructive: a nullable column
    // plus a backfill from the existing device_id (the best stable key we have
    // for historical rows). New meals are tagged with the hardware product id.
    if (oldVersion < 15) {
      await _safeExec(
        db,
        'ALTER TABLE meals ADD COLUMN spoon_key TEXT',
        'v15 meals.spoon_key',
      );
      await _safeExec(
        db,
        'UPDATE meals SET spoon_key = device_id '
        'WHERE spoon_key IS NULL AND device_id IS NOT NULL',
        'v15 backfill spoon_key',
      );
      await _safeExec(
        db,
        'CREATE INDEX IF NOT EXISTS idx_meals_spoon '
        'ON meals(user_id, spoon_key, started_at DESC)',
        'v15 index meals.spoon_key',
      );
      if (kDebugMode) {
        debugPrint('[DB] v15: added per-spoon meals.spoon_key + backfill.');
      }
    }

    // v16: hand-steadiness columns — see [v16Statements] for the reasoning.
    if (oldVersion < 16) {
      for (final sql in v16Statements) {
        await _safeExec(db, sql, 'v16 ${sql.split('COLUMN').last.trim()}');
      }
      if (kDebugMode) {
        debugPrint('[DB] v16: added hand-steadiness columns.');
      }
    }

    // v17: widen the per-bite movement window to the rolling 60 s the model
    // actually produces.
    //
    // The old CHECK capped it at 30 s, sized for the bounded sliding window of
    // the detector the AI Lab model replaced. The model's reading spans the
    // meal, so past 0:30 every bite broke the constraint — and a CHECK does
    // not degrade, it aborts. The bite+meal transaction rolled back, the
    // caller rolled its anchor back with it, and the next tick retried the
    // same doomed write forever: no bite after the 30 s mark was ever stored,
    // and because the paired-NULL check ties them together, none carried
    // tremor_confidence either. The client now writes a rolling reading; this
    // makes the column accept it. SQLite cannot alter a CHECK, so the table is
    // rebuilt — copying every row, keeping ids.
    if (oldVersion < 17) {
      await _rebuildBitesTableV17(db);
      if (kDebugMode) {
        debugPrint('[DB] v17: per-bite movement window widened to 60 s.');
      }
    }

    if (kDebugMode) debugPrint('[DB] Upgrade complete.');
  }

  /// Rebuilds `bites` with the current [createBitesTable] DDL, preserving every
  /// row. Used to change a CHECK, which SQLite cannot alter in place.
  Future<void> _rebuildBitesTableV17(Database db) async {
    final before =
        Sqflite.firstIntValue(
          await db.rawQuery('SELECT COUNT(*) FROM bites'),
        ) ??
        0;

    // Not _safeExec: if the rename fails there is nothing to rebuild from, and
    // silently continuing would drop the table the copy reads.
    await db.execute('ALTER TABLE bites RENAME TO bites_old_v17');
    try {
      await db.execute(createBitesTable);
      await db.execute('''
        INSERT INTO bites (id, meal_uuid, timestamp, sequence_number,
                           tremor_magnitude, tremor_frequency, tremor_confidence,
                           tremor_window_ms, steady_pct, food_temp_c,
                           is_valid, is_synced)
        SELECT id, meal_uuid, timestamp, sequence_number,
               tremor_magnitude, tremor_frequency, tremor_confidence,
               -- Historical rows cannot exceed the old 30 s cap, but a row
               -- written by a build that skipped this bound would abort the
               -- whole copy. Clamp rather than lose the user's meals.
               CASE WHEN tremor_window_ms IS NULL THEN NULL
                    WHEN tremor_window_ms > 60000 THEN 60000
                    WHEN tremor_window_ms < 3000 THEN 3000
                    ELSE tremor_window_ms END,
               steady_pct, food_temp_c, is_valid, is_synced
        FROM bites_old_v17
      ''');
      await db.execute('DROP TABLE bites_old_v17');
    } catch (e) {
      // Put the user's data back before giving up; throwing here rolls the
      // onUpgrade transaction back, but only if the table still exists.
      await _safeExec(db, 'DROP TABLE IF EXISTS bites', 'v17 drop partial');
      await db.execute('ALTER TABLE bites_old_v17 RENAME TO bites');
      rethrow;
    }

    await _safeExec(db, 'CREATE INDEX IF NOT EXISTS idx_bites_meal ON bites(meal_uuid)',
        'v17 index meal');
    await _safeExec(
        db, 'CREATE INDEX IF NOT EXISTS idx_bites_time ON bites(timestamp DESC)',
        'v17 index time');
    await _safeExec(
        db,
        'CREATE UNIQUE INDEX IF NOT EXISTS idx_bites_meal_sequence_unique '
        'ON bites(meal_uuid, sequence_number)',
        'v17 index unique');

    final after =
        Sqflite.firstIntValue(
          await db.rawQuery('SELECT COUNT(*) FROM bites'),
        ) ??
        0;
    if (kDebugMode) {
      debugPrint('[DB] v17 rebuild bites: $before rows before, $after after');
    }
  }

  // Safe wrapper for migrations — logs errors but doesn't crash
  Future<void> _safeExec(Database db, String sql, String label) async {
    try {
      await db.execute(sql);
    } catch (e) {
      if (kDebugMode) debugPrint('[DB] Migration warning ($label): $e');
    }
  }

  /// True when this SQLite build supports window functions (`ROW_NUMBER() OVER`).
  ///
  /// Requires SQLite >= 3.25 (2018). Android does NOT bundle SQLite — it uses
  /// the OS copy, and API < 26 ships 3.9–3.18. Assuming window functions are
  /// available is therefore a real portability bug on older devices, not a
  /// theoretical one.
  Future<bool> _supportsWindowFunctions(Database db) async {
    try {
      final rows = await db.rawQuery('SELECT sqlite_version() AS v');
      final raw = (rows.first['v'] as String?) ?? '0';
      final parts = raw.split('.').map((p) => int.tryParse(p) ?? 0).toList();
      final major = parts.isNotEmpty ? parts[0] : 0;
      final minor = parts.length > 1 ? parts[1] : 0;
      final ok = major > 3 || (major == 3 && minor >= 25);
      if (kDebugMode) {
        debugPrint('[DB] SQLite $raw — window functions: $ok');
      }
      return ok;
    } catch (e) {
      // Unknown version → assume the older dialect. Being wrong in this
      // direction is merely slower; being wrong the other way loses data.
      if (kDebugMode) debugPrint('[DB] sqlite_version() failed ($e)');
      return false;
    }
  }

  /// Rebuilds the bites table (drops weight_grams, repairs sequence numbers,
  /// removes duplicates, enforces the uniqueness index).
  ///
  /// ⚠️ DESTRUCTIVE. Every statement that must succeed runs WITHOUT [_safeExec].
  ///
  /// This previously ran every step through _safeExec, which catches and
  /// discards the exception and only logs under kDebugMode — silent in release.
  /// Because nothing rethrew, sqflite's onUpgrade transaction COMMITTED the
  /// half-finished migration instead of rolling back, and `DROP TABLE bites_old`
  /// then ran unconditionally. On a device whose SQLite predates window
  /// functions the copy threw, was swallowed, and the drop still executed:
  /// every bite the patient had ever recorded was destroyed, on app update,
  /// with no error shown. Letting these throw is the entire fix — sqflite rolls
  /// the transaction back and the old data survives to be retried.
  Future<void> _rebuildBitesTable(Database db) async {
    final useWindowFns = await _supportsWindowFunctions(db);

    final beforeCount =
        Sqflite.firstIntValue(
          await db.rawQuery('SELECT COUNT(*) FROM bites'),
        ) ??
        0;
    if (kDebugMode) debugPrint('[DB] rebuild bites: $beforeCount rows before');

    // NOT _safeExec — if the rename fails there is nothing to rebuild from.
    await db.execute('ALTER TABLE bites RENAME TO bites_old');
    // This one MAY legitimately fail (column already present on newer schemas),
    // so it stays tolerant.
    await _safeExec(
      db,
      'ALTER TABLE bites_old ADD COLUMN food_temp_c REAL',
      'rebuild bites old food_temp',
    );
    await _safeExec(db, '''
      CREATE TABLE bites (
        id              INTEGER PRIMARY KEY AUTOINCREMENT,
        meal_uuid       TEXT    NOT NULL,
        timestamp       TEXT    NOT NULL,
        sequence_number INTEGER NOT NULL,
        tremor_magnitude REAL,
        tremor_frequency REAL,
        food_temp_c     REAL,
        is_valid        INTEGER DEFAULT 1,
        is_synced       INTEGER DEFAULT 0,
        FOREIGN KEY (meal_uuid) REFERENCES meals(uuid) ON DELETE CASCADE
      )
    ''', 'rebuild bites create');
    // ── Copy ────────────────────────────────────────────────────────────────
    // Repairs a NULL sequence_number by numbering rows per meal in time order.
    // The window-function form is preferred; the correlated-subquery fallback
    // produces identical results on SQLite < 3.25 (O(n²), but these tables are
    // small and this runs once per upgrade).
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
             ELSE $repairedSequence END AS repaired_sequence,
        b.is_synced
      FROM bites_old b
      ORDER BY b.meal_uuid, b.timestamp ASC, b.id ASC
    ''');

    // ── Verify BEFORE destroying ────────────────────────────────────────────
    // The unique index below cannot be created while duplicates exist, and the
    // old table must not be dropped unless the copy actually landed. Throwing
    // here rolls the whole onUpgrade transaction back, leaving the user's data
    // intact for the next attempt.
    final copiedCount =
        Sqflite.firstIntValue(
          await db.rawQuery('SELECT COUNT(*) FROM bites'),
        ) ??
        0;
    if (copiedCount < beforeCount) {
      throw StateError(
        'bites rebuild copied $copiedCount of $beforeCount rows — aborting so '
        'the migration rolls back instead of dropping bites_old',
      );
    }

    // ── De-duplicate (meal_uuid, sequence_number), keeping synced/newest ────
    if (useWindowFns) {
      await db.execute('''
        DELETE FROM bites WHERE id IN (
          SELECT id FROM (
            SELECT id, ROW_NUMBER() OVER (
              PARTITION BY meal_uuid, sequence_number
              ORDER BY is_synced DESC, id DESC
            ) AS duplicate_rank
            FROM bites
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
          )
          FROM bites grp GROUP BY grp.meal_uuid, grp.sequence_number
        )
      ''');
    }

    // Only now is it safe to destroy the original.
    await db.execute('DROP TABLE bites_old');

    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_bites_meal ON bites(meal_uuid)',
    );
    // Was missing from the rebuild, so every migrated install silently lost
    // this index and its timestamp-ordered queries.
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_bites_time ON bites(timestamp DESC)',
    );
    await db.execute(
      'CREATE UNIQUE INDEX IF NOT EXISTS idx_bites_meal_sequence_unique '
      'ON bites(meal_uuid, sequence_number)',
    );

    if (kDebugMode) {
      final after =
          Sqflite.firstIntValue(
            await db.rawQuery('SELECT COUNT(*) FROM bites'),
          ) ??
          0;
      debugPrint('[DB] rebuild bites: $beforeCount → $after rows');
    }
  }

  // ==========================================================================
  // MEAL OPERATIONS
  // ==========================================================================

  Future<int> insertMeal(Meal meal) async {
    final db = await database;
    return db.insert(
      'meals',
      meal.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<int> updateMeal(Meal meal) async {
    final db = await database;
    return db.update(
      'meals',
      meal.toMap(),
      where: 'uuid = ?',
      whereArgs: [meal.uuid],
    );
  }

  Future<Meal?> getMeal(String uuid) async {
    final db = await database;
    final rows = await db.query('meals', where: 'uuid = ?', whereArgs: [uuid]);
    return rows.isNotEmpty ? Meal.fromMap(rows.first) : null;
  }

  Future<List<Meal>> getMeals({
    required String userId,
    int limit = 20,
    int offset = 0,
    String? spoonKey,
  }) async {
    final db = await database;
    final filterSpoon = spoonKey != null && spoonKey.isNotEmpty;
    final rows = await db.query(
      'meals',
      where: filterSpoon ? 'user_id = ? AND spoon_key = ?' : 'user_id = ?',
      whereArgs: filterSpoon ? [userId, spoonKey] : [userId],
      orderBy: 'started_at DESC',
      limit: limit,
      offset: offset,
    );
    return rows.map(Meal.fromMap).toList();
  }

  Future<DateTime?> getLatestMealUpdatedAt({required String userId}) async {
    final db = await database;
    final rows = await db.query(
      'meals',
      columns: ['updated_at', 'started_at'],
      where: 'user_id = ?',
      whereArgs: [userId],
      orderBy: 'updated_at DESC',
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final value = rows.first['updated_at'] ?? rows.first['started_at'];
    if (value is! String || value.isEmpty) return null;
    return DateTime.tryParse(value)?.toLocal();
  }

  /// One-time repair for a legacy bug: older app builds wrote local meals
  /// with a literal placeholder ('current_user' / 'offline_user') instead of
  /// the real authenticated user id. Every query in this app correctly
  /// filters by the real user id, so those rows became permanently invisible
  /// — silently "missing" months of real history that's actually still on
  /// disk. Re-tags only literal placeholder rows to [realUserId]. Backend
  /// numeric ids and rows on shared devices are intentionally not auto-claimed
  /// because they cannot be proven to belong to the current Firebase account.
  Future<int> repairLegacyUserIdTags(
    String realUserId, {
    List<String> extraLegacyIds = const [],
  }) async {
    if (realUserId.isEmpty) return 0;
    final db = await database;
    final placeholderIds = [
      'current_user',
      'offline_user',
    ].where((id) => id.isNotEmpty && id != realUserId).toList();
    if (placeholderIds.isEmpty) return 0;

    if (extraLegacyIds.isNotEmpty && kDebugMode) {
      debugPrint(
        '[DB] Legacy repair ignored ambiguous backend user ids: $extraLegacyIds',
      );
    }

    final otherOwnerRows = await db.rawQuery(
      '''
      SELECT COUNT(DISTINCT user_id) AS cnt
      FROM meals
      WHERE user_id IS NOT NULL
        AND user_id != ''
        AND user_id != ?
        AND user_id NOT IN (${placeholderIds.map((_) => '?').join(',')})
    ''',
      [realUserId, ...placeholderIds],
    );
    final otherOwnerCount = (otherOwnerRows.first['cnt'] as num?)?.toInt() ?? 0;
    if (otherOwnerCount > 0) {
      if (kDebugMode) {
        debugPrint(
          '[DB] Legacy repair skipped: local DB contains another real user owner.',
        );
      }
      return 0;
    }

    final updated = await db.update(
      'meals',
      {'user_id': realUserId},
      where: 'user_id IN (${placeholderIds.map((_) => '?').join(',')})',
      whereArgs: placeholderIds,
    );
    if (updated > 0) {
      debugPrint('[DB] Legacy repair: re-tagged $updated meal(s).');
    }
    return updated;
  }

  /// Query meals for a specific date range using SQL (no in-memory scanning).
  /// [start] is inclusive (start of day), [end] is exclusive (start of next day).
  /// Filters by [userId] to prevent cross-user data leakage.
  Future<List<Meal>> getMealsForDateRange(
    DateTime start,
    DateTime end, {
    String? userId,
    String? spoonKey,
  }) async {
    final db = await database;
    final startStr = start.toIso8601String().substring(0, 10); // YYYY-MM-DD
    final endStr = end.toIso8601String().substring(0, 10);
    final filterSpoon = spoonKey != null && spoonKey.isNotEmpty;
    final spoonClause = filterSpoon ? ' AND spoon_key = ?' : '';

    if (userId != null && userId.isNotEmpty) {
      final rows = await db.rawQuery(
        '''
        SELECT * FROM meals
        WHERE user_id = ?
          AND substr(started_at, 1, 10) >= ?
          AND substr(started_at, 1, 10) < ?$spoonClause
        ORDER BY started_at DESC
      ''',
        filterSpoon
            ? [userId, startStr, endStr, spoonKey]
            : [userId, startStr, endStr],
      );
      return rows.map(Meal.fromMap).toList();
    }

    // Fallback: no userId filter (offline / pre-login edge case)
    final rows = await db.rawQuery(
      '''
      SELECT * FROM meals
      WHERE substr(started_at, 1, 10) >= ? AND substr(started_at, 1, 10) < ?
      ORDER BY started_at DESC
    ''',
      [startStr, endStr],
    );
    return rows.map(Meal.fromMap).toList();
  }

  /// Unsynced meals for [userId]. When [since] is given, only meals whose
  /// `started_at` is at/after it are returned — this is how the 3-month sync
  /// window is enforced: older meals are neither uploaded nor counted as
  /// "pending" (which would otherwise keep the app permanently trying to sync).
  Future<List<Meal>> getUnsyncedMeals({
    required String userId,
    DateTime? since,
  }) async {
    final db = await database;
    final where = StringBuffer('is_synced = 0 AND user_id = ?');
    final args = <Object?>[userId];
    if (since != null) {
      where.write(' AND started_at >= ?');
      args.add(since.toIso8601String());
    }
    final rows = await db.query(
      'meals',
      where: where.toString(),
      whereArgs: args,
    );
    return rows.map(Meal.fromMap).toList();
  }

  /// Mark a meal as synced — but ONLY if it still matches what was uploaded.
  ///
  /// Returns true when the flag was applied, false when the row changed
  /// underneath the in-flight request and was deliberately left unsynced.
  ///
  /// ⚠️ The compare-and-set is the whole point. This used to be an
  /// unconditional `WHERE uuid = ?`, which loses the tail of a meal:
  ///
  ///   12:00  sync starts, POSTs {total_bites: 20, ended_at: null}
  ///   12:01  user finishes; endSession writes {total_bites: 61, ended_at: …,
  ///          is_synced: 0}
  ///   12:01  the in-flight POST returns and flips is_synced = 1
  ///
  /// The meal never reappears in getUnsyncedMeals, so the CLOUD copy keeps
  /// ended_at = NULL and 20 bites forever. Raw bites still arrive via the
  /// orphan path, but every meal-level aggregate — duration, avg pace, tremor
  /// index, end time — is permanently wrong after a reinstall + restore.
  /// A 5-minute periodic sync makes hitting this mid-meal routine, not rare.
  ///
  /// [expectedTotalBites] / [expectedEndedAt] must be the values that were
  /// actually serialised into the request body.
  Future<bool> markMealSynced(
    String uuid,
    dynamic serverId, {
    int? expectedTotalBites,
    String? expectedEndedAt,
  }) async {
    final db = await database;
    final int? safeServerId = (serverId is int)
        ? serverId
        : int.tryParse(serverId?.toString() ?? '');

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

    if (rows == 0 && kDebugMode) {
      debugPrint(
        '[DB] markMealSynced skipped $uuid — row changed mid-flight; '
        'left unsynced so the next cycle uploads the final version',
      );
    }
    return rows > 0;
  }

  // ==========================================================================
  // BITE OPERATIONS
  // ==========================================================================

  Future<int> insertBite(Bite bite) async {
    final db = await database;
    return db.insert(
      'bites',
      bite.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> insertBites(List<Bite> bites) async {
    final db = await database;
    final batch = db.batch();
    for (final bite in bites) {
      batch.insert(
        'bites',
        bite.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    await batch.commit(noResult: true);
  }

  /// Inserts [bites] and upserts the `meals` row that owns them ATOMICALLY,
  /// returning the in-transaction meal stats.
  ///
  /// These two writes used to be separate commits with an aggregate query
  /// between them. If the app was killed in that window — which is exactly when
  /// it is most likely to be killed, mid-meal in the background — the bites were
  /// on disk under a meal_uuid with no `meals` row. Every query joins through
  /// `meals`, so those bites became invisible: never displayed, never uploaded,
  /// never recoverable. Committing both together makes that window impossible.
  ///
  /// [buildMeal] receives the stats computed from the bites table WITH the new
  /// rows already applied, and must return the meal row to write. It runs inside
  /// the transaction, so it must be pure — any DB call from it will deadlock.
  Future<Map<String, dynamic>> insertBitesAndUpsertMeal({
    required List<Bite> bites,
    required String mealUuid,
    required Meal Function(Map<String, dynamic> stats) buildMeal,
  }) async {
    final db = await database;
    return db.transaction((txn) async {
      if (bites.isNotEmpty) {
        final batch = txn.batch();
        for (final bite in bites) {
          batch.insert(
            'bites',
            bite.toMap(),
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        }
        await batch.commit(noResult: true);
      }

      final stats = await _mealStatsFrom(txn, mealUuid);
      await txn.insert(
        'meals',
        buildMeal(stats).toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      return stats;
    });
  }

  /// Direct count from the `bites` table for a given meal UUID.
  /// Used for real-time UI updates during an active session where no `meals` row exists yet.
  Future<int> countBitesForMeal(String mealUuid) async {
    final db = await database;
    final result = await db.rawQuery(
      'SELECT COUNT(*) as cnt FROM bites WHERE meal_uuid = ? AND is_valid = 1',
      [mealUuid],
    );
    return (result.first['cnt'] as num?)?.toInt() ?? 0;
  }

  /// Returns live stats for an in-progress meal: bite count + tremor averages.
  /// Computed from the bites table — survives app kill, always accurate.
  /// This is the single source of truth during an active session.
  Future<Map<String, dynamic>> getMealStats(String mealUuid) async {
    final db = await database;
    return _mealStatsFrom(db, mealUuid);
  }

  /// Shared body of [getMealStats], parameterised over the executor so it can
  /// also run INSIDE a transaction (Database and Transaction both implement
  /// DatabaseExecutor). Reading through the transaction is what lets
  /// [insertBitesAndUpsertMeal] see its own not-yet-committed bites.
  Future<Map<String, dynamic>> _mealStatsFrom(
    DatabaseExecutor executor,
    String mealUuid,
  ) async {
    final result = await executor.rawQuery(
      '''
      SELECT
        COUNT(*)                                                                                      AS total_bites,
        AVG(CASE WHEN tremor_magnitude IS NOT NULL AND tremor_magnitude <= 3.0 THEN tremor_magnitude END) AS avg_tremor_magnitude,
        AVG(CASE WHEN tremor_frequency IS NOT NULL THEN tremor_frequency END)                         AS avg_tremor_frequency,
        SUM(CASE WHEN tremor_magnitude IS NOT NULL AND tremor_magnitude <= 3.0 AND tremor_magnitude < 0.6  THEN 1 ELSE 0 END) AS tremor_low,
        SUM(CASE WHEN tremor_magnitude IS NOT NULL AND tremor_magnitude <= 3.0 AND tremor_magnitude >= 0.6 AND tremor_magnitude < 1.4 THEN 1 ELSE 0 END) AS tremor_moderate,
        SUM(CASE WHEN tremor_magnitude IS NOT NULL AND tremor_magnitude <= 3.0 AND tremor_magnitude >= 1.4 THEN 1 ELSE 0 END) AS tremor_high,
        AVG(CASE WHEN food_temp_c IS NOT NULL AND food_temp_c > 0 THEN food_temp_c END)               AS avg_food_temp
      FROM bites
      WHERE meal_uuid = ? AND is_valid = 1
    ''',
      [mealUuid],
    );
    final r = result.first;
    return {
      // Counts are genuinely zero when nothing matched.
      'total_bites': (r['total_bites'] as num?)?.toInt() ?? 0,
      'tremor_low': (r['tremor_low'] as num?)?.toInt() ?? 0,
      'tremor_moderate': (r['tremor_moderate'] as num?)?.toInt() ?? 0,
      'tremor_high': (r['tremor_high'] as num?)?.toInt() ?? 0,
      // ⚠️ Averages stay NULLABLE. SQL AVG() returns NULL when no row carried a
      // reading, and for a medical device "we have no tremor measurement" must
      // never be flattened into "measured, and it was 0.0" — a clinician cannot
      // tell a missing sensor from an absent symptom once that happens. Callers
      // must propagate the null (Meal.tremorIndex/avgFoodTemp are both double?).
      'avg_tremor_magnitude': (r['avg_tremor_magnitude'] as num?)?.toDouble(),
      'avg_tremor_frequency': (r['avg_tremor_frequency'] as num?)?.toDouble(),
      'avg_food_temp': (r['avg_food_temp'] as num?)?.toDouble(),
    };
  }

  Future<List<Bite>> getBitesForMeal(String mealUuid) async {
    final db = await database;
    final rows = await db.query(
      'bites',
      where: 'meal_uuid = ?',
      whereArgs: [mealUuid],
      orderBy: 'timestamp ASC',
    );
    return rows.map(Bite.fromMap).toList();
  }

  Future<List<Bite>> getUnsyncedBites({
    int limit = 50,
    required String userId,
    DateTime? since,
  }) async {
    final db = await database;
    final sinceClause = since != null ? 'AND m.started_at >= ?' : '';
    final args = since != null
        ? <Object?>[userId, since.toIso8601String(), limit]
        : <Object?>[userId, limit];
    final rows = await db.rawQuery('''
      SELECT b.*
      FROM bites b
      JOIN meals m ON m.uuid = b.meal_uuid
      WHERE b.is_synced = 0 AND m.user_id = ?
        $sinceClause
      LIMIT ?
    ''', args);
    return rows.map(Bite.fromMap).toList();
  }

  /// All unsynced bites for a specific meal — no limit, used by sync service.
  Future<List<Bite>> getUnsyncedBitesForMeal(
    String mealUuid, {
    required String userId,
  }) async {
    final db = await database;
    final rows = await db.rawQuery(
      '''
      SELECT b.*
      FROM bites b
      JOIN meals m ON m.uuid = b.meal_uuid
      WHERE b.meal_uuid = ?
        AND b.is_synced = 0
        AND m.user_id = ?
    ''',
      [mealUuid, userId],
    );
    return rows.map(Bite.fromMap).toList();
  }

  /// UUIDs of meals that are already synced to the server but still have
  /// unsynced bites — i.e. bites orphaned by a partial failure (the meal POST
  /// succeeded, the bites POST didn't). Such meals never appear in
  /// getUnsyncedMeals, so without this their bites would never be pushed.
  Future<List<String>> getSyncedMealUuidsWithUnsyncedBites({
    required String userId,
    DateTime? since,
  }) async {
    final db = await database;
    final sinceClause = since != null ? 'AND m.started_at >= ?' : '';
    final args = since != null
        ? <Object?>[userId, since.toIso8601String()]
        : <Object?>[userId];
    final rows = await db.rawQuery('''
      SELECT DISTINCT b.meal_uuid AS uuid
      FROM bites b
      JOIN meals m ON m.uuid = b.meal_uuid
      WHERE b.is_synced = 0
        AND m.is_synced = 1
        AND m.user_id = ?
        $sinceClause
    ''', args);
    return rows.map((r) => r['uuid'] as String?).whereType<String>().toList();
  }

  Future<void> markBitesSynced(List<int> ids) async {
    final db = await database;
    final batch = db.batch();
    for (final id in ids) {
      batch.update('bites', {'is_synced': 1}, where: 'id = ?', whereArgs: [id]);
    }
    await batch.commit(noResult: true);
  }

  /// Fetch daily summaries dynamically directly from the meals table to guarantee
  /// 100% data consistency (single source of truth).
  Future<List<Map<String, dynamic>>> getDailySummaries({
    required String userId,
    required DateTime start,
    required DateTime end,
    String? spoonKey,
  }) async {
    try {
      final db = await database;
      final startStr = start.toIso8601String().substring(0, 10);
      end = end.add(
        const Duration(days: 1),
      ); // Include current day up to midnight
      final endStr = end.toIso8601String().substring(0, 10);
      // Optional per-spoon (per-person) filter. The subquery correlates on
      // m.spoon_key (no extra param) so daily totals stay scoped to the spoon.
      final filterSpoon = spoonKey != null && spoonKey.isNotEmpty;
      final rows = await db.rawQuery(
        dailySummarySql(filterSpoon: filterSpoon),
        filterSpoon
            ? [userId, startStr, endStr, spoonKey]
            : [userId, startStr, endStr],
      );

      return rows;
    } catch (e) {
      // ⚠️ Do NOT swallow this to []. `meals`/`bites` are core tables created
      // unconditionally in _onCreate — by the time a user has data, a query
      // error here means something is actually wrong (disk I/O, corruption,
      // a bad migration), not "no meals yet". An empty list is exactly what
      // "the patient ate nothing this range" also looks like: for a clinician
      // reading a trend chart, a swallowed error and a genuinely bite-free day
      // render identically. Every caller either already has a try/catch that
      // preserves its last-known-good state on failure, or has been given one
      // (see live_insights_repository.dart / insights_controller.dart) — none
      // of them may treat "error" as "confirmed zero".
      debugPrint('[DB] getDailySummaries error: $e');
      rethrow;
    }
  }

  /// One-time attribution of pre-existing meals that have no spoon_key (recorded
  /// before per-spoon tracking) to a spoon, so historical data shows under a
  /// spoon instead of vanishing from the per-spoon home cards. Idempotent — once
  /// every row has a key this affects zero rows. Returns rows updated.
  Future<int> backfillNullSpoonKeys({
    required String userId,
    required String spoonKey,
  }) async {
    if (spoonKey.isEmpty) return 0;
    try {
      final db = await database;
      return await db.update(
        'meals',
        {'spoon_key': spoonKey},
        where:
            "user_id = ? AND (spoon_key IS NULL OR spoon_key = '')",
        whereArgs: [userId],
      );
    } catch (e) {
      debugPrint('[DB] backfillNullSpoonKeys error: $e');
      return 0;
    }
  }

  /// Per-spoon (per-person) stats for a SINGLE day, aggregated straight from the
  /// bites table (the single source of truth), filtered by the spoon's stable
  /// key. This is what lets each home card show its own spoon's numbers instead
  /// of one global total. Returns a map with total_bites, per-meal-type bites,
  /// total_eating_min and avg_food_temp_c (all zero when the spoon has no meals
  /// that day). [spoonKey] null-safe: an unpaired/unknown spoon returns zeros.
  Future<Map<String, dynamic>> getTodayStatsForSpoon({
    required String userId,
    required String spoonKey,
    required DateTime day,
  }) async {
    final empty = <String, dynamic>{
      'total_bites': 0,
      'breakfast_bites': 0,
      'lunch_bites': 0,
      'dinner_bites': 0,
      'snack_bites': 0,
      'total_eating_min': 0.0,
      'avg_food_temp_c': 0.0,
    };
    if (spoonKey.isEmpty) return empty;
    try {
      final db = await database;
      final dayStr = day.toIso8601String().substring(0, 10);
      final rows = await db.rawQuery(
        '''
        SELECT
          COUNT(b.id)                                                                       AS total_bites,
          (SELECT COALESCE(SUM(m2.duration_minutes), 0)
           FROM meals m2
           WHERE m2.user_id = m.user_id
             AND m2.spoon_key = m.spoon_key
             AND substr(m2.started_at, 1, 10) = ?)                                          AS total_eating_min,
          SUM(CASE WHEN m.meal_type = 'Breakfast' AND b.id IS NOT NULL THEN 1 ELSE 0 END)  AS breakfast_bites,
          SUM(CASE WHEN m.meal_type = 'Lunch'     AND b.id IS NOT NULL THEN 1 ELSE 0 END)  AS lunch_bites,
          SUM(CASE WHEN m.meal_type = 'Dinner'    AND b.id IS NOT NULL THEN 1 ELSE 0 END)  AS dinner_bites,
          SUM(CASE WHEN m.meal_type = 'Snack'     AND b.id IS NOT NULL THEN 1 ELSE 0 END)  AS snack_bites,
          AVG(b.food_temp_c)                                                                AS avg_food_temp_c
        FROM meals m
        LEFT JOIN bites b ON b.meal_uuid = m.uuid AND b.is_valid = 1
        WHERE m.user_id = ? AND m.spoon_key = ? AND substr(m.started_at, 1, 10) = ?
      ''',
        [dayStr, userId, spoonKey, dayStr],
      );
      if (rows.isEmpty) return empty;
      final r = rows.first;
      return <String, dynamic>{
        'total_bites': (r['total_bites'] as num?)?.toInt() ?? 0,
        'breakfast_bites': (r['breakfast_bites'] as num?)?.toInt() ?? 0,
        'lunch_bites': (r['lunch_bites'] as num?)?.toInt() ?? 0,
        'dinner_bites': (r['dinner_bites'] as num?)?.toInt() ?? 0,
        'snack_bites': (r['snack_bites'] as num?)?.toInt() ?? 0,
        'total_eating_min': (r['total_eating_min'] as num?)?.toDouble() ?? 0.0,
        'avg_food_temp_c': (r['avg_food_temp_c'] as num?)?.toDouble() ?? 0.0,
      };
    } catch (e) {
      debugPrint('[DB] getTodayStatsForSpoon error: $e');
      return empty;
    }
  }

  // ==========================================================================
  // TREMOR STATS — computed live from bites (used by Tremor History page)
  // Kept as on-demand query so no extra table is needed.
  // ==========================================================================

  Future<List<Map<String, dynamic>>> getDailyTremorStats({
    required String userId,
    required DateTime start,
    required DateTime end,
  }) async {
    final db = await database;
    return db.rawQuery(
      '''
      SELECT
        substr(m.started_at, 1, 10)                                                        AS date,
        AVG(CASE WHEN b.tremor_confidence >= 0.5 AND b.tremor_window_ms >= 3000 THEN b.tremor_frequency END) AS avg_frequency,
        COUNT(CASE WHEN b.tremor_confidence >= 0.5 AND b.tremor_window_ms >= 3000 THEN b.tremor_frequency END) AS rhythmic_sample_count,
        AVG(CASE WHEN b.tremor_magnitude <= 3.0 THEN b.tremor_magnitude END)               AS avg_magnitude,
        AVG(m.steady_pct)                                                                  AS avg_steady_pct,
        COUNT(b.id)                                                                        AS sample_count,
        SUM(CASE WHEN b.tremor_magnitude <= 3.0 AND b.tremor_magnitude <  0.6 THEN 1 ELSE 0 END) AS low_count,
        SUM(CASE WHEN b.tremor_magnitude <= 3.0 AND b.tremor_magnitude >= 0.6 AND b.tremor_magnitude < 1.4 THEN 1 ELSE 0 END) AS moderate_count,
        SUM(CASE WHEN b.tremor_magnitude <= 3.0 AND b.tremor_magnitude >= 1.4 THEN 1 ELSE 0 END) AS high_count
      FROM meals  m
      JOIN bites  b ON b.meal_uuid = m.uuid
      WHERE m.user_id = ? AND m.started_at >= ? AND m.started_at <= ?
        AND b.tremor_magnitude IS NOT NULL
      GROUP BY substr(m.started_at, 1, 10)
    ''',
      [userId, start.toIso8601String(), end.toIso8601String()],
    );
  }

  // Per meal-type tremor breakdown (Tremor History detail view)
  Future<List<Map<String, dynamic>>> getMealTypeTremorStats({
    required String userId,
    required DateTime start,
    required DateTime end,
    String? spoonKey,
  }) async {
    final db = await database;
    final filterSpoon = spoonKey != null && spoonKey.isNotEmpty;
    final spoonClause = filterSpoon ? ' AND m.spoon_key = ?' : '';
    return db.rawQuery(
      '''
      SELECT
        substr(m.started_at, 1, 10)                                                        AS date,
        m.meal_type,
        AVG(CASE WHEN b.tremor_confidence >= 0.5 AND b.tremor_window_ms >= 3000 THEN b.tremor_frequency END) AS avg_frequency,
        COUNT(CASE WHEN b.tremor_confidence >= 0.5 AND b.tremor_window_ms >= 3000 THEN b.tremor_frequency END) AS rhythmic_sample_count,
        AVG(CASE WHEN b.tremor_magnitude <= 3.0 THEN b.tremor_magnitude END)               AS avg_magnitude,
        AVG(m.steady_pct)                                                                  AS avg_steady_pct,
        SUM(CASE WHEN b.tremor_magnitude <= 3.0 AND b.tremor_magnitude <  0.6 THEN 1 ELSE 0 END) AS low_count,
        SUM(CASE WHEN b.tremor_magnitude <= 3.0 AND b.tremor_magnitude >= 0.6 AND b.tremor_magnitude < 1.4 THEN 1 ELSE 0 END) AS moderate_count,
        SUM(CASE WHEN b.tremor_magnitude <= 3.0 AND b.tremor_magnitude >= 1.4 THEN 1 ELSE 0 END) AS high_count
      FROM meals  m
      JOIN bites  b ON b.meal_uuid = m.uuid
      WHERE m.user_id = ? AND m.started_at >= ? AND m.started_at <= ?$spoonClause
        AND b.tremor_magnitude IS NOT NULL
      GROUP BY substr(m.started_at, 1, 10), m.meal_type
    ''',
      filterSpoon
          ? [userId, start.toIso8601String(), end.toIso8601String(), spoonKey]
          : [userId, start.toIso8601String(), end.toIso8601String()],
    );
  }

  // ==========================================================================
  // UTILITY
  // ==========================================================================

  Future<void> clearDatabase({bool includeDevices = false}) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.delete('bites');
      await txn.delete('meals');
      await txn.delete('daily_summaries');
      if (includeDevices) await txn.delete('devices');
    });
  }
}
