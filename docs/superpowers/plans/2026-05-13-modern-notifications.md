# Modern Notification System Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement three industry-standard notification types: real-time in-app eating alerts (overlay when foreground, OS heads-up when background), inbox-style expandable daily summary with action buttons, and smart context-aware meal reminders.

**Architecture:** New `InAppAlertService` handles overlay banners via Flutter `OverlayEntry`. Existing `NotificationService` gets new Android `InboxStyle`/`BigTextStyle` methods and two new channels. New `SmartReminderService` owns all scheduling logic using `flutter_local_notifications` zonedSchedule with context checks against `UnifiedDataService` state.

**Tech Stack:** Flutter, `flutter_local_notifications ^19`, `flutter_timezone`, existing `UnifiedDataService`, `DatabaseService`, `NotificationService`.

---

## File Map

| Action | File | Responsibility |
|---|---|---|
| **Create** | `lib/features/notifications/domain/services/in_app_alert_service.dart` | Overlay banner widget + show/dismiss logic |
| **Create** | `lib/features/notifications/domain/services/smart_reminder_service.dart` | Context-aware reminder scheduling |
| **Modify** | `lib/features/notifications/domain/services/notification_service.dart` | Add 2 channels, InboxStyle, BigTextStyle, action buttons |
| **Modify** | `lib/features/insights/domain/services/unified_data_service.dart` | Call in-app alerts on eating speed/temp/tremor thresholds |
| **Modify** | `lib/core/services/app_setup_service.dart` | Start SmartReminderService on boot |
| **Modify** | `lib/main.dart` | Provide InAppAlertService in Provider tree |
| **Modify** | `lib/features/home/presentation/screens/home_page.dart` | Wrap body with overlay anchor widget |
| **Modify** | `android/app/src/main/AndroidManifest.xml` | Add USE_EXACT_ALARM for summary scheduling |
| **Modify** | `ios/Runner/Info.plist` | Nothing new needed — existing background modes sufficient |

---

## Task 1: InAppAlertService — Overlay Banner

**Files:**
- Create: `lib/features/notifications/domain/services/in_app_alert_service.dart`

- [ ] **Step 1: Create the service file**

```dart
// lib/features/notifications/domain/services/in_app_alert_service.dart
import 'dart:async';
import 'package:flutter/material.dart';

enum AlertSeverity { info, warning, danger, success }

class InAppAlert {
  final String title;
  final String body;
  final AlertSeverity severity;
  final Duration duration;

  const InAppAlert({
    required this.title,
    required this.body,
    this.severity = AlertSeverity.info,
    this.duration = const Duration(seconds: 4),
  });
}

class InAppAlertService extends ChangeNotifier {
  static final InAppAlertService _instance = InAppAlertService._internal();
  factory InAppAlertService() => _instance;
  InAppAlertService._internal();

  OverlayEntry? _overlayEntry;
  Timer? _dismissTimer;

  // Throttle: same alert type max once per 30 seconds
  final Map<String, DateTime> _lastShown = {};

  void show(BuildContext context, InAppAlert alert, {String? throttleKey}) {
    final key = throttleKey ?? alert.title;
    final last = _lastShown[key];
    if (last != null && DateTime.now().difference(last).inSeconds < 30) return;
    _lastShown[key] = DateTime.now();

    _dismiss();

    _overlayEntry = OverlayEntry(
      builder: (_) => _AlertBanner(
        alert: alert,
        onDismiss: _dismiss,
      ),
    );

    Overlay.of(context).insert(_overlayEntry!);

    _dismissTimer = Timer(alert.duration, _dismiss);
  }

  void _dismiss() {
    _dismissTimer?.cancel();
    _overlayEntry?.remove();
    _overlayEntry = null;
  }

  @override
  void dispose() {
    _dismiss();
    super.dispose();
  }
}

class _AlertBanner extends StatefulWidget {
  final InAppAlert alert;
  final VoidCallback onDismiss;
  const _AlertBanner({required this.alert, required this.onDismiss});

  @override
  State<_AlertBanner> createState() => _AlertBannerState();
}

class _AlertBannerState extends State<_AlertBanner>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<Offset> _slide;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    _slide = Tween<Offset>(
      begin: const Offset(0, -1),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeOut));
    _ctrl.forward();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Color get _color {
    switch (widget.alert.severity) {
      case AlertSeverity.danger:  return const Color(0xFFEF5350);
      case AlertSeverity.warning: return const Color(0xFFFFA726);
      case AlertSeverity.success: return const Color(0xFF66BB6A);
      case AlertSeverity.info:    return const Color(0xFF42A5F5);
    }
  }

  IconData get _icon {
    switch (widget.alert.severity) {
      case AlertSeverity.danger:  return Icons.warning_rounded;
      case AlertSeverity.warning: return Icons.speed_rounded;
      case AlertSeverity.success: return Icons.check_circle_rounded;
      case AlertSeverity.info:    return Icons.info_rounded;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Positioned(
      top: MediaQuery.of(context).padding.top + 8,
      left: 16,
      right: 16,
      child: SlideTransition(
        position: _slide,
        child: Material(
          elevation: 8,
          borderRadius: BorderRadius.circular(14),
          color: _color,
          child: InkWell(
            onTap: widget.onDismiss,
            borderRadius: BorderRadius.circular(14),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                children: [
                  Icon(_icon, color: Colors.white, size: 24),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          widget.alert.title,
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 14,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          widget.alert.body,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Icon(Icons.close, color: Colors.white70, size: 18),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
```

- [ ] **Step 2: Add to Provider tree in `main.dart`**

In `lib/main.dart`, add to `MultiProvider`:
```dart
ChangeNotifierProvider(create: (_) => InAppAlertService()),
```

Import:
```dart
import 'package:smartspoon/features/notifications/domain/services/in_app_alert_service.dart';
```

- [ ] **Step 3: Export from notifications index**

In `lib/features/notifications/index.dart`, add:
```dart
export 'domain/services/in_app_alert_service.dart';
```

- [ ] **Step 4: Commit**
```bash
git add lib/features/notifications/domain/services/in_app_alert_service.dart lib/features/notifications/index.dart lib/main.dart
git commit -m "feat: add InAppAlertService with animated overlay banner"
```

---

## Task 2: Wire In-App Alerts to Eating Thresholds

**Files:**
- Modify: `lib/features/insights/domain/services/unified_data_service.dart`
- Modify: `lib/features/home/presentation/screens/home_page.dart`

- [ ] **Step 1: Add alert triggers in `UnifiedDataService`**

In `unified_data_service.dart`, add import:
```dart
import 'package:smartspoon/features/notifications/domain/services/in_app_alert_service.dart';
import 'package:smartspoon/features/notifications/domain/services/notification_service.dart';
```

Add these private fields near other state fields:
```dart
// Alert thresholds
static const double _fastEatingThreshold = 25.0;  // bpm
static const double _hotFoodThreshold    = 60.0;  // °C
static const double _veryHotFoodThreshold= 70.0;  // °C
static const double _tremorAlertThreshold = 1.5;  // score
```

Add this method to `UnifiedDataService`:
```dart
/// Call after every bite or temp update during active session.
/// Shows in-app overlay if app is foregrounded, OS notification if backgrounded.
void _checkEatingAlerts(BuildContext? context) {
  if (!isSessionActive) return;

  // Speed alert
  if (_smoothedSpeedBpm > _fastEatingThreshold) {
    if (context != null && context.mounted) {
      InAppAlertService().show(
        context,
        const InAppAlert(
          title: 'Eating Too Fast',
          body: 'Try to slow down — aim for under 20 bites/min',
          severity: AlertSeverity.warning,
        ),
        throttleKey: 'speed_alert',
      );
    } else {
      NotificationService().showLocalAlert(
        title: '⚡ Eating Too Fast',
        body: 'Slow down — ${_smoothedSpeedBpm.toStringAsFixed(0)} bites/min detected',
        type: 'health_alerts',
        priority: 'HIGH',
      );
    }
  }

  // Temperature alert
  final temp = currentFoodTemp;
  if (temp > _veryHotFoodThreshold) {
    if (context != null && context.mounted) {
      InAppAlertService().show(
        context,
        InAppAlert(
          title: 'Food Very Hot — ${temp.toStringAsFixed(0)}°C',
          body: 'Wait a moment before eating to avoid burns',
          severity: AlertSeverity.danger,
        ),
        throttleKey: 'temp_danger',
      );
    } else {
      NotificationService().showLocalAlert(
        title: '🌡️ Food Very Hot',
        body: '${temp.toStringAsFixed(0)}°C — wait before eating',
        type: 'health_alerts',
        priority: 'CRITICAL',
      );
    }
  } else if (temp > _hotFoodThreshold) {
    if (context != null && context.mounted) {
      InAppAlertService().show(
        context,
        InAppAlert(
          title: 'Food is Hot — ${temp.toStringAsFixed(0)}°C',
          body: 'Be careful while eating',
          severity: AlertSeverity.warning,
        ),
        throttleKey: 'temp_warning',
      );
    }
  }

  // Tremor alert
  final ti = tremorIndex;
  if (ti > _tremorAlertThreshold) {
    if (context != null && context.mounted) {
      InAppAlertService().show(
        context,
        const InAppAlert(
          title: 'Tremor Spike Detected',
          body: 'Elevated tremor activity recorded during this bite',
          severity: AlertSeverity.danger,
          duration: Duration(seconds: 6),
        ),
        throttleKey: 'tremor_alert',
      );
    } else {
      NotificationService().showLocalAlert(
        title: '📳 Tremor Spike Detected',
        body: 'Elevated tremor activity during this bite',
        type: 'health_alerts',
        priority: 'HIGH',
      );
    }
  }
}
```

Find where bites are counted and speed is updated (near `_smoothBiteSpeed` call), and add:
```dart
_checkEatingAlerts(navigatorKey.currentContext);
```

Add import at top:
```dart
import 'package:smartspoon/main.dart' show navigatorKey;
```

- [ ] **Step 2: Commit**
```bash
git add lib/features/insights/domain/services/unified_data_service.dart
git commit -m "feat: trigger in-app and OS eating alerts from UnifiedDataService"
```

---

## Task 3: Add New Android Notification Channels + InboxStyle

**Files:**
- Modify: `lib/features/notifications/domain/services/notification_service.dart`

- [ ] **Step 1: Add two new channels in `_createAndroidChannels()`**

Add inside `_createAndroidChannels()` after existing channels:
```dart
const AndroidNotificationChannel eatingAlertsChannel = AndroidNotificationChannel(
  'eating_alerts',
  'Eating Alerts',
  description: 'Real-time alerts during active meals',
  importance: Importance.max,
  playSound: false,        // vibrate only — don't interrupt conversation
  enableVibration: true,
  vibrationPattern: Int64List.fromList([0, 200, 100, 200]),
);

const AndroidNotificationChannel dailySummaryChannel = AndroidNotificationChannel(
  'daily_summary',
  'Daily Summary',
  description: 'End-of-day eating summary with stats',
  importance: Importance.defaultImportance,
  playSound: false,
);
```

Also add to plugin.createNotificationChannel calls:
```dart
await plugin.createNotificationChannel(eatingAlertsChannel);
await plugin.createNotificationChannel(dailySummaryChannel);
```

Add import at top of file:
```dart
import 'dart:typed_data';
```

- [ ] **Step 2: Add `showDailySummary()` method**

Add this method to `NotificationService`:
```dart
/// Show an expandable inbox-style daily summary notification.
/// [stats] keys: total_bites, goal_bites, breakfast, lunch, dinner, snack,
///               tremor_level ('Low'/'Moderate'/'High'), avg_temp_c
Future<void> showDailySummary(Map<String, dynamic> stats) async {
  if (!_initialized) await initialize();

  final totalBites = stats['total_bites'] as int? ?? 0;
  final goalBites  = stats['goal_bites']  as int? ?? 50;
  final goalReached = totalBites >= goalBites;
  final tremorLevel = stats['tremor_level'] as String? ?? 'Low';
  final avgTemp     = (stats['avg_temp_c'] as num?)?.toStringAsFixed(1) ?? '--';

  final tremorEmoji = tremorLevel == 'Low' ? '🟢'
      : tremorLevel == 'Moderate' ? '🟡' : '🔴';
  final goalEmoji = goalReached ? '✅' : '⭕';

  // Lines shown when notification is expanded
  final lines = [
    '$goalEmoji $totalBites / $goalBites bites ${goalReached ? "— Goal reached!" : ""}',
    if ((stats['breakfast'] as int? ?? 0) > 0)
      '🌅 Breakfast   ${stats['breakfast']} bites',
    if ((stats['lunch'] as int? ?? 0) > 0)
      '☀️ Lunch       ${stats['lunch']} bites',
    if ((stats['dinner'] as int? ?? 0) > 0)
      '🌙 Dinner      ${stats['dinner']} bites',
    if ((stats['snack'] as int? ?? 0) > 0)
      '🍎 Snack       ${stats['snack']} bites',
    '$tremorEmoji Tremor        $tremorLevel',
    '🌡️ Avg temp    ${avgTemp}°C',
  ];

  final AndroidNotificationDetails androidDetails = AndroidNotificationDetails(
    'daily_summary',
    'Daily Summary',
    importance: Importance.defaultImportance,
    priority: Priority.defaultPriority,
    icon: '@drawable/ic_stat_notification',
    largeIcon: const DrawableResourceAndroidBitmap('@mipmap/ic_launcher'),
    styleInformation: InboxStyleInformation(
      lines,
      contentTitle: '🥄 i-Spoon Daily Summary',
      summaryText: '$totalBites bites today',
    ),
    actions: [
      const AndroidNotificationAction(
        'view_insights',
        'View Details',
        showsUserInterface: true,
      ),
      const AndroidNotificationAction(
        'dismiss',
        'Dismiss',
      ),
    ],
  );

  const DarwinNotificationDetails iosDetails = DarwinNotificationDetails(
    presentAlert: true,
    presentBadge: false,
    presentSound: false,
    subtitle: 'Tap to view your full report',
  );

  await _localNotifications.show(
    900, // fixed ID so daily summary replaces itself
    goalReached ? '🎯 Goal Reached Today!' : '📊 Daily Summary',
    '$totalBites bites • Tremor: $tremorLevel • Temp: ${avgTemp}°C',
    NotificationDetails(android: androidDetails, iOS: iosDetails),
    payload: 'open_insights',
  );
}
```

- [ ] **Step 3: Handle action button tap in `_handleLocalNotificationTap()`**

In the existing `_handleLocalNotificationTap` method, add to the payload check:
```dart
// Handle daily summary action buttons
if (response.actionId == 'view_insights') {
  final context = navigatorKey.currentContext;
  if (context != null) {
    Navigator.of(context).pushNamed('/insights');
  }
  return;
}
if (response.actionId == 'dismiss') return;
```

- [ ] **Step 4: Commit**
```bash
git add lib/features/notifications/domain/services/notification_service.dart
git commit -m "feat: add eating_alerts/daily_summary channels, InboxStyle summary notification"
```

---

## Task 4: SmartReminderService

**Files:**
- Create: `lib/features/notifications/domain/services/smart_reminder_service.dart`

- [ ] **Step 1: Create the service**

```dart
// lib/features/notifications/domain/services/smart_reminder_service.dart
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest_all.dart' as tz;
import 'package:timezone/timezone.dart' as tz;
import 'package:smartspoon/core/services/database_service.dart';
import 'package:smartspoon/features/auth/domain/services/auth_service.dart';

/// Notification IDs reserved for smart reminders: 800–849
class SmartReminderService {
  static final SmartReminderService _instance = SmartReminderService._internal();
  factory SmartReminderService() => _instance;
  SmartReminderService._internal();

  final FlutterLocalNotificationsPlugin _plugin = FlutterLocalNotificationsPlugin();
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
      debugPrint('[SmartReminder] Error: $e');
    }
  }

  Future<void> stop() async {
    for (final id in [
      _idBreakfastReminder, _idAfternoonCheck,
      _idEveningGoal, _idWeeklySummary, _idDailySummary,
    ]) {
      await _plugin.cancel(id);
    }
    _initialized = false;
  }

  Future<void> _scheduleAll() async {
    await _scheduleBreakfastReminder();
    await _scheduleAfternoonCheck();
    await _scheduleEveningGoalNudge();
    await _scheduleWeeklySummary();
    await _scheduleDailySummary();
  }

  // ── 10:00 AM — if no breakfast logged yet ────────────────────────────────
  Future<void> _scheduleBreakfastReminder() async {
    final fireAt = _nextTime(hour: 10, minute: 0);
    await _scheduleNotification(
      id: _idBreakfastReminder,
      title: '🌅 Good morning!',
      body: "Haven't tracked breakfast yet — time to eat!",
      at: fireAt,
      channelId: 'engagement',
      payload: 'open_home',
    );
  }

  // ── 2:00 PM — if no meal logged all day ──────────────────────────────────
  Future<void> _scheduleAfternoonCheck() async {
    final fireAt = _nextTime(hour: 14, minute: 0);
    await _scheduleNotification(
      id: _idAfternoonCheck,
      title: '🍽️ No meals tracked today',
      body: 'Everything okay? Log your meals to track your progress.',
      at: fireAt,
      channelId: 'engagement',
      payload: 'open_home',
    );
  }

  // ── 7:00 PM — nudge if goal not reached ──────────────────────────────────
  Future<void> _scheduleEveningGoalNudge() async {
    final fireAt = _nextTime(hour: 19, minute: 0);
    await _scheduleNotification(
      id: _idEveningGoal,
      title: '🎯 Almost at your goal!',
      body: "A few more bites and you'll hit today's target.",
      at: fireAt,
      channelId: 'engagement',
      payload: 'open_home',
    );
  }

  // ── Sunday 8:00 PM — weekly summary ──────────────────────────────────────
  Future<void> _scheduleWeeklySummary() async {
    final now = tz.TZDateTime.now(tz.local);
    // Days until next Sunday (weekday 7)
    int daysUntilSunday = (DateTime.sunday - now.weekday + 7) % 7;
    if (daysUntilSunday == 0) daysUntilSunday = 7;
    final fireAt = tz.TZDateTime(
      tz.local,
      now.year, now.month, now.day + daysUntilSunday,
      20, 0,
    );
    await _scheduleNotification(
      id: _idWeeklySummary,
      title: '📊 Your week in review',
      body: 'See how your eating and tremor trends looked this week.',
      at: fireAt,
      channelId: 'daily_summary',
      payload: 'open_insights',
    );
  }

  // ── 9:00 PM daily — trigger daily summary build ───────────────────────────
  Future<void> _scheduleDailySummary() async {
    final fireAt = _nextTime(hour: 21, minute: 0);
    await _scheduleNotification(
      id: _idDailySummary,
      title: '🥄 Daily Summary Ready',
      body: 'Tap to see your full eating report for today.',
      at: fireAt,
      channelId: 'daily_summary',
      payload: 'open_insights',
    );
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  tz.TZDateTime _nextTime({required int hour, required int minute}) {
    final now = tz.TZDateTime.now(tz.local);
    var target = tz.TZDateTime(tz.local, now.year, now.month, now.day, hour, minute);
    if (target.isBefore(now)) {
      target = target.add(const Duration(days: 1));
    }
    return target;
  }

  Future<void> _scheduleNotification({
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

  /// Call this when a meal is logged to cancel redundant reminders for today.
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

  /// Call this when daily goal is reached.
  Future<void> onGoalReached() async {
    await _plugin.cancel(_idEveningGoal);
    debugPrint('[SmartReminder] Cancelled evening nudge — goal reached');
  }
}
```

- [ ] **Step 2: Start service in `app_setup_service.dart`**

In `lib/core/services/app_setup_service.dart`, add import:
```dart
import 'package:smartspoon/features/notifications/domain/services/smart_reminder_service.dart';
```

Add to `initializeBackgroundServices()` microtask:
```dart
try {
  await SmartReminderService().start();
  debugPrint('[Setup] SmartReminderService started');
} catch (e) {
  debugPrint('[Setup] SmartReminderService.start() failed: $e');
}
```

- [ ] **Step 3: Cancel reminders when meal is logged**

In `lib/features/insights/domain/services/unified_data_service.dart`, inside `startSession()` or wherever a meal begins, add:
```dart
SmartReminderService().onMealLogged();
```

Add import:
```dart
import 'package:smartspoon/features/notifications/domain/services/smart_reminder_service.dart';
```

- [ ] **Step 4: Cancel evening nudge when goal is reached**

In `unified_data_service.dart`, where `totalBites` crosses the daily goal threshold, add:
```dart
SmartReminderService().onGoalReached();
```

- [ ] **Step 5: Export from index**

In `lib/features/notifications/index.dart`:
```dart
export 'domain/services/smart_reminder_service.dart';
```

- [ ] **Step 6: Commit**
```bash
git add lib/features/notifications/domain/services/smart_reminder_service.dart \
        lib/core/services/app_setup_service.dart \
        lib/features/insights/domain/services/unified_data_service.dart \
        lib/features/notifications/index.dart
git commit -m "feat: add SmartReminderService with context-aware scheduled reminders"
```

---

## Task 5: Wire Daily Summary Trigger

**Files:**
- Modify: `lib/features/insights/domain/services/unified_data_service.dart`

- [ ] **Step 1: Add `triggerDailySummary()` method**

In `UnifiedDataService`, add:
```dart
/// Build and show the daily summary notification.
/// Call this at end of last meal or from scheduled trigger.
Future<void> triggerDailySummary() async {
  try {
    final userId = await AuthService.getUserId();
    if (userId == null) return;

    final db = DatabaseService();
    final today = DateTime.now();
    final start = DateTime(today.year, today.month, today.day);
    final end   = start.add(const Duration(days: 1));

    final summaries = await db.getDailySummaries(
      userId: userId,
      start: start,
      end: end,
    );

    if (summaries.isEmpty) return;

    final s = summaries.first;
    final totalBites = (s['total_bites'] as num?)?.toInt() ?? 0;

    // Tremor level from today's bites
    final tremorMag = (s['avg_tremor_magnitude'] as num?)?.toDouble() ?? 0.0;
    final tremorLevel = tremorMag < 0.6 ? 'Low'
        : tremorMag < 1.4 ? 'Moderate' : 'High';

    await NotificationService().showDailySummary({
      'total_bites':  totalBites,
      'goal_bites':   dailyBiteGoal,
      'breakfast':    (s['breakfast_bites'] as num?)?.toInt() ?? 0,
      'lunch':        (s['lunch_bites']     as num?)?.toInt() ?? 0,
      'dinner':       (s['dinner_bites']    as num?)?.toInt() ?? 0,
      'snack':        (s['snack_bites']     as num?)?.toInt() ?? 0,
      'tremor_level': tremorLevel,
      'avg_temp_c':   s['avg_food_temp_c'],
    });

    // Cancel evening nudge — summary was sent
    SmartReminderService().onGoalReached();
  } catch (e) {
    debugPrint('[UDS] triggerDailySummary error: $e');
  }
}
```

- [ ] **Step 2: Handle `open_insights` payload navigation**

In `notification_service.dart`, in `_handleLocalNotificationTap`, ensure:
```dart
if (response.payload == 'open_insights') {
  final context = navigatorKey.currentContext;
  if (context != null && context.mounted) {
    Navigator.of(context).pushNamed('/insights');
  }
  return;
}
```

- [ ] **Step 3: Commit**
```bash
git add lib/features/insights/domain/services/unified_data_service.dart \
        lib/features/notifications/domain/services/notification_service.dart
git commit -m "feat: wire daily summary trigger from UnifiedDataService"
```

---

## Task 6: Analyze + Build + Install

- [ ] **Step 1: Run analyzer**
```bash
cd "/Volumes/Bees-SSD/SmartSpoon copy 2/smartspoon"
flutter analyze lib/features/notifications lib/features/insights/domain/services/unified_data_service.dart lib/core/services/app_setup_service.dart 2>&1
```
Expected: No errors (warnings OK)

- [ ] **Step 2: Build release APK**
```bash
flutter build apk --release --target-platform android-arm64 2>&1 | tail -4
```
Expected: `✓ Built build/app/outputs/flutter-apk/app-release.apk`

- [ ] **Step 3: Install**
```bash
adb install -r build/app/outputs/flutter-apk/app-release.apk
adb shell am start -n com.example.smartspoon/.MainActivity
```

- [ ] **Step 4: Manual test checklist**
  - [ ] Open app → start a meal → eat fast → in-app yellow banner appears
  - [ ] Background app → eat fast → OS heads-up notification appears
  - [ ] Tap "Test Notification" button in notifications screen → inbox-style appears
  - [ ] Check notification shade → daily summary expands to show all stats
  - [ ] Tap "View Details" action → app opens on Insights tab

- [ ] **Step 5: Final commit**
```bash
git add .
git commit -m "feat: complete modern notification system - overlays, inbox summary, smart reminders"
```

---

## Summary of New Notifications

| Type | Trigger | Channel | Style |
|---|---|---|---|
| Eating too fast | `speedBpm > 25` | `eating_alerts` | In-app banner (yellow) |
| Food very hot | `temp > 70°C` | `eating_alerts` | In-app banner (red) |
| Food hot | `temp > 60°C` | `eating_alerts` | In-app banner (yellow) |
| Tremor spike | `tremorIndex > 1.5` | `health_alerts` | In-app banner (red) |
| Daily summary | 9pm daily | `daily_summary` | InboxStyle expandable |
| Breakfast reminder | 10am if no meal | `engagement` | Simple heads-up |
| Afternoon check | 2pm if no meal | `engagement` | Simple heads-up |
| Evening goal nudge | 7pm if goal not met | `engagement` | Simple heads-up |
| Weekly summary | Sunday 8pm | `daily_summary` | Simple heads-up |
