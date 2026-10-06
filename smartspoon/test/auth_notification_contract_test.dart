import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:smartspoon/features/auth/domain/services/auth_service.dart';
import 'package:smartspoon/features/notifications/domain/models/notification_models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('authentication refresh policy', () {
    test('refreshes a 15 minute token two minutes before expiry', () {
      final now = DateTime.utc(2026, 7, 20, 12);
      final expiry = now.add(const Duration(minutes: 15));

      expect(
        AuthService.tokenRefreshDelay(now, expiry),
        const Duration(minutes: 13),
      );
    });

    test(
      'refreshes short-lived and expired tokens without a negative timer',
      () {
        final now = DateTime.utc(2026, 7, 20, 12);

        expect(
          AuthService.tokenRefreshDelay(
            now,
            now.add(const Duration(seconds: 90)),
          ),
          const Duration(seconds: 30),
        );
        expect(
          AuthService.tokenRefreshDelay(
            now,
            now.subtract(const Duration(seconds: 1)),
          ),
          Duration.zero,
        );
      },
    );
  });

  group('notification API contract', () {
    test('parses PostgreSQL bigint IDs and legacy read/data fields', () {
      final notification = NotificationModel.fromJson({
        'id': '42',
        'title': 'Meal reminder',
        'body': 'Time to eat',
        'type': 'engagement',
        'priority': 'DEFAULT',
        'read': true,
        'data': {'meal_uuid': 'meal-1'},
        'created_at': '2026-07-20T12:00:00.000Z',
      });

      expect(notification.id, 42);
      expect(notification.isUnread, isFalse);
      expect(notification.actionData, {'meal_uuid': 'meal-1'});
      expect(notification.deliveryStatus, 'delivered');
    });

    test('serializes every backend preference field', () {
      final json = NotificationPreferences(
        enabled: true,
        quietHoursStart: '22:00',
        quietHoursEnd: '07:00',
        healthAlertsEnabled: true,
        achievementEnabled: true,
        engagementEnabled: true,
        systemAlertsEnabled: true,
        maxDailyNotifications: 5,
        weeklyDigestEnabled: true,
        weeklyDigestDay: 0,
        weeklyDigestTime: '20:00',
      ).toJson();

      expect(json.keys, {
        'enabled',
        'quiet_hours_start',
        'quiet_hours_end',
        'health_alerts_enabled',
        'achievement_enabled',
        'engagement_enabled',
        'system_alerts_enabled',
        'max_daily_notifications',
        'weekly_digest_enabled',
        'weekly_digest_day',
        'weekly_digest_time',
      });
    });

    test(
      'clears access and refresh session storage without recursion',
      () async {
        FlutterSecureStorage.setMockInitialValues({});
        SharedPreferences.setMockInitialValues({});

        await AuthService.saveToken('not-a-jwt');
        expect(await AuthService.getToken(), 'not-a-jwt');

        await AuthService.clearLocalTokens();
        expect(await AuthService.getToken(), isNull);
      },
    );
  });
}
