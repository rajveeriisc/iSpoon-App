// personalized_eating_model.dart — per-person adaptive eating model.
//
// The AI Lab's data collector builds a POPULATION dataset ("20 sessions × 20
// bites"). This service is the complementary piece the user asked for: an
// on-device model that LEARNS EACH PERSON'S OWN eating habits over time and
// personalizes the app to them.
//
// HOW IT LEARNS (online, no server, no heavy ML):
//   • Keyed by the stable per-spoon key (spoon = person), so each family member
//     gets their own learned profile.
//   • Every completed meal updates running EWMA statistics — pace (bites/min),
//     meal duration, bites/meal, tremor baseline — so RECENT behaviour weighs
//     more (the model keeps adapting as the person changes).
//   • It also tracks the variance of pace, so it can tell a "normal for you"
//     meal from an unusual one (personalized anomaly band, not a fixed rule).
//   • After [learnThreshold] meals the profile is considered LEARNED and the
//     app switches from generic tips to personalized coaching.
//
// Persisted per profile in SharedPreferences; survives restarts.
import 'dart:convert';
import 'dart:math' show sqrt;
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// One person's learned eating profile (keyed by the stable spoon key).
class PersonalizedProfile {
  final String spoonKey;
  int mealCount;
  double avgBitesPerMeal; // EWMA
  double avgPaceBpm; // EWMA (bites / minute)
  double avgMealMinutes; // EWMA
  double avgTremor; // EWMA (0–3)
  double paceVar; // EWMA of squared pace deviation (personalized band)
  DateTime updatedAt;

  PersonalizedProfile({
    required this.spoonKey,
    this.mealCount = 0,
    this.avgBitesPerMeal = 0,
    this.avgPaceBpm = 0,
    this.avgMealMinutes = 0,
    this.avgTremor = 0,
    this.paceVar = 0,
    DateTime? updatedAt,
  }) : updatedAt = updatedAt ?? DateTime.now();

  /// Meals needed before the model personalizes ("after 20 sets").
  static const int learnThreshold = 20;

  bool get isLearned => mealCount >= learnThreshold;
  double get progress => (mealCount / learnThreshold).clamp(0.0, 1.0);
  double get paceStd => paceVar <= 0 ? 0 : sqrt(paceVar);

  Map<String, dynamic> toJson() => {
        'spoonKey': spoonKey,
        'mealCount': mealCount,
        'avgBitesPerMeal': avgBitesPerMeal,
        'avgPaceBpm': avgPaceBpm,
        'avgMealMinutes': avgMealMinutes,
        'avgTremor': avgTremor,
        'paceVar': paceVar,
        'updatedAt': updatedAt.toIso8601String(),
      };

  factory PersonalizedProfile.fromJson(Map<String, dynamic> j) =>
      PersonalizedProfile(
        spoonKey: j['spoonKey'] as String? ?? '',
        mealCount: (j['mealCount'] as num?)?.toInt() ?? 0,
        avgBitesPerMeal: (j['avgBitesPerMeal'] as num?)?.toDouble() ?? 0,
        avgPaceBpm: (j['avgPaceBpm'] as num?)?.toDouble() ?? 0,
        avgMealMinutes: (j['avgMealMinutes'] as num?)?.toDouble() ?? 0,
        avgTremor: (j['avgTremor'] as num?)?.toDouble() ?? 0,
        paceVar: (j['paceVar'] as num?)?.toDouble() ?? 0,
        updatedAt: DateTime.tryParse(j['updatedAt'] as String? ?? '') ??
            DateTime.now(),
      );
}

class PersonalizedEatingModel extends ChangeNotifier {
  static final PersonalizedEatingModel _instance =
      PersonalizedEatingModel._internal();
  factory PersonalizedEatingModel() => _instance;
  PersonalizedEatingModel._internal();

  static const String _prefsKey = 'personalized_eating_model_v1';

  /// Learning rate for the EWMA. 0.2 ≈ "last ~5 meals dominate", so the model
  /// tracks the person as their habits change instead of freezing on old data.
  static const double _alpha = 0.2;

  final Map<String, PersonalizedProfile> _profiles = {};
  bool _loaded = false;
  bool get isLoaded => _loaded;

  /// Load persisted profiles. Idempotent; call once at startup.
  Future<void> load() async {
    if (_loaded) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsKey);
      if (raw != null && raw.isNotEmpty) {
        final map = jsonDecode(raw) as Map<String, dynamic>;
        for (final entry in map.entries) {
          _profiles[entry.key] =
              PersonalizedProfile.fromJson(entry.value as Map<String, dynamic>);
        }
      }
    } catch (e) {
      debugPrint('[PEM] load error: $e');
    }
    _loaded = true;
    notifyListeners();
  }

  PersonalizedProfile? profileFor(String spoonKey) =>
      spoonKey.isEmpty ? null : _profiles[spoonKey];

  /// Feed one completed meal into the person's model. Online update — the more
  /// meals, the better it knows them; after [learnThreshold] it is "learned".
  Future<void> recordMeal({
    required String spoonKey,
    required int bites,
    required double paceBpm,
    required double durationMinutes,
    required double tremor,
  }) async {
    if (spoonKey.isEmpty || bites <= 0) return; // ignore empty/aborted meals
    final p = _profiles.putIfAbsent(
      spoonKey,
      () => PersonalizedProfile(spoonKey: spoonKey),
    );

    if (p.mealCount == 0) {
      p.avgBitesPerMeal = bites.toDouble();
      p.avgPaceBpm = paceBpm;
      p.avgMealMinutes = durationMinutes;
      p.avgTremor = tremor >= 0 ? tremor : 0; // Issue #9: skip unmeasured
      p.paceVar = 0;
    } else {
      final dPace = paceBpm - p.avgPaceBpm;
      p.avgBitesPerMeal += _alpha * (bites - p.avgBitesPerMeal);
      p.avgPaceBpm += _alpha * dPace;
      p.avgMealMinutes += _alpha * (durationMinutes - p.avgMealMinutes);
      // Issue #9: only update tremor EWMA when actually measured
      if (tremor >= 0) {
        p.avgTremor += _alpha * (tremor - p.avgTremor);
      }
      p.paceVar += _alpha * (dPace * dPace - p.paceVar);
    }
    p.mealCount += 1;
    p.updatedAt = DateTime.now();
    await _persist();
    notifyListeners();
  }

  /// Personalized headline for the Daily Tip / insights. Returns null when there
  /// is no profile yet (caller falls back to a generic tip).
  String? personalizedTip(String spoonKey) {
    final p = profileFor(spoonKey);
    if (p == null || p.mealCount == 0) return null;
    if (!p.isLearned) {
      final left = PersonalizedProfile.learnThreshold - p.mealCount;
      return 'Learning your eating style — $left more meal${left == 1 ? '' : 's'} '
          'until your insights are personalized to you.';
    }
    return 'Personalized for you: your usual pace is '
        '${p.avgPaceBpm.toStringAsFixed(0)} bites/min over about '
        '${p.avgMealMinutes.toStringAsFixed(0)} min a meal. '
        'We now flag meals that drift from your normal.';
  }

  /// Coaching feedback comparing a just-finished meal to the learned baseline,
  /// using the person's OWN pace variability (not a fixed threshold). Null until
  /// the profile is learned.
  String? feedbackForMeal(String spoonKey, {required double paceBpm}) {
    final p = profileFor(spoonKey);
    if (p == null || !p.isLearned) return null;
    final std = p.paceStd < 2.0 ? 2.0 : p.paceStd; // floor to avoid over-flagging
    final z = (paceBpm - p.avgPaceBpm) / std;
    if (z > 1.2) {
      return 'You ate faster than your usual pace today — try setting the spoon '
          'down between bites.';
    }
    if (z < -1.2) {
      return 'Nicely paced — slower than your usual today, which is great for '
          'digestion.';
    }
    return 'Right on your usual eating rhythm today.';
  }

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final map = {for (final e in _profiles.entries) e.key: e.value.toJson()};
      await prefs.setString(_prefsKey, jsonEncode(map));
    } catch (e) {
      debugPrint('[PEM] persist error: $e');
    }
  }
}
