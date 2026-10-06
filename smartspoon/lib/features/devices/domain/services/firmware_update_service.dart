// firmware_update_service.dart — over-the-air (OTA/DFU) firmware update engine.
//
// Wraps the Nordic MCUmgr / SMP BLE transport (mcumgr_flutter) to flash a new
// firmware image onto a connected nRF52840 / Zephyr spoon.
//
// iSpoon firmware (MCUboot TEST + self-confirm after health):
//   Use [FirmwareUpgradeMode.testOnly] so the manager tests + resets without
//   confirming an inactive secondary (firmware rejects that). The new image
//   confirms itself after its health dwell.
//
// IMPORTANT: callers MUST release the app's BLE link before [start] and restore
// after a terminal state (see FirmwareUpdateScreen).
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:mcumgr_flutter/mcumgr_flutter.dart';
import 'package:mcumgr_flutter/models/firmware_upgrade_mode.dart';

/// Coarse DFU phase surfaced to the UI.
enum FirmwareDfuStatus {
  idle,
  preparing,
  uploading,
  swapping,
  success,
  error,
  cancelled,
}

class FirmwareUpdateService extends ChangeNotifier {
  FirmwareDfuStatus _status = FirmwareDfuStatus.idle;
  double _progress = 0.0;
  String _stage = '';
  String? _error;
  bool _disposed = false;
  Timer? _stallTimer;

  FirmwareUpdateManager? _manager;
  StreamSubscription<FirmwareUpgradeState>? _stateSub;
  StreamSubscription<ProgressUpdate>? _progressSub;

  FirmwareDfuStatus get status => _status;
  double get progress => _progress;
  String get stage => _stage;
  String? get error => _error;

  bool get isBusy =>
      _status == FirmwareDfuStatus.preparing ||
      _status == FirmwareDfuStatus.uploading ||
      _status == FirmwareDfuStatus.swapping;

  bool get isTerminal =>
      _status == FirmwareDfuStatus.success ||
      _status == FirmwareDfuStatus.error ||
      _status == FirmwareDfuStatus.cancelled;

  void _set(FirmwareDfuStatus s) {
    if (_disposed) return;
    _status = s;
    notifyListeners();
  }

  void reset() {
    if (isBusy) return;
    _progress = 0.0;
    _stage = '';
    _error = null;
    _set(FirmwareDfuStatus.idle);
  }

  /// Start a firmware update. Defaults to [FirmwareUpgradeMode.testOnly]
  /// which matches Spoon firmware MCUboot TEST + running-image self-confirm.
  Future<void> start({
    required String deviceId,
    required Uint8List image,
    FirmwareUpgradeMode mode = FirmwareUpgradeMode.testOnly,
    Duration overallTimeout = const Duration(minutes: 8),
  }) async {
    if (isBusy) {
      debugPrint('⚠️ DFU: update already in progress — ignoring start()');
      return;
    }
    if (image.isEmpty) {
      _error = 'Firmware image is empty.';
      _set(FirmwareDfuStatus.error);
      return;
    }

    // Always tear down any previous manager before a new attempt.
    await _teardownManager();

    _progress = 0.0;
    _error = null;
    _stage = 'Preparing…';
    _set(FirmwareDfuStatus.preparing);
    _armStallWatchdog(overallTimeout);

    try {
      _manager = await FirmwareUpdateManagerFactory().getUpdateManager(deviceId);

      final stateStream = _manager!.setup();
      _stateSub = stateStream.listen(
        _onState,
        onError: _onError,
        cancelOnError: false,
      );

      _progressSub = _manager!.progressStream.listen(
        (p) {
          if (_disposed) return;
          if (p.imageSize > 0) {
            _progress = (p.bytesSent / p.imageSize).clamp(0.0, 1.0);
            _stage = 'Uploading ${(_progress * 100).toStringAsFixed(0)}%';
            if (_status != FirmwareDfuStatus.uploading) {
              _status = FirmwareDfuStatus.uploading;
            }
            _armStallWatchdog(overallTimeout);
            notifyListeners();
          }
        },
        onError: _onError,
        cancelOnError: false,
      );

      await _manager!.updateWithImageData(
        image: image,
        configuration: FirmwareUpgradeConfiguration(
          firmwareUpgradeMode: mode,
          // Do not wipe NVS bond / settings partition on every OTA.
          eraseAppSettings: false,
          // Spoon reboot + splash + BLE advertising + 10 s TEST health dwell.
          estimatedSwapTime: const Duration(seconds: 30),
        ),
      );
    } catch (e) {
      _onError(e);
    }
  }

  void _armStallWatchdog(Duration timeout) {
    _stallTimer?.cancel();
    _stallTimer = Timer(timeout, () {
      if (_disposed || isTerminal) return;
      _error = 'Firmware update timed out — check the spoon and try again.';
      _stage = 'Timed out';
      _status = FirmwareDfuStatus.error;
      debugPrint('❌ DFU: overall timeout');
      notifyListeners();
      unawaited(_teardownManager());
    });
  }

  void _onState(FirmwareUpgradeState state) {
    if (_disposed) return;
    // Compare the public label, not instance identity — the plugin constructs
    // new FirmwareUpgradeState objects from protobuf.
    final raw = state.toString();
    _stage = raw;
    if (raw == FirmwareUpgradeState.upload.toString()) {
      _status = FirmwareDfuStatus.uploading;
    } else if (raw == FirmwareUpgradeState.test.toString() ||
        raw == FirmwareUpgradeState.reset.toString() ||
        raw == FirmwareUpgradeState.confirm.toString()) {
      // testOnly must not permanently confirm the inactive slot. The plugin
      // still reports Test/Reset; Confirm here is treated as swap-in-progress
      // so a misconfigured confirmOnly path cannot look like success.
      _status = FirmwareDfuStatus.swapping;
      _stage = 'Installing (TEST boot)…';
    } else if (raw == FirmwareUpgradeState.success.toString()) {
      _status = FirmwareDfuStatus.success;
      _stage = 'Spoon rebooting into the new firmware';
      _progress = 1.0;
      _stallTimer?.cancel();
      unawaited(_teardownManager());
    } else if (_status != FirmwareDfuStatus.uploading) {
      _status = FirmwareDfuStatus.preparing;
    }
    notifyListeners();
  }

  void _onError(Object e) {
    if (_disposed) return;
    _error = e.toString();
    _stage = 'Failed';
    _status = FirmwareDfuStatus.error;
    _stallTimer?.cancel();
    debugPrint('❌ DFU: $_error');
    notifyListeners();
    unawaited(_teardownManager());
  }

  Future<void> pause() async {
    if (_status == FirmwareDfuStatus.uploading) {
      try {
        await _manager?.pause();
      } catch (_) {}
    }
  }

  Future<void> resume() async {
    try {
      await _manager?.resume();
    } catch (_) {}
  }

  Future<void> cancel() async {
    if (!isBusy && _status != FirmwareDfuStatus.preparing) return;
    try {
      await _manager?.cancel();
    } catch (_) {}
    _stallTimer?.cancel();
    _stage = 'Cancelled';
    _set(FirmwareDfuStatus.cancelled);
    await _teardownManager();
  }

  Future<void> _teardownManager() async {
    _stallTimer?.cancel();
    _stallTimer = null;
    await _stateSub?.cancel();
    await _progressSub?.cancel();
    _stateSub = null;
    _progressSub = null;
    try {
      await _manager?.kill();
    } catch (_) {}
    _manager = null;
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_teardownManager());
    super.dispose();
  }
}
