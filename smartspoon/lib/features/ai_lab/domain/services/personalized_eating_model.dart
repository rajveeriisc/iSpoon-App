// personalized_eating_model.dart — per-person adaptive eating model.
//
// The bite model in assets/models is a POPULATION model: one set of weights
// trained on 8 people. This is the complementary piece — an on-device model
// that learns EACH PERSON'S own eating habits and judges a meal against their
// normal rather than against a fixed rule.
//
// HOW IT LEARNS (online, on-device, no server):
//   • Keyed by the stable per-spoon key, so each family member gets their own
//     profile.
//   • Every completed meal updates EWMA statistics — pace, duration, bites,
//     steadiness baseline — so recent behaviour weighs more and the model
//     keeps tracking the person as they change.
//   • Pace is also tracked PER MEAL TYPE, because breakfast and dinner are
//     not the same meal. A meal type with few samples is pulled toward the
//     person's overall mean (shrinkage), so a new meal type is never judged
//     off one or two readings.
//   • It tracks the spread of pace, so "unusual for you" is measured in the
//     person's own variability rather than a fixed number of bites/min.
//
// Four things this version fixes, all of which made it either wrong or silent:
//
//   1. feedbackForMeal was never called from anywhere. The personalised
//      coaching existed but never reached a screen.
//   2. It needed 20 meals before saying anything personal. With EWMA at
//      alpha 0.2 the mean has absorbed most of its weight long before that,
//      so the wait was far longer than the statistics required.
//   3. One bad meal moved the baseline by a full alpha. A 3-second "meal"
//      with 2 bites, or a glitched pace, was folded in at full weight.
//   4. Variance started at zero, so the second and third meals were compared
//      against a spread of nothing and flagged as unusual.
//
// Persisted per profile in SharedPreferences; survives restarts.
import 'dart:convert';
import 'dart:math' as math;

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Running pace statistics for one meal type (breakfast, lunch, ...).
class MealTypeStats {
  MealTypeStats({this.n = 0, this.meanPace = 0});

  int n;
  double meanPace;

  Map<String, dynamic> toJson() => {'n': n, 'meanPace': meanPace};

  factory MealTypeStats.fromJson(Map<String, dynamic> j) => MealTypeStats(
        n: (j['n'] as num?)?.toInt() ?? 0,
        meanPace: (j['meanPace'] as num?)?.toDouble() ?? 0,
      );
}

/// One person's learned eating profile (keyed by the stable spoon key).
class PersonalizedProfile {
  PersonalizedProfile({
    required this.spoonKey,
    this.mealCount = 0,
    this.avgBitesPerMeal = 0,
    this.avgPaceBpm = 0,
    this.avgMealMinutes = 0,
    this.avgTremor = 0,
    this.paceVar = 0,
    this.paceUpdates = 0,
    this.outlierStreak = 0,
    this.distinctDays = 0,
    this.lastDayKey = '',
    this.lastJudgedMealUuid,
    this.lastZ,
    this.lastBaselinePace,
    this.lastObservedPace,
    Map<String, MealTypeStats>? byMealType,
    DateTime? updatedAt,
  })  : byMealType = byMealType ?? {},
        updatedAt = updatedAt ?? DateTime.now();

  final String spoonKey;
  int mealCount;
  double avgBitesPerMeal; // EWMA
  double avgPaceBpm; // EWMA (bites / minute)
  double avgMealMinutes; // EWMA
  double avgTremor; // EWMA (0–3)
  double paceVar; // EWMA of squared pace deviation

  /// How many deviations have been folded into [paceVar]. The first meal
  /// contributes none, so this is always one behind [mealCount] at best, and
  /// it is what decides whether the spread is worth trusting yet.
  int paceUpdates;

  /// Consecutive readings judged to be bad. Reset by any ordinary meal.
  int outlierStreak;

  /// Calendar days (local) on which a meal was learned from, and the last
  /// such day, which is all that is needed to count them as meals arrive.
  int distinctDays;
  String lastDayKey;

  /// How the most recent meal compared with the baseline AS IT STOOD BEFORE
  /// that meal was folded in, and which meal that was.
  ///
  /// Judging a meal after recordMeal has run compares it with a baseline that
  /// already contains it: the mean has moved toward it and the spread has
  /// widened because of it. Measured, with a true sd of 2 bites/min:
  ///
  ///     meal #7    true z 4.0  ->  reads 1.93   (limit is 2.0: not flagged)
  ///     meal #10   true z 3.0  ->  reads 2.01
  ///     meal #20   true z 2.5  ->  reads 2.05
  ///
  /// so early on, when the weights are largest, even a meal four standard
  /// deviations out was reported as "on your usual rhythm". The verdict is
  /// therefore taken once, before the update, and kept here.
  String? lastJudgedMealUuid;
  double? lastZ;
  double? lastBaselinePace;
  double? lastObservedPace;

  final Map<String, MealTypeStats> byMealType;
  DateTime updatedAt;

  /// Meals before the profile is treated as fully settled. Used for the
  /// progress indicator only — coaching unlocks on [canPersonalize], which
  /// is a statistical test, not a countdown.
  static const int learnThreshold = 20;

  /// Fewest meals before any personal judgement is offered.
  ///
  /// An EWMA with weight a has absorbed 1-(1-a)^n of its asymptotic value
  /// after n samples: at a=0.2 that is 74% by meal 6. Waiting for 20 meals
  /// held back a usable estimate for about three weeks of normal use.
  /// Validated by simulation in test/ai_lab/personalized_model_accuracy_test.
  static const int minMealsToPersonalize = 6;

  /// Fewest distinct days the meals must come from.
  ///
  /// A meal count alone is satisfied by one afternoon of trying the spoon —
  /// the eight labelled sessions this model was tuned on were all recorded
  /// inside twenty minutes — and six back-to-back demonstrations are not a
  /// record of how someone eats. Three is a product rule, not a measured
  /// threshold: it is the smallest number that cannot be met in a weekend
  /// sitting and still unlocks within the first week of real use.
  static const int minDaysToPersonalize = 3;

  /// Deviations needed before the spread is trusted.
  static const int minPaceUpdatesForBand = 4;

  double get paceStd => paceVar <= 0 ? 0 : math.sqrt(paceVar);

  /// True once there is enough history AND enough spread to judge a meal.
  bool get canPersonalize =>
      mealCount >= minMealsToPersonalize &&
      distinctDays >= minDaysToPersonalize &&
      paceUpdates >= minPaceUpdatesForBand &&
      avgPaceBpm > 0;

  /// The stored pre-update verdict for whichever meal was recorded last.
  MealJudgement? get lastJudgement => judgementFor(lastJudgedMealUuid) ??
      (lastJudgedMealUuid == null && lastZ != null
          ? MealJudgement(
              verdict: lastZ! > PersonalizedEatingModel.zFlag
                  ? PaceVerdict.faster
                  : lastZ! < -PersonalizedEatingModel.zFlag
                      ? PaceVerdict.slower
                      : PaceVerdict.usual,
              z: lastZ!,
              baselinePace: lastBaselinePace ?? 0,
              observedPace: lastObservedPace ?? 0,
            )
          : null);

  /// The stored pre-update verdict for [mealUuid], or null when the latest
  /// judged meal is a different one (or predates this field).
  MealJudgement? judgementFor(String? mealUuid) {
    final z = lastZ, base = lastBaselinePace, obs = lastObservedPace;
    if (mealUuid == null || mealUuid != lastJudgedMealUuid) return null;
    if (z == null || base == null || obs == null) return null;
    return MealJudgement(
      verdict: z > PersonalizedEatingModel.zFlag
          ? PaceVerdict.faster
          : z < -PersonalizedEatingModel.zFlag
              ? PaceVerdict.slower
              : PaceVerdict.usual,
      z: z,
      baselinePace: base,
      observedPace: obs,
    );
  }

  /// Kept for the existing progress UI.
  bool get isLearned => mealCount >= learnThreshold;

  double get progress => (mealCount / learnThreshold).clamp(0.0, 1.0);

  /// How much of a personal baseline there is, 0..1.
  ///
  /// An EWMA cannot keep accumulating certainty forever — it deliberately
  /// forgets, so its effective sample size saturates at (2-a)/a, which is 9
  /// meals at a=0.2. Reporting raw meal count as confidence would keep
  /// climbing past the point where the estimate actually improves.
  double get confidence {
    if (mealCount == 0) return 0;
    final effective = math.min(
      mealCount.toDouble(),
      PersonalizedEatingModel.effectiveSampleSize,
    );
    return (effective / PersonalizedEatingModel.effectiveSampleSize)
        .clamp(0.0, 1.0);
  }

  /// This person's expected pace for [mealType], in bites/min.
  ///
  /// A meal type seen only once or twice is pulled toward the person's
  /// overall pace, so a brand-new meal type is never judged off a single
  /// reading. As samples accumulate the blend moves to that meal type's own
  /// mean. Standard partial pooling; the prior weight k is in units of meals.
  double baselinePaceFor(String? mealType) {
    final global = avgPaceBpm;
    if (mealType == null || mealType.isEmpty) return global;
    final s = byMealType[mealType];
    if (s == null || s.n == 0) return global;
    const k = PersonalizedEatingModel.mealTypePriorMeals;
    return (s.n * s.meanPace + k * global) / (s.n + k);
  }

  Map<String, dynamic> toJson() => {
        'spoonKey': spoonKey,
        'mealCount': mealCount,
        'avgBitesPerMeal': avgBitesPerMeal,
        'avgPaceBpm': avgPaceBpm,
        'avgMealMinutes': avgMealMinutes,
        'avgTremor': avgTremor,
        'paceVar': paceVar,
        'paceUpdates': paceUpdates,
        'outlierStreak': outlierStreak,
        'distinctDays': distinctDays,
        'lastDayKey': lastDayKey,
        'lastJudgedMealUuid': lastJudgedMealUuid,
        'lastZ': lastZ,
        'lastBaselinePace': lastBaselinePace,
        'lastObservedPace': lastObservedPace,
        'byMealType': {
          for (final e in byMealType.entries) e.key: e.value.toJson(),
        },
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
        // Older profiles predate this counter. Assume the deviations that the
        // meal count implies, so an existing user is not reset to "learning".
        paceUpdates: (j['paceUpdates'] as num?)?.toInt() ??
            math.max(0, ((j['mealCount'] as num?)?.toInt() ?? 0) - 1),
        outlierStreak: (j['outlierStreak'] as num?)?.toInt() ?? 0,
        // Profiles saved before days were counted: credit one day per meal up
        // to the requirement, for the same reason paceUpdates is inferred
        // above — someone already personalised must not be sent back to
        // "learning" by an update.
        distinctDays: (j['distinctDays'] as num?)?.toInt() ??
            math.min(((j['mealCount'] as num?)?.toInt() ?? 0),
                minDaysToPersonalize),
        lastDayKey: j['lastDayKey'] as String? ?? '',
        lastJudgedMealUuid: j['lastJudgedMealUuid'] as String?,
        lastZ: (j['lastZ'] as num?)?.toDouble(),
        lastBaselinePace: (j['lastBaselinePace'] as num?)?.toDouble(),
        lastObservedPace: (j['lastObservedPace'] as num?)?.toDouble(),
        byMealType: {
          for (final e in ((j['byMealType'] as Map?) ?? const {}).entries)
            e.key as String:
                MealTypeStats.fromJson((e.value as Map).cast<String, dynamic>()),
        },
        updatedAt:
            DateTime.tryParse(j['updatedAt'] as String? ?? '') ?? DateTime.now(),
      );
}

/// How a just-finished meal compares with this person's normal.
enum PaceVerdict { faster, slower, usual }

class MealJudgement {
  const MealJudgement({
    required this.verdict,
    required this.z,
    required this.baselinePace,
    required this.observedPace,
  });

  final PaceVerdict verdict;

  /// Deviation from this person's baseline, in their own standard deviations.
  final double z;
  final double baselinePace;
  final double observedPace;
}

class PersonalizedEatingModel extends ChangeNotifier {
  static final PersonalizedEatingModel _instance =
      PersonalizedEatingModel._internal();
  factory PersonalizedEatingModel() => _instance;
  PersonalizedEatingModel._internal();

  static const String _prefsKey = 'personalized_eating_model_v1';

  /// Who the profiles belong to. Overridable so tests need no Firebase.
  static String Function() userIdProvider = _signedInUserId;

  static String _signedInUserId() {
    try {
      return FirebaseAuth.instance.currentUser?.uid ?? '';
    } catch (_) {
      return ''; // Firebase not initialised (tests, very early startup).
    }
  }

  /// Profiles used to live under one key for the whole phone, keyed inside
  /// only by spoon. Two accounts on one phone using the same spoon therefore
  /// shared a single baseline, and signing in as someone else inherited the
  /// previous person's "usual pace". Each account now has its own key.
  static String _keyFor(String uid) => uid.isEmpty ? _prefsKey : '$_prefsKey:$uid';

  /// EWMA weight. 0.2 ≈ "the last ~5 meals dominate", so the model tracks the
  /// person as their habits change instead of freezing on old data.
  static const double alpha = 0.2;

  /// Effective sample size an EWMA converges to: (2-a)/a. At a=0.2 that is 9.
  static const double effectiveSampleSize = (2 - alpha) / alpha;

  /// Separate, slower weight for the SPREAD.
  ///
  /// The mean should chase the person — habits change, and alpha=0.2 keeps it
  /// current. The spread must not, because it is the denominator of every
  /// judgement: at alpha=0.2 its effective sample size is 9, giving the
  /// standard deviation about 25% error, and it was measured swinging
  /// 1.25 -> 1.90 -> 2.17 -> 1.41 on a stationary eater. That swing lands
  /// directly on the false-alarm rate. At 0.05 the effective sample size is
  /// 39 and the error falls to about 11%.
  static const double alphaVar = 0.05;

  /// Floor for the pace baseline's weight, i.e. how fast it is allowed to
  /// forget once it has enough history. 0.08 keeps an effective window of
  /// about 24 meals.
  static const double alphaPace = 0.08;

  /// The weight actually used for a baseline on its [n]th sample.
  ///
  /// 1/n for the first meals, which is exactly a running average: unbiased,
  /// with standard error sigma/sqrt(n), and with no dependence on whatever
  /// the first meal happened to be. It decays into a constant-weight EWMA as
  /// soon as 1/n falls below the floor, so the baseline still forgets.
  ///
  /// A fixed weight was measured doing badly on both counts. At 0.2 the
  /// baseline tracked only the last ~5 meals, and for 3 users in 60 it sat
  /// far enough off that a third of their ordinary meals were reported as
  /// "faster than usual". Simply lowering the weight did not help, because
  /// after 40 meals a 0.05 EWMA still carries 13% of the very first meal.
  static double baselineWeight(double floor, int n) =>
      math.max(floor, 1.0 / math.max(1, n));

  /// Prior weight, in meals, pulling a meal type toward the overall mean.
  static const double mealTypePriorMeals = 3.0;

  /// Deviation, in the person's own standard deviations, before a meal is
  /// called unusual.
  ///
  /// Chosen by simulating 60 eaters, because the average case was not the
  /// problem — the unlucky tail was. Both the baseline and the spread are
  /// estimated from roughly 40 meals, and when both happen to err the same
  /// way that user is flagged on a large share of perfectly ordinary meals:
  ///
  ///   z    mean   worst user   users over 20%   catches a +50% meal
  ///   1.5  7.2%   30.5%        4 / 60           62%
  ///   1.8  4.2%   22.0%        1 / 60           50%
  ///   2.0  2.9%   16.5%        0 / 60           43%
  ///   2.3  1.6%   12.5%        0 / 60           32%
  ///
  /// 2.0 is the first value where nobody is nagged on more than a fifth of
  /// their meals. The two errors are not equally costly: a false "you ate too
  /// fast" is wrong about the person and erodes trust in everything else on
  /// the page, while a missed one only means no tip that meal.
  static const double zFlag = 2.0;

  /// Least spread used when judging, in bites/min.
  ///
  /// Someone extremely consistent would otherwise get a standard deviation
  /// near zero, and every ordinary meal would read as a large deviation.
  static const double paceStdFloor = 2.0;

  /// Rejected outright — not a meal, or not a believable measurement.
  static const int minPlausibleBites = 3;
  static const double minPlausibleMinutes = 0.5;
  static const double maxPlausiblePaceBpm = 120.0;

  /// How far out a meal must be, in the person's own standard deviations,
  /// before it is treated as a bad reading rather than a real meal.
  ///
  /// Set to 4, where genuine variation essentially never lands (about 6 in
  /// 100,000 of a normal distribution), while the glitch this exists to stop
  /// — a 90 bites/min reading from someone who eats at 15 — sits around 19.
  static const double outlierZ = 4.0;

  /// Deviations needed before outlier handling switches on at all.
  ///
  /// This is not caution for its own sake. The first attempt clamped every
  /// meal to mean +/- 3 std from the start, and the early std estimate is
  /// tight, so the window was narrow: high draws were clipped far more often
  /// than low ones, which pulled the mean down, which moved the window down,
  /// which clipped more. On a simulated eater with a true mean of 15 the
  /// baseline ran away to 11.5, and 36% of ordinary meals were then reported
  /// as "faster than usual".
  static const int minUpdatesForOutlierCheck = 10;

  /// Consecutive outliers after which the model accepts that this is not a
  /// glitch but a real change in how the person eats, and follows them.
  static const int outliersBeforeAccepting = 3;

  final Map<String, PersonalizedProfile> _profiles = {};
  bool _loaded = false;
  bool get isLoaded => _loaded;

  /// Which meal a given hour belongs to.
  ///
  /// Shared so the per-meal-type baselines are keyed the same way the meals
  /// themselves are labelled — if these two ever disagreed, a meal would be
  /// judged against the baseline of a different meal type.
  static String mealTypeForHour(int hour) {
    if (hour < 11) return 'Breakfast';
    if (hour < 15) return 'Lunch';
    if (hour < 18) return 'Snack';
    return 'Dinner';
  }

  /// Load persisted profiles. Idempotent; call once at startup.
  Future<void> load() async {
    if (_loaded) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final uid = userIdProvider();
      var raw = prefs.getString(_keyFor(uid));
      if (raw == null && uid.isNotEmpty) {
        // First load for this account since profiles became per-user: the
        // shared copy is theirs if anyone's, so adopt it — and REMOVE it, or
        // the next account to sign in on this phone would adopt it too.
        raw = prefs.getString(_prefsKey);
        if (raw != null) {
          await prefs.setString(_keyFor(uid), raw);
          await prefs.remove(_prefsKey);
        }
      }
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

  /// Drop the previous account's profiles and load the current one's.
  Future<void> reloadForUser() async {
    _profiles.clear();
    _loaded = false;
    await load();
  }

  PersonalizedProfile? profileFor(String spoonKey) =>
      spoonKey.isEmpty ? null : _profiles[spoonKey];

  /// True when the meal is believable enough to learn from.
  ///
  /// The old guard was `bites <= 0`, which let a 3-second session with two
  /// bites set the baseline at a wild pace, and every later meal was then
  /// judged against it.
  static bool isPlausibleMeal({
    required int bites,
    required double paceBpm,
    required double durationMinutes,
  }) =>
      bites >= minPlausibleBites &&
      durationMinutes >= minPlausibleMinutes &&
      paceBpm > 0 &&
      paceBpm <= maxPlausiblePaceBpm &&
      paceBpm.isFinite &&
      durationMinutes.isFinite;

  /// Feed one completed meal into the person's model.
  Future<void> recordMeal({
    required String spoonKey,
    required int bites,
    required double paceBpm,
    required double durationMinutes,
    required double tremor,
    String? mealType,
    String? mealUuid,
    DateTime? at,
  }) async {
    if (spoonKey.isEmpty) return;
    if (!isPlausibleMeal(
      bites: bites,
      paceBpm: paceBpm,
      durationMinutes: durationMinutes,
    )) {
      return;
    }

    final p = _profiles.putIfAbsent(
      spoonKey,
      () => PersonalizedProfile(spoonKey: spoonKey),
    );

    // Verdict first, against the baseline as it stands. Everything below
    // moves that baseline toward this meal; see lastZ for what that cost.
    final verdict = judgeMeal(spoonKey, paceBpm: paceBpm, mealType: mealType);
    p.lastJudgedMealUuid = mealUuid;
    p.lastZ = verdict?.z;
    p.lastBaselinePace = verdict?.baselinePace;
    p.lastObservedPace = verdict?.observedPace;

    final when = at ?? DateTime.now();
    final dayKey = '${when.year}-${when.month}-${when.day}';
    if (dayKey != p.lastDayKey) {
      p.distinctDays += 1;
      p.lastDayKey = dayKey;
    }

    if (p.mealCount == 0) {
      p.avgBitesPerMeal = bites.toDouble();
      p.avgPaceBpm = paceBpm;
      p.avgMealMinutes = durationMinutes;
      p.avgTremor = tremor >= 0 ? tremor : 0; // -1 means not measured
      p.paceVar = 0;
    } else {
      // Decide whether this meal is evidence about the person or a bad
      // reading. An EWMA gives every sample weight alpha, so one wild value
      // moves the baseline by a fifth of the way to itself.
      //
      // Outliers are SKIPPED, not clamped. Clamping parks the value on the
      // edge of the window, which still drags the mean and, because the
      // window follows the mean, feeds back on itself.
      final n = p.mealCount + 1; // this meal's ordinal
      final aPace = baselineWeight(alphaPace, n);
      final aVar = baselineWeight(alphaVar, n);
      final std = math.max(p.paceStd, paceStdFloor);
      final checking = p.paceUpdates >= minUpdatesForOutlierCheck;
      final isOutlier =
          checking && (paceBpm - p.avgPaceBpm).abs() > outlierZ * std;

      // ...unless it keeps happening, in which case the person has genuinely
      // changed and the model should follow rather than ignore them.
      final ignore = isOutlier && p.outlierStreak < outliersBeforeAccepting - 1;
      p.outlierStreak = isOutlier ? p.outlierStreak + 1 : 0;

      final dPace = paceBpm - p.avgPaceBpm;

      // Spread is measured from the RAW deviation against the mean as it was
      // BEFORE this meal moved it. Taking it afterwards shrinks every
      // deviation by exactly (1-alpha), which understates the standard
      // deviation by ~20% at alpha=0.2 — measured at 1.6 against a true 2.0,
      // 3.2 against 4.0, 5.6 against 7.0. Since the spread is the denominator
      // of the z-score, that inflated every judgement and pushed the
      // false-alarm rate to 23% where the distribution predicts 13%.
      //
      // The deviation is also taken from the unwinsorised pace: an unusual
      // meal is evidence that this person is variable, even when its pull on
      // the mean is capped.
      final rawD = dPace;

      if (!ignore) {
        p.avgBitesPerMeal += alpha * (bites - p.avgBitesPerMeal);
        p.avgPaceBpm += aPace * dPace;
        p.avgMealMinutes += alpha * (durationMinutes - p.avgMealMinutes);
        if (tremor >= 0) {
          p.avgTremor += alpha * (tremor - p.avgTremor);
        }
      }
      // Seed from the first few deviations rather than crawling up from zero
      // at alphaVar, which would leave the band far too tight early on —
      // exactly when there is least reason to trust it.
      p.paceVar += aVar * (rawD * rawD - p.paceVar);
      p.paceUpdates += 1;
    }

    if (mealType != null && mealType.isNotEmpty) {
      final s = p.byMealType.putIfAbsent(mealType, () => MealTypeStats());
      if (s.n == 0) {
        s.meanPace = paceBpm;
      } else {
        s.meanPace += alpha * (paceBpm - s.meanPace);
      }
      s.n += 1;
    }

    p.mealCount += 1;
    p.updatedAt = DateTime.now();
    await _persist();
    notifyListeners();
  }

  /// Where a meal sits against this person's normal, or null when there is
  /// not yet enough history to say.
  MealJudgement? judgeMeal(
    String spoonKey, {
    required double paceBpm,
    String? mealType,
  }) {
    final p = profileFor(spoonKey);
    if (p == null || !p.canPersonalize) return null;
    if (!paceBpm.isFinite || paceBpm <= 0) return null;

    final baseline = p.baselinePaceFor(mealType);
    final std = math.max(p.paceStd, paceStdFloor);
    final z = (paceBpm - baseline) / std;

    final verdict = z > zFlag
        ? PaceVerdict.faster
        : z < -zFlag
            ? PaceVerdict.slower
            : PaceVerdict.usual;

    return MealJudgement(
      verdict: verdict,
      z: z,
      baselinePace: baseline,
      observedPace: paceBpm,
    );
  }

  /// Personalized headline for the Daily Tip / insights. Null when there is no
  /// profile yet (caller falls back to a generic tip).
  String? personalizedTip(String spoonKey) {
    final p = profileFor(spoonKey);
    if (p == null || p.mealCount == 0) return null;
    if (!p.canPersonalize) {
      final left = PersonalizedProfile.minMealsToPersonalize - p.mealCount;
      if (left > 0) {
        return 'Learning your eating style — $left more meal${left == 1 ? '' : 's'} '
            'until your insights are personalized to you.';
      }
      final daysLeft =
          PersonalizedProfile.minDaysToPersonalize - p.distinctDays;
      if (daysLeft > 0) {
        return 'Learning your eating style — meals on $daysLeft more '
            'day${daysLeft == 1 ? '' : 's'} and your insights will be '
            'personalized to you.';
      }
      return 'Learning your eating style — a couple more meals and your '
          'insights will be personalized to you.';
    }
    return 'Personalized for you: your usual pace is '
        '${p.avgPaceBpm.toStringAsFixed(0)} bites/min over about '
        '${p.avgMealMinutes.toStringAsFixed(0)} min a meal. '
        'We now flag meals that drift from your normal.';
  }

  /// Coaching line comparing a just-finished meal to the learned baseline.
  /// Null until there is enough history.
  String? feedbackForMeal(
    String spoonKey, {
    required double paceBpm,
    String? mealType,
  }) {
    final j = judgeMeal(spoonKey, paceBpm: paceBpm, mealType: mealType);
    if (j == null) return null;
    switch (j.verdict) {
      case PaceVerdict.faster:
        return 'You ate faster than your usual pace today — try setting the '
            'spoon down between bites.';
      case PaceVerdict.slower:
        return 'Slower than your usual pace today.';
      case PaceVerdict.usual:
        return 'Right on your usual eating rhythm today.';
    }
  }

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final map = {for (final e in _profiles.entries) e.key: e.value.toJson()};
      await prefs.setString(_keyFor(userIdProvider()), jsonEncode(map));
    } catch (e) {
      debugPrint('[PEM] persist error: $e');
    }
  }

  /// Test seam: drop in-memory state so a test starts from nothing.
  @visibleForTesting
  void resetForTest() {
    _profiles.clear();
    _loaded = false;
  }
}
