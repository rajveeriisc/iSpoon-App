// resilient_http.dart — shared HTTP helper with stale-connection retry.
//
// Static get/post/put wrappers used by every backend-facing service so retry
// policy and tunnel-bypass headers live in one place. _withStaleTlsRetry sends
// the request on the shared pooled client and, if it fails with a
// HandshakeException / "Connection closed" (a pooled TLS socket the server —
// e.g. an ngrok tunnel — already closed), retries once on a fresh client.
// tunnelBypassHeaders() adds ngrok skip-warning headers whenever the API
// host is ngrok (debug and release Desktop APKs).
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import '../config/app_config.dart';

/// Shared HTTP plumbing for services that talk to the backend
/// (SyncService, AuthService, ...).
///
/// Every request gets one retry on a stale pooled-TLS connection
/// (HandshakeException / "Connection closed") — the global http client
/// reuses pooled connections that a tunnel like ngrok may have already
/// closed on its end; retrying once with a fresh client succeeds.
///
/// Keeping this in one place means retry policy and tunnel-bypass headers
/// can't silently diverge between the sync and auth paths.
class ResilientHttp {
  ResilientHttp._();

  /// Request-signing secret, shared with the backend's verifyHmac middleware.
  ///
  /// Injected at build time so it is not a source-code constant:
  ///   flutter build apk --dart-define=HMAC_SECRET=...
  /// and the same value must be set as HMAC_SECRET on the server, which
  /// refuses to boot in production without it.
  ///
  /// Note this is only defence in depth. Anything compiled into the app can be
  /// read back out of the APK, so a shared static secret cannot authenticate a
  /// client; the bearer token checked by `protect` is what actually does.
  ///
  /// The fallback is the well-known development value, kept so local debug
  /// builds work against a dev server without extra flags. It is deliberately
  /// NOT used in release: a release build with no secret configured would
  /// otherwise sign every request with a value published in a public repo.
  static const String _devFallbackSecret = 'smartspoon_hmac_secret_2026';

  static const String _hmacSecretFromEnv = String.fromEnvironment('HMAC_SECRET');

  static String get _hmacSecret {
    if (_hmacSecretFromEnv.isNotEmpty) return _hmacSecretFromEnv;
    assert(
      kDebugMode,
      'HMAC_SECRET was not provided at build time. Pass '
      '--dart-define=HMAC_SECRET=<value matching the server> for release builds.',
    );
    return _devFallbackSecret;
  }

  static Map<String, String> _signRequest(Object? body, Map<String, String>? headers) {
    final signedHeaders = headers == null ? <String, String>{} : Map<String, String>.from(headers);
    // Best effort stringification matching Node.js behavior
    final bodyString = body is String ? body : (body != null ? jsonEncode(body) : '');
    final hmac = Hmac(sha256, utf8.encode(_hmacSecret));
    final digest = hmac.convert(utf8.encode(bodyString));
    signedHeaders['x-signature'] = digest.toString();
    return signedHeaders;
  }

  /// Tunnel bypass headers (ngrok/localtunnel).
  /// Must apply in release too: a Desktop ngrok APK uses https://*.ngrok-free.dev
  /// and the interstitial HTML would otherwise replace every API response.
  static Map<String, String> tunnelBypassHeaders() {
    if (AppConfig.apiBaseUrl.contains('ngrok')) {
      return {
        'ngrok-skip-browser-warning': 'true',
        'Bypass-Tunnel-Reminder': 'true',
      };
    }
    return {};
  }

  static Future<http.Response> get(Uri uri, {Map<String, String>? headers}) =>
      _withStaleTlsRetry(
        (client) => client == null
            ? http.get(uri, headers: headers)
            : client.get(uri, headers: headers),
      );

  static Future<http.Response> post(Uri uri,
          {Map<String, String>? headers, Object? body}) =>
      _withStaleTlsRetry(
        (client) => client == null
            ? http.post(uri, headers: _signRequest(body, headers), body: body)
            : client.post(uri, headers: _signRequest(body, headers), body: body),
      );

  static Future<http.Response> put(Uri uri,
          {Map<String, String>? headers, Object? body}) =>
      _withStaleTlsRetry(
        (client) => client == null
            ? http.put(uri, headers: _signRequest(body, headers), body: body)
            : client.put(uri, headers: _signRequest(body, headers), body: body),
      );

  static Future<http.Response> _withStaleTlsRetry(
    Future<http.Response> Function(http.Client? client) send,
  ) async {
    try {
      return await send(null).timeout(AppConfig.connectionTimeout);
    } catch (e) {
      final msg = e.toString();
      if (msg.contains('HandshakeException') || msg.contains('Connection closed')) {
        final client = http.Client();
        try {
          return await send(client).timeout(AppConfig.connectionTimeout);
        } finally {
          client.close();
        }
      }
      rethrow;
    }
  }
}
