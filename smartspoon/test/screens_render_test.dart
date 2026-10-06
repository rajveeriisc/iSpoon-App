import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_core_platform_interface/test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:smartspoon/core/providers/theme_provider.dart';
import 'package:smartspoon/features/auth/application/user_provider.dart';
import 'package:smartspoon/features/notifications/domain/services/in_app_alert_service.dart';
import 'package:smartspoon/features/devices/index.dart';
import 'package:smartspoon/features/insights/domain/services/unified_data_service.dart';
import 'package:smartspoon/features/insights/infrastructure/live_insights_repository.dart';
import 'package:smartspoon/features/insights/application/insights_controller.dart';
import 'package:smartspoon/features/notifications/application/notification_provider.dart';
import 'package:smartspoon/features/home/presentation/screens/home_page.dart';

void main() {
  // These screens reach FirebaseAuth for the signed-in user id. Without a
  // Firebase app the very first widget that asks throws, and the test reports
  // a rendering failure that has nothing to do with rendering.
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    setupFirebaseCoreMocks();
    await Firebase.initializeApp();
  });

  testWidgets('HomePage renders all 4 tabs without exceptions', (WidgetTester tester) async {
    final runtime = SpoonRuntime();
    final tremorService = TremorDetectionService(runtime.sensorBatchStream);
    final dataService = UnifiedDataService(
      runtime: runtime,
      tremorService: tremorService,
    );
    final repo = LiveInsightsRepository(dataService);
    final controller = InsightsController(repo);
    dataService.insightsController = controller;
    controller.setUnifiedDataService(dataService);


    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider(create: (_) => ThemeProvider()),
          ChangeNotifierProvider(create: (_) => UserProvider()),
          ChangeNotifierProvider(create: (_) => InAppAlertService()),
          ChangeNotifierProvider.value(value: runtime),
          ChangeNotifierProvider.value(value: tremorService),
          ChangeNotifierProvider.value(value: dataService),
          Provider.value(value: repo),
          ChangeNotifierProvider.value(value: controller),
          ChangeNotifierProvider(create: (_) => NotificationProvider()),
        ],
        child: const MaterialApp(
          home: HomePage(initialIndex: 0),
        ),
      ),
    );

    // Initial pump
    await tester.pump();
    debugPrint('Tab 0 (Home) pumped');

    // Switch to Tab 1 (Insights)
    await tester.tap(find.text('Insights'));
    await tester.pump();
    debugPrint('Tab 1 (Insights) pumped');

    // Switch to Tab 2 (Mealsense, formerly 'AI Lab')
    await tester.tap(find.text('Mealsense'));
    await tester.pump();
    debugPrint('Tab 2 (Mealsense) pumped');

    // Switch to Tab 3 (Profile)
    await tester.tap(find.text('Profile'));
    await tester.pump();
    debugPrint('Tab 3 (Profile) pumped');

    // Unmount first, then dispose the services the tree does not own (they are
    // passed in with .value). This has to happen INSIDE the test body: the
    // binding asserts no timer is still pending at the end of the body, which
    // is before addTearDown callbacks run.
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
    repo.dispose();
    dataService.dispose();
    tremorService.dispose();
    runtime.dispose();
  });
}
