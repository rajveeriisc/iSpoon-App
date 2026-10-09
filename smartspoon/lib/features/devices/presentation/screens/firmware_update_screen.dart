// firmware_update_screen.dart — user-facing OTA (firmware update) screen.
//
// Lets the user install a new firmware image on a specific spoon. It downloads
// the signed MCUboot image (app_update.bin) from a URL, releases the app's BLE
// link so the MCUmgr layer can own the connection, runs the DFU via
// FirmwareUpdateService, shows live progress, and restores the normal BLE
// connection when finished. On success the spoon reboots into the new firmware.
import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:mcumgr_flutter/models/firmware_upgrade_mode.dart';
import 'package:provider/provider.dart';
import 'package:smartspoon/features/devices/domain/mcuboot_image.dart';
import 'package:smartspoon/ble/spoon_runtime.dart';
import 'package:smartspoon/features/devices/domain/services/firmware_update_service.dart';
import 'package:smartspoon/features/devices/domain/services/smart_spoon_ble_service.dart';
import 'package:smartspoon/core/theme/app_theme.dart';
import 'package:smartspoon/core/widgets/geometric_background.dart';
import 'package:smartspoon/core/widgets/premium_widgets.dart';

class FirmwareUpdateScreen extends StatefulWidget {
  final String deviceId;
  final String deviceName;

  const FirmwareUpdateScreen({
    super.key,
    required this.deviceId,
    required this.deviceName,
  });

  @override
  State<FirmwareUpdateScreen> createState() => _FirmwareUpdateScreenState();
}

class _FirmwareUpdateScreenState extends State<FirmwareUpdateScreen> {
  final FirmwareUpdateService _dfu = FirmwareUpdateService();
  final TextEditingController _urlController = TextEditingController();
  // Required SHA-256 (hex) from the release manifest. Verified before flash.
  final TextEditingController _shaController = TextEditingController();

  bool _downloading = false;
  bool _linkRestored = true; // false while the app's BLE link is released for DFU
  String? _downloadError;
  int? _imageBytes;

  late final SpoonRuntime _bleService;

  @override
  void initState() {
    super.initState();
    _bleService = Provider.of<SpoonRuntime>(context, listen: false);
    _dfu.addListener(_onDfuChanged);
  }

  @override
  void dispose() {
    _dfu.removeListener(_onDfuChanged);
    _dfu.dispose();
    _urlController.dispose();
    _shaController.dispose();
    // Safety net: if we leave mid-flow, restore BLE stacks after DFU teardown.
    if (!_linkRestored) {
      unawaited(_restoreBleStacks());
    }
    super.dispose();
  }

  Future<void> _restoreBleStacks() async {
    // TEST image is still coming out of reset (splash + advertising).
    await Future.delayed(const Duration(seconds: 3));
    if (!mounted) return;
    _linkRestored = true;
    await SmartSpoonBleService().startBackgroundMonitoring();
    await _bleService.reconnectSavedDevice(widget.deviceId);
  }

  void _onDfuChanged() {
    if (!mounted) return;
    setState(() {});
    if (_dfu.isTerminal && !_linkRestored) {
      unawaited(_restoreBleStacks());
    }
  }

  Future<void> _downloadAndInstall() async {
    setState(() {
      _downloading = true;
      _downloadError = null;
      _imageBytes = null;
    });

    Uint8List image;
    try {
      final source = await _resolveFirmwareSource();
      final resp = await http
          .get(Uri.parse(source.binUrl))
          .timeout(const Duration(seconds: 60));
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        throw Exception('Server returned ${resp.statusCode}');
      }
      image = resp.bodyBytes;
      if (image.isEmpty) throw Exception('Downloaded file is empty');

      final actual = sha256.convert(image).toString();
      if (actual != source.sha256) {
        throw Exception(
          'SHA-256 mismatch — refusing to flash.\n'
          'expected: ${source.sha256}\nactual:   $actual',
        );
      }

      final header = McubootImage.parse(image);
      debugPrint('DFU: MCUboot image ${header.versionLabel} '
          '(${image.length} bytes)');
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _downloading = false;
        _downloadError = 'Download failed: $e';
      });
      return;
    }

    if (!mounted) return;
    setState(() {
      _downloading = false;
      _imageBytes = image.length;
    });

    // Industry flow: heater OFF, then exclusive SMP ownership of the GATT
    // client (app + FGS must not hold the link). Firmware rejects SMP chunks
    // with EBUSY while the rail is on.
    try {
      await SpoonRuntime().setHeaterParameters(
        0,
        0,
        deviceId: widget.deviceId,
      );
    } catch (e) {
      debugPrint('DFU: heater OFF before upload failed: $e');
    }

    _linkRestored = false;
    await SmartSpoonBleService().stopBackgroundMonitoring();
    await _bleService.disconnectDevice(widget.deviceId);
    await Future.delayed(const Duration(seconds: 1));

    await _dfu.start(
      deviceId: widget.deviceId,
      image: image,
      mode: FirmwareUpgradeMode.testOnly,
    );
  }

  Future<({String binUrl, String sha256})> _resolveFirmwareSource() async {
    var url = _urlController.text.trim();
    var sha = _shaController.text.trim().toLowerCase().replaceAll(':', '');

    if (url.isEmpty || !url.startsWith('https://')) {
      throw Exception(
        'Enter a valid https:// firmware URL or signed manifest JSON.',
      );
    }

    if (url.toLowerCase().endsWith('.json')) {
      final resp = await http
          .get(Uri.parse(url))
          .timeout(const Duration(seconds: 30));
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        throw Exception('Manifest returned ${resp.statusCode}');
      }
      final decoded = jsonDecode(resp.body);
      if (decoded is! Map) {
        throw Exception('Manifest is not a JSON object.');
      }
      url = (decoded['url'] as String? ?? '').trim();
      sha = (decoded['sha256'] as String? ?? '')
          .trim()
          .toLowerCase()
          .replaceAll(':', '');
      if (!url.startsWith('https://')) {
        throw Exception('Manifest url must be https://.');
      }
    }

    if (sha.length != 64 || !RegExp(r'^[0-9a-f]{64}$').hasMatch(sha)) {
      throw Exception(
        'SHA-256 is required (64 hex chars from the release manifest).',
      );
    }
    return (binUrl: url, sha256: sha);
  }

  @override
  Widget build(BuildContext context) {
    final busy = _dfu.isBusy || _downloading;
    return PopScope(
      canPop: !busy,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop || !busy) return;
        // User tried to leave mid-flash — cancel and await teardown first.
        await _dfu.cancel();
        if (!_linkRestored) await _restoreBleStacks();
        if (context.mounted) Navigator.of(context).maybePop();
      },
      child: Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: Text(
          'Firmware Update',
          style: GoogleFonts.figtree(fontWeight: FontWeight.bold),
        ),
        automaticallyImplyLeading: !busy,
      ),
      body: Stack(
        children: [
          const GeometricBackground(),
          SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 40),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildDeviceCard(),
                  const SizedBox(height: 20),
                  _buildSourceCard(busy),
                  const SizedBox(height: 20),
                  _buildStatusCard(),
                  const SizedBox(height: 20),
                  _buildActions(busy),
                ],
              ),
            ),
          ),
        ],
      ),
      ),
    );
  }

  Widget _buildDeviceCard() {
    return PremiumGlassCard(
      child: Row(
        children: [
          PremiumIconBox(icon: Icons.memory, color: AppTheme.emerald),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.deviceName.isEmpty ? 'I-Spoon Device' : widget.deviceName,
                  style: GoogleFonts.figtree(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: Theme.of(context).colorScheme.onSurface,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'Current version: ${_currentFirmwareVersion()}',
                  style: GoogleFonts.figtree(
                    fontSize: 13,
                    color: Theme.of(context)
                        .colorScheme
                        .onSurface
                        .withValues(alpha: 0.6),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSourceCard(bool busy) {
    return PremiumGlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Firmware image',
            style: GoogleFonts.figtree(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: Theme.of(context).colorScheme.onSurface,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Paste the HTTPS URL of zephyr.signed.bin and its SHA-256, or a '
            'signed release-manifest.json (url + sha256). HTTP is refused. '
            'The spoon TEST-boots the image; it confirms itself after health checks.',
            style: GoogleFonts.figtree(
              fontSize: 13,
              color: Theme.of(context)
                  .colorScheme
                  .onSurface
                  .withValues(alpha: 0.6),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _urlController,
            enabled: !busy,
            keyboardType: TextInputType.url,
            decoration: InputDecoration(
              hintText: 'https://…/zephyr.signed.bin',
              border: const OutlineInputBorder(),
              errorText: _downloadError,
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _shaController,
            enabled: !busy,
            decoration: const InputDecoration(
              labelText: 'SHA-256 (required)',
              hintText: 'expected hex digest',
              border: OutlineInputBorder(),
            ),
          ),
          if (_imageBytes != null) ...[
            const SizedBox(height: 8),
            Text(
              'Downloaded ${(_imageBytes! / 1024).toStringAsFixed(1)} KB',
              style: GoogleFonts.figtree(fontSize: 13, color: AppTheme.emerald),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildStatusCard() {
    final status = _dfu.status;
    Color color;
    IconData icon;
    switch (status) {
      case FirmwareDfuStatus.success:
        color = AppTheme.emerald;
        icon = Icons.check_circle;
        break;
      case FirmwareDfuStatus.error:
        color = Colors.redAccent;
        icon = Icons.error;
        break;
      case FirmwareDfuStatus.cancelled:
        color = Colors.orangeAccent;
        icon = Icons.cancel;
        break;
      default:
        color = AppTheme.emerald;
        icon = Icons.system_update_alt;
    }

    final showBar = _dfu.status == FirmwareDfuStatus.uploading;

    return PremiumGlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: color),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  _statusLabel(),
                  style: GoogleFonts.figtree(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: Theme.of(context).colorScheme.onSurface,
                  ),
                ),
              ),
            ],
          ),
          if (showBar) ...[
            const SizedBox(height: 14),
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: LinearProgressIndicator(
                value: _dfu.progress,
                minHeight: 10,
                backgroundColor: AppTheme.emerald.withValues(alpha: 0.15),
                valueColor: AlwaysStoppedAnimation(AppTheme.emerald),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '${(_dfu.progress * 100).toStringAsFixed(0)}%',
              style: GoogleFonts.figtree(fontSize: 13, color: color),
            ),
          ],
          if (_dfu.isBusy) ...[
            const SizedBox(height: 12),
            Text(
              'Keep the app open and the spoon nearby until the update finishes.',
              style: GoogleFonts.figtree(
                fontSize: 12,
                color: Colors.orangeAccent,
              ),
            ),
          ],
          if (_dfu.status == FirmwareDfuStatus.error && _dfu.error != null) ...[
            const SizedBox(height: 8),
            Text(
              _dfu.error!,
              style: GoogleFonts.figtree(fontSize: 12, color: Colors.redAccent),
            ),
          ],
        ],
      ),
    );
  }

  String _statusLabel() {
    switch (_dfu.status) {
      case FirmwareDfuStatus.idle:
        return 'Ready to update';
      case FirmwareDfuStatus.preparing:
        return _dfu.stage.isEmpty ? 'Preparing…' : _dfu.stage;
      case FirmwareDfuStatus.uploading:
        return 'Uploading firmware…';
      case FirmwareDfuStatus.swapping:
        return 'Installing & rebooting…';
      case FirmwareDfuStatus.success:
        return 'Update complete — spoon TEST-boots, then confirms itself.';
      case FirmwareDfuStatus.error:
        return 'Update failed';
      case FirmwareDfuStatus.cancelled:
        return 'Update cancelled';
    }
  }

  String _currentFirmwareVersion() {
    final saved = context
        .watch<SpoonRuntime>()
        .previousDevices
        .where((d) => d.id == widget.deviceId)
        .firstOrNull;
    final v = saved?.firmwareVersion?.trim();
    return (v == null || v.isEmpty) ? 'unknown' : v;
  }

  Widget _buildActions(bool busy) {
    if (_dfu.isBusy) {
      return SizedBox(
        width: double.infinity,
        child: OutlinedButton.icon(
          onPressed: _dfu.status == FirmwareDfuStatus.uploading
              ? () => _dfu.cancel()
              : null,
          icon: const Icon(Icons.close),
          label: const Text('Cancel'),
        ),
      );
    }

    if (_dfu.status == FirmwareDfuStatus.success) {
      return SizedBox(
        width: double.infinity,
        child: FilledButton(
          onPressed: () => Navigator.of(context).maybePop(),
          child: const Text('Done'),
        ),
      );
    }

    final label = _dfu.isTerminal ? 'Retry' : 'Download & Install';
    return SizedBox(
      width: double.infinity,
      child: FilledButton.icon(
        onPressed: busy
            ? null
            : () {
                _dfu.reset();
                _downloadAndInstall();
              },
        icon: _downloading
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.system_update),
        label: Text(_downloading ? 'Downloading…' : label),
      ),
    );
  }
}
