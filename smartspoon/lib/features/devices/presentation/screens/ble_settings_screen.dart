// ble_settings_screen.dart — live BLE diagnostics / developer inspection screen.
//
// A debug/settings view for a connected spoon: shows connection status, battery,
// temperature, hardware bite count, packet/data-rate stats, dropped packets, and
// a rolling raw-packet log from McuBleService. Useful for verifying that sensor
// data is actually flowing and for firmware/protocol troubleshooting.
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:smartspoon/core/widgets/bowl_spoon_icon.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'package:smartspoon/features/devices/index.dart';
import 'package:smartspoon/features/devices/presentation/screens/firmware_update_screen.dart';
import 'package:smartspoon/core/theme/app_theme.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:smartspoon/core/utils/temperature_format.dart';

/// Comprehensive BLE data visualization screen
class BleSettingsScreen extends StatefulWidget {
  final String deviceId;
  final String deviceName;

  const BleSettingsScreen({
    super.key,
    required this.deviceId,
    required this.deviceName,
  });

  @override
  State<BleSettingsScreen> createState() => _BleSettingsScreenState();
}

class _BleSettingsScreenState extends State<BleSettingsScreen> {
  late SpoonRuntime _mcuService;
  bool _isConnecting = true;
  bool _showRawData = false;
  String _statusMessage = 'Connecting to device...';

  @override
  void initState() {
    super.initState();
    // Use the shared McuBleService from Provider
    _mcuService = Provider.of<SpoonRuntime>(context, listen: false);
    _connectToDevice();
  }

  Future<void> _connectToDevice() async {
    setState(() {
      _statusMessage = 'Checking device connection...';
    });

    try {
      final bleService = Provider.of<SpoonRuntime>(context, listen: false);
      bool isGattConnected = bleService.isDeviceConnected(widget.deviceId);

      // If not connected yet, wait a moment (gives time for background takeover to finish)
      if (!isGattConnected) {
        setState(() {
          _isConnecting = true;
          _statusMessage = 'Waiting for connection...';
        });
        // Actually ASK for a reconnect. This screen's Disconnect button persists
        // autoConnect=false, so just polling for 3 s could never succeed — the
        // Reconnect button reliably reported "Connect from Home first" while
        // Home offered no way back either.
        await bleService.reconnectSavedDevice(widget.deviceId);
        for (int i = 0; i < 5; i++) {
          await Future.delayed(const Duration(milliseconds: 600));
          if (bleService.isDeviceConnected(widget.deviceId)) {
            isGattConnected = true;
            break;
          }
        }
      }

      if (!isGattConnected) {
        if (!mounted) return;
        setState(() {
          _isConnecting = false;
          _statusMessage =
              'Still looking for this spoon — keep it nearby and powered on.';
        });
        return;
      }

      // OPTIMISTIC: If GATT is active, show the dashboard immediately.
      setState(() {
        _isConnecting = false;
        _statusMessage = 'Initializing data stream...';
      });

      // Background subscription
      await _mcuService.subscribeToDevice(widget.deviceId);

      if (mounted) {
        setState(() {
          _statusMessage = _mcuService.isConnected
              ? 'Connected and receiving data'
              : 'Failed to subscribe';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isConnecting = false;
          _statusMessage = 'Error: $e';
        });
      }
    }
  }

  @override
  void dispose() {
    // Don't disconnect - keep connection alive for other screens
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;

    return ChangeNotifierProvider.value(
      value: _mcuService,
      child: Scaffold(
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        appBar: AppBar(
          title: Text(
            'BLE Data Monitor',
            style: AppTheme.serif(fontSize: 18, fontWeight: FontWeight.w600),
          ),
          centerTitle: true,
          actions: [
            // Debug-only: FirmwareUpdateScreen expects the operator to paste
            // the raw HTTPS URL of zephyr.signed.bin and its SHA-256 by
            // hand — a developer/QA tool, not a patient-facing "check for
            // updates" flow (there's no bundled trusted manifest URL to
            // check against; SHA-256 there only catches accidental
            // corruption, not a malicious source, since the operator
            // supplies both the file and the hash to compare it against).
            // This screen is reached by tapping an already-paired device's
            // own name in the normal device list, so without this gate any
            // real patient doing that could land on a firmware-flashing
            // tool built for engineers. Keep it available in debug builds
            // for development/QA; hide it once a real backend-driven
            // update flow with a trusted manifest source exists.
            if (kDebugMode)
              IconButton(
                icon: const Icon(Icons.system_update),
                tooltip: 'Firmware Update',
                onPressed: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => FirmwareUpdateScreen(
                        deviceId: widget.deviceId,
                        deviceName: widget.deviceName,
                      ),
                    ),
                  );
                },
              ),
            IconButton(
              icon: const Icon(Icons.bluetooth_disabled),
              tooltip: 'Disconnect',
              onPressed: () async {
                final bleService = Provider.of<SpoonRuntime>(
                  context,
                  listen: false,
                );
                await bleService.disconnectDevice(widget.deviceId);
                if (context.mounted) {
                  Navigator.of(
                    context,
                  ).pop(); // Go back home after forcing disconnect
                }
              },
            ),
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: 'Reconnect',
              onPressed: _connectToDevice,
            ),
          ],
        ),
        body: _isConnecting
            ? _buildLoadingState()
            : Consumer<SpoonRuntime>(
                builder: (context, service, _) {
                  if (!service.isConnected) {
                    return _buildDisconnectedState();
                  }
                  return _buildDataView(service, isDarkMode);
                },
              ),
      ),
    );
  }

  Widget _buildLoadingState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 16),
          Text(
            _statusMessage,
            style: GoogleFonts.figtree(
              fontSize: 16,
              color: AppTheme.textSecondary,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  Widget _buildDisconnectedState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.bluetooth_disabled,
            size: 80,
            color: AppTheme.textTertiary,
          ),
          const SizedBox(height: 24),
          Text(
            'Device Disconnected',
            style: AppTheme.serif(fontSize: 22, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 12),
          Text(
            _statusMessage,
            style: GoogleFonts.figtree(
              fontSize: 16,
              color: AppTheme.textSecondary,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 32),
          ElevatedButton.icon(
            onPressed: _connectToDevice,
            icon: const Icon(Icons.refresh),
            label: const Text('Reconnect'),
          ),
          const SizedBox(height: 16),
          TextButton.icon(
            onPressed: () async {
              final bleService = Provider.of<SpoonRuntime>(
                context,
                listen: false,
              );
              await bleService.forgetDevice(widget.deviceId);
              if (mounted) {
                Navigator.of(context).pop();
              }
            },
            icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
            label: const Text(
              'Forget / Unpair Device',
              style: TextStyle(color: Colors.redAccent),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDataView(SpoonRuntime service, bool isDarkMode) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Device Info Header
          _buildDeviceHeader(service, isDarkMode),
          const SizedBox(height: 12),
          _buildPanelPolarityCard(service, isDarkMode),
          const SizedBox(height: 20),

          // Overview Cards
          _buildOverviewCards(service, isDarkMode),
          const SizedBox(height: 20),

          // Packet Statistics
          _buildPacketStats(service, isDarkMode),
          const SizedBox(height: 20),

          // Tremor Analysis
          _buildTremorSection(isDarkMode),
          const SizedBox(height: 20),

          // IMU Samples Table
          _buildImuSamplesSection(service, isDarkMode),
          const SizedBox(height: 20),

          // Packet Structure Info
          _buildPacketStructure(isDarkMode),
          const SizedBox(height: 20),

          // Raw Data Viewer
          _buildRawDataViewer(service, isDarkMode),
          const SizedBox(height: 32),

          // Unpair Button
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () async {
                final bleService = Provider.of<SpoonRuntime>(
                  context,
                  listen: false,
                );
                await bleService.forgetDevice(widget.deviceId);
                if (mounted) {
                  Navigator.of(context).pop();
                }
              },
              icon: const Icon(Icons.phonelink_erase, color: Colors.redAccent),
              label: const Text(
                'Forget / Unpair Device',
                style: TextStyle(
                  color: Colors.redAccent,
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 16),
                side: const BorderSide(color: Colors.redAccent),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ),
          const SizedBox(height: 32),
        ],
      ),
    );
  }

  /// Spoon screen polarity.
  ///
  /// Two glass variants ship on this product and they cannot be told apart in
  /// software — the panel SPI is write-only, so the glass never answers an ID
  /// read. On one variant the dark theme paints correctly; on the other the
  /// same bytes come out inverted, giving a white screen with black text. The
  /// firmware persists whichever the user picks, so this is set once per spoon.
  Widget _buildPanelPolarityCard(SpoonRuntime service, bool isDarkMode) {
    final connected = service.isConnected;
    return Card(
      margin: EdgeInsets.zero,
      child: ListTile(
        leading: Icon(
          Icons.contrast,
          color: connected ? AppTheme.caramel : Colors.grey,
        ),
        title: const Text('Spoon screen colours'),
        subtitle: Text(
          connected
              ? 'If the spoon shows black text on white, tap Invert.'
              : 'Connect a spoon to change its screen.',
        ),
        trailing: Wrap(
          spacing: 8,
          children: [
            OutlinedButton(
              onPressed: connected
                  ? () async {
                      final ok = await service.setPanelInverted(true);
                      if (!context.mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                        content: Text(ok
                            ? 'Sent — the spoon screen should turn dark.'
                            : 'Could not reach the spoon.'),
                      ));
                    }
                  : null,
              child: const Text('Invert'),
            ),
            TextButton(
              onPressed: connected
                  ? () async {
                      final ok = await service.setPanelInverted(false);
                      if (!context.mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                        content: Text(ok
                            ? 'Sent — screen restored to the other variant.'
                            : 'Could not reach the spoon.'),
                      ));
                    }
                  : null,
              child: const Text('Reset'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDeviceHeader(SpoonRuntime service, bool isDarkMode) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: isDarkMode
              ? [AppTheme.darkBg, AppTheme.darkSurfaceCard]
              : [AppTheme.caramel, AppTheme.honey],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: AppTheme.cardShadow,
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.2),
              shape: BoxShape.circle,
            ),
            child: Icon(
              service.isConnected ? Icons.bluetooth_connected : Icons.bluetooth,
              color: Colors.white,
              size: 32,
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.deviceName,
                  style: AppTheme.serif(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  service.isConnected
                      ? 'Connected & Streaming'
                      : 'Disconnected',
                  style: GoogleFonts.figtree(
                    fontSize: 14,
                    color: Colors.white.withValues(alpha: 0.9),
                  ),
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: service.isConnected ? AppTheme.sageDeep : AppTheme.paprika,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(
              service.isConnected ? 'LIVE' : 'OFFLINE',
              style: GoogleFonts.figtree(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
          ),
        ],
      ),
    ).animate().fadeIn(duration: 400.ms).slideY(begin: -0.2, end: 0);
  }

  Widget _buildOverviewCards(SpoonRuntime service, bool isDarkMode) {
    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: _buildMetricCard(
                icon: const Icon(Icons.battery_charging_full),
                iconColor: _getBatteryColor(service.batteryLevel),
                label: 'Battery',
                value: '${service.batteryLevel}%',
                subtitle: service.batteryLevel < 20 ? 'Low' : 'Good',
                isDarkMode: isDarkMode,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _buildMetricCard(
                icon: const Icon(Icons.thermostat),
                iconColor: _getTempColor(service.temperature),
                label: 'Temperature',
                value: formatSpoonTempWithUnit(service.temperature),
                subtitle: _getTempLabel(service.temperature),
                isDarkMode: isDarkMode,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: _buildMetricCard(
                icon: const Icon(Icons.access_time),
                iconColor: AppTheme.emerald,
                label: 'Last Packet',
                value: service.lastPacketTime != null
                    ? _formatTimestamp(service.lastPacketTime!)
                    : 'N/A',
                subtitle: service.lastPacketTime != null
                    ? '${DateTime.now().difference(service.lastPacketTime!).inMilliseconds}ms ago'
                    : 'Waiting...',
                isDarkMode: isDarkMode,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _buildMetricCard(
                icon: const BowlSpoonIcon(),
                iconColor: AppTheme.honey,
                label: 'Bites (MCU)',
                value: '${service.hardwareBiteCount}',
                // The spoon's own counter, shown for firmware debugging only:
                // every screen in the app counts with the AI Lab model instead.
                subtitle: service.hardwareBiteCount == 0
                    ? 'Device counter'
                    : 'Device counter (stats use Mealsense)',
                isDarkMode: isDarkMode,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildMetricCard({
    required Widget icon,
    required Color iconColor,
    required String label,
    required String value,
    required String subtitle,
    required bool isDarkMode,
  }) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isDarkMode ? AppTheme.darkSurfaceCard : AppTheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isDarkMode ? AppTheme.darkBorder : AppTheme.border,
        ),
        boxShadow: [
          BoxShadow(
            color: AppTheme.cardShadow,
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        children: [
          IconTheme(
            data: IconThemeData(color: iconColor, size: 36),
            child: icon,
          ),
          const SizedBox(height: 8),
          Text(
            label,
            style: GoogleFonts.figtree(
              fontSize: 12,
              color: AppTheme.textSecondary,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            value,
            style: GoogleFonts.figtree(
              fontSize: 24,
              fontWeight: FontWeight.bold,
              color: Theme.of(context).colorScheme.onSurface,
            ),
          ),
          Text(
            subtitle,
            style: GoogleFonts.figtree(
              fontSize: 11,
              color: AppTheme.textTertiary,
            ),
          ),
        ],
      ),
    ).animate().fadeIn(duration: 400.ms).scale(begin: const Offset(0.9, 0.9));
  }

  Widget _buildPacketStats(SpoonRuntime service, bool isDarkMode) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isDarkMode ? AppTheme.darkSurfaceCard : AppTheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isDarkMode ? AppTheme.darkBorder : AppTheme.border,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.analytics, color: AppTheme.emerald, size: 24),
              const SizedBox(width: 8),
              Text(
                'Packet Statistics',
                style: GoogleFonts.figtree(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: Theme.of(context).colorScheme.onSurface,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          _buildStatRow(
            'Total Packets',
            '${service.receivedPackets}',
            Icons.inventory_2,
          ),
          _buildStatRow(
            'Packets/sec',
            service.packetsPerSecond.toStringAsFixed(1),
            Icons.speed,
          ),
          _buildStatRow(
            'Data Rate',
            '${service.dataRate.toStringAsFixed(0)} B/s',
            Icons.data_usage,
          ),
          _buildStatRow(
            'Expected Size',
            '127 bytes/packet',
            Icons.info_outline,
          ),
        ],
      ),
    );
  }

  Widget _buildStatRow(String label, String value, IconData icon) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Icon(icon, size: 20, color: AppTheme.textSecondary),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              label,
              style: GoogleFonts.figtree(
                fontSize: 14,
                color: AppTheme.textSecondary,
              ),
            ),
          ),
          Text(
            value,
            style: GoogleFonts.figtree(
              fontSize: 14,
              fontWeight: FontWeight.bold,
              color: AppTheme.textPrimary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildImuSamplesSection(SpoonRuntime service, bool isDarkMode) {
    final data = service.currentData;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isDarkMode ? AppTheme.darkSurfaceCard : AppTheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isDarkMode
              ? Colors.transparent
              : AppTheme.emerald.withValues(alpha: 0.3),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.sensors, color: AppTheme.emerald, size: 24),
              const SizedBox(width: 8),
              Text(
                'Current IMU Data',
                style: GoogleFonts.figtree(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: Theme.of(context).colorScheme.onSurface,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          if (data == null)
            Center(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Text(
                  'Waiting for sensor data...',
                  style: GoogleFonts.figtree(color: AppTheme.textSecondary),
                ),
              ),
            )
          else
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: DataTable(
                headingRowColor: WidgetStateProperty.all(
                  AppTheme.emerald.withValues(alpha: 0.1),
                ),
                columns: [
                  DataColumn(
                    label: Text(
                      'Axis',
                      style: GoogleFonts.figtree(fontWeight: FontWeight.bold),
                    ),
                  ),
                  DataColumn(
                    label: Text(
                      'Accel (g)',
                      style: GoogleFonts.figtree(fontWeight: FontWeight.bold),
                    ),
                  ),
                  DataColumn(
                    label: Text(
                      'Gyro (°/s)',
                      style: GoogleFonts.figtree(fontWeight: FontWeight.bold),
                    ),
                  ),
                ],
                rows: [
                  _buildDataRow('X', data.accelX, data.gyroX),
                  _buildDataRow('Y', data.accelY, data.gyroY),
                  _buildDataRow('Z', data.accelZ, data.gyroZ),
                ],
              ),
            ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppTheme.emerald.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                Icon(Icons.info_outline, size: 16, color: AppTheme.emerald),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Showing last sample from 10-sample packet',
                    style: GoogleFonts.figtree(
                      fontSize: 12,
                      color: AppTheme.textSecondary,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  DataRow _buildDataRow(String axis, double accel, double gyro) {
    return DataRow(
      cells: [
        DataCell(
          Text(axis, style: GoogleFonts.figtree(fontWeight: FontWeight.bold)),
        ),
        DataCell(
          Text(accel.toStringAsFixed(3), style: GoogleFonts.robotoMono()),
        ),
        DataCell(
          Text(gyro.toStringAsFixed(2), style: GoogleFonts.robotoMono()),
        ),
      ],
    );
  }

  Widget _buildPacketStructure(bool isDarkMode) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isDarkMode ? AppTheme.darkSurfaceCard : AppTheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isDarkMode
              ? Colors.transparent
              : AppTheme.emerald.withValues(alpha: 0.3),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.architecture, color: AppTheme.emerald, size: 24),
              const SizedBox(width: 8),
              Text(
                'Packet Structure (127 bytes)',
                style: GoogleFonts.figtree(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: Theme.of(context).colorScheme.onSurface,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          _buildStructureItem('Byte 0', 'Battery Level', 'uint8 (0-100%)'),
          _buildStructureItem(
            'Bytes 1-2',
            'Temperature',
            'int16 LE (°C × 100)',
          ),
          _buildStructureItem(
            'Bytes 3-6',
            'Timestamp',
            'uint32 LE (milliseconds)',
          ),
          _buildStructureItem(
            'Bytes 7-8',
            'Bite Count',
            'uint16 LE (total bites)',
          ),
          _buildStructureItem(
            'Bytes 9-128',
            '10 IMU Samples',
            'Each 12 bytes:',
          ),
          Padding(
            padding: const EdgeInsets.only(left: 24, top: 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildSubItem('ax, ay, az', 'int16 × 3 (÷1000 → g)'),
                _buildSubItem('gx, gy, gz', 'int16 × 3 (÷100 → °/s)'),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStructureItem(String bytes, String field, String format) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 80,
            child: Text(
              bytes,
              style: GoogleFonts.robotoMono(
                fontSize: 12,
                color: AppTheme.emerald,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  field,
                  style: GoogleFonts.figtree(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.textPrimary,
                  ),
                ),
                Text(
                  format,
                  style: GoogleFonts.figtree(
                    fontSize: 12,
                    color: AppTheme.textSecondary,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSubItem(String field, String format) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Text('• ', style: TextStyle(color: AppTheme.textSecondary)),
          Text(
            field,
            style: GoogleFonts.robotoMono(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: AppTheme.textPrimary,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            format,
            style: GoogleFonts.figtree(
              fontSize: 12,
              color: AppTheme.textSecondary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRawDataViewer(SpoonRuntime service, bool isDarkMode) {
    final rawPacket = service.lastRawPacket;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isDarkMode ? AppTheme.darkSurfaceCard : AppTheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isDarkMode
              ? Colors.transparent
              : AppTheme.emerald.withValues(alpha: 0.3),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  Icon(Icons.code, color: AppTheme.emerald, size: 24),
                  const SizedBox(width: 8),
                  Text(
                    'Raw Packet Data',
                    style: GoogleFonts.figtree(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                  ),
                ],
              ),
              Row(
                children: [
                  if (rawPacket != null)
                    IconButton(
                      icon: const Icon(Icons.copy, size: 20),
                      tooltip: 'Copy to clipboard',
                      onPressed: () => _copyRawData(rawPacket),
                    ),
                  IconButton(
                    icon: Icon(
                      _showRawData ? Icons.expand_less : Icons.expand_more,
                      size: 24,
                    ),
                    onPressed: () {
                      setState(() {
                        _showRawData = !_showRawData;
                      });
                    },
                  ),
                ],
              ),
            ],
          ),
          if (_showRawData) ...[
            const SizedBox(height: 12),
            if (rawPacket == null)
              Center(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Text(
                    'No packet data available',
                    style: GoogleFonts.figtree(color: AppTheme.textSecondary),
                  ),
                ),
              )
            else
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.grey[900],
                  borderRadius: BorderRadius.circular(8),
                ),
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Text(
                    _formatHexDump(rawPacket),
                    style: GoogleFonts.jetBrainsMono(
                      fontSize: 11,
                      // Cyan rather than terminal-green: keeps the console feel
                      // of a raw hex dump without reintroducing green.
                      color: const Color(0xFF5FD8F0),
                      height: 1.5,
                    ),
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }

  String _formatHexDump(List<int> data) {
    final buffer = StringBuffer();
    for (int i = 0; i < data.length; i += 16) {
      // Offset
      buffer.write('${i.toRadixString(16).padLeft(4, '0')}:  ');

      // Hex values
      for (int j = 0; j < 16; j++) {
        if (i + j < data.length) {
          buffer.write('${data[i + j].toRadixString(16).padLeft(2, '0')} ');
        } else {
          buffer.write('   ');
        }
        if (j == 7) buffer.write(' ');
      }

      buffer.write('\n');
    }
    return buffer.toString();
  }

  void _copyRawData(List<int> data) {
    final hexString = data
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join(' ');
    Clipboard.setData(ClipboardData(text: hexString));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Raw data copied to clipboard',
          style: GoogleFonts.figtree(),
        ),
        backgroundColor: AppTheme.sageDeep,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    );
  }

  Widget _buildTremorSection(bool isDarkMode) {
    // DO NOT use Consumer - causes crashes
    // Read data once without listening
    final tremorService = Provider.of<TremorDetectionService>(
      context,
      listen: false,
    );
    final result = tremorService.lastResult;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isDarkMode ? AppTheme.darkSurfaceCard : AppTheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isDarkMode ? AppTheme.darkBorder : AppTheme.border,
        ),
        boxShadow: [
          BoxShadow(
            color: AppTheme.cardShadow,
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.waves, color: AppTheme.emerald, size: 24),
              const SizedBox(width: 8),
              Text(
                'Movement Pattern',
                style: GoogleFonts.figtree(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: AppTheme.textPrimary,
                ),
              ),
              const Spacer(),
              // Manual refresh button
              IconButton(
                icon: Icon(
                  Icons.refresh,
                  size: 20,
                  color: AppTheme.textSecondary,
                ),
                onPressed: () {
                  setState(() {}); // Rebuild to get latest data
                },
                tooltip: 'Refresh',
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: result.measured && result.detected
                      ? AppTheme.paprika.withValues(alpha: 0.1)
                      : AppTheme.brandTint,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  !result.measured
                      ? 'NO READING'
                      : result.detected
                      ? 'RHYTHM FOUND'
                      : 'NO RHYTHM',
                  style: GoogleFonts.figtree(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: result.measured && result.detected
                        ? AppTheme.paprika
                        : AppTheme.primary,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          if (!result.measured)
            Center(
              child: Padding(
                padding: const EdgeInsets.all(8.0),
                child: Text(
                  'Collecting a clean sample…\nHold and use the spoon naturally for about 4 seconds.',
                  textAlign: TextAlign.center,
                  style: GoogleFonts.figtree(
                    color: AppTheme.textSecondary,
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ),
            )
          else
            Row(
              children: [
                Expanded(
                  child: _buildTremorMetric(
                    'Pattern index',
                    '${result.score.toStringAsFixed(2)} / 3',
                    Icons.graphic_eq,
                    AppTheme.emerald,
                    isDarkMode,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _buildTremorMetric(
                    'Repeated rhythm',
                    result.detected
                        ? '${result.frequency.toStringAsFixed(1)} Hz'
                        : 'Not seen',
                    Icons.show_chart,
                    AppTheme.coral,
                    isDarkMode,
                  ),
                ),
              ],
            ),
          if (result.measured) ...[
            const SizedBox(height: 12),
            Text(
              'Reading quality ${(result.confidence * 100).round()}%',
              style: GoogleFonts.figtree(
                fontSize: 12,
                color: AppTheme.textSecondary,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildTremorMetric(
    String label,
    String value,
    IconData icon,
    Color color,
    bool isDarkMode,
  ) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: color, size: 16),
              const SizedBox(width: 4),
              Text(
                label,
                style: GoogleFonts.figtree(
                  fontSize: 12,
                  color: AppTheme.textSecondary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            value,
            style: GoogleFonts.figtree(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: AppTheme.textPrimary,
            ),
          ),
        ],
      ),
    );
  }

  String _formatTimestamp(DateTime time) {
    return '${time.hour.toString().padLeft(2, '0')}:'
        '${time.minute.toString().padLeft(2, '0')}:'
        '${time.second.toString().padLeft(2, '0')}';
  }

  Color _getBatteryColor(int level) {
    if (level >= 60) return AppTheme.sageDeep;
    if (level >= 30) return AppTheme.honey;
    return AppTheme.paprika;
  }

  Color _getTempColor(double temp) {
    if (temp >= 60) return AppTheme.paprika;
    if (temp >= 35) return AppTheme.honey;
    return AppTheme.emerald;
  }

  String _getTempLabel(double temp) {
    if (temp >= 60) return 'Hot';
    if (temp >= 35) return 'Warm';
    if (temp >= 20) return 'Room Temp';
    return 'Cold';
  }
}
