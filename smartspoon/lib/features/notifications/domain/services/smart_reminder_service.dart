// smart_reminder_service.dart — context-aware scheduled meal/health reminders.
//
// A singleton that schedules timezone-aware local reminders (e.g. mealtime
// nudges) using flutter_local_notifications' zonedSchedule, reserving
// notification IDs 800–849. Started from AppSetupService; keeps reminders
// firing on schedule even when the app isn't running.
//
// zonedSchedule fires later, via the OS, outside the Dart process — there is
// no hook to re-check a preference at fire time the way an immediate
// notification can. So respecting a toggle here means cancelling/rescheduling
// the affected alarms whenever the preference changes (applyPreferences,
// called by NotificationProvider after every fetch/update), not a runtime
// gate. Without this, per-category toggles and the weekly-digest day/time —
// stored and editable in Settings — had no effect on these OS-level alarms at
// all: breakfast/afternoon/evening nudges kept firing after "Reminders" was
// turned off, and the weekly summary fired hardcoded every Sunday 20:00
// regardless of what was configured.
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest_all.dart' as tz;
import 'package:timezone/timezone.dart' as tz;
import 'notification_service.dart';

/// Schedules context-aware reminders. Notification IDs 800–849 reserved.
class SmartReminderService {
  static final SmartReminderService _instance =
      SmartReminderService._internal();
  factory SmartReminderService() => _instance;
  SmartReminderService._internal();

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  bool _initialized = false;

  static const int _idBreakfastReminder = 800;
  static const int _idAfternoonCheck    = 801;
  static const int _idEveningGoal       = 802;
  static const int _idWeeklySummary     = 803;
  static const int _idDailySummary      = 804;

  Future<void> start() async {
    if (_initialized) return;
    try {
      tz.initializeTimeZones();
      final tzName = await FlutterTimezone.getLocalTimezone();
      tz.setLocalLocation(tz.getLocation(tzName));
      await _scheduleAll();
      _initialized = true;
      debugPrint('[SmartReminder] All reminders scheduled');
    } catch (e) {
      debugPrint('[SmartReminder] Error starting: $e');
    }
  }

  Future<void> stop() async {
    for (final id in [
      _idBreakfastReminder,
      _idAfternoonCheck,
      _idEveningGoal,
      _idWeeklySummary,
      _idDailySummary,
    ]) {
      await _plugin.cancel(id);
    }
    _initialized = false;
    debugPrint('[SmartReminder] All reminders cancelled');
  }

  /// Cancel breakfast + afternoon reminders when any meal is logged today.
  Future<void> onMealLogged() async {
    final now = DateTime.now();
    if (now.hour < 12) {
      await _plugin.cancel(_idBreakfastReminder);
      debugPrint('[SmartReminder] Cancelled breakfast reminder — meal logged');
    }
    if (now.hour < 17) {
      await _plugin.cancel(_idAfternoonCheck);
      debugPrint('[SmartReminder] Cancelled afternoon check — meal logged');
    }
  }

  /// Cancel evening nudge when daily bite goal is reached.
  Future<void> onGoalReached() async {
    await _plugin.cancel(_idEveningGoal);
    debugPrint('[SmartReminder] Cancelled evening nudge — goal reached');
  }

  /// Re-apply preferences to already-scheduled alarms — call this whenever
  /// notification preferences change (NotificationProvider does, right after
  /// every successful fetch/update). A toggle flipped in Settings must take
  /// effect on the alarms that are already scheduled, not just on the next
  /// ones start() would schedule at a future app launch.
  Future<void> applyPreferences() async {
    if (!_initialized) return; // start() will pick up current prefs itself
    try {
      await _scheduleAll();
    } catch (e) {
      debugPrint('[SmartReminder] applyPreferences failed: $e');
    }
  }

  // ── Scheduling ────────────────────────────────────────────────────────────

  Future<void> _scheduleAll() async {
    final engagementOn = await NotificationService().isCategoryEnabled(
      'engagement',
    );
    if (engagementOn) {
      await _scheduleBreakfastReminder();
      await _scheduleAfternoonCheck();
      await _scheduleEveningGoalNudge();
    } else {
      for (final id in [
        _idBreakfastReminder,
        _idAfternoonCheck,
        _idEveningGoal,
      ]) {
        await _plugin.cancel(id);
      }
    }

    // "daily_summary" has no dedicated per-category backend toggle (see
    // NotificationService._shouldShow) — only the master switch gates it.
    final masterOn = await NotificationService().masterEnabled;
    if (masterOn) {
      await _scheduleWeeklySummary();
      await _scheduleDailySummary();
    } else {
      await _plugin.cancel(_idWeeklySummary);
      await _plugin.cancel(_idDailySummary);
    }
  }

  Future<void> _scheduleBreakfastReminder() async {
    await _schedule(
      id: _idBreakfastReminder,
      title: '🌅 Good morning!',
      body: "Haven't tracked breakfast yet — time to eat!",
      at: _nextTime(hour: 10, minute: 0),
      channelId: 'engagement',
      payload: 'open_home',
    );
  }

  Future<void> _scheduleAfternoonCheck() async {
    await _schedule(
      id: _idAfternoonCheck,
      title: '🍽️ No meals tracked today',
      body: 'Everything okay? Log your meals to track your progress.',
      at: _nextTime(hour: 14, minute: 0),
      channelId: 'engagement',
      payload: 'open_home',
    );
  }

  Future<void> _scheduleEveningGoalNudge() async {
    await _schedule(
      id: _idEveningGoal,
      title: '🎯 Almost at your goal!',
      body: "A few more bites and you'll hit today's target.",
      at: _nextTime(hour: 19, minute: 0),
      channelId: 'engagement',
      payload: 'open_home',
    );
  }

  Future<void> _scheduleWeeklySummary() async {
    final (digestEnabled, backendDay, timeStr) =
        await NotificationService().getWeeklyDigestSettings();
    if (!digestEnabled) {
      await _plugin.cancel(_idWeeklySummary);
      return;
    }

    // Backend convention (weekly_digest_day, DEFAULT_PREFERENCES on the
    // server) is 0=Sunday..6=Saturday, matching JS Date.getDay()/cron —
    // Dart's DateTime.weekday is 1=Monday..7=Sunday, so only the Sunday case
    // (0) needs remapping; 1–6 already line up (Mon=1..Sat=6 in both).
    final targetWeekday = backendDay == 0 ? DateTime.sunday : backendDay;
    final timeParts = timeStr.split(':');
    final hour = int.tryParse(timeParts.elementAtOrNull(0) ?? '') ?? 20;
    final minute = int.tryParse(timeParts.elementAtOrNull(1) ?? '') ?? 0;

    final now = tz.TZDateTime.now(tz.local);
    int daysUntilTarget = (targetWeekday - now.weekday + 7) % 7;
    var fireAt = tz.TZDateTime(
      tz.local,
      now.year, now.month, now.day + daysUntilTarget,
      hour, minute,
    );
    // Same weekday but the time already passed today — push to next week,
    // not immediately (matches _nextTime's same-day-passed handling below).
    if (daysUntilTarget == 0 && fireAt.isBefore(now)) {
      fireAt = fireAt.add(const Duration(days: 7));
    }

    await _schedule(
      id: _idWeeklySummary,
      title: '📊 Your week in review',
      body: 'See how your eating and tremor trends looked this week.',
      at: fireAt,
      channelId: 'daily_summary',
      payload: 'open_insights',
    );
  }

  Future<void> _scheduleDailySummary() async {
    await _schedule(
      id: _idDailySummary,
      title: '🥄 Daily Summary Ready',
      body: 'Tap to see your full eating report for today.',
      at: _nextTime(hour: 21, minute: 0),
      channelId: 'daily_summary',
      payload: 'open_insights',
    );
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  tz.TZDateTime _nextTime({required int hour, required int minute}) {
    final now = tz.TZDateTime.now(tz.local);
    var target = tz.TZDateTime(
        tz.local, now.year, now.month, now.day, hour, minute);
    if (target.isBefore(now)) {
      target = target.add(const Duration(days: 1));
    }
    return target;
  }

  Future<void> _schedule({
    required int id,
    required String title,
    required String body,
    required tz.TZDateTime at,
    required String channelId,
    required String payload,
  }) async {
    final AndroidNotificationDetails android = AndroidNotificationDetails(
      channelId,
      channelId == 'daily_summary' ? 'Daily Summary' : 'Reminders',
      importance: channelId == 'daily_summary'
          ? Importance.defaultImportance
          : Importance.low,
      priority: Priority.defaultPriority,
      icon: '@drawable/ic_stat_notification',
      largeIcon: const DrawableResourceAndroidBitmap('@mipmap/ic_launcher'),
    );

    const DarwinNotificationDetails ios = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: false,
      presentSound: false,
    );

    await _plugin.zonedSchedule(
      id,
      title,
      body,
      at,
      NotificationDetails(android: android, iOS: ios),
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      payload: payload,
    );

    debugPrint('[SmartReminder] Scheduled #$id "$title" at $at');
  }
}
