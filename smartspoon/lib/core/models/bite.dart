// bite.dart — data model for a single detected bite.
//
// One row in the local `bites` table and one record synced to the backend.
// Carries the parent meal UUID, timestamp, sequence number, and per-bite
// sensor readings (tremor magnitude/frequency from TremorDetectionService,
// food temperature from the BLE temperature characteristic). `toMap`/`fromMap`
// handle SQLite (de)serialization; `hasSameSyncContent` compares only the
// user-facing fields (ignoring ids/sync flags) so an identical cloud restore
// is not mistaken for a change.
class Bite {
  final int? id;
  final String mealUuid;
  final DateTime timestamp;
  final int? sequenceNumber;

  /// Legacy storage name for the 0–3 movement-variation index.
  final double? tremorMagnitude;
  final double? tremorFrequency; // Hz   — repeated rhythm, when one was found
  final double? tremorConfidence; // 0–1 signal quality
  final int? tremorWindowMs;

  /// How steady the hand was around this bite, 0–100 — the same number the
  /// user reads on every screen. Stored alongside the 0–3 index rather than
  /// derived, so a bite recorded today still means what it meant when the
  /// scale or the model changes.
  final double? steadyPct;
  final double? foodTempC; // °C   — from BLE temperature characteristic
  final bool isValid;
  final bool isSynced;

  Bite({
    this.id,
    required this.mealUuid,
    required this.timestamp,
    this.sequenceNumber,
    this.tremorMagnitude,
    this.tremorFrequency,
    this.tremorConfidence,
    this.tremorWindowMs,
    this.steadyPct,
    this.foodTempC,
    this.isValid = true,
    this.isSynced = false,
  });

  bool hasSameSyncContent(Bite other) {
    return mealUuid == other.mealUuid &&
        timestamp.toUtc().microsecondsSinceEpoch ==
            other.timestamp.toUtc().microsecondsSinceEpoch &&
        sequenceNumber == other.sequenceNumber &&
        _sameNullableNumber(tremorMagnitude, other.tremorMagnitude) &&
        _sameNullableNumber(tremorFrequency, other.tremorFrequency) &&
        _sameNullableNumber(tremorConfidence, other.tremorConfidence) &&
        tremorWindowMs == other.tremorWindowMs &&
        _sameNullableNumber(steadyPct, other.steadyPct) &&
        _sameNullableNumber(foodTempC, other.foodTempC) &&
        isValid == other.isValid;
  }

  static bool _sameNullableNumber(double? a, double? b) {
    if (a == null || b == null) return a == b;
    return (a - b).abs() <= 0.000001;
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'meal_uuid': mealUuid,
      'timestamp': timestamp.toIso8601String(),
      'sequence_number': sequenceNumber,
      'tremor_magnitude': tremorMagnitude,
      'tremor_frequency': tremorFrequency,
      'tremor_confidence': tremorConfidence,
      'tremor_window_ms': tremorWindowMs,
      'steady_pct': steadyPct,
      'food_temp_c': foodTempC,
      'is_valid': isValid ? 1 : 0,
      'is_synced': isSynced ? 1 : 0,
    };
  }

  factory Bite.fromMap(Map<String, dynamic> map) {
    return Bite(
      id: map['id'],
      mealUuid: map['meal_uuid'],
      timestamp: DateTime.parse(map['timestamp']).toLocal(),
      sequenceNumber: map['sequence_number'],
      tremorMagnitude: map['tremor_magnitude'],
      tremorFrequency: map['tremor_frequency'],
      tremorConfidence: (map['tremor_confidence'] as num?)?.toDouble(),
      tremorWindowMs: (map['tremor_window_ms'] as num?)?.toInt(),
      steadyPct: (map['steady_pct'] as num?)?.toDouble(),
      foodTempC: map['food_temp_c'],
      isValid: (map['is_valid'] ?? 1) == 1,
      isSynced: (map['is_synced'] ?? 0) == 1,
    );
  }
}
