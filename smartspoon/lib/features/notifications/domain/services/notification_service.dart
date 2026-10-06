// notification_service.dart — push + local notification engine.
//
// Singleton that owns all notification plumbing: initializes Firebase Cloud
// Messaging and flutter_local_notifications, handles foreground/background/
// terminated messages (including the top-level background handler), registers
// the device FCM token with the backend, routes notification taps to the right
// screen via the global navigatorKey, and exposes showLocalAlert() used
// throughout the app (sync, eating/temperature/tremor alerts) to raise local
// notifications by category.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:smartspoon/core/config/app_config.dart';
import 'package:smartspoon/features/auth/domain/services/auth_service.dart';
import 'package:smartspoon/features/home/presentation/screens/home_page.dart';
import 'package:smartspoon/main.dart'; // Import navigatorKey
import 'package:smartspoon/core/utils/temperature_format.dart';

/// Top-level function for handling background messages
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  if (kDebugMode) {
    print('Handling background message: ${message.messageId}');
    print('Title: ${message.notification?.title}');
    print('Body: ${message.notification?.body}');
  }
}

class NotificationService {
  static final NotificationService _instance = NotificationService._internal();
  factory NotificationService() => _instance;
  NotificationService._internal();

  final FirebaseMessaging _fcm = FirebaseMessaging.instance;
  final FlutterLocalNotificationsPlugin _localNotifications =
      FlutterLocalNotificationsPlugin();

  bool _initialized = false;
  Completer<void>? _initCompleter;
  String? _fcmToken;

  final String _baseUrl = AppConfig.apiBaseUrl;

  /// Initialize notification service.
  /// Concurrent callers wait for the same initialization — only one runs.
  Future<void> initialize() async {
    if (_initialized) return;

    // If init is already in progress, wait for it instead of running again.
    if (_initCompleter != null) {
      return _initCompleter!.future;
    }
    _initCompleter = Completer<void>();

    try {
      // Background handler is registered once in main() before runApp().
      // Do not re-register here — Firebase requires a single top-level handler.

      // Request permissions
      await _fcm.setForegroundNotificationPresentationOptions(
        alert: true,
        badge: true,
        sound: true,
      );

      final NotificationSettings settings = await _fcm.requestPermission(
        alert: true,
        badge: true,
        sound: true,
        provisional: false,
      );

      if (settings.authorizationStatus == AuthorizationStatus.authorized) {
        if (kDebugMode) print('Notification permissions granted');
      } else {
        if (kDebugMode) print('Notification permissions denied');
        // Don't return — local notifications still work without FCM permission
      }

      // Initialize local notifications
      await _initializeLocalNotifications();

      // Get FCM token in background — don't block initialization on it.
      // On iOS debug builds, APNs token may never arrive (no provisioning profile).
      unawaited(_fetchAndRegisterFcmToken());

      // Listen for token refresh
      _fcm.onTokenRefresh.listen((newToken) {
        _fcmToken = newToken;
        _registerFCMToken(newToken);
      });

      // Listen for foreground messages
      FirebaseMessaging.onMessage.listen(_handleForegroundMessage);

      // Listen for notification taps
      FirebaseMessaging.onMessageOpenedApp.listen(_handleNotificationTap);

      // Check if app was opened from a notification
      final RemoteMessage? initialMessage = await _fcm.getInitialMessage();
      if (initialMessage != null) {
        _handleNotificationTap(initialMessage);
      }

      _initialized = true;
      if (kDebugMode) print('NotificationService initialized');
      _initCompleter!.complete();
    } catch (e) {
      if (kDebugMode) print('Error initializing NotificationService: $e');
      _initCompleter!.completeError(e);
      _initCompleter = null; // Allow retry on next call if init failed
    }
  }

  /// Fetch FCM token and register it — runs in background, never blocks initialization.
  Future<void> _fetchAndRegisterFcmToken() async {
    for (int i = 0; i < 2; i++) {
      try {
        final token = await _fcm.getToken();
        if (token != null) {
          _fcmToken = token;
          await _registerFCMToken(token);
          return;
        }
      } catch (e) {
        if (kDebugMode) print('FCM token attempt ${i + 1} failed: $e');
      }
      if (i == 0) await Future.delayed(const Duration(seconds: 10));
    }
    if (kDebugMode) print('FCM token unavailable — relying on onTokenRefresh');
  }

  /// Initialize local notifications
  Future<void> _initializeLocalNotifications() async {
    // Use monochrome drawable for Android small icon (API 21+ requirement).
    // @mipmap/ic_launcher shows as a grey square; the vector drawable is white-on-transparent.
    const AndroidInitializationSettings androidSettings =
        AndroidInitializationSettings('@drawable/ic_stat_notification');

    const DarwinInitializationSettings iosSettings =
        DarwinInitializationSettings(
          requestAlertPermission: true,
          requestBadgePermission: true,
          requestSoundPermission: true,
        );

    const InitializationSettings settings = InitializationSettings(
      android: androidSettings,
      iOS: iosSettings,
    );

    await _localNotifications.initialize(
      settings,
      onDidReceiveNotificationResponse: _handleLocalNotificationTap,
    );

    // Create Android notification channels
    await _createAndroidChannels();

    // Explicitly request permission for Android 13+ via local notifications plugin
    // This is more reliable than FCM's requestPermission on some devices
    final androidImplementation = _localNotifications
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    if (androidImplementation != null) {
      await androidImplementation.requestNotificationsPermission();
    }
  }

  /// Create Android notification channels
  Future<void> _createAndroidChannels() async {
    const healthChannel = AndroidNotificationChannel(
      'health_alerts',
      'Health Alerts',
      description: 'Notifications about eating pace, tremors, and temperature',
      importance: Importance.high,
      playSound: true,
    );

    const achievementChannel = AndroidNotificationChannel(
      'achievements',
      'Achievements',
      description: 'Goal completions and milestones',
      importance: Importance.defaultImportance,
    );

    const engagementChannel = AndroidNotificationChannel(
      'engagement',
      'Reminders',
      description: 'Meal reminders and insights',
      importance: Importance.low,
    );

    const systemChannel = AndroidNotificationChannel(
      'system_alerts',
      'System Alerts',
      description: 'Battery, sync, and update notifications',
      importance: Importance.max,
      playSound: true,
    );

    const funnyChannel = AndroidNotificationChannel(
      'funny_reminders',
      'Fun Reminders',
      description: 'Friendly i-Spoon reminders and tips',
      importance: Importance.high,
      playSound: true,
    );

    // Real-time alerts during active meals — vibrate only, no sound
    final eatingAlertsChannel = AndroidNotificationChannel(
      'eating_alerts',
      'Eating Alerts',
      description: 'Real-time alerts during active meals',
      importance: Importance.max,
      playSound: false,
      enableVibration: true,
      vibrationPattern: Int64List.fromList([0, 200, 100, 200]),
    );

    // End-of-day summary — quiet, informational
    const dailySummaryChannel = AndroidNotificationChannel(
      'daily_summary',
      'Daily Summary',
      description: 'End-of-day eating summary with stats',
      importance: Importance.defaultImportance,
      playSound: false,
    );

    final plugin = _localNotifications
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();

    if (plugin != null) {
      await plugin.createNotificationChannel(healthChannel);
      await plugin.createNotificationChannel(achievementChannel);
      await plugin.createNotificationChannel(engagementChannel);
      await plugin.createNotificationChannel(systemChannel);
      await plugin.createNotificationChannel(funnyChannel);
      await plugin.createNotificationChannel(eatingAlertsChannel);
      await plugin.createNotificationChannel(dailySummaryChannel);
    }
  }

  /// Register FCM token with backend
  Future<void> _registerFCMToken(String token) async {
    try {
      final authToken = await AuthService.getValidToken();

      // If no auth token (user not logged in), we can't register the FCM token yet.
      // This is expected during onboarding/login screens.
      if (authToken == null) {
        if (kDebugMode) {
          print('ℹ️ User not logged in. Skipping FCM token registration.');
        }
        return;
      }

      final url = Uri.parse('$_baseUrl/notifications/fcm-token');
      if (kDebugMode) print('Registering FCM Token at: $url');

      final response = await http
          .post(
            url,
            headers: {
              'Authorization': 'Bearer $authToken',
              'Content-Type': 'application/json',
            },
            body: jsonEncode({'fcm_token': token}),
          )
          .timeout(const Duration(seconds: 10));

      if (response.statusCode >= 200 && response.statusCode < 300) {
        if (kDebugMode) print('✅ FCM token registered successfully');
      } else {
        if (kDebugMode) {
          print(
            '⚠️ Failed to register FCM token: ${response.statusCode} - ${response.body}',
          );
        }
      }
    } catch (e, stackTrace) {
      if (kDebugMode) print('❌ Error registering FCM token: $e\n$stackTrace');
    }
  }

  /// Handle foreground messages
  void _handleForegroundMessage(RemoteMessage message) {
    if (kDebugMode) {
      print('Foreground message received: ${message.messageId}');
      print('Title: ${message.notification?.title}');
      print('Body: ${message.notification?.body}');
    }

    // Show local notification
    unawaited(_showLocalNotification(message));

    // Mark as delivered
    if (message.data['notification_id'] != null) {
      // Could track delivery here if needed
    }
  }

  /// Build platform-specific Android notification details with correct icons
  AndroidNotificationDetails _androidDetails(
    String channelId, {
    required bool isHigh,
    required bool playSound,
  }) {
    return AndroidNotificationDetails(
      channelId,
      _getChannelName(channelId),
      importance: isHigh ? Importance.high : Importance.defaultImportance,
      priority: isHigh ? Priority.high : Priority.defaultPriority,
      playSound: playSound,
      // Monochrome small icon (white-on-transparent) — required by Android 5+
      icon: '@drawable/ic_stat_notification',
      // Full-colour app logo shown in the expanded notification
      largeIcon: const DrawableResourceAndroidBitmap('@mipmap/ic_launcher'),
    );
  }

  /// Show local notification (from FCM foreground message)
  Future<void> _showLocalNotification(RemoteMessage message) async {
    final notification = message.notification;
    if (notification == null) return;

    final priority = message.data['priority'] ?? 'LOW';
    final type = message.data['type'] ?? '';
    final channelId = _getChannelId(type);

    // Previously this path showed EVERY foreground push unconditionally — the
    // master notifications-off toggle was only checked in showLocalAlert
    // (on-device alerts), not here. A user who disabled notifications in the
    // app still saw every server-sent push while the app was foregrounded.
    if (!await _shouldShow(channelId, priority)) return;

    final isHigh = priority == 'CRITICAL' || priority == 'HIGH';

    final AndroidNotificationDetails androidDetails = _androidDetails(
      channelId,
      isHigh: isHigh,
      playSound: priority == 'CRITICAL',
    );

    const DarwinNotificationDetails iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
    );

    NotificationDetails details = NotificationDetails(
      android: androidDetails,
      iOS: iosDetails,
    );

    await _localNotifications.show(
      message.hashCode,
      notification.title,
      notification.body,
      details,
      payload: jsonEncode(message.data),
    );
    unawaited(_incrementDailyCount());
  }

  static const _prefKeyEnabled = 'notifications_enabled';
  static const _prefKeyHealth = 'notif_pref_health_alerts_enabled';
  static const _prefKeyAchievement = 'notif_pref_achievement_enabled';
  static const _prefKeyEngagement = 'notif_pref_engagement_enabled';
  static const _prefKeySystem = 'notif_pref_system_alerts_enabled';
  static const _prefKeyQuietStart = 'notif_pref_quiet_hours_start';
  static const _prefKeyQuietEnd = 'notif_pref_quiet_hours_end';
  static const _prefKeyMaxDaily = 'notif_pref_max_daily_notifications';
  static const _prefKeyWeeklyDigestEnabled = 'notif_pref_weekly_digest_enabled';
  static const _prefKeyWeeklyDigestDay = 'notif_pref_weekly_digest_day';
  static const _prefKeyWeeklyDigestTime = 'notif_pref_weekly_digest_time';
  static const _prefKeyDailyCountDate = 'notif_daily_count_date';
  static const _prefKeyDailyCount = 'notif_daily_count';

  /// Persist the master on/off toggle locally so it survives restarts.
  /// Kept separate from cachePreferences (below) — settings screens or
  /// callers that only need the master switch don't need a full
  /// NotificationPreferences round-trip to flip it.
  Future<void> setEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefKeyEnabled, enabled);
  }

  /// Cache the full preference set locally so every gating decision below
  /// can run synchronously against SharedPreferences instead of a network
  /// round-trip. Call this after any successful fetch/update of preferences
  /// from the backend (NotificationProvider does, on both fetchPreferences
  /// and updatePreferences).
  ///
  /// Before this existed, health/achievement/engagement/system per-category
  /// toggles, quiet hours, and the daily notification cap were all stored on
  /// the backend and editable from Settings, but NOTHING in this service ever
  /// read them back — toggling any of them had zero effect on what actually
  /// got shown. Only the single master on/off switch was wired end to end.
  Future<void> cachePreferences({
    required bool enabled,
    required bool healthAlertsEnabled,
    required bool achievementEnabled,
    required bool engagementEnabled,
    required bool systemAlertsEnabled,
    required String quietHoursStart,
    required String quietHoursEnd,
    required int maxDailyNotifications,
    required bool weeklyDigestEnabled,
    required int weeklyDigestDay,
    required String weeklyDigestTime,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefKeyEnabled, enabled);
    await prefs.setBool(_prefKeyHealth, healthAlertsEnabled);
    await prefs.setBool(_prefKeyAchievement, achievementEnabled);
    await prefs.setBool(_prefKeyEngagement, engagementEnabled);
    await prefs.setBool(_prefKeySystem, systemAlertsEnabled);
    await prefs.setString(_prefKeyQuietStart, quietHoursStart);
    await prefs.setString(_prefKeyQuietEnd, quietHoursEnd);
    await prefs.setInt(_prefKeyMaxDaily, maxDailyNotifications);
    await prefs.setBool(_prefKeyWeeklyDigestEnabled, weeklyDigestEnabled);
    await prefs.setInt(_prefKeyWeeklyDigestDay, weeklyDigestDay);
    await prefs.setString(_prefKeyWeeklyDigestTime, weeklyDigestTime);
  }

  /// Weekly digest settings for SmartReminderService — (enabled, weekday
  /// 0=Sunday..6=Saturday matching the backend's convention, "HH:mm"). Was
  /// previously stored and editable in Settings but never read anywhere: the
  /// weekly summary fired hardcoded every Sunday at 20:00 regardless of what
  /// the user configured.
  Future<(bool, int, String)> getWeeklyDigestSettings() async {
    final prefs = await SharedPreferences.getInstance();
    return (
      prefs.getBool(_prefKeyWeeklyDigestEnabled) ?? true,
      prefs.getInt(_prefKeyWeeklyDigestDay) ?? 0,
      prefs.getString(_prefKeyWeeklyDigestTime) ?? '20:00',
    );
  }

  /// The cached master on/off toggle alone — for callers that need it
  /// without a category (e.g. the daily/weekly summary reminders, which have
  /// no dedicated per-category backend preference).
  Future<bool> get masterEnabled async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_prefKeyEnabled) ?? true;
  }

  /// Read-only access to the cached master + category toggles for callers
  /// that schedule OS alarms (SmartReminderService) rather than showing a
  /// notification immediately — those can't use _shouldShow's synchronous
  /// per-notification gate, since a zonedSchedule fires later, outside the
  /// Dart process, with no hook to re-check preferences at fire time. Instead
  /// they read these once to decide whether to schedule/cancel at all,
  /// re-applied whenever preferences change (see NotificationProvider).
  Future<bool> isCategoryEnabled(String category) async {
    final prefs = await SharedPreferences.getInstance();
    if (!(prefs.getBool(_prefKeyEnabled) ?? true)) return false;
    final key = switch (category) {
      'health' => _prefKeyHealth,
      'achievement' => _prefKeyAchievement,
      'engagement' => _prefKeyEngagement,
      'system' => _prefKeySystem,
      _ => null,
    };
    if (key == null) return true;
    return prefs.getBool(key) ?? true;
  }

  /// Single suppression policy, consulted by every path that shows a
  /// notification (showLocalAlert for on-device alerts, _showLocalNotification
  /// for FCM foreground pushes) — previously each path re-implemented its own
  /// (incomplete) subset of this, which is exactly how the master-toggle gap
  /// above went unnoticed: one path had the check, the other didn't.
  ///
  /// CRITICAL-priority notifications bypass quiet hours and the daily cap —
  /// on a device that tracks tremor and eating behaviour, a genuine health
  /// alert must not be silenced by "it's after 10pm" or "you already got 5
  /// notifications today". This mirrors how OS-level Do Not Disturb / Focus
  /// modes let time-sensitive alerts through rather than muting everything.
  Future<bool> _shouldShow(String channelId, String priority) async {
    final prefs = await SharedPreferences.getInstance();
    if (!(prefs.getBool(_prefKeyEnabled) ?? true)) return false;

    final categoryKey = switch (channelId) {
      'health_alerts' || 'eating_alerts' => _prefKeyHealth,
      'achievements' => _prefKeyAchievement,
      'engagement' => _prefKeyEngagement,
      'system_alerts' => _prefKeySystem,
      // daily_summary and anything unmapped: no per-category toggle exists
      // for it, so only the master switch above gates it.
      _ => null,
    };
    if (categoryKey != null && !(prefs.getBool(categoryKey) ?? true)) {
      return false;
    }

    if (priority == 'CRITICAL') return true;

    final start = prefs.getString(_prefKeyQuietStart) ?? '22:00';
    final end = prefs.getString(_prefKeyQuietEnd) ?? '07:00';
    if (_isWithinQuietHours(start, end)) return false;

    final maxDaily = prefs.getInt(_prefKeyMaxDaily) ?? 5;
    if (maxDaily > 0 && await _todayCount(prefs) >= maxDaily) return false;

    return true;
  }

  /// True when the current local time falls in [start, end), handling the
  /// overnight case (e.g. 22:00–07:00) where start > end and the window
  /// wraps past midnight. A zero-length window (start == end) is treated as
  /// "quiet hours disabled" rather than "always quiet" — the reasonable
  /// reading of a user never having set a real range.
  bool _isWithinQuietHours(String start, String end) {
    final s = _parseMinutesOfDay(start);
    final e = _parseMinutesOfDay(end);
    if (s == null || e == null || s == e) return false;

    final now = DateTime.now();
    final nowMin = now.hour * 60 + now.minute;

    if (s < e) return nowMin >= s && nowMin < e;
    return nowMin >= s || nowMin < e; // overnight wraparound
  }

  int? _parseMinutesOfDay(String hhmm) {
    final parts = hhmm.split(':');
    if (parts.length != 2) return null;
    final h = int.tryParse(parts[0]);
    final m = int.tryParse(parts[1]);
    if (h == null || m == null) return null;
    return h * 60 + m;
  }

  /// Notifications shown so far today, per the device's local calendar day.
  /// A stale stored date (yesterday or earlier) reads as 0 — the counter
  /// resets itself on first use each day rather than needing a scheduled job.
  Future<int> _todayCount(SharedPreferences prefs) async {
    if (prefs.getString(_prefKeyDailyCountDate) != _todayDateKey()) return 0;
    return prefs.getInt(_prefKeyDailyCount) ?? 0;
  }

  Future<void> _incrementDailyCount() async {
    final prefs = await SharedPreferences.getInstance();
    final today = _todayDateKey();
    final current = prefs.getString(_prefKeyDailyCountDate) == today
        ? (prefs.getInt(_prefKeyDailyCount) ?? 0)
        : 0;
    await prefs.setString(_prefKeyDailyCountDate, today);
    await prefs.setInt(_prefKeyDailyCount, current + 1);
  }

  String _todayDateKey() {
    final now = DateTime.now();
    return '${now.year}-${now.month}-${now.day}';
  }

  /// Explicitly show a local alert from any service
  Future<void> showLocalAlert({
    required String title,
    required String body,
    String type = 'default',
    String priority = 'DEFAULT',
    Map<String, dynamic>? data,
  }) async {
    if (!_initialized) await initialize();

    final channelId = _getChannelId(type);
    if (!await _shouldShow(channelId, priority)) return;

    final isHigh = priority == 'CRITICAL' || priority == 'HIGH';

    final AndroidNotificationDetails androidDetails = _androidDetails(
      channelId,
      isHigh: isHigh,
      playSound: isHigh,
    );

    const DarwinNotificationDetails iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
    );

    final NotificationDetails details = NotificationDetails(
      android: androidDetails,
      iOS: iosDetails,
    );

    // Use microsecond-based ID to avoid collisions
    final id = DateTime.now().microsecondsSinceEpoch % 2147483647;

    await _localNotifications.show(
      id,
      title,
      body,
      details,
      payload: data != null ? jsonEncode(data) : null,
    );
    unawaited(_incrementDailyCount());
  }

  /// Show a random test notification with app logo (for testing the bell button)
  Future<void> showTestNotification() async {
    final messages = [
      ('i-Spoon', 'Your data has been synced successfully! 🥄'),
      ('Eating Reminder', 'Time for your next meal check-in!'),
      ('Great Job!', 'You\'ve completed your daily bite goal today.'),
      ('Health Tip', 'Eating slowly helps digestion — keep it up!'),
      ('i-Spoon', 'Your spoon is ready to track your next meal.'),
    ];
    final pick = messages[DateTime.now().second % messages.length];
    await showLocalAlert(
      title: pick.$1,
      body: pick.$2,
      type: 'system_alerts',
      priority: 'HIGH',
    );
  }

  /// Handle notification tap (from background/terminated state)
  void _handleNotificationTap(RemoteMessage message) {
    if (kDebugMode) print('Notification tapped: ${message.messageId}');

    final notificationId = int.tryParse(message.data['notification_id'] ?? '');
    if (notificationId != null) {
      markNotificationOpened(notificationId);
    }

    // Navigate based on action_type
    final actionType = message.data['action_type'];
    if (actionType != null && actionType.isNotEmpty) {
      _navigateToScreen(actionType, message.data['action_data']);

      if (notificationId != null) {
        markNotificationActionTaken(notificationId);
      }
    }
  }

  /// Handle local notification tap
  void _handleLocalNotificationTap(NotificationResponse response) {
    // Handle daily summary action buttons
    if (response.actionId == 'view_insights' ||
        response.payload == 'open_insights') {
      _openHomeTab(1);
      return;
    }
    if (response.payload == 'open_home') {
      _openHomeTab(0);
      return;
    }
    if (response.actionId == 'dismiss') return;

    if (response.payload == null) return;

    try {
      final data = jsonDecode(response.payload!);
      final notificationId = int.tryParse(
        data['notification_id']?.toString() ?? '',
      );
      final actionType = data['action_type'];

      if (notificationId != null) {
        markNotificationOpened(notificationId);
      }

      if (actionType != null && actionType.isNotEmpty) {
        _navigateToScreen(actionType, data['action_data']);

        if (notificationId != null) {
          markNotificationActionTaken(notificationId);
        }
      }
    } catch (e) {
      if (kDebugMode) print('Error handling local notification tap: $e');
    }
  }

  /// Open the main shell on a specific bottom-nav tab (no named routes needed).
  void _openHomeTab(int index) {
    final context = navigatorKey.currentContext;
    if (context == null || !context.mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => HomePage(initialIndex: index)),
      (route) => false,
    );
  }

  /// Navigate to appropriate screen based on action type
  void _navigateToScreen(String actionType, dynamic actionData) {
    if (kDebugMode) print('Navigate to: $actionType with data: $actionData');

    switch (actionType) {
      case 'open_insights':
      case 'view_insights':
        _openHomeTab(1);
        break;
      case 'open_home':
        _openHomeTab(0);
        break;
      case 'open_profile':
        _openHomeTab(2);
        break;
      case 'open_tremor_analysis':
      case 'open_temperature':
        // Insights tab hosts tremor/temperature analysis.
        _openHomeTab(1);
        break;
      default:
        if (kDebugMode) print('Unknown action type: $actionType');
    }
  }

  /// Get channel ID based on notification type
  String _getChannelId(String type) {
    final normalized = type.toLowerCase().trim();

    // Exact known types first so "system_alerts" is not swallowed by "alert".
    switch (normalized) {
      case 'system_alerts':
      case 'battery':
      case 'sync':
      case 'firmware':
        return 'system_alerts';
      case 'health_alerts':
      case 'eating_alerts':
      case 'spike':
      case 'temperature':
        return 'health_alerts';
      case 'achievements':
      case 'goal':
      case 'streak':
      case 'best':
        return 'achievements';
      case 'engagement':
      case 'reminder':
      case 'insight':
      case 'inactive':
      case 'funny_reminders':
        return 'engagement';
      case 'daily_summary':
        return 'daily_summary';
    }

    if (normalized.contains('system') ||
        normalized.contains('battery') ||
        normalized.contains('sync') ||
        normalized.contains('firmware')) {
      return 'system_alerts';
    }
    if (normalized.contains('goal') ||
        normalized.contains('streak') ||
        normalized.contains('best') ||
        normalized.contains('achievement')) {
      return 'achievements';
    }
    if (normalized.contains('reminder') ||
        normalized.contains('insight') ||
        normalized.contains('inactive') ||
        normalized.contains('funny')) {
      return 'engagement';
    }
    if (normalized.contains('health') ||
        normalized.contains('spike') ||
        normalized.contains('temperature') ||
        normalized.contains('eating')) {
      return 'health_alerts';
    }
    // Prefer a channel that is always created on Android 8+.
    return 'system_alerts';
  }

  /// Get channel name
  String _getChannelName(String channelId) {
    switch (channelId) {
      case 'health_alerts':
        return 'Health Alerts';
      case 'achievements':
        return 'Achievements';
      case 'engagement':
        return 'Reminders';
      case 'system_alerts':
        return 'System Alerts';
      default:
        return 'Notifications';
    }
  }

  /// Mark notification as opened (API call)
  Future<void> markNotificationOpened(int notificationId) async {
    try {
      final authToken = await AuthService.getValidToken();
      if (authToken == null) return;

      final url = Uri.parse('$_baseUrl/notifications/$notificationId/opened');
      final response = await http
          .post(url, headers: {'Authorization': 'Bearer $authToken'})
          .timeout(const Duration(seconds: 10));

      if (response.statusCode >= 200 && response.statusCode < 300) {
        if (kDebugMode) {
          print('✅ Notification $notificationId marked as opened');
        }
      }
    } catch (e) {
      if (kDebugMode) print('❌ Error marking notification opened: $e');
    }
  }

  /// Mark notification action taken (API call)
  Future<void> markNotificationActionTaken(int notificationId) async {
    try {
      final authToken = await AuthService.getValidToken();
      if (authToken == null) return;

      final url = Uri.parse('$_baseUrl/notifications/$notificationId/action');
      final response = await http
          .post(url, headers: {'Authorization': 'Bearer $authToken'})
          .timeout(const Duration(seconds: 10));

      if (response.statusCode >= 200 && response.statusCode < 300) {
        if (kDebugMode) print('✅ Notification $notificationId action recorded');
      }
    } catch (e) {
      if (kDebugMode) print('❌ Error marking notification action: $e');
    }
  }

  /// Get FCM token
  String? get fcmToken => _fcmToken;

  /// Show an expandable inbox-style daily summary notification.
  /// [stats] keys: total_bites, goal_bites, breakfast, lunch, dinner, snack,
  ///               movement_level ('No rhythm'/'Some'/'More'/'Not measured'),
  ///               avg_temp_c
  Future<void> showDailySummary(Map<String, dynamic> stats) async {
    if (!_initialized) await initialize();

    final totalBites = stats['total_bites'] as int? ?? 0;
    final goalBites = stats['goal_bites'] as int? ?? 50;
    final goalReached = totalBites >= goalBites;
    final movementLevel =
        stats['movement_level'] as String? ??
        stats['tremor_level'] as String? ??
        'Not measured';
    final avgTempC = (stats['avg_temp_c'] as num?)?.toDouble();
    final avgTemp = avgTempC != null ? formatSpoonTempC(avgTempC) : '--';

    final movementEmoji =
        movementLevel == 'No rhythm' ||
            movementLevel == 'Steady' ||
            movementLevel == 'Low'
        ? '🟢'
        : movementLevel == 'Some' || movementLevel == 'Moderate'
        ? '🟡'
        : movementLevel == 'More' || movementLevel == 'High'
        ? '🔴'
        : '⚪';
    final goalEmoji = goalReached ? '✅' : '⭕';

    final lines = [
      '$goalEmoji $totalBites / $goalBites bites${goalReached ? ' — Goal reached!' : ''}',
      if ((stats['breakfast'] as int? ?? 0) > 0)
        '🌅 Breakfast   ${stats['breakfast']} bites',
      if ((stats['lunch'] as int? ?? 0) > 0)
        '☀️  Lunch       ${stats['lunch']} bites',
      if ((stats['dinner'] as int? ?? 0) > 0)
        '🌙 Dinner      ${stats['dinner']} bites',
      if ((stats['snack'] as int? ?? 0) > 0)
        '🍎 Snack       ${stats['snack']} bites',
      '$movementEmoji Repeated movement  $movementLevel',
      '🌡️ Avg temp    $avgTemp°C',
    ];

    final AndroidNotificationDetails androidDetails =
        AndroidNotificationDetails(
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
          actions: const [
            AndroidNotificationAction(
              'view_insights',
              'View Details',
              showsUserInterface: true,
            ),
            AndroidNotificationAction('dismiss', 'Dismiss'),
          ],
        );

    const DarwinNotificationDetails iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: false,
      presentSound: false,
      subtitle: 'Tap to view your full report',
    );

    await _localNotifications.show(
      850, // fixed ID — daily summary (funny reminders use 1000+)
      goalReached ? '🎯 Goal Reached Today!' : '📊 Daily Summary',
      '$totalBites bites • Movement: $movementLevel • Temp: $avgTemp°C',
      NotificationDetails(android: androidDetails, iOS: iosDetails),
      payload: 'open_insights',
    );
  }
}
