import 'package:flutter/foundation.dart';
import 'package:freerasp/freerasp.dart';

class SecurityService {
  static Future<void> initialize() async {
    if (kDebugMode) {
      debugPrint('SecurityService: Bypassing freerasp initialization in debug mode');
      return;
    }

    try {
      final config = TalsecConfig(
        androidConfig: AndroidConfig(
          packageName: 'com.example.smartspoon', // Update with actual package name
          signingCertHashes: ['YOUR_CERT_HASH_HERE'],
          supportedStores: ['com.android.vending'],
        ),
        iosConfig: IOSConfig(
          bundleIds: ['com.example.smartspoon'], // Update with actual bundle ID
          teamId: 'YOUR_TEAM_ID',
        ),
        watcherMail: 'security@smartspoon.com',
        isProd: true,
      );

      final callback = ThreatCallback(
        onAppIntegrity: () => _handleThreat('App Integrity Compromised'),
        onObfuscationIssues: () => _handleThreat('Obfuscation Issues'),
        onDebug: () => _handleThreat('Debugging Detected'),
        onDeviceBinding: () => _handleThreat('Device Binding Failed'),
        onDeviceID: () => _handleThreat('Device ID Tampering'),
        onHooks: () => _handleThreat('Hooking Framework Detected'),
        onPrivilegedAccess: () => _handleThreat('Root/Jailbreak Detected'),
        onSecureHardwareNotAvailable: () => debugPrint('Secure Hardware Unavailable'),
        onSimulator: () => _handleThreat('Simulator Environment Detected'),
        onUnofficialStore: () => _handleThreat('Unofficial Store Installation'),
      );

      Talsec.instance.attachListener(callback);
      await Talsec.instance.start(config);
      
      debugPrint('SecurityService: freerasp successfully initialized');
    } catch (e) {
      debugPrint('SecurityService: Failed to initialize freerasp: $e');
    }
  }

  static void _handleThreat(String threatMessage) {
    debugPrint('SECURITY THREAT DETECTED: $threatMessage');
    // Log threat warning; do not forcibly terminate during testing/development builds
  }
}
