// auth_service.dart — backend authentication + token/session manager.
//
// The bridge between Firebase Auth and the app's own REST backend. It exchanges
// a Firebase ID token for a backend JWT (verifyFirebaseToken), stores tokens
// securely (flutter_secure_storage), and exposes getValidToken() which decodes
// the JWT (via the private _JWTDecoder) and transparently refreshes it before
// expiry. Also handles registering the FCM push token, exposes baseUrl for
// building asset URLs, and clears all local state on sign-out. All HTTP goes
// through ResilientHttp.
import 'dart:convert';
import 'dart:async';
import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;
import 'package:http/http.dart' as http;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:smartspoon/core/config/app_config.dart';
import 'package:smartspoon/core/services/database_service.dart';
import 'package:smartspoon/core/services/sync_service.dart';
import 'package:smartspoon/core/services/resilient_http.dart';
import 'package:smartspoon/ble/spoon_runtime.dart';
import 'package:smartspoon/features/devices/domain/services/smart_spoon_ble_service.dart';

/// Simple JWT decoder for extracting token expiry
class _JWTDecoder {
  static Map<String, dynamic>? decodePayload(String token) {
    try {
      final parts = token.split('.');
      if (parts.length != 3) return null;

      // Decode the payload (second part)
      final payload = parts[1];
      // Add padding if needed for base64 decoding
      final normalized = base64.normalize(payload);
      final decoded = utf8.decode(base64.decode(normalized));
      return jsonDecode(decoded) as Map<String, dynamic>;
    } catch (e) {
      debugPrint('JWT decode error: $e');
      return null;
    }
  }

  static DateTime? getExpiry(String token) {
    final payload = decodePayload(token);
    if (payload == null) return null;

    final exp = payload['exp'];
    if (exp is int) {
      return DateTime.fromMillisecondsSinceEpoch(exp * 1000);
    }
    return null;
  }
}

class AuthService {
  AuthService._();

  static final FlutterSecureStorage _storage = const FlutterSecureStorage(
    aOptions: AndroidOptions(
      resetOnError: true, // auto-clears corrupted Keystore keys on reinstall
      storageNamespace: 'ispoon_secure_storage',
      preferencesKeyPrefix: 'ispoon_',
    ),
    iOptions: IOSOptions(
      accessibility: KeychainAccessibility.first_unlock_this_device,
    ),
  );

  static final Map<String, String?> _memoryStorage = <String, String?>{};
  // Never allow bearer tokens in SharedPreferences in release builds.
  static const bool _allowPlaintextAuthFallback = kDebugMode;

  static DateTime? _tokenExpiry;
  static Timer? _refreshTimer;

  static Future<void> _setItem(String key, String value) async {
    _memoryStorage[key] = value;

    // Plaintext fallback is debug/explicit-opt-in only. Release builds should
    // never duplicate bearer tokens outside encrypted platform storage.
    if (_allowPlaintextAuthFallback) {
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('fallback_auth_$key', value);
      } catch (_) {}
    }

    try {
      await _storage.write(key: key, value: value);
    } catch (e) {
      debugPrint('SecureStorage write error (using SharedPrefs fallback): $e');
      // resetOnError=true will clear corrupted keys automatically on next read
    }
  }

  static Future<String?> _getItem(String key) async {
    // Return memory cache first if we wrote it this session
    if (_memoryStorage.containsKey(key) && _memoryStorage[key] != null) {
      return _memoryStorage[key];
    }

    String? finalValue;
    try {
      finalValue = await _storage.read(key: key);
    } catch (e) {
      debugPrint('SecureStorage read error (using SharedPrefs fallback): $e');
    }

    // Debug/explicit fallback helps local isolate testing without weakening
    // production token storage.
    if (finalValue == null && _allowPlaintextAuthFallback) {
      try {
        final prefs = await SharedPreferences.getInstance();
        finalValue = prefs.getString('fallback_auth_$key');
      } catch (_) {}
    }

    if (finalValue != null) {
      _memoryStorage[key] = finalValue; // populate memory cache
    }
    return finalValue;
  }

  static Future<void> _removeItem(String key) async {
    _memoryStorage.remove(key);

    // Always clear the SharedPreferences fallback — not just in debug — so
    // logout/account-deletion doesn't leave a plaintext token behind in
    // release builds.
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('fallback_auth_$key');
    } catch (_) {}

    try {
      await _storage.delete(key: key);
    } catch (e) {
      debugPrint('SecureStorage delete error: $e');
    }
  }

  static String get baseUrl => AppConfig.baseUrl;
  static String get apiBaseUrl => AppConfig.apiBaseUrl;

  /// Returns tunnel bypass headers only in debug builds targeting a tunnel URL.
  /// Shared with SyncService via ResilientHttp so the header set can't diverge.
  static Map<String, String> _debugHeaders() =>
      ResilientHttp.tunnelBypassHeaders();

  /// PUT with one retry on stale-connection HandshakeException (see ResilientHttp).
  static Future<http.Response> _put(
    Uri uri, {
    Map<String, String>? headers,
    Object? body,
  }) => ResilientHttp.put(uri, headers: headers, body: body);

  /// Check backend connectivity
  static Future<bool> checkBackendHealth() async {
    try {
      final uri = Uri.parse('$baseUrl/api/health');
      final resp = await http.get(uri).timeout(const Duration(seconds: 5));
      return resp.statusCode == 200;
    } catch (e) {
      debugPrint('Backend health check failed: $e');
      return false;
    }
  }

  static const _accessTokenKey = 'auth_token';
  static const _refreshTokenKey = 'refresh_token';
  static const _backendFirebaseUidKey = 'backend_firebase_uid';
  static const _refreshLead = Duration(minutes: 2);

  /// Pure timing policy kept public for regression testing.
  static Duration tokenRefreshDelay(DateTime now, DateTime expiry) {
    final remaining = expiry.difference(now);
    if (remaining <= Duration.zero) return Duration.zero;
    final normalDelay = remaining - _refreshLead;
    if (normalDelay > Duration.zero) return normalDelay;
    // When already inside the refresh window, retry soon without spinning.
    return remaining > const Duration(seconds: 30)
        ? const Duration(seconds: 30)
        : const Duration(seconds: 1);
  }

  static Future<void> _saveTokensFromResponse(Map<String, dynamic> data) async {
    final tokens = data['tokens'];
    // Handles three response shapes:
    // 1. /auth/firebase/verify  → { token, tokens: { accessToken, refreshToken } }
    // 2. /auth/refresh          → { accessToken, refreshToken, ... }
    // 3. Legacy                 → { token, refreshToken }
    final accessToken =
        (data['token'] as String?) ??
        (tokens is Map ? tokens['accessToken'] as String? : null) ??
        (data['accessToken'] as String?);
    final refreshToken =
        (tokens is Map ? tokens['refreshToken'] as String? : null) ??
        (data['refreshToken'] as String?);

    // Persist the replacement refresh token before scheduling anything that
    // could consume it. Reversing this order can replay the just-used token.
    if (refreshToken != null) {
      await _setItem(_refreshTokenKey, refreshToken);
    }

    final user = data['user'];
    final firebaseUid = user is Map ? user['firebase_uid'] as String? : null;
    if (firebaseUid != null && firebaseUid.isNotEmpty) {
      await _setItem(_backendFirebaseUidKey, firebaseUid);
    }

    if (accessToken != null) {
      await _setItem(_accessTokenKey, accessToken);
      _scheduleTokenRefresh(accessToken);
      unawaited(_registerCurrentFcmToken(accessToken));
    }
  }

  static Future<void> _registerCurrentFcmToken(String accessToken) async {
    try {
      final fcmToken = await FirebaseMessaging.instance.getToken();
      if (fcmToken == null || fcmToken.isEmpty) return;
      await http
          .post(
            Uri.parse('$apiBaseUrl/notifications/fcm-token'),
            headers: {
              'Authorization': 'Bearer $accessToken',
              'Content-Type': 'application/json',
            },
            body: jsonEncode({'fcm_token': fcmToken}),
          )
          .timeout(AppConfig.connectionTimeout);
    } catch (e) {
      debugPrint('FCM registration deferred: $e');
    }
  }

  static Future<String?> _refreshAccessToken() async {
    final refreshToken = await _getItem(_refreshTokenKey);
    if (refreshToken == null || refreshToken.isEmpty) return null;

    try {
      final uri = Uri.parse('$apiBaseUrl/auth/refresh');
      final resp = await http
          .post(
            uri,
            headers: {'Content-Type': 'application/json', ..._debugHeaders()},
            body: jsonEncode({'refreshToken': refreshToken}),
          )
          .timeout(AppConfig.connectionTimeout);

      final data = _decodeBody(resp.body);
      if (resp.statusCode >= 200 && resp.statusCode < 300) {
        await _saveTokensFromResponse(data);
        return await getToken(); // return what was actually saved
      }

      if (resp.statusCode == 400 ||
          resp.statusCode == 401 ||
          resp.statusCode == 403) {
        await clearLocalTokens();
      }
      debugPrint('Refresh rejected with status ${resp.statusCode}');
      return null;
    } catch (e) {
      debugPrint('Refresh token request failed: $e');
      // Preserve the session on timeouts/5xx/network errors. A later request
      // can retry while the current access token is still valid.
      return null;
    }
  }

  /// Manually save access token (e.g. for Firebase-only auth)
  static Future<void> saveToken(String token) async {
    await _setItem(_accessTokenKey, token);
    _scheduleTokenRefresh(token);
  }

  /// Clear local backend tokens without calling the backend logout endpoint.
  /// Used when the Firebase session is still valid but stored backend tokens
  /// are stale or belong to a different Firebase user.
  static Future<void> clearLocalTokens() async {
    _refreshTimer?.cancel();
    _refreshTimer = null;
    _tokenExpiry = null;
    await _removeItem(_accessTokenKey);
    await _removeItem(_refreshTokenKey);
    await _removeItem(_backendFirebaseUidKey);
  }

  static Future<String?> getBoundFirebaseUid() =>
      _getItem(_backendFirebaseUidKey);

  /// Schedule automatic token refresh before expiry
  static void _scheduleTokenRefresh(String token) {
    try {
      _refreshTimer?.cancel();

      final expiry = _JWTDecoder.getExpiry(token);
      if (expiry == null) return;
      _tokenExpiry = expiry;

      final delay = tokenRefreshDelay(DateTime.now(), expiry);

      debugPrint('Token refresh scheduled in ${delay.inMinutes} minutes');

      _refreshTimer = Timer(delay, () async {
        final refreshed = await _refreshSingleFlight();
        if (refreshed == null) {
          final current = await getToken();
          if (current == token && DateTime.now().isBefore(expiry)) {
            _scheduleTokenRefresh(token);
          }
        }
      });
    } catch (e) {
      debugPrint('Failed to schedule token refresh: $e');
    }
  }

  /// Check if token is expired or expiring soon
  static bool isTokenExpiringSoon() {
    if (_tokenExpiry == null) return true;
    return _tokenExpiry!.difference(DateTime.now()) <= _refreshLead;
  }

  /// Verify Firebase ID Token with Backend and get Backend JWT
  ///
  /// AUTH FLOW:
  /// 1. Called from login_screen.dart after Firebase sign-in succeeds
  /// 2. POST request to backend: /api/auth/firebase/verify
  /// 3. Backend verifies token with Firebase Admin SDK
  /// 4. Backend upserts user in PostgreSQL database
  /// 5. Backend generates JWT tokens (accessToken + refreshToken)
  /// 6. This function saves tokens to FlutterSecureStorage
  /// 7. Returns backend user data and tokens
  ///
  /// CALLED BY: login_screen.dart → _login() and _signInWithGoogle()
  /// NEXT STEP: login_screen.dart calls getMe() to fetch user profile,
  ///            then navigates to HomePage
  static Future<Map<String, dynamic>> verifyFirebaseToken({
    required String idToken,
  }) async {
    final uri = Uri.parse('$apiBaseUrl/auth/firebase/verify');
    debugPrint('🚀 Firebase Verify: POST to $uri');
    try {
      final resp = await http
          .post(
            uri,
            headers: {'Content-Type': 'application/json', ..._debugHeaders()},
            body: jsonEncode({'idToken': idToken}),
          )
          .timeout(AppConfig.connectionTimeout);
      debugPrint('🚀 Firebase Verify: Response status: ${resp.statusCode}');
      // NOTE: never log resp.body here — it contains access + refresh tokens,
      // and debugPrint is not stripped from release builds.

      final data = _decodeBody(resp.body);
      if (resp.statusCode >= 200 && resp.statusCode < 300) {
        await _saveTokensFromResponse(data);
        try {
          await SpoonRuntime().bindOwner(FirebaseAuth.instance.currentUser?.uid);
        } catch (e) {
          debugPrint('BLE bindOwner after verify failed: $e');
        }
        return data;
      }
      throw AuthException(_extractErrorMessage(data));
    } catch (e, stack) {
      debugPrint('🚀 Firebase Verify: EXCEPTION CAUGHT: $e\\n$stack');
      if (e is AuthException) rethrow;
      throw AuthException('Network/parsing error during verify: $e');
    }
  }

  static Future<void> logout({
    bool silent = false,
    bool clearUserData = false,
  }) async {
    // Cancel token refresh timer
    _refreshTimer?.cancel();
    _refreshTimer = null;
    _tokenExpiry = null;

    final refreshToken = await _getItem(_refreshTokenKey);
    String? fcmToken;
    try {
      fcmToken = await FirebaseMessaging.instance.getToken();
    } catch (_) {}

    if (!silent && refreshToken != null) {
      try {
        final uri = Uri.parse('$apiBaseUrl/auth/logout');
        final accessToken = await _getItem(_accessTokenKey);
        await http.post(
          uri,
          headers: {
            'Content-Type': 'application/json',
            if (accessToken != null) 'Authorization': 'Bearer $accessToken',
          },
          body: jsonEncode({
            'refreshToken': refreshToken,
            'fcmToken': ?fcmToken,
          }),
        );
      } catch (e) {
        debugPrint('Logout request failed: $e');
      }
    }

    await clearLocalTokens();
    if (clearUserData) {
      // Tear down live BLE before wiping prefs so FGS/GATT cannot outlive logout.
      // Keep the per-user spoon list so the same account still sees its spoons
      // after the next sign-in. Account deletion wipes the store separately.
      try {
        await SpoonRuntime().detachOwner(wipeStore: false);
      } catch (e) {
        debugPrint('Logout BLE teardown failed: $e');
      }
      try {
        await SmartSpoonBleService().stopBackgroundMonitoring();
      } catch (e) {
        debugPrint('Logout FGS stop failed: $e');
      }
      await _clearLocalUserData();
    }
  }

  static Future<void> _clearLocalUserData({bool wipeSpoons = false}) async {
    // If a sync push is mid-flight, let it finish (bounded) before wiping the
    // DB — clearing mid-push interleaves deletes with is_synced updates.
    var waitedMs = 0;
    while (SyncService.isPushInProgress && waitedMs < 30000) {
      await Future.delayed(const Duration(milliseconds: 100));
      waitedMs += 100;
    }

    try {
      await DatabaseService().clearDatabase(includeDevices: true);
    } catch (e) {
      debugPrint('Failed to clear local database: $e');
    }

    try {
      final prefs = await SharedPreferences.getInstance();
      const exactKeys = {
        'ble_saved_devices',
        'smart_spoon_id',
        'smart_spoon_ids',
        'session_active',
        'session_start_time',
        'session_meal_uuid',
        'session_last_bite_time',
        'breakfastGoal',
        'lunchGoal',
        'dinnerGoal',
        'snackGoal',
      };
      final dynamicPrefixes = {
        if (wipeSpoons) 'ble_saved_devices_v2',
        'heater_on_',
        'heater_max_',
        'bg_avg_accel_',
        'bg_battery_',
        'bg_bite_count_',
        'bg_temperature_',
        'bg_updated_at_',
      };
      for (final key in prefs.getKeys()) {
        if (exactKeys.contains(key) ||
            dynamicPrefixes.any((prefix) => key.startsWith(prefix))) {
          await prefs.remove(key);
        }
      }
    } catch (e) {
      debugPrint('Failed to clear user preferences: $e');
    }
  }

  /// Permanently delete the current user's account.
  ///
  /// AUTH FLOW:
  /// 1. Calls DELETE /api/auth/me with the bearer token — backend deletes the
  ///    Firebase Auth user, then cascade-deletes the Postgres row (and every
  ///    related table via ON DELETE CASCADE).
  /// 2. Regardless of step 1's outcome being a hard failure, this method still
  ///    clears all local state on success so the device doesn't keep stale
  ///    credentials around for an account that may no longer exist server-side.
  /// 3. Clears local SQLite data, secure-storage tokens, and signs out of
  ///    Firebase, mirroring what `logout()` does plus the local DB wipe.
  ///
  /// CALLED BY: profile_page.dart "Delete Account" action (after confirmation)
  static Future<void> deleteAccount({required String firebaseIdToken}) async {
    final token = await getValidToken();
    if (token == null) throw AuthException('Not authenticated');

    final uri = Uri.parse('$apiBaseUrl/auth/me');
    final resp = await http
        .delete(
          uri,
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer $token',
            ..._debugHeaders(),
          },
          body: jsonEncode({'idToken': firebaseIdToken}),
        )
        .timeout(AppConfig.connectionTimeout);

    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      final data = _decodeBody(resp.body);
      throw AuthException(_extractErrorMessage(data));
    }

    // Backend confirmed deletion — now clear everything locally.
    _refreshTimer?.cancel();
    _refreshTimer = null;
    _tokenExpiry = null;

    try {
      await SpoonRuntime().detachOwner(wipeStore: true);
    } catch (e) {
      debugPrint('Failed to wipe spoons after account deletion: $e');
    }

    try {
      await _clearLocalUserData(wipeSpoons: true);
    } catch (e) {
      debugPrint('Failed to clear local database after account deletion: $e');
    }

    try {
      await FirebaseAuth.instance.signOut();
      await GoogleSignIn().signOut();
    } catch (e) {
      debugPrint('Firebase signOut after account deletion failed: $e');
    }

    await clearLocalTokens();
  }

  static Future<String?> getToken() => _getItem(_accessTokenKey);

  /// Validate if stored token is still valid
  static Future<bool> isTokenValid() async {
    try {
      final token = await getToken();
      if (token == null || token.isEmpty) return false;

      // Decode and check expiry
      final expiry = _JWTDecoder.getExpiry(token);
      if (expiry == null) return false;

      return DateTime.now().isBefore(expiry);
    } catch (e) {
      debugPrint('Token validation error: $e');
      return false;
    }
  }

  /// Get current user ID from stored token
  static Future<String?> getUserId() async {
    final token = await getToken();
    if (token == null) return null;
    final payload = _JWTDecoder.decodePayload(token);
    final id = payload?['id'];
    if (id == null) return null;
    if (id is String) return id;
    if (id is int) return id.toString();
    if (id is double) return id.toInt().toString();
    return null; // Unknown type — don't crash, return null
  }

  static Completer<String?>? _refreshCompleter;

  /// Get token only if it's valid, otherwise clear it
  static Future<String?> getValidToken() async {
    // Prevent multiple parallel refresh calls
    if (_refreshCompleter != null) {
      return _refreshCompleter!.future;
    }

    final token = await getToken();
    if (token == null) {
      return _refreshSingleFlight();
    }

    final expiry = _JWTDecoder.getExpiry(token);
    if (expiry != null &&
        DateTime.now().isBefore(expiry.subtract(_refreshLead))) {
      return token;
    }

    final refreshed = await _refreshSingleFlight();
    if (refreshed != null) return refreshed;
    // A transient refresh failure must not discard an access token that has
    // not actually expired yet.
    if (expiry != null && DateTime.now().isBefore(expiry)) return token;
    return null;
  }

  /// Runs a token refresh, coalescing concurrent callers onto one attempt.
  /// The completer is captured locally: the `await getToken()` above yields
  /// to the event loop, so two callers could both reach here — using the
  /// static field inside try/catch raced and crashed with a null-check error.
  static Future<String?> _refreshSingleFlight() async {
    final pending = _refreshCompleter;
    if (pending != null) return pending.future;

    final completer = Completer<String?>();
    _refreshCompleter = completer;
    try {
      final newToken = await _refreshAccessToken();
      completer.complete(newToken);
      return newToken;
    } catch (e) {
      completer.complete(null);
      return null;
    } finally {
      if (identical(_refreshCompleter, completer)) {
        _refreshCompleter = null;
      }
    }
  }

  static Map<String, dynamic> _unwrapData(Map<String, dynamic> body) {
    if (body.containsKey('data') && body['data'] is Map<String, dynamic>) {
      return body['data'] as Map<String, dynamic>;
    }
    return body;
  }

  static Future<Map<String, dynamic>> updateProfile({
    required Map<String, dynamic> data,
  }) async {
    final token = await getValidToken();
    if (token == null) throw AuthException('Not authenticated');
    final uri = Uri.parse('$apiBaseUrl/users/me');
    final resp = await _put(
      uri,
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $token',
        ..._debugHeaders(),
      },
      body: jsonEncode(data),
    );
    final body = _decodeBody(resp.body);
    if (resp.statusCode >= 200 && resp.statusCode < 300) {
      return _unwrapData(body);
    }
    throw AuthException(_extractErrorMessage(body));
  }

  static Future<Map<String, dynamic>> getMe() async {
    final token = await getValidToken();
    if (token == null) throw AuthException('Not authenticated');
    final uri = Uri.parse('$apiBaseUrl/users/me');
    final resp = await http
        .get(
          uri,
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer $token',
            ..._debugHeaders(),
          },
        )
        .timeout(AppConfig.connectionTimeout);
    final body = _decodeBody(resp.body);
    if (resp.statusCode >= 200 && resp.statusCode < 300) {
      final data = _unwrapData(body);
      final user = data['user'];
      final firebaseUid = user is Map ? user['firebase_uid'] as String? : null;
      if (firebaseUid != null && firebaseUid.isNotEmpty) {
        await _setItem(_backendFirebaseUidKey, firebaseUid);
      }
      return data;
    }
    throw AuthException(_extractErrorMessage(body));
  }

  static Map<String, dynamic> _decodeBody(String body) {
    try {
      final dynamic parsed = jsonDecode(body);
      if (parsed is Map<String, dynamic>) return parsed;
      return {'message': parsed.toString()};
    } catch (_) {
      return {'message': body};
    }
  }

  static String _extractErrorMessage(Map<String, dynamic> data) {
    if (data['errors'] is Map && (data['errors'] as Map).isNotEmpty) {
      final Map errMap = data['errors'] as Map;
      return errMap.values.first.toString();
    }
    return (data['message'] as String?) ?? 'Request failed';
  }

  // Web-only helpers removed
}

class AuthException implements Exception {
  final String message;
  AuthException(this.message);
  @override
  String toString() => message;
}
