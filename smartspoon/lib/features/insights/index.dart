/// Insights feature barrel export
///
/// Import this file to access all insights-related functionality
library;

// Domain layer
export 'domain/domain.dart';
export 'domain/models.dart';
export 'domain/insights_repository.dart';

// Infrastructure layer
export 'infrastructure/live_insights_repository.dart';

// Application layer
export 'application/insights_controller.dart';

// Presentation layer
export 'presentation/screens/insights_dashboard.dart';
export 'presentation/screens/bite_history_page.dart';
export 'presentation/screens/tremor_history_page.dart';

export 'presentation/screens/heater_control_page.dart';
export 'presentation/screens/meals_analysis_page.dart';

// Widgets
export 'presentation/widgets/daily_food_timeline.dart';
export 'presentation/widgets/recommendations.dart';
export 'presentation/widgets/summary_cards.dart';
export 'presentation/widgets/temperature_section.dart';
export 'presentation/widgets/tremor_charts.dart';

// Analytics redesign
export 'presentation/widgets/analytics_widgets.dart';
