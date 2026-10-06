// ai_lab_profile_store.dart — what AI Lab has learned about each person.
//
// Keyed by the stable spoon key (spoon = person). Kept apart from
// PersonalizedEatingModel on purpose: that one is fed by the firmware bite
// counter and shown on Home; this one is fed only by the AI Lab model and
// shown only in AI Lab, so neither double-counts the other's meals.
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:smartspoon/features/ai_lab/domain/engine/handedness.dart';
import 'package:smartspoon/features/ai_lab/domain/insights/eating_insights.dart';

double? _d(Object? v) => (v as num?)?.toDouble();

class MealSummary {
  const MealSummary({
    required this.start,
    required this.bites,
    required this.durationMin,
    this.meanGapSec,
    this.gapCv,
    this.speedChange,
    this.steadyPct,
    this.rhythmHz,
  });

  factory MealSummary.fromMetrics(DateTime start, MealMetrics m) => MealSummary(
        start: start,
        bites: m.bites,
        durationMin: m.duration.inMilliseconds / 60000.0,
        meanGapSec: m.meanGapSec,
        gapCv: m.gapCv,
        speedChange: m.speedChange,
        steadyPct: m.steadyPct,
        rhythmHz: m.rhythmHz,
      );

  factory MealSummary.fromJson(Map<String, dynamic> j) => MealSummary(
        start: DateTime.tryParse(j['start'] as String? ?? '') ??
            DateTime.fromMillisecondsSinceEpoch(0),
        bites: (j['bites'] as num?)?.toInt() ?? 0,
        durationMin: _d(j['durationMin']) ?? 0,
        meanGapSec: _d(j['meanGapSec']),
        gapCv: _d(j['gapCv']),
        speedChange: _d(j['speedChange']),
        steadyPct: _d(j['steadyPct']),
        rhythmHz: _d(j['rhythmHz']),
      );

  final DateTime start;
  final int bites;
  final double durationMin;
  final double? meanGapSec;
  final double? gapCv;
  final double? speedChange;
  final double? steadyPct;
  final double? rhythmHz;

  Map<String, dynamic> toJson() => {
        'start': start.toIso8601String(),
        'bites': bites,
        'durationMin': durationMin,
        'meanGapSec': meanGapSec,
        'gapCv': gapCv,
        'speedChange': speedChange,
        'steadyPct': steadyPct,
        'rhythmHz': rhythmHz,
      };
}

class AiLabProfile {
  AiLabProfile({
    required this.spoonKey,
    this.mealCount = 0,
    this.avgGapSec,
    this.avgGapCv,
    this.avgBites,
    this.avgDurationMin,
    this.avgSteadyPct,
    this.handPreference = HandPreference.auto,
    this.detectedHand,
    List<MealSummary>? recent,
  }) : recent = recent ?? [];

  factory AiLabProfile.fromJson(Map<String, dynamic> j) => AiLabProfile(
        spoonKey: j['spoonKey'] as String? ?? '',
        mealCount: (j['mealCount'] as num?)?.toInt() ?? 0,
        avgGapSec: _d(j['avgGapSec']),
        avgGapCv: _d(j['avgGapCv']),
        avgBites: _d(j['avgBites']),
        avgDurationMin: _d(j['avgDurationMin']),
        avgSteadyPct: _d(j['avgSteadyPct']),
        handPreference: HandPreference.values.firstWhere(
            (h) => h.name == j['handPreference'],
            orElse: () => HandPreference.auto),
        detectedHand: Hand.values
            .where((h) => h.name == j['detectedHand'])
            .firstOrNull,
        recent: [
          for (final m in (j['recent'] as List?) ?? const [])
            MealSummary.fromJson(m as Map<String, dynamic>),
        ],
      );

  final String spoonKey;
  int mealCount;
  double? avgGapSec;
  double? avgGapCv;
  double? avgBites;
  double? avgDurationMin;
  double? avgSteadyPct;
  HandPreference handPreference;
  Hand? detectedHand;

  /// Newest first, at most [AiLabProfileStore.maxRecent].
  final List<MealSummary> recent;

  PersonalBaseline get baseline => PersonalBaseline(
        meals: mealCount,
        avgGapSec: avgGapSec,
        avgGapCv: avgGapCv,
        avgBites: avgBites,
        avgDurationMin: avgDurationMin,
        avgSteadyPct: avgSteadyPct,
        recentSteadyPct: [for (final m in recent) m.steadyPct],
      );

  Map<String, dynamic> toJson() => {
        'spoonKey': spoonKey,
        'mealCount': mealCount,
        'avgGapSec': avgGapSec,
        'avgGapCv': avgGapCv,
        'avgBites': avgBites,
        'avgDurationMin': avgDurationMin,
        'avgSteadyPct': avgSteadyPct,
        'handPreference': handPreference.name,
        'detectedHand': detectedHand?.name,
        'recent': [for (final m in recent) m.toJson()],
      };
}

class AiLabProfileStore extends ChangeNotifier {
  static const String prefsKey = 'ai_lab_profile_v1';
  static const int maxRecent = 20;

  /// EWMA learning rate: the last ~5 meals dominate, so the profile follows
  /// the person as their habits change.
  static const double alpha = 0.2;

  final Map<String, AiLabProfile> _profiles = {};
  bool _loaded = false;
  bool get isLoaded => _loaded;

  Future<void> load() async {
    if (_loaded) return;
    try {
      final raw = (await SharedPreferences.getInstance()).getString(prefsKey);
      if (raw != null && raw.isNotEmpty) {
        final map = jsonDecode(raw) as Map<String, dynamic>;
        for (final e in map.entries) {
          _profiles[e.key] =
              AiLabProfile.fromJson(e.value as Map<String, dynamic>);
        }
      }
    } catch (e) {
      debugPrint('[AiLabProfileStore] load error: $e');
    }
    _loaded = true;
    notifyListeners();
  }

  /// The profile for [spoonKey]; an empty one when nothing is known yet.
  AiLabProfile profileFor(String spoonKey) =>
      _profiles[spoonKey] ?? AiLabProfile(spoonKey: spoonKey);

  AiLabProfile _mutable(String spoonKey) =>
      _profiles.putIfAbsent(spoonKey, () => AiLabProfile(spoonKey: spoonKey));

  static double? _ewma(double? avg, double? value) {
    if (value == null) return avg;
    if (avg == null) return value;
    return avg + alpha * (value - avg);
  }

  Future<void> recordMeal(String spoonKey, MealSummary meal) async {
    if (spoonKey.isEmpty) return;
    final p = _mutable(spoonKey);
    p.avgGapSec = _ewma(p.avgGapSec, meal.meanGapSec);
    p.avgGapCv = _ewma(p.avgGapCv, meal.gapCv);
    p.avgBites = _ewma(p.avgBites, meal.bites.toDouble());
    p.avgDurationMin = _ewma(p.avgDurationMin, meal.durationMin);
    p.avgSteadyPct = _ewma(p.avgSteadyPct, meal.steadyPct);
    p.mealCount++;
    p.recent.insert(0, meal);
    if (p.recent.length > maxRecent) p.recent.removeRange(maxRecent, p.recent.length);
    await _persist();
    notifyListeners();
  }

  Future<void> setHandPreference(String spoonKey, HandPreference pref) async {
    if (spoonKey.isEmpty) return;
    _mutable(spoonKey).handPreference = pref;
    await _persist();
    notifyListeners();
  }

  Future<void> setDetectedHand(String spoonKey, Hand? hand) async {
    if (spoonKey.isEmpty) return;
    _mutable(spoonKey).detectedHand = hand;
    await _persist();
    notifyListeners();
  }

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(prefsKey,
          jsonEncode({for (final e in _profiles.entries) e.key: e.value.toJson()}));
    } catch (e) {
      debugPrint('[AiLabProfileStore] persist error: $e');
    }
  }
}
