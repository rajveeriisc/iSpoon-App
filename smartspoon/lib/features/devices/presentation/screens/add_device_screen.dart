// add_device_screen.dart — pair a new spoon (BLE scan + connect flow).
//
// Drives device onboarding: requests permissions, scans for nearby iSpoon /
// iSpoon Pro devices via BleService, lists discovered spoons live, and lets the
// user tap one to connect and save it as a paired device. Shows scanning,
// connecting, and error states.
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:smartspoon/ble/models/runtime_models.dart';
import 'package:smartspoon/ble/spoon_runtime.dart';
import 'package:smartspoon/core/theme/app_theme.dart';
import 'package:smartspoon/core/widgets/geometric_background.dart';
import 'package:smartspoon/core/widgets/premium_widgets.dart';
import 'package:smartspoon/features/devices/presentation/screens/ble_settings_screen.dart';
import 'package:smartspoon/features/devices/presentation/widgets/heater_capability_prompt.dart';
import 'package:permission_handler/permission_handler.dart';
import 'dart:io';

class AddDeviceScreen extends StatefulWidget {
  const AddDeviceScreen({super.key});

  @override
  State<AddDeviceScreen> createState() => _AddDeviceScreenState();
}

class _AddDeviceScreenState extends State<AddDeviceScreen> {
  final _bleService = SpoonRuntime();
  String? _connectingDeviceId;

  @override
  void initState() {
    super.initState();
    _checkPermissionsAndScan();
  }

  Future<void> _checkPermissionsAndScan() async {
    // Explicitly prompt the user for permissions first if needed.
    final permissionResult = await _bleService.checkAndRequestPermissions();
    if (permissionResult != BlePermissionResult.granted) {
      if (mounted) {
        await _explainPermissionFailure(permissionResult);
      }
      return;
    }

    // Small delay to ensure UI is ready
    await Future.delayed(const Duration(milliseconds: 500));
    _startScan();
  }

  Future<void> _startScan() async {
    if (_bleService.isScanning) {
      return;
    }

    // We already checked and got permissions above, safe to scan
    try {
      await _bleService.startScan();
    } catch (e) {
      if (mounted) {
        _showSnackBar('Scanning failed: $e', isError: true);
      }
    }
  }

  // Heater-capability prompt (ambiguous-name bottom sheet) moved to
  // heater_capability_prompt.dart — shared with the Home page's "New spoon
  // nearby" quick-connect, which was silently diverging from this flow.

  Future<void> _handleConnect(SavedBleDevice device) async {
    if (_connectingDeviceId != null) {
      return;
    }

    final displayName = device.displayName;
    // No spoon-type question here any more. The device reports its own heater
    // capability in the owner-status capability bits, which the coordinator
    // reads on connect and writes into the record — so this seeds a
    // provisional value and the device corrects it moments later. See
    // heater_capability_prompt.dart.
    _bleService.setDeviceCapability(
      device.id,
      provisionalHeaterCapability(displayName),
    );

    setState(() => _connectingDeviceId = device.id);

    try {
      final result = await _bleService.connectToDevice(
        device.id,
        displayName: displayName,
      );
      if (!result.isSuccess) {
        // Stay on this screen and say why (e.g. the spoon is switched off) —
        // leaving it with "Connection failed: Exception: …" explained nothing.
        if (mounted) {
          _showSnackBar(
            result.detail ?? 'Could not connect — please try again.',
            isError: true,
          );
        }
        return;
      }

      if (mounted) {
        final name = displayName.isNotEmpty ? displayName : device.name;
        Navigator.pop(context);
        _showSnackBar(
          _bleService.isConnectedTo(device.id)
              ? 'Connected to $name'
              : 'Connecting to $name…',
          isError: false,
        );
      }
    } catch (e) {
      if (mounted) {
        // Timeout means we saved the device and are retrying in background.
        // Navigate back so the user can see the connection status on the home screen.
        final isTimeout = e.toString().contains('timed out');
        Navigator.pop(context);
        _showSnackBar(
          isTimeout
              ? 'Connecting to ${displayName.isNotEmpty ? displayName : device.name}… check back in a moment'
              : 'Connection failed: $e',
          isError: !isTimeout,
        );
      }
    } finally {
      if (mounted) {
        setState(() => _connectingDeviceId = null);
      }
    }
  }

  Future<void> _explainPermissionFailure(BlePermissionResult result) async {
    switch (result) {
      case BlePermissionResult.bluetoothOff:
        _showSnackBar('Turn on Bluetooth to find your spoon', isError: true);
        return;
      case BlePermissionResult.permanentlyDenied:
        final openSettings = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Bluetooth access needed'),
            content: Text(
              Platform.isIOS
                  ? 'Bluetooth is off for this app in iOS Settings. Enable it to scan for your spoon.'
                  : 'Bluetooth permission is blocked. Enable it in Settings to scan for your spoon.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Not now'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Open Settings'),
              ),
            ],
          ),
        );
        if (openSettings == true) {
          await openAppSettings();
        }
        return;
      case BlePermissionResult.denied:
      case BlePermissionResult.granted:
        _showSnackBar(
          Platform.isIOS
              ? 'Bluetooth permission is required to scan'
              : 'Bluetooth/Location permissions are required to scan',
          isError: true,
        );
    }
  }

  void _showSnackBar(String message, {bool isError = false}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message, style: GoogleFonts.figtree(color: Colors.white)),
        backgroundColor: isError ? AppTheme.paprika : AppTheme.sageDeep,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        margin: const EdgeInsets.all(16),
      ),
    );
  }

  @override
  void dispose() {
    // Ideally we stop scanning when leaving connection screen to save battery
    _bleService.stopScan();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Always dark mode for premium screen
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: Stack(
        children: [
          // Background
          Container(
            decoration: BoxDecoration(
              gradient: Theme.of(context).brightness == Brightness.dark
                  ? AppTheme.darkBackgroundGradient
                  : AppTheme.backgroundGradient,
            ),
          ),
          const GeometricBackground(),

          ListenableBuilder(
            // McuBleService owns the pairing verdict and the data-flow state
            // this screen now displays, so it must repaint on its notifications
            // too — otherwise the card keeps showing a stale status.
            listenable: _bleService,
            builder: (context, _) {
              final scannedDevices = _bleService.discoveredDevices;
              final savedDevices = _bleService.previousDevices;
              // Only spoons that are really connected. A spoon the app is
              // still reaching belongs in the saved list with its live status —
              // listing it under "Connected Devices" with a Disconnect button is
              // how a spoon that was not even in range looked connected.
              final connectedIds = _bleService.connectedDeviceIds;
              final isScanning = _bleService.isScanning;
              final isBluetoothOn = _bleService.isBluetoothOn;

              // If Bluetooth is off, show warning immediately
              if (!isBluetoothOn && _bleService.adapterResolved) {
                return _buildBluetoothOffState(context);
              }

              // Hide already-connected spoons. Keep unnamed iOS shells if they
              // already carry our product id or service UUID so a newly flashed
              // PCB is not invisible until the scan response arrives.
              final availableDevices = scannedDevices.where((d) {
                if (_bleService.isConnectedTo(d.id) ||
                    _bleService.isLinkingTo(d.id)) {
                  return false;
                }
                return d.name.trim().isNotEmpty ||
                    (d.productId != null && d.productId!.isNotEmpty);
              }).toList();

              return RefreshIndicator(
                onRefresh: () async {
                  await _bleService.stopScan();
                  await _startScan();
                },
                color: AppTheme.emerald,
                backgroundColor: Theme.of(context).colorScheme.surface,
                child: CustomScrollView(
                  slivers: [
                    _buildAppBar(context),

                    SliverToBoxAdapter(
                      child: _buildScanningHeader(
                      context,
                      isScanning: isScanning,
                      isConnecting: _bleService.isConnectHandshake,
                      isLinked: _bleService.isConnected,
                    ),
                    ),

                    // 1. Connected Devices Section
                    if (connectedIds.isNotEmpty) ...[
                      _buildSectionHeader(context, 'Connected Devices'),
                      SliverPadding(
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        sliver: SliverList(
                          delegate: SliverChildBuilderDelegate((
                            context,
                            index,
                          ) {
                            final deviceId = connectedIds[index];
                            final device = _bleService.getDeviceById(deviceId);
                            return _buildConnectedDeviceCard(
                              context,
                              device,
                              deviceId,
                            );
                          }, childCount: connectedIds.length),
                        ),
                      ),
                      const SliverToBoxAdapter(child: SizedBox(height: 24)),
                    ],

                    // 2. Previously Connected Devices Section
                    if (savedDevices
                        .where((d) =>
                            !_bleService.isConnectedTo(d.id))
                        .isNotEmpty) ...[
                      _buildSectionHeader(context, 'Previously Connected'),
                      SliverPadding(
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        sliver: SliverList(
                          delegate: SliverChildBuilderDelegate((
                            context,
                            index,
                          ) {
                            final savedDevice = savedDevices
                                .where((d) =>
                                    !_bleService.isConnectedTo(d.id))
                                .toList()[index];
                            return _buildSavedDeviceCard(context, savedDevice);
                          },
                          childCount: savedDevices
                              .where((d) =>
                                  !_bleService.isConnectedTo(d.id))
                              .length),
                        ),
                      ),
                      const SliverToBoxAdapter(child: SizedBox(height: 24)),
                    ],

                    // 3. Available Devices Section
                    _buildSectionHeader(context, 'Available Devices'),
                    if (availableDevices.isEmpty && !isScanning)
                      SliverFillRemaining(
                        hasScrollBody: false,
                        child: Padding(
                          padding: const EdgeInsets.only(top: 40, bottom: 40),
                          child: Center(
                            child: Text(
                              'No new devices found.\nPull to refresh.',
                              textAlign: TextAlign.center,
                              style: GoogleFonts.figtree(
                                color: AppTheme.textSecondary,
                                fontSize: 16,
                              ),
                            ),
                          ),
                        ),
                      )
                    else
                      SliverPadding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 20,
                          vertical: 8,
                        ),
                        sliver: SliverList(
                          delegate: SliverChildBuilderDelegate((
                            context,
                            index,
                          ) {
                            final device = availableDevices[index];
                            return _buildDeviceCard(context, device);
                          }, childCount: availableDevices.length),
                        ),
                      ),

                    // Bottom padding for scroll
                    const SliverToBoxAdapter(child: SizedBox(height: 40)),
                  ],
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildAppBar(BuildContext context) {
    return SliverAppBar(
      pinned: true,
      floating: true,
      elevation: 0,
      backgroundColor: Colors.transparent,
      title: Text(
        'Bluetooth Manager',
        style: GoogleFonts.outfit(
          fontWeight: FontWeight.w600,
          color: AppTheme.textPrimary,
          fontSize: 20,
        ),
      ),
      centerTitle: true,
      leading: IconButton(
        icon: Icon(
          Icons.arrow_back_ios_new,
          size: 20,
          color: Theme.of(context).colorScheme.onSurface,
        ),
        onPressed: () => Navigator.pop(context),
      ),
      actions: [
        IconButton(
          icon: Icon(Icons.refresh_rounded, color: AppTheme.emerald),
          onPressed: () {
            _bleService.stopScan().then((_) => _startScan());
          },
          tooltip: 'Rescan',
        ),
      ],
    );
  }

  Widget _buildBluetoothOffState(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.bluetooth_disabled,
            size: 80,
            color: Theme.of(
              context,
            ).colorScheme.onSurface.withValues(alpha: 0.3),
          ),
          const SizedBox(height: 24),
          Text(
            'Bluetooth is Off',
            style: GoogleFonts.figtree(
              fontSize: 24,
              fontWeight: FontWeight.bold,
              color: Theme.of(context).colorScheme.onSurface,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            'Please enable Bluetooth to\nscan for devices.',
            textAlign: TextAlign.center,
            style: GoogleFonts.figtree(
              fontSize: 13,
              color: Theme.of(
                context,
              ).colorScheme.onSurface.withValues(alpha: 0.7),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildScanningHeader(
    BuildContext context, {
    required bool isScanning,
    required bool isConnecting,
    required bool isLinked,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 32),
      child: Column(
        children: [
          SizedBox(
            height: 140,
            width: 140,
            child: Stack(
              alignment: Alignment.center,
              children: [
                // Radar Rings
                if (isScanning) ...[
                  Container(
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: AppTheme.emerald.withValues(alpha: 0.2),
                            width: 1,
                          ),
                        ),
                      )
                      .animate(onPlay: (c) => c.repeat(reverse: false))
                      .scale(
                        duration: 2.seconds,
                        begin: const Offset(0.5, 0.5),
                        end: const Offset(1.5, 1.5),
                      )
                      .fadeOut(duration: 2.seconds),

                  Container(
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: AppTheme.emerald.withValues(alpha: 0.2),
                            width: 1,
                          ),
                        ),
                      )
                      .animate(
                        delay: 1.seconds,
                        onPlay: (c) => c.repeat(reverse: false),
                      )
                      .scale(
                        duration: 2.seconds,
                        begin: const Offset(0.5, 0.5),
                        end: const Offset(1.5, 1.5),
                      )
                      .fadeOut(duration: 2.seconds),
                ],

                // Center Icon
                Container(
                  width: 90,
                  height: 90,
                  decoration: BoxDecoration(
                    color: AppTheme.emerald.withValues(alpha: 0.15),
                    shape: BoxShape.circle,
                    boxShadow: [
                      if (isScanning)
                        BoxShadow(
                          color: AppTheme.emerald.withValues(alpha: 0.3),
                          blurRadius: 30,
                          spreadRadius: 5,
                        ),
                    ],
                    border: Border.all(
                      color: AppTheme.emerald.withValues(alpha: 0.3),
                    ),
                  ),
                  child: Icon(
                    isScanning ? Icons.bluetooth_searching : Icons.bluetooth,
                    color: AppTheme.emerald,
                    size: 40,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          Text(
            isConnecting
                ? 'Connecting to your spoon…'
                : isScanning
                    ? 'Scanning for nearby devices...'
                    : isLinked
                        ? 'Spoon connected — pull to find another'
                        : 'Pull down to scan',
            style: GoogleFonts.figtree(
              color: Theme.of(
                context,
              ).colorScheme.onSurface.withValues(alpha: 0.6),
              fontSize: 14,
              letterSpacing: 0.5,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionHeader(BuildContext context, String title) {
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
        child: Text(
          title.toUpperCase(),
          style: GoogleFonts.figtree(
            fontSize: 12,
            fontWeight: FontWeight.bold,
            color: AppTheme.emerald,
            letterSpacing: 1.5,
          ),
        ),
      ),
    );
  }

  Widget _buildDeviceCard(BuildContext context, SavedBleDevice device) {
    final isConnecting = _connectingDeviceId == device.id;
    final displayName = device.displayName;

    return Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: PremiumGlassCard(
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                borderRadius: BorderRadius.circular(24),
                onTap: () => _handleConnect(device),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      // Signal Indicator
                      _buildRssiIndicator(device.lastRssi ?? device.rssi, context),
                      const SizedBox(width: 16),

                      // Device Info
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              displayName.isNotEmpty
                                  ? displayName
                                  : 'Unknown Device',
                              style: GoogleFonts.figtree(
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                                color: Theme.of(context).colorScheme.onSurface,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              device.id,
                              style: GoogleFonts.sourceCodePro(
                                // Monospace for ID
                                fontSize: 11,
                                color: Theme.of(
                                  context,
                                ).colorScheme.onSurface.withValues(alpha: 0.7),
                              ),
                            ),
                          ],
                        ),
                      ),

                      // Action / Status
                      if (isConnecting)
                        SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            valueColor: AlwaysStoppedAnimation<Color>(
                              AppTheme.emerald,
                            ),
                          ),
                        )
                      else
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 8,
                          ),
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              colors: [AppTheme.emerald, AppTheme.emerald],
                            ),
                            borderRadius: BorderRadius.circular(20),
                            boxShadow: [
                              BoxShadow(
                                color: AppTheme.emerald.withValues(alpha: 0.3),
                                blurRadius: 8,
                              ),
                            ],
                          ),
                          child: Text(
                            'Connect',
                            style: GoogleFonts.figtree(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                              fontSize: 12,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        )
        .animate()
        .fadeIn(duration: 300.ms)
        .slideY(begin: 0.1, end: 0, duration: 300.ms);
  }

  Widget _buildConnectedDeviceCard(
    BuildContext context,
    SavedBleDevice? device,
    String deviceId,
  ) {
    final name = device?.name ?? 'Unknown Device';

    // ⚠️ Derive the label from getDeviceUiState, NOT from the raw
    // connectedDeviceIds list this section is built from. That list means "a
    // GATT link exists", which is not the same as "working" — a spoon that
    // cannot bond has a perfectly good link and sends nothing. Hard-coding
    // 'Connected' here made this screen contradict the Home card, which
    // correctly showed "Preparing…" for the very same device at the same moment.
    final uiState = _bleService.getDeviceUiState(deviceId);
    final isReady = uiState == DeviceUiState.connected;
    // This list is a device picker, not a troubleshooting surface. The full
    // repair guidance lives on the Home card (with its action button); here a
    // multi-line instruction just wrapped into an unreadable column beside the
    // Disconnect button. Show the state, not the essay.
    final needsAttention = _bleService.isAuthRejected(deviceId);
    final prepareStep = _bleService.prepareStepFor(deviceId);
    final statusLabel = needsAttention
        ? 'Needs re-pairing'
        : (isReady ? 'Connected' : (prepareStep ?? 'Preparing…'));
    final statusColor = needsAttention
        ? Colors.orangeAccent
        : (isReady ? AppTheme.emerald : AppTheme.amber);

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: PremiumGlassCard(
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(24),
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => BleSettingsScreen(
                    deviceId: deviceId,
                    deviceName: name,
                  ),
                ),
              );
            },
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: AppTheme.emerald.withValues(alpha: 0.15),
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: AppTheme.emerald.withValues(alpha: 0.5),
                      ),
                    ),
                    child: Icon(
                      Icons.bluetooth_connected,
                      color: statusColor,
                      size: 20,
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          name,
                          style: GoogleFonts.figtree(
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                            color: Theme.of(context).colorScheme.onSurface,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          statusLabel,
                          style: GoogleFonts.figtree(
                            fontSize: 13,
                            color: needsAttention
                                ? statusColor
                                : Theme.of(context)
                                    .colorScheme
                                    .onSurface
                                    .withValues(alpha: 0.7),
                            height: 1.4,
                          ),
                        ),
                      ],
                    ),
                  ),
                  TextButton(
                    onPressed: () async {
                      await _bleService.disconnectDevice(deviceId);
                    },
                    style: TextButton.styleFrom(
                      foregroundColor: AppTheme.rose,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                    ),
                    child: const Text('Disconnect'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ).animate().fadeIn();
  }

  Widget _buildSavedDeviceCard(BuildContext context, SavedBleDevice device) {
    final uiState = _bleService.getDeviceUiState(device.id);
    // `preparing` means the link is up but not yet usable — treat it as busy so
    // the card shows a spinner instead of offering a second connect tap.
    final isConnecting = uiState == DeviceUiState.connecting ||
        uiState == DeviceUiState.preparing;
    final isConnected = uiState == DeviceUiState.connected;
    final isAvailable = uiState == DeviceUiState.available;

    // Status badge colour / label
    final Color stateColor;
    final String stateLabel;
    final IconData stateIcon;
    switch (uiState) {
      case DeviceUiState.connected:
        stateColor = AppTheme.emerald;
        stateLabel = 'Connected';
        stateIcon = Icons.bluetooth_connected;
      case DeviceUiState.preparing:
        stateColor = AppTheme.amber;
        stateLabel = 'Preparing…';
        stateIcon = Icons.bluetooth_connected;
      case DeviceUiState.connecting:
        stateColor = AppTheme.amber;
        stateLabel = 'Connecting…';
        stateIcon = Icons.bluetooth_searching;
      case DeviceUiState.available:
        stateColor = AppTheme.amber;
        stateLabel = 'In range';
        stateIcon = Icons.bluetooth_searching;
      case DeviceUiState.error:
        stateColor = Colors.redAccent;
        stateLabel = 'Error – Tap to retry';
        stateIcon = Icons.error_outline;
      case DeviceUiState.bluetoothOff:
        stateColor = Colors.grey;
        stateLabel = 'Bluetooth Off';
        stateIcon = Icons.bluetooth_disabled;
      case DeviceUiState.unavailable:
        stateColor = Colors.grey;
        // Not heard advertising. Show when it was last seen instead of a bare
        // "Unavailable" — same wording as the Home card so the two screens
        // never disagree about the same device.
        stateLabel = device.formattedLastConnected.isNotEmpty
            ? 'Not connected · last ${device.formattedLastConnected}'
            : 'Not connected';
        stateIcon = Icons.bluetooth_disabled;
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: PremiumGlassCard(
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(24),
            onTap: isConnected
                ? null
                : () {
                    _handleConnect(device);
                  },
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  // Icon with state-colour background
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: stateColor.withValues(alpha: 0.12),
                      shape: BoxShape.circle,
                    ),
                    child: isConnecting
                        ? Padding(
                            padding: const EdgeInsets.all(10),
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              valueColor: AlwaysStoppedAnimation<Color>(stateColor),
                            ),
                          )
                        : Icon(stateIcon, color: stateColor, size: 22),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          device.displayName,
                          style: GoogleFonts.figtree(
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                            color: Theme.of(context).colorScheme.onSurface,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 3),
                        // State badge row
                        Row(
                          children: [
                            Container(
                              width: 6,
                              height: 6,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: stateColor,
                              ),
                            ),
                            const SizedBox(width: 5),
                            Expanded(
                              child: Text(
                                stateLabel,
                                style: GoogleFonts.figtree(
                                  fontSize: 12,
                                  color: stateColor,
                                  fontWeight: FontWeight.w600,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 3),
                        // Last seen or last connected
                        Text(
                          isAvailable && device.lastRssi != null
                              ? 'RSSI: ${device.lastRssi} dBm · ${device.formattedLastConnected}'
                              : 'Last: ${device.formattedLastConnected}',
                          style: GoogleFonts.figtree(
                            fontSize: 11,
                            color: Theme.of(context)
                                .colorScheme
                                .onSurface
                                .withValues(alpha: 0.4),
                          ),
                        ),
                      ],
                    ),
                  ),
                  // RSSI bars when available
                  if (device.lastRssi != null && !isConnected)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: _buildRssiIndicator(device.lastRssi!, context),
                    ),
                  // Rename button
                  IconButton(
                    icon: Icon(
                      Icons.edit_outlined,
                      size: 18,
                      color: Theme.of(context)
                          .colorScheme
                          .onSurface
                          .withValues(alpha: 0.4),
                    ),
                    tooltip: 'Rename',
                    onPressed: () => _showRenameDialog(context, device),
                  ),
                  // Forget button — destructive (full re-scan/re-pair to
                  // undo), so it gets a confirmation like every other
                  // destructive action in this app rather than firing on a
                  // single tap of an 18px icon sitting right next to Rename.
                  IconButton(
                    icon: const Icon(
                      Icons.delete_outline,
                      size: 18,
                      color: AppTheme.paprika,
                    ),
                    tooltip: 'Forget',
                    onPressed: () => _confirmForgetDevice(context, device),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ).animate().fadeIn();
  }

  /// PRD FR-SAVE-006 — user-facing rename dialog.
  void _showRenameDialog(BuildContext context, SavedBleDevice device) {
    final controller = TextEditingController(text: device.customName ?? device.name);
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          'Rename Device',
          style: GoogleFonts.figtree(fontWeight: FontWeight.bold),
        ),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(
            labelText: 'Display Name',
            hintText: device.name,
            border: const OutlineInputBorder(),
          ),
          onSubmitted: (_) => _commitRename(ctx, device.id, controller.text),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => _commitRename(ctx, device.id, controller.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  Future<void> _commitRename(
      BuildContext ctx, String deviceId, String newName) async {
    Navigator.pop(ctx);
    await _bleService.renameDevice(deviceId, newName);
  }

  /// Confirm before forgetting a paired spoon — forgetDevice disconnects,
  /// wipes the saved record, and clears the session; undoing it means
  /// scanning and re-pairing from scratch. Was previously one tap on an 18px
  /// icon right next to Rename, with no confirmation at all.
  Future<void> _confirmForgetDevice(
    BuildContext context,
    SavedBleDevice device,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          'Forget this spoon?',
          style: GoogleFonts.figtree(fontWeight: FontWeight.bold),
        ),
        content: Text(
          '"${device.displayName}" will be unpaired. You\'ll need to scan '
          'and pair it again to use it.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppTheme.paprika),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Forget'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await _bleService.forgetDevice(device.id);
    }
  }


  Widget _buildRssiIndicator(int rssi, BuildContext context) {
    // RSSI range typically -100 (weak) to -40 (strong)
    // 4 bars
    int bars = 0;
    if (rssi > -60) {
      bars = 4;
    } else if (rssi > -70) {
      bars = 3;
    } else if (rssi > -80) {
      bars = 2;
    } else if (rssi > -90) {
      bars = 1;
    }

    final color = AppTheme.emerald;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: List.generate(4, (index) {
        return Container(
          margin: const EdgeInsets.symmetric(horizontal: 1.5),
          width: 3,
          height: 6.0 + (index * 4), // 6, 10, 14, 18
          decoration: BoxDecoration(
            color: index < bars ? color : color.withValues(alpha: 0.2),
            borderRadius: BorderRadius.circular(2),
            boxShadow: index < bars
                ? [
                    BoxShadow(
                      color: color.withValues(alpha: 0.5),
                      blurRadius: 4,
                    ),
                  ]
                : null,
          ),
        );
      }),
    );
  }
}

// SpoonTypeOption (the bottom-sheet row widget) now lives in
// heater_capability_prompt.dart alongside the prompt that uses it.
