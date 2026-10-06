// Best-effort cloud registry for spoons owned by the signed-in user.
// Pairing still works offline; a failed register must never block BLE.
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:smartspoon/core/config/app_config.dart';
import 'package:smartspoon/core/services/resilient_http.dart';
import 'package:smartspoon/features/auth/domain/services/auth_service.dart';

class DeviceCloudService {
  DeviceCloudService._();

  static Future<void> registerPairedSpoon({
    required String productId,
    String? firmwareVersion,
    String? displayName,
  }) async {
    final hex = productId.trim().toLowerCase();
    if (hex.length != 16) return;

    try {
      final token = await AuthService.getValidToken();
      if (token == null) return;

      final uri = Uri.parse('${AppConfig.apiBaseUrl}/devices/register');
      final resp = await ResilientHttp.post(
        uri,
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $token',
          ...ResilientHttp.tunnelBypassHeaders(),
        },
        body: jsonEncode({
          'productId': hex,
          'macAddressHash': hex,
          if (firmwareVersion != null && firmwareVersion.isNotEmpty)
            'firmwareVersion': firmwareVersion,
          if (displayName != null && displayName.isNotEmpty)
            'displayName': displayName,
        }),
      );
      if (resp.statusCode >= 400) {
        debugPrint('⚠️ Device cloud register ${resp.statusCode}: ${resp.body}');
      }
    } catch (e) {
      debugPrint('⚠️ Device cloud register skipped: $e');
    }
  }
}
