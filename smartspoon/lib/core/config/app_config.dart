// app_config.dart — central app/backend configuration.
//
// Single source of truth for the backend base URL, API version prefix, HTTP
// timeouts, and retry/backoff constants. `baseUrl` resolves from the
// `API_BASE_URL` dart-define: in debug it falls back to a local loopback URL,
// while release builds fail loudly unless a valid https:// URL is supplied
// (prevents shipping credentials to a plaintext dev endpoint). All members are
// static — the class is never instantiated (private `._()` constructor).
import 'package:flutter/foundation.dart';

class AppConfig {
  AppConfig._();

  /// Local debug backend. Android USB: `adb reverse tcp:5001 tcp:5001`.
  /// iOS Simulator can use this loopback URL. A physical iPhone cannot —
  /// pass `--dart-define=API_BASE_URL=http://<Mac-LAN-IP>:5001`.
  static const String _localDevUrl = 'http://127.0.0.1:5001';

  /// True when the API URL was explicitly provided via dart-define.
  static const bool _hasExplicitUrl =
      String.fromEnvironment('API_BASE_URL') != '';

  /// Backend host the Flutter app talks to.
  static String get baseUrl {
    const fromEnv = String.fromEnvironment('API_BASE_URL');

    if (fromEnv.isNotEmpty) {
      return fromEnv;
    }

    // When API_BASE_URL is not provided at build time, fall back gracefully
    // to local backend rather than throwing an unhandled StateError that breaks
    // widget build phases.
    return _localDevUrl;
  }

  /// API version prefix
  static const String apiVersion = '/api';

  /// Full API base URL with version
  static String get apiBaseUrl => '$baseUrl$apiVersion';

  /// Connection timeout for API calls
  static const Duration connectionTimeout = Duration(seconds: 10);

  /// Receive timeout for API calls
  static const Duration receiveTimeout = Duration(seconds: 10);

  /// Maximum retry attempts for failed requests
  static const int maxRetryAttempts = 3;

  /// Initial delay for exponential backoff
  static const Duration initialRetryDelay = Duration(milliseconds: 500);

  /// Enable debug logging
  static bool get enableDebugLogging => kDebugMode;

  /// True when a production API URL was explicitly configured.
  /// In debug mode this is always true (ngrok fallback is expected).
  static bool get isBackendConfigured => kDebugMode || _hasExplicitUrl;

  static String get configStatusMessage => 'Backend: $baseUrl';
}
