/// Notifications feature barrel export
///
/// Import this file to access all notification-related functionality
library;

// Domain layer
export 'domain/models/notification_models.dart';
export 'domain/services/notification_service.dart';
export 'domain/services/in_app_alert_service.dart';
export 'domain/services/smart_reminder_service.dart';

// Application layer (providers / controllers)
export 'application/notification_provider.dart';

// Presentation layer
export 'presentation/screens/notification_screen.dart';
