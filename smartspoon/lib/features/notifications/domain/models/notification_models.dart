// notification_models.dart — data models for the notifications feature.
//
// Plain data classes (de)serialized from the backend: NotificationModel (a
// single notification — id, type, priority, title/body, optional action + data,
// timestamps, delivery status, and an isUnread helper) and NotificationPreferences
// (the user's per-category opt-in settings). No logic beyond JSON mapping.
class NotificationModel {
  final int id;
  final String type;
  final String priority;
  final String title;
  final String body;
  final String? actionType;
  final Map<String, dynamic>? actionData;
  final DateTime createdAt;
  final DateTime? openedAt;
  final DateTime? actionTakenAt;
  final String deliveryStatus;

  NotificationModel({
    required this.id,
    required this.type,
    required this.priority,
    required this.title,
    required this.body,
    this.actionType,
    this.actionData,
    required this.createdAt,
    this.openedAt,
    this.actionTakenAt,
    required this.deliveryStatus,
  });

  factory NotificationModel.fromJson(Map<String, dynamic> json) {
    final createdAt = DateTime.parse(json['created_at'].toString());
    final openedAt = json['opened_at'] != null
        ? DateTime.tryParse(json['opened_at'].toString())
        : (json['read'] == true ? createdAt : null);
    final rawId = json['id'];
    final id = rawId is num
        ? rawId.toInt()
        : int.tryParse(rawId?.toString() ?? '');
    if (id == null) throw const FormatException('Invalid notification id');

    final rawActionData = json['action_data'] ?? json['data'];
    return NotificationModel(
      id: id,
      type: json['type'] as String? ?? 'system_alerts',
      priority: json['priority'] as String? ?? 'DEFAULT',
      title: json['title'] as String? ?? '',
      body: json['body'] as String? ?? '',
      actionType: json['action_type'] as String?,
      actionData: rawActionData is Map
          ? Map<String, dynamic>.from(rawActionData)
          : null,
      createdAt: createdAt,
      openedAt: openedAt,
      actionTakenAt: json['action_taken_at'] != null
          ? DateTime.tryParse(json['action_taken_at'].toString())
          : null,
      deliveryStatus: json['delivery_status'] as String? ?? 'delivered',
    );
  }

  bool get isUnread => openedAt == null;
  bool get isActionTaken => actionTakenAt != null;

  NotificationModel copyWith({
    int? id,
    String? type,
    String? priority,
    String? title,
    String? body,
    String? actionType,
    Map<String, dynamic>? actionData,
    DateTime? createdAt,
    DateTime? openedAt,
    DateTime? actionTakenAt,
    String? deliveryStatus,
  }) {
    return NotificationModel(
      id: id ?? this.id,
      type: type ?? this.type,
      priority: priority ?? this.priority,
      title: title ?? this.title,
      body: body ?? this.body,
      actionType: actionType ?? this.actionType,
      actionData: actionData ?? this.actionData,
      createdAt: createdAt ?? this.createdAt,
      openedAt: openedAt ?? this.openedAt,
      actionTakenAt: actionTakenAt ?? this.actionTakenAt,
      deliveryStatus: deliveryStatus ?? this.deliveryStatus,
    );
  }
}

class NotificationPreferences {
  final bool enabled;
  final String quietHoursStart;
  final String quietHoursEnd;
  final bool healthAlertsEnabled;
  final bool achievementEnabled;
  final bool engagementEnabled;
  final bool systemAlertsEnabled;
  final int maxDailyNotifications;
  final bool weeklyDigestEnabled;
  final int weeklyDigestDay;
  final String weeklyDigestTime;

  NotificationPreferences({
    required this.enabled,
    required this.quietHoursStart,
    required this.quietHoursEnd,
    required this.healthAlertsEnabled,
    required this.achievementEnabled,
    required this.engagementEnabled,
    required this.systemAlertsEnabled,
    required this.maxDailyNotifications,
    required this.weeklyDigestEnabled,
    required this.weeklyDigestDay,
    required this.weeklyDigestTime,
  });

  factory NotificationPreferences.fromJson(Map<String, dynamic> json) {
    return NotificationPreferences(
      enabled: json['enabled'] ?? true,
      quietHoursStart: json['quiet_hours_start'] ?? '22:00',
      quietHoursEnd: json['quiet_hours_end'] ?? '07:00',
      healthAlertsEnabled: json['health_alerts_enabled'] ?? true,
      achievementEnabled: json['achievement_enabled'] ?? true,
      engagementEnabled: json['engagement_enabled'] ?? true,
      systemAlertsEnabled: json['system_alerts_enabled'] ?? true,
      maxDailyNotifications: json['max_daily_notifications'] ?? 5,
      weeklyDigestEnabled: json['weekly_digest_enabled'] ?? true,
      weeklyDigestDay: json['weekly_digest_day'] ?? 0,
      weeklyDigestTime: json['weekly_digest_time'] ?? '20:00',
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'enabled': enabled,
      'quiet_hours_start': quietHoursStart,
      'quiet_hours_end': quietHoursEnd,
      'health_alerts_enabled': healthAlertsEnabled,
      'achievement_enabled': achievementEnabled,
      'engagement_enabled': engagementEnabled,
      'system_alerts_enabled': systemAlertsEnabled,
      'max_daily_notifications': maxDailyNotifications,
      'weekly_digest_enabled': weeklyDigestEnabled,
      'weekly_digest_day': weeklyDigestDay,
      'weekly_digest_time': weeklyDigestTime,
    };
  }

  NotificationPreferences copyWith({
    bool? enabled,
    String? quietHoursStart,
    String? quietHoursEnd,
    bool? healthAlertsEnabled,
    bool? achievementEnabled,
    bool? engagementEnabled,
    bool? systemAlertsEnabled,
    int? maxDailyNotifications,
    bool? weeklyDigestEnabled,
    int? weeklyDigestDay,
    String? weeklyDigestTime,
  }) {
    return NotificationPreferences(
      enabled: enabled ?? this.enabled,
      quietHoursStart: quietHoursStart ?? this.quietHoursStart,
      quietHoursEnd: quietHoursEnd ?? this.quietHoursEnd,
      healthAlertsEnabled: healthAlertsEnabled ?? this.healthAlertsEnabled,
      achievementEnabled: achievementEnabled ?? this.achievementEnabled,
      engagementEnabled: engagementEnabled ?? this.engagementEnabled,
      systemAlertsEnabled: systemAlertsEnabled ?? this.systemAlertsEnabled,
      maxDailyNotifications:
          maxDailyNotifications ?? this.maxDailyNotifications,
      weeklyDigestEnabled: weeklyDigestEnabled ?? this.weeklyDigestEnabled,
      weeklyDigestDay: weeklyDigestDay ?? this.weeklyDigestDay,
      weeklyDigestTime: weeklyDigestTime ?? this.weeklyDigestTime,
    );
  }
}
