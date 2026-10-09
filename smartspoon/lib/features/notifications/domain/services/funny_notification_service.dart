// funny_notification_service.dart — debug-only rotating "fun" notifications.
//
// A singleton that OS-schedules light-hearted notifications every couple of
// minutes (via zonedSchedule, firing even when backgrounded/killed) to exercise
// and demo the notification pipeline. Enabled only in debug builds and always
// cancelled in release (see AppSetupService) so it never ships to users.
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest_all.dart' as tz;
import 'package:timezone/timezone.dart' as tz;

/// Schedules fun rotating notifications with the OS using zonedSchedule.
/// Fires every 2 minutes even when the app is in background or killed.
class FunnyNotificationService {
  static final FunnyNotificationService _instance =
      FunnyNotificationService._internal();
  factory FunnyNotificationService() => _instance;
  FunnyNotificationService._internal();

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  bool _initialized = false;

  // Debug-only engagement cadence; release builds do not schedule these.
  static const int _intervalMinutes = 120;
  // Notification IDs 1000–1014 reserved for funny notifications (daily summary = 850).
  static const int _baseId = 1000;

  static const List<Map<String, String>> _notifications = [
    {
      'title': 'Your spoon\'s ready when you are',
      'body':
          'Haven\'t seen a bite in a while — open up and pick up where you left off.',
    },
    {
      'title': 'Hungry?',
      'body': 'Your i-Spoon is charged and ready to track your next meal.',
    },
    {
      'title': 'Nice work yesterday',
      'body': 'You hit your bite goal. Let\'s see if today can match it.',
    },
    {
      'title': 'Heads up on the heat',
      'body':
          'i-Spoon keeps an eye on food temp so you don\'t catch a surprise.',
    },
    {
      'title': 'Eating slower pays off',
      'body':
          'It takes about 20 minutes to feel full — i-Spoon helps you find that pace.',
    },
    {
      'title': 'Don\'t skip lunch',
      'body':
          'A quick, tracked meal beats none. Grab a bite when you get a moment.',
    },
    {
      'title': 'No meals logged yet today',
      'body':
          'Whenever you eat next, your spoon will pick it up automatically.',
    },
    {
      'title': 'Bite goal reached',
      'body':
          'You\'re on a roll — see if you can keep the streak going tomorrow.',
    },
    {
      'title': 'Review your meal trend',
      'body': 'Open Insights to compare pace and hand movement across meals.',
    },
    {
      'title': 'Quick reminder',
      'body': 'You haven\'t logged breakfast yet — a small meal still counts.',
    },
    {
      'title': 'Good morning',
      'body': 'No meals tracked yet today. Start whenever you\'re ready.',
    },
    {
      'title': 'Pacing check',
      'body':
          'You\'re eating a little fast — a short pause between bites can help.',
    },
    {
      'title': 'You\'re doing great',
      'body': 'Consistent tracking adds up — keep going.',
    },
    {
      'title': 'Whatever\'s on the menu',
      'body': 'Your i-Spoon is ready to track it, salty or sweet.',
    },
    {
      'title': 'Did you know?',
      'body':
          'Eating slowly is linked to eating less overall. Small changes add up.',
    },
  ];

  Future<void> _ensureInitialized() async {
    if (_initialized) return;

    tz.initializeTimeZones();
    final timeZoneName = await FlutterTimezone.getLocalTimezone();
    tz.setLocalLocation(tz.getLocation(timeZoneName));

    _initialized = true;
  }

  /// Schedule all funny notifications — fires every 2 min, rotates through messages.
  /// Call this on app start. Cancels any previous funny notifications first.
  Future<void> start() async {
    try {
      await _ensureInitialized();
      await _cancelAll();
      await _scheduleAll();
      if (kDebugMode) print('[FunnyNotifications] Scheduled all notifications');
    } catch (e) {
      if (kDebugMode) print('[FunnyNotifications] Error: $e');
    }
  }

  Future<void> stop() async {
    await _cancelAll();
    if (kDebugMode) print('[FunnyNotifications] Cancelled all');
  }

  Future<void> _cancelAll() async {
    for (int i = 0; i < _notifications.length; i++) {
      await _plugin.cancel(_baseId + i);
    }
  }

  Future<void> _scheduleAll() async {
    final msgs = List<Map<String, String>>.from(_notifications)
      ..shuffle(Random());
    final now = tz.TZDateTime.now(tz.local);

    for (int i = 0; i < msgs.length; i++) {
      final fireAt = now.add(Duration(minutes: _intervalMinutes * (i + 1)));
      await _scheduleOne(id: _baseId + i, msg: msgs[i], at: fireAt);
    }
  }

  Future<void> _scheduleOne({
    required int id,
    required Map<String, String> msg,
    required tz.TZDateTime at,
  }) async {
    const AndroidNotificationDetails android = AndroidNotificationDetails(
      'funny_reminders',
      'Fun Reminders',
      importance: Importance.defaultImportance,
      priority: Priority.defaultPriority,
      playSound: true,
      icon: '@drawable/ic_stat_notification',
      largeIcon: DrawableResourceAndroidBitmap('@mipmap/ic_launcher'),
    );

    // Use inexact alarms — Android 14+ (API 33+) restricts exact alarms
    // to apps that explicitly request SCHEDULE_EXACT_ALARM permission.
    // Inexact delivery (OS may delay by a few minutes) is fine for fun reminders.
    await _plugin.zonedSchedule(
      id,
      msg['title'],
      msg['body'],
      at,
      const NotificationDetails(android: android),
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
    );

    if (kDebugMode) {
      print('[FunnyNotifications] Scheduled #$id at $at: ${msg['title']}');
    }
  }
}
