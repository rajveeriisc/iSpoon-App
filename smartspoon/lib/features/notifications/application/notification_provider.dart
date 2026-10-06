// notification_provider.dart — state + backend sync for the notifications inbox.
//
// A ChangeNotifier that fetches the user's notification list and preferences
// from the backend, exposes loading/error state and an unreadCount (used by the
// header bell badge), and performs actions like mark-as-read and updating
// notification preferences. Feeds the notifications screen and the header.
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:smartspoon/core/config/app_config.dart';
import '../../auth/domain/services/auth_service.dart';
import '../domain/models/notification_models.dart';
import '../domain/services/notification_service.dart';
import '../domain/services/smart_reminder_service.dart';

class NotificationProvider with ChangeNotifier {
  List<NotificationModel> _notifications = [];
  NotificationPreferences? _preferences;
  bool _loading = false;
  String? _error;

  List<NotificationModel> get notifications => _notifications;
  NotificationPreferences? get preferences => _preferences;
  bool get loading => _loading;
  String? get error => _error;
  int get unreadCount => _notifications.where((n) => n.isUnread).length;

  String get _baseUrl {
    try {
      return AppConfig.apiBaseUrl;
    } catch (_) {
      return '';
    }
  }

  /// Initialize notification provider
  Future<void> initialize() async {
    // Defer network operations past the initial build frame to prevent
    // calling notifyListeners() while the widget tree is constructing.
    await Future.delayed(Duration.zero);
    try {
      await NotificationService().initialize();
      await fetchPreferences();
      await fetchNotifications();
    } catch (e) {
      if (kDebugMode) print('NotificationProvider initialization error: $e');
    }
  }

  /// Fetch notification preferences
  Future<void> fetchPreferences() async {
    try {
      _loading = true;
      _error = null;
      notifyListeners();

      final authToken = await AuthService.getValidToken();
      if (authToken == null) {
        _error = 'Not authenticated';
        _loading = false;
        notifyListeners();
        return;
      }

      final response = await http.get(
        Uri.parse('$_baseUrl/notifications/preferences'),
        headers: {'Authorization': 'Bearer $authToken'},
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        _preferences = NotificationPreferences.fromJson(data['preferences']);
        await _cacheLocally(_preferences!);
        _error = null;
      } else {
        _error = 'Failed to load preferences';
      }
    } catch (e) {
      _error = e.toString();
      if (kDebugMode) print('Error fetching preferences: $e');
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  /// Push the fetched/updated preferences into NotificationService's local
  /// cache so it can gate a notification without a network round-trip. Without
  /// this, per-category toggles/quiet hours/daily cap only ever lived in this
  /// provider's in-memory _preferences — invisible to NotificationService,
  /// which is a separate singleton this provider holds no reference to and
  /// which is what actually decides whether a notification gets shown.
  Future<void> _cacheLocally(NotificationPreferences prefs) async {
    await NotificationService().cachePreferences(
      enabled: prefs.enabled,
      healthAlertsEnabled: prefs.healthAlertsEnabled,
      achievementEnabled: prefs.achievementEnabled,
      engagementEnabled: prefs.engagementEnabled,
      systemAlertsEnabled: prefs.systemAlertsEnabled,
      quietHoursStart: prefs.quietHoursStart,
      quietHoursEnd: prefs.quietHoursEnd,
      maxDailyNotifications: prefs.maxDailyNotifications,
      weeklyDigestEnabled: prefs.weeklyDigestEnabled,
      weeklyDigestDay: prefs.weeklyDigestDay,
      weeklyDigestTime: prefs.weeklyDigestTime,
    );
    // Re-apply to already-scheduled OS alarms immediately — see the note atop
    // smart_reminder_service.dart for why a runtime gate alone can't cover
    // zonedSchedule'd reminders.
    await SmartReminderService().applyPreferences();
  }

  /// Update notification preferences
  Future<bool> updatePreferences(
    NotificationPreferences updatedPreferences,
  ) async {
    try {
      _loading = true;
      notifyListeners();

      final authToken = await AuthService.getValidToken();
      if (authToken == null) return false;

      final response = await http.put(
        Uri.parse('$_baseUrl/notifications/preferences'),
        headers: {
          'Authorization': 'Bearer $authToken',
          'Content-Type': 'application/json',
        },
        body: jsonEncode(updatedPreferences.toJson()),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        _preferences = NotificationPreferences.fromJson(data['preferences']);
        await _cacheLocally(_preferences!);
        _error = null;
        _loading = false;
        notifyListeners();
        return true;
      } else {
        _error = 'Failed to update preferences';
        _loading = false;
        notifyListeners();
        return false;
      }
    } catch (e) {
      _error = e.toString();
      _loading = false;
      notifyListeners();
      if (kDebugMode) print('Error updating preferences: $e');
      return false;
    }
  }

  /// Fetch notification history (falls back to local test data when backend unavailable)
  Future<void> fetchNotifications({int limit = 50, int offset = 0}) async {
    try {
      _loading = true;
      if (offset == 0) _error = null;
      notifyListeners();

      final authToken = await AuthService.getValidToken();
      if (authToken == null) {
        if (offset == 0) {
          _notifications = [];
          _error = null;
        }
        _loading = false;
        notifyListeners();
        return;
      }

      final response = await http
          .get(
            Uri.parse(
              '$_baseUrl/notifications/history?limit=$limit&offset=$offset',
            ),
            headers: {'Authorization': 'Bearer $authToken'},
          )
          .timeout(const Duration(seconds: 8));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final List<dynamic> notificationsJson = data['notifications'] ?? [];

        final fetched = notificationsJson
            .map((json) => NotificationModel.fromJson(json))
            .toList();

        if (offset == 0) {
          _notifications = fetched;
        } else {
          _notifications.addAll(fetched);
        }
        _error = null;
      } else {
        if (offset == 0 && _notifications.isEmpty) {
          _notifications = [];
        }
        _error = 'Failed to load notifications';
      }
    } catch (e) {
      if (kDebugMode) print('Error fetching notifications: $e');
      if (offset == 0 && _notifications.isEmpty) {
        _notifications = [];
      }
      _error = 'Failed to load notifications';
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  /// Trigger a real OS push notification and add it to the in-app list
  Future<void> sendTestNotification() async {
    await NotificationService().showTestNotification();

    // Also add it to the in-app list immediately
    final messages = [
      ('i-Spoon', 'Your data has been synced successfully!'),
      ('Eating Reminder', 'Time for your next meal check-in!'),
      ('Great Job!', 'You\'ve completed your daily bite goal today.'),
      ('Health Tip', 'Eating slowly helps digestion — keep it up!'),
    ];
    final pick = messages[DateTime.now().second % messages.length];
    final newNotif = NotificationModel(
      id: -(DateTime.now().millisecondsSinceEpoch % 100000 + 10),
      type: 'system_alerts',
      priority: 'HIGH',
      title: pick.$1,
      body: pick.$2,
      createdAt: DateTime.now(),
      deliveryStatus: 'delivered',
    );
    _notifications = [newNotif, ..._notifications];
    notifyListeners();
  }

  /// Mark notification as read locally (optimistic update)
  Future<void> markAsRead(int notificationId) async {
    final index = _notifications.indexWhere((n) => n.id == notificationId);
    if (index != -1) {
      _notifications[index] = _notifications[index].copyWith(
        openedAt: DateTime.now(),
      );
      notifyListeners();
      if (notificationId > 0) {
        await NotificationService().markNotificationOpened(notificationId);
      }
    }
  }

  /// Toggle preference category
  Future<void> toggleCategory(String category, bool enabled) async {
    if (_preferences == null) return;

    NotificationPreferences updated;
    switch (category) {
      case 'health':
        updated = _preferences!.copyWith(healthAlertsEnabled: enabled);
        break;
      case 'achievement':
        updated = _preferences!.copyWith(achievementEnabled: enabled);
        break;
      case 'engagement':
        updated = _preferences!.copyWith(engagementEnabled: enabled);
        break;
      case 'system':
        updated = _preferences!.copyWith(systemAlertsEnabled: enabled);
        break;
      default:
        return;
    }

    await updatePreferences(updated);
  }

  /// Toggle all notifications
  Future<void> toggleAllNotifications(bool enabled) async {
    if (_preferences == null) return;
    final updated = _preferences!.copyWith(enabled: enabled);
    await NotificationService().setEnabled(enabled);
    await updatePreferences(updated);
  }

  /// Update quiet hours
  Future<void> updateQuietHours(String start, String end) async {
    if (_preferences == null) return;
    final updated = _preferences!.copyWith(
      quietHoursStart: start,
      quietHoursEnd: end,
    );
    await updatePreferences(updated);
  }

  /// Clear error
  void clearError() {
    _error = null;
    notifyListeners();
  }
}
