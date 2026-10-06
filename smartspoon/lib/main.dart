// main.dart — application entry point and dependency wiring.
//
// main() initializes Flutter bindings, Firebase, and background services
// (AppSetupService), then runs the app inside a MultiProvider that constructs
// and links the whole service graph: SpoonRuntime →
// TremorDetectionService → UnifiedDataService → LiveInsightsRepository →
// InsightsController, plus Theme/User/Notification/InAppAlert providers. MyApp
// builds MaterialApp (theme from ThemeProvider) and starts at AuthGate. Also
// owns the global navigatorKey used for notification-tap routing.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:flutter/foundation.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:smartspoon/core/core.dart';
import 'package:smartspoon/features/ai_lab/domain/services/ai_lab_service.dart';
import 'package:smartspoon/features/auth/index.dart';
import 'package:smartspoon/features/devices/index.dart';
import 'package:smartspoon/features/insights/index.dart';
import 'package:smartspoon/features/notifications/index.dart';
import 'package:smartspoon/core/services/security_service.dart';
import 'package:smartspoon/firebase_options.dart';
import 'package:smartspoon/core/config/app_config.dart';
import 'package:firebase_app_check/firebase_app_check.dart';

final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

Future<void> main() async {
  // Ensure Flutter is initialized
  WidgetsFlutterBinding.ensureInitialized();

  // Shout if this build has no backend URL. AppConfig.baseUrl falls back to
  // http://127.0.0.1:5001 when --dart-define=API_BASE_URL is missing, which on
  // a phone is loopback to the phone itself — every login, signup and sync
  // call fails with a connection error that looks like "the backend is down".
  // AppConfig.isBackendConfigured existed for exactly this and was never
  // referenced anywhere, so release APKs shipped silently pointed at nothing.
  if (!AppConfig.isBackendConfigured) {
    debugPrint('############################################################');
    debugPrint('## NO API_BASE_URL IN THIS BUILD.                         ##');
    debugPrint('## ${AppConfig.configStatusMessage}');
    debugPrint('## Rebuild with:                                          ##');
    debugPrint('##   flutter build apk --release \\                       ##');
    debugPrint('##     --dart-define=API_BASE_URL=https://<host>          ##');
    debugPrint('############################################################');
  }

  FlutterForegroundTask.initCommunicationPort();
  await FlutterBluePlus.setOptions(restoreState: true);

  // Initialize Firebase. The firebase_core plugin handles duplicate-init by
  // returning the existing app. On iOS the native SDK may configure [DEFAULT]
  // from GoogleService-Info.plist before Dart runs; calling initializeApp()
  // again is safe — the plugin detects the existing app and skips re-config.
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

  // ── Firebase App Check ────────────────────────────────────────────────────
  // Attests that requests come from THIS app on a genuine device. It is the
  // protection Google names for a setup like ours: the Firebase apiKey is a
  // public identifier (recoverable from any release APK), so nothing stops a
  // script from hitting the Auth endpoints with it. App Check is what makes
  // those requests provably come from the real app.
  //
  // DELIBERATELY NON-FATAL. App Check has to be turned on per-app in the
  // Firebase console (Play Integrity for Android, Device Check for iOS). Until
  // that is done, attestation fails — and a failure here must never stop the
  // app from starting. Shipping the client first and enforcing later is the
  // documented rollout order: clients populate the console's metrics, you
  // confirm real traffic is attesting, and only then switch enforcement on.
  //
  // A debug build on an emulator has no Play Integrity, hence the debug
  // provider; its token is printed to logcat and must be registered under
  // App Check > Manage debug tokens to be accepted.
  try {
    await FirebaseAppCheck.instance.activate(
      androidProvider:
          kDebugMode ? AndroidProvider.debug : AndroidProvider.playIntegrity,
      appleProvider:
          kDebugMode ? AppleProvider.debug : AppleProvider.deviceCheck,
    );
    debugPrint('[AppCheck] activated');
  } catch (e) {
    // Expected until App Check is enabled in the console. Not an error state.
    debugPrint('[AppCheck] not active ($e) — enable it in the Firebase console');
  }

  // Register background handler immediately after initialization for terminated state handling
  FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);

  // System bars are made transparent here; icon brightness is applied
  // per-theme via AnnotatedRegion in MyApp so dark mode gets light icons.
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      systemNavigationBarColor: Colors.transparent,
    ),
  );

  // Set preferred orientations
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);

  // Configure Google Fonts
  GoogleFonts.config.allowRuntimeFetching = true;

  // Set up global error handlers matching mobile-design constraints
  FlutterError.onError = (FlutterErrorDetails details) {
    FlutterError.presentError(details);
    debugPrint('Flutter Error: ${details.exception}');
  };

  ErrorWidget.builder = (FlutterErrorDetails details) {
    debugPrint('Widget build error caught by fallback: ${details.exception}');
    return const SizedBox.shrink();
  };

  PlatformDispatcher.instance.onError = (error, stack) {
    debugPrint('Platform Error: $error');
    return true; // Handled
  };

  _configureCacheManager();

  // Utilize the new setup service to avoid UI blocking (ANR prevention)
  AppSetupService.initializeBackgroundServices();

  // OLD app-side bite counter. The AI Lab model counts every bite the app
  // shows now, so running this too meant two different numbers.
  // ImuBiteDetectorService().startMonitoring();

  // AI Lab eating model: runs from launch so a meal started on another tab is
  // not missed; its results are shown only on the AI Lab page.
  unawaited(AiLabService().start());

  // Initialize RASP (Runtime Application Self-Protection)
  await SecurityService.initialize();

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => ThemeProvider()..loadTheme()),
        ChangeNotifierProvider(create: (_) => UserProvider()),
        ChangeNotifierProvider(create: (_) => InAppAlertService()),

        // 1. Single BLE authority (SpoonRuntime → ConnectionCoordinator)
        // .value, NOT create: — SpoonRuntime is an app-wide singleton that owns
        // the live GATT link, and `create:` makes Provider dispose it. Android
        // recreates the Activity for ordinary things (screen off, theme or
        // locale change, OEM housekeeping), and each recreation was therefore
        // tearing the spoon's connection down and building a brand-new
        // coordinator from generation zero — the app came back to a spoon it
        // had just disconnected, and sat on "connecting".
        //
        // The runtime's lifetime is the process; only the app decides when it
        // ends (see AppSetupService), so Provider must not own it.
        ChangeNotifierProvider<SpoonRuntime>.value(
          value: SpoonRuntime()..initialize(),
        ),

        ChangeNotifierProxyProvider<SpoonRuntime, TremorDetectionService>(
          create: (context) => TremorDetectionService(
            Provider.of<SpoonRuntime>(context, listen: false).sensorBatchStream,
          ),
          update: (_, runtime, previous) =>
              previous ?? TremorDetectionService(runtime.sensorBatchStream),
        ),

        ChangeNotifierProxyProvider2<
          SpoonRuntime,
          TremorDetectionService,
          UnifiedDataService
        >(
          create: (context) => UnifiedDataService(
            runtime: Provider.of<SpoonRuntime>(context, listen: false),
            tremorService: Provider.of<TremorDetectionService>(
              context,
              listen: false,
            ),
          ),
          update: (_, runtime, tremorService, previous) {
            return previous ??
                UnifiedDataService(
                  runtime: runtime,
                  tremorService: tremorService,
                );
          },
        ),

        // 3. Create Repository using UnifiedDataService
        ProxyProvider<UnifiedDataService, LiveInsightsRepository>(
          create: (context) => LiveInsightsRepository(
            Provider.of<UnifiedDataService>(context, listen: false),
          ),
          update: (_, dataService, previous) =>
              previous ?? LiveInsightsRepository(dataService),
          dispose: (_, repo) => repo.dispose(),
        ),

        // 4. Create InsightsController using Repository
        // Proxy update hook automatically injects the controller into the service, removing the hacky builder injection.
        ChangeNotifierProxyProvider2<
          LiveInsightsRepository,
          UnifiedDataService,
          InsightsController
        >(
          create: (context) => InsightsController(
            Provider.of<LiveInsightsRepository>(context, listen: false),
          )..init(),
          update: (_, repository, dataService, previous) {
            final controller = previous ?? InsightsController(repository);
            if (dataService.insightsController == null) {
              // safely establish the link
              dataService.insightsController = controller;
              controller.setUnifiedDataService(dataService);
            }
            return controller;
          },
        ),

        // 5. Notification Provider
        ChangeNotifierProvider(
          create: (_) => NotificationProvider()..initialize(),
        ),
      ],
      child: const MyApp(),
    ),
  );
}

/// Configure cache manager for optimal performance
void _configureCacheManager() {
  CachedNetworkImage.logLevel = CacheManagerLogLevel.warning;
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<ThemeProvider>(
      builder: (context, themeProvider, child) {
        return MaterialApp(
          debugShowCheckedModeBanner: false,
          title: 'i-Spoon',
          theme: AppTheme.lightTheme,
          darkTheme: AppTheme.darkTheme,
          themeMode: themeProvider.themeMode,
          scrollBehavior: AppScrollBehavior(),
          navigatorKey: navigatorKey,
          home: const AuthGate(),
          // Performance improvements
          builder: (context, child) {
            // Preserve user scaling while capping only the extreme range that
            // would make dense health charts unusable. Auth and navigation
            // layouts are responsive through this full supported range.
            final mediaQuery = MediaQuery.of(context);
            final constrainedTextScale = mediaQuery.textScaler.clamp(
              minScaleFactor: 0.8,
              maxScaleFactor: 1.6,
            );

            final isDark = Theme.of(context).brightness == Brightness.dark;
            return AnnotatedRegion<SystemUiOverlayStyle>(
              value: SystemUiOverlayStyle(
                statusBarColor: Colors.transparent,
                statusBarIconBrightness: isDark
                    ? Brightness.light
                    : Brightness.dark,
                statusBarBrightness: isDark
                    ? Brightness.dark
                    : Brightness.light,
                systemNavigationBarColor: Colors.transparent,
                systemNavigationBarIconBrightness: isDark
                    ? Brightness.light
                    : Brightness.dark,
              ),
              child: MediaQuery(
                data: mediaQuery.copyWith(textScaler: constrainedTextScale),
                child: child!,
              ),
            );
          },
        );
      },
    );
  }
}

class AppScrollBehavior extends MaterialScrollBehavior {
  @override
  Widget buildScrollbar(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) {
    return child;
  }
}
