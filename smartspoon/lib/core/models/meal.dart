// meal.dart — data model for one eating session (a "meal").
//
// One row in the local `meals` table and one record synced to the backend.
// Holds identity (local id, sync uuid, server id, owning user/device), timing
// (startedAt/endedAt/durationMinutes), meal type, and aggregate stats
// (totalBites, avgPaceBpm, tremorIndex 0–3, avgFoodTemp). `copyWith` produces
// edited copies; `toMap`/`fromMap` do SQLite (de)serialization; and
// `hasSameSyncContent` compares only synced user data (ignoring ids, sync flags,
// and timestamps) so an identical restore isn't counted as a change.
import 'package:uuid/uuid.dart';

class Meal {
  final int? id; // SQLite ID
  final String uuid; // Sync ID
  final int? serverId; // Backend ID
  final String userId;
  final String? deviceId;

  /// Stable per-spoon (per-person) key — the spoon's hardware product id, or the
  /// BLE deviceId as a fallback. Survives BLE address rotation and reflash, so a
  /// spoon's meals/bites stay attributed to the right spoon/person even when the
  /// address changes. This is the dimension the home cards filter on.
  final String? spoonKey;
  final DateTime startedAt;
  final DateTime? endedAt;
  final String? mealType; // Breakfast, Lunch, Dinner, Snack
  final int totalBites;
  final double? avgPaceBpm;
  final double? tremorIndex; // 0–3 scale (tremor band power ratio)

  /// Hand steadiness for the whole meal, 0–100: the share of the measured time
  /// with no repeated rhythm. This is the number the user reads.
  final double? steadyPct;

  /// The repeated rhythm found during the meal, in Hz, or null when none was.
  final double? rhythmHz;

  /// How much of the meal was actually measured. Without it "94 % steady"
  /// from 8 seconds looks the same as from 20 minutes.
  final int? measuredSeconds;

  /// Which engine produced the movement numbers: 'ai_lab', or null for meals
  /// recorded before the model existed. Local only — not sent to the backend.
  final String? movementSource;
  final double? durationMinutes;
  final double? avgFoodTemp; // Average temperature during meal
  final bool isSynced;
  final bool dirty;
  final DateTime createdAt;
  final DateTime updatedAt;

  Meal({
    this.id,
    String? uuid,
    this.serverId,
    required this.userId,
    this.deviceId,
    this.spoonKey,
    required this.startedAt,
    this.endedAt,
    this.mealType,
    this.totalBites = 0,
    this.avgPaceBpm,
    this.tremorIndex,
    this.steadyPct,
    this.rhythmHz,
    this.measuredSeconds,
    this.movementSource,
    this.durationMinutes,
    this.avgFoodTemp,
    this.isSynced = false,
    this.dirty = false,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) : uuid = uuid ?? const Uuid().v4(),
       createdAt = createdAt ?? DateTime.now(),
       updatedAt = updatedAt ?? DateTime.now();

  Meal copyWith({
    int? id,
    String? uuid,
    int? serverId,
    String? userId,
    String? deviceId,
    String? spoonKey,
    DateTime? startedAt,
    DateTime? endedAt,
    String? mealType,
    int? totalBites,
    double? avgPaceBpm,
    double? tremorIndex,
    double? steadyPct,
    double? rhythmHz,
    int? measuredSeconds,
    String? movementSource,
    double? durationMinutes,
    double? avgFoodTemp,
    bool? isSynced,
    bool? dirty,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return Meal(
      id: id ?? this.id,
      uuid: uuid ?? this.uuid,
      serverId: serverId ?? this.serverId,
      userId: userId ?? this.userId,
      deviceId: deviceId ?? this.deviceId,
      spoonKey: spoonKey ?? this.spoonKey,
      startedAt: startedAt ?? this.startedAt,
      endedAt: endedAt ?? this.endedAt,
      mealType: mealType ?? this.mealType,
      totalBites: totalBites ?? this.totalBites,
      avgPaceBpm: avgPaceBpm ?? this.avgPaceBpm,
      tremorIndex: tremorIndex ?? this.tremorIndex,
      steadyPct: steadyPct ?? this.steadyPct,
      rhythmHz: rhythmHz ?? this.rhythmHz,
      measuredSeconds: measuredSeconds ?? this.measuredSeconds,
      movementSource: movementSource ?? this.movementSource,
      durationMinutes: durationMinutes ?? this.durationMinutes,
      avgFoodTemp: avgFoodTemp ?? this.avgFoodTemp,
      isSynced: isSynced ?? this.isSynced,
      dirty: dirty ?? this.dirty,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  /// Compares only user data that is synchronized with the backend.
  /// Local database ids, sync flags, ownership, and server timestamps are
  /// transport metadata and must not turn an identical restore into a change.
  bool hasSameSyncContent(Meal other) {
    return uuid == other.uuid &&
        deviceId == other.deviceId &&
        spoonKey == other.spoonKey &&
        _sameInstant(startedAt, other.startedAt) &&
        _sameNullableInstant(endedAt, other.endedAt) &&
        mealType == other.mealType &&
        totalBites == other.totalBites &&
        _sameNullableNumber(avgPaceBpm, other.avgPaceBpm) &&
        _sameNullableNumber(tremorIndex, other.tremorIndex) &&
        _sameNullableNumber(durationMinutes, other.durationMinutes) &&
        _sameNullableNumber(avgFoodTemp, other.avgFoodTemp);
  }

  static bool _sameInstant(DateTime a, DateTime b) =>
      a.toUtc().microsecondsSinceEpoch == b.toUtc().microsecondsSinceEpoch;

  static bool _sameNullableInstant(DateTime? a, DateTime? b) {
    if (a == null || b == null) return a == b;
    return _sameInstant(a, b);
  }

  static bool _sameNullableNumber(double? a, double? b) {
    if (a == null || b == null) return a == b;
    return (a - b).abs() <= 0.000001;
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'uuid': uuid,
      'server_id': serverId,
      'user_id': userId,
      'device_id': deviceId,
      'spoon_key': spoonKey,
      'started_at': startedAt.toUtc().toIso8601String(),
      'ended_at': endedAt?.toUtc().toIso8601String(),
      'meal_type': mealType,
      'total_bites': totalBites,
      'avg_pace_bpm': avgPaceBpm,
      'tremor_index': tremorIndex,
      'steady_pct': steadyPct,
      'rhythm_hz': rhythmHz,
      'measured_seconds': measuredSeconds,
      'movement_source': movementSource,
      'duration_minutes': durationMinutes,
      'avg_food_temp_c': avgFoodTemp, // Fixed column name
      'is_synced': isSynced ? 1 : 0,
      'dirty': dirty ? 1 : 0,
      'created_at': createdAt.toUtc().toIso8601String(),
      'updated_at': updatedAt.toUtc().toIso8601String(),
    };
  }

  factory Meal.fromMap(Map<String, dynamic> map) {
    return Meal(
      id: map['id'],
      uuid: map['uuid'],
      serverId: map['server_id'],
      userId: map['user_id'],
      deviceId: map['device_id'],
      spoonKey: map['spoon_key'],
      startedAt: DateTime.parse(map['started_at']).toLocal(),
      endedAt: map['ended_at'] != null
          ? DateTime.parse(map['ended_at']).toLocal()
          : null,
      mealType: map['meal_type'],
      totalBites: map['total_bites'] ?? 0,
      avgPaceBpm: map['avg_pace_bpm'],
      tremorIndex: (map['tremor_index'] as num?)?.toDouble(),
      steadyPct: (map['steady_pct'] as num?)?.toDouble(),
      rhythmHz: (map['rhythm_hz'] as num?)?.toDouble(),
      measuredSeconds: (map['measured_seconds'] as num?)?.toInt(),
      movementSource: map['movement_source'] as String?,
      durationMinutes: map['duration_minutes'],
      avgFoodTemp: map['avg_food_temp_c'], // Fixed column name
      isSynced: (map['is_synced'] ?? 0) == 1,
      dirty: (map['dirty'] ?? 0) == 1,
      createdAt: map['created_at'] != null
          ? DateTime.parse(map['created_at']).toLocal()
          : null,
      updatedAt: map['updated_at'] != null
          ? DateTime.parse(map['updated_at']).toLocal()
          : null,
    );
  }
}
