// Pure helpers for meal-session identity and today's live overlay.
// Kept out of UnifiedDataService so they can be unit-tested without BLE/Firebase.

String? pinSessionDeviceId(String? deviceId) {
  if (deviceId == null) return null;
  final trimmed = deviceId.trim();
  if (trimmed.isEmpty) return null;
  return trimmed;
}

/// Meals are keyed by Firebase UID. The backend JWT `id` is a numeric Postgres
/// id — writing it orphans the row from every Firebase-scoped query.
String mealWriteUserId(String? firebaseUid) {
  final uid = firebaseUid?.trim();
  if (uid == null || uid.isEmpty) return 'offline_user';
  if (RegExp(r'^\d+$').hasMatch(uid)) return 'offline_user';
  return uid;
}

class TodayBiteBuckets {
  const TodayBiteBuckets({
    required this.breakfast,
    required this.lunch,
    required this.dinner,
    required this.snack,
  });

  final int breakfast;
  final int lunch;
  final int dinner;
  final int snack;

  int get total => breakfast + lunch + dinner + snack;

  TodayBiteBuckets overlaySession({
    required String mealType,
    required int sessionBites,
  }) {
    switch (mealType) {
      case 'Breakfast':
        return TodayBiteBuckets(
          breakfast: breakfast + sessionBites,
          lunch: lunch,
          dinner: dinner,
          snack: snack,
        );
      case 'Lunch':
        return TodayBiteBuckets(
          breakfast: breakfast,
          lunch: lunch + sessionBites,
          dinner: dinner,
          snack: snack,
        );
      case 'Snack':
        return TodayBiteBuckets(
          breakfast: breakfast,
          lunch: lunch,
          dinner: dinner,
          snack: snack + sessionBites,
        );
      default:
        return TodayBiteBuckets(
          breakfast: breakfast,
          lunch: lunch,
          dinner: dinner + sessionBites,
          snack: snack,
        );
    }
  }
}

/// Monotonic catch-up after a background event-char gap should be counted.
/// A firmware reset that drops the counter is handled by `newBites <= 0`.
bool shouldCountHardwareDelta(int newBites) => newBites > 0;

/// What the 1 s tick should do with the AI Lab bite total.
enum BiteTickAction {
  /// No sensor data yet. A real zero and "nothing connected" must not be
  /// confused, or the anchor is burned against a count that never happened.
  waitForData,

  /// First reading of this session: remember it, count nothing.
  baseline,

  /// The total went backwards, which only happens when the app restarted and
  /// the model began at zero again. Re-anchor, count nothing. Without this the
  /// anchor stays above every future total and counting stops for good.
  rebaseline,

  /// Same total as last tick.
  ignore,

  /// New bites to record.
  count,
}

class BiteTickDecision {
  const BiteTickDecision(this.action, {this.newBites = 0, this.anchor = 0});

  final BiteTickAction action;

  /// Bites to write, for [BiteTickAction.count].
  final int newBites;

  /// The value the session anchor should hold after this tick.
  final int anchor;
}

/// Decides what one tick does, given the model's running bite total ([total],
/// null before any sensor data), the session [anchor] and whether this session
/// has seen a reading yet.
BiteTickDecision decideBiteTick({
  required int? total,
  required int anchor,
  required bool initialized,
}) {
  if (total == null) return const BiteTickDecision(BiteTickAction.waitForData);
  if (!initialized) {
    return BiteTickDecision(BiteTickAction.baseline, anchor: total);
  }
  if (total < anchor) {
    return BiteTickDecision(BiteTickAction.rebaseline, anchor: total);
  }
  if (total == anchor) {
    return BiteTickDecision(BiteTickAction.ignore, anchor: anchor);
  }
  return BiteTickDecision(BiteTickAction.count,
      newBites: total - anchor, anchor: total);
}
