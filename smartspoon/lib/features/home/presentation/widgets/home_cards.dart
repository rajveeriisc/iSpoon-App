// home_cards.dart — the card widgets that make up the Home tab.
//
// A collection of dashboard cards driven by UnifiedDataService / McuBleService:
// SpoonConnectedCard (device + battery/status), TemperatureCard, EatingAnalysisCard
// (bites, pace, stability + per-meal breakdown) and the daily tip / motivation
// cards. Each is a self-contained, per-deviceId widget the home_page composes
// into the feed.
import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'package:smartspoon/features/ai_lab/domain/services/personalized_eating_model.dart';
import 'package:smartspoon/features/insights/index.dart';
import 'package:smartspoon/features/devices/index.dart';
import 'package:smartspoon/core/widgets/premium_widgets.dart'; // Import custom premium widgets
import 'package:smartspoon/core/theme/app_theme.dart';
import 'package:smartspoon/core/services/system_settings_service.dart';
import 'package:flutter_animate/flutter_animate.dart'; // For animations
import 'package:smartspoon/core/utils/temperature_format.dart';

/// BLE Device Card - Shows connected device with battery and status
class SpoonConnectedCard extends StatefulWidget {
  final String? deviceId;
  const SpoonConnectedCard({super.key, this.deviceId});

  @override
  State<SpoonConnectedCard> createState() => _SpoonConnectedCardState();
}

class _SpoonConnectedCardState extends State<SpoonConnectedCard> {
  late SpoonRuntime _bleService;

  @override
  void initState() {
    super.initState();
    _bleService = Provider.of<SpoonRuntime>(context, listen: false);
  }

  void _navigateToAddDevice() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => const AddDeviceScreen()),
    );
  }

  void _navigateToDeviceDetails() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => const AddDeviceScreen()),
    );
  }

  Future<void> _handleReconnect(String deviceId) async {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Attempting to reconnect...')));
    // reconnectSavedDevice (not autoConnectToLastDevice): the latter skips any
    // device with autoConnect=false, which is exactly the state an explicit
    // "Disconnect" leaves the spoon in — so this button used to do nothing for
    // the one case a user is most likely to press it in.
    final outcome = await _bleService.reconnectSavedDevice(deviceId);
    if (!mounted) return;
    final name =
        _bleService.getDeviceById(deviceId)?.displayName ?? 'This spoon';
    await explainSpoonSwitch(context, _bleService, deviceId, name, outcome);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      // McuBleService owns the auth-rejection flag and the live data state, so
      // the card must repaint on its notifications too — not just BleService's.
      listenable: _bleService,
      builder: (context, _) {
        final dataService = Provider.of<UnifiedDataService>(context);
        final savedDevices = _bleService.previousDevices;
        final devId = widget.deviceId ?? dataService.primaryDeviceId ?? '';
        final batteryLevel = dataService.batteryLevelFor(devId);

        // PRD §7.7 — single source-of-truth state from BleService
        final uiState = devId.isNotEmpty
            ? _bleService.getDeviceUiState(devId)
            : (savedDevices.isEmpty
                  ? null
                  : _bleService.getDeviceUiState(savedDevices.first.id));

        // If no saved device at all, show the "add device" prompt card
        if (uiState == null && savedDevices.isEmpty) {
          return _buildNoDeviceCard();
        }

        final effectiveDevId = devId.isNotEmpty ? devId : savedDevices.first.id;
        var effectiveState = uiState ?? DeviceUiState.unavailable;

        // DATA IS THE GROUND TRUTH. BleService's FSM only tracks the FOREGROUND
        // GATT link, and that link can lag the one actually streaming — right
        // after an RPA-rotation adopt (spoon re-anchored to a new address), a
        // background→foreground takeover, or when the background isolate owns the
        // connection on aggressive OEMs (vivo/Funtouch, Xiaomi, Oppo). In every
        // one of those cases IMU + temp packets are arriving while the FSM still
        // reads "connecting", which is exactly what pinned the card on
        // "Connecting…/waiting for data" with data visibly flowing.
        //
        // So: if ANY sensor data is flowing — live foreground stream OR the
        // background isolate within its freshness window — the spoon IS
        // connected. Promote regardless of what the FSM currently reports.
        final dataFlowing = dataService.isEffectivelyConnectedFor(effectiveDevId);
        if (dataFlowing &&
            effectiveState != DeviceUiState.connected &&
            effectiveState != DeviceUiState.bluetoothOff) {
          effectiveState = DeviceUiState.connected;
        }

        // Resolve display name (prefer custom name → BLE name → fallback)
        final savedMatch = savedDevices
            .where((d) => d.id == effectiveDevId)
            .firstOrNull;
        final discoveredDevice = _bleService.getDeviceById(effectiveDevId);
        final deviceName = savedMatch?.displayName.isNotEmpty == true
            ? savedMatch!.displayName
            : (discoveredDevice?.name.isNotEmpty == true
                  ? discoveredDevice!.name
                  : 'I-Spoon Device');

        // The firmware sends no sensor data until the link is encrypted. When
        // bonding cannot complete, the GATT link comes up fine and the card
        // would otherwise sit at "Preparing…" forever with no explanation.
        // repairHintFor names the ONE action that fixes it — and which action
        // that is depends on whether the spoon or the phone is holding the bad
        // bond, so never hard-code one of them here.
        // A known pairing fault names its own fix. Otherwise, a link that went
        // silent past the deadline still needs to say SOMETHING actionable —
        // "Connection Error" with no next step is what left the card stuck.
        final repairHint =
            _bleService.repairHintFor(effectiveDevId) ??
            (effectiveState == DeviceUiState.error
                ? 'Connected but no sensor data'
                : null);
        // Only the stale-bond case is fixable in system Bluetooth settings;
        // the others are fixed on the spoon itself, so don't send the user
        // somewhere that cannot help them.
        final showBtSettings =
            _bleService.pairingIssueFor(effectiveDevId) ==
            SpoonPairingIssue.stalePhoneBond;

        final lastConnectedText = savedMatch?.formattedLastConnected ?? '';
        final isSyncing =
            effectiveState == DeviceUiState.connected &&
            !dataService.isEffectivelyConnectedFor(effectiveDevId);

        return _buildStatusCard(
          deviceId: effectiveDevId,
          uiState: effectiveState,
          deviceName: deviceName,
          repairHint: repairHint,
          showBtSettings: showBtSettings,
          prepareStep: _bleService.prepareStepFor(effectiveDevId),
          lastConnectedText: lastConnectedText,
          batteryLevel: batteryLevel,
          isSyncing: isSyncing,
        );
      },
    ).animate().fadeIn().slideY(begin: 0.1, end: 0);
  }

  Widget _buildNoDeviceCard() {
    return PremiumGlassCard(
      onTap: _navigateToAddDevice,
      child: Row(
        children: [
          PremiumIconBox(
            icon: Icons.bluetooth_searching,
            color: AppTheme.textSecondary,
            size: 28.sp,
          ),
          SizedBox(width: 16.w),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Connect Device',
                  style: GoogleFonts.figtree(
                    fontSize: 18.sp,
                    fontWeight: FontWeight.bold,
                    color: Theme.of(context).colorScheme.onSurface,
                  ),
                ),
                SizedBox(height: 4.h),
                Text(
                  'Tap to pair your I-Spoon',
                  style: GoogleFonts.figtree(
                    fontSize: 14.sp,
                    color: Theme.of(
                      context,
                    ).colorScheme.onSurface.withValues(alpha: 0.6),
                  ),
                ),
              ],
            ),
          ),
          Icon(Icons.add_circle, color: AppTheme.emerald, size: 28.sp),
        ],
      ),
    ).animate().fadeIn().slideY(begin: 0.1, end: 0);
  }

  Widget _buildStatusCard({
    required String deviceId,
    required DeviceUiState uiState,
    required String deviceName,
    required String lastConnectedText,

    /// Actionable instruction when the spoon cannot bond; replaces the
    /// "Last seen" line because it is the only thing that will unblock data.
    String? repairHint,

    /// Which setup step is running while [DeviceUiState.preparing].
    String? prepareStep,

    /// Show a shortcut into system Bluetooth settings — true only for the
    /// stale-OS-bond fault, which is the one the user fixes there.
    bool showBtSettings = false,
    required int batteryLevel,
    bool isSyncing = false,
  }) {
    // Map PRD §7.7 DeviceUiState → UI label / color / icon
    final String statusText;
    final Color statusColor;
    final IconData statusIcon;

    switch (uiState) {
      case DeviceUiState.connected:
        statusText = 'Connected';
        statusColor = AppTheme.emerald;
        statusIcon = Icons.bluetooth_connected;
      case DeviceUiState.preparing:
        // Link is up but no data yet. Show WHICH step is running — a bare
        // "Preparing…" is indistinguishable from a hang, which is exactly how
        // this read while bonding was silently failing behind it.
        statusText = prepareStep ?? 'Preparing…';
        statusColor = AppTheme.amber;
        statusIcon = Icons.bluetooth_connected;
      case DeviceUiState.connecting:
        statusText = 'Connecting…';
        statusColor = AppTheme.amber;
        statusIcon = Icons.bluetooth_searching;
      case DeviceUiState.available:
        // Heard advertising, not linked yet — genuinely "in range".
        statusText = 'In range';
        statusColor = AppTheme.amber;
        statusIcon = Icons.bluetooth_searching;
      case DeviceUiState.unavailable:
        // Not heard from. This is the normal resting state of a spoon that is
        // switched off or elsewhere — not an error, so don't paint it red.
        // The "Last: …" line beneath carries the useful detail, exactly as
        // fitness-tracker apps do ("Not connected · Last synced 2h ago").
        statusText = 'Not connected';
        statusColor = Theme.of(
          context,
        ).colorScheme.onSurface.withValues(alpha: 0.55);
        statusIcon = Icons.bluetooth_disabled;
      case DeviceUiState.error:
        statusText = 'Connection Error';
        statusColor = Colors.redAccent;
        statusIcon = Icons.error_outline;
      case DeviceUiState.bluetoothOff:
        statusText = 'Bluetooth Off';
        statusColor = Colors.grey;
        statusIcon = Icons.bluetooth_disabled;
    }

    final isConnected = uiState == DeviceUiState.connected;

    return PremiumGlassCard(
      onTap: _navigateToDeviceDetails,
      child: Column(
        children: [
          Row(
            children: [
              PremiumIconBox(icon: statusIcon, color: statusColor),
              SizedBox(width: 16.w),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      deviceName,
                      style: GoogleFonts.figtree(
                        fontSize: 18.sp,
                        fontWeight: FontWeight.bold,
                        color: Theme.of(context).colorScheme.onSurface,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    SizedBox(height: 4.h),
                    Row(
                      children: [
                        Container(
                          width: 8.w,
                          height: 8.h,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: statusColor,
                            boxShadow: [
                              BoxShadow(
                                color: statusColor.withValues(alpha: 0.5),
                                blurRadius: 4,
                                spreadRadius: 1,
                              ),
                            ],
                          ),
                        ),
                        SizedBox(width: 8.w),
                        Text(
                          statusText,
                          style: GoogleFonts.figtree(
                            fontSize: 14.sp,
                            color: statusColor,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
          SizedBox(height: 16.h),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              if (isConnected) ...[
                Expanded(
                  child: Row(
                    children: [
                      Icon(
                        _getBatteryIcon(batteryLevel),
                        size: 20.sp,
                        color: _getBatteryColor(batteryLevel),
                      ),
                      SizedBox(width: 8.w),
                      Expanded(
                        child: Text(
                          batteryLevel > 0
                              ? '$batteryLevel% Battery'
                              : isSyncing
                              ? 'Syncing…'
                              : 'Battery N/A',
                          style: GoogleFonts.figtree(
                            fontSize: 14.sp,
                            color: Theme.of(
                              context,
                            ).colorScheme.onSurface.withValues(alpha: 0.6),
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
              ] else ...[
                Expanded(
                  child: Row(
                    children: [
                      Icon(
                        Icons.history,
                        size: 20.sp,
                        color: Theme.of(
                          context,
                        ).colorScheme.onSurface.withValues(alpha: 0.6),
                      ),
                      SizedBox(width: 8.w),
                      Expanded(
                        child: Text(
                          lastConnectedText.isNotEmpty
                              ? 'Last connected $lastConnectedText'
                              : uiState == DeviceUiState.bluetoothOff
                              ? 'Turn on Bluetooth'
                              : 'Tap to connect',
                          style: GoogleFonts.figtree(
                            fontSize: 14.sp,
                            color: Theme.of(
                              context,
                            ).colorScheme.onSurface.withValues(alpha: 0.6),
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              if (!isConnected)
                GestureDetector(
                  // A chip labelled "Reconnect" must actually reconnect. It used
                  // to open the Add-Device screen for every state except `error`,
                  // so re-pairing was the only way back from a manual disconnect.
                  onTap: deviceId.isEmpty
                      ? _navigateToDeviceDetails
                      : () => _handleReconnect(deviceId),
                  child: Container(
                    padding: EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: AppTheme.emerald.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(20.r),
                      border: Border.all(
                        color: AppTheme.emerald.withValues(alpha: 0.3),
                      ),
                    ),
                    child: Text(
                      uiState == DeviceUiState.error ? 'Retry' : 'Reconnect',
                      style: GoogleFonts.figtree(
                        fontSize: 12.sp,
                        color: AppTheme.emerald,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
            ],
          ),

          // The repair instruction gets its OWN full-width row. Squeezed into
          // the status line beside the Reconnect chip it rendered as
          // 'Forget "iSpoon Pro" in Blu…' — an instruction the user cannot act
          // on is the same as no instruction at all.
          if (repairHint != null) ...[
            SizedBox(height: 12.h),
            Container(
              width: double.infinity,
              padding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: Colors.orangeAccent.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(12.r),
                border: Border.all(
                  color: Colors.orangeAccent.withValues(alpha: 0.35),
                ),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.warning_amber_rounded,
                    size: 18.sp,
                    color: Colors.orangeAccent,
                  ),
                  SizedBox(width: 8.w),
                  Expanded(
                    child: Text(
                      repairHint,
                      style: GoogleFonts.figtree(
                        fontSize: 13.sp,
                        height: 1.35.h,
                        color: Colors.orange.shade900,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  // Only shown for the one fault the user can actually fix in
                  // system settings — a button that leads nowhere useful is
                  // worse than no button. A plain gear reads instantly and
                  // costs none of the width the message needs.
                  if (showBtSettings) ...[
                    SizedBox(width: 6.w),
                    IconButton(
                      onPressed: SystemSettingsService.openBluetoothSettings,
                      icon: Icon(Icons.settings),
                      iconSize: 20,
                      color: Colors.orange.shade900,
                      tooltip: 'Open Bluetooth settings',
                      visualDensity: VisualDensity.compact,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(
                        minWidth: 32,
                        minHeight: 32,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  IconData _getBatteryIcon(int level) {
    if (level == 0) return Icons.battery_unknown;
    if (level > 90) return Icons.battery_full;
    if (level > 70) return Icons.battery_6_bar;
    if (level > 50) return Icons.battery_5_bar;
    if (level > 30) return Icons.battery_3_bar;
    if (level > 10) return Icons.battery_2_bar;
    return Icons.battery_alert;
  }

  Color _getBatteryColor(int level) {
    if (level == 0) return Colors.grey;
    if (level > 30) return AppTheme.emerald;
    if (level > 10) return Colors.orange;
    return Colors.red;
  }
}

/// Temperature Display Card
class TemperatureCard extends StatelessWidget {
  final String? deviceId;
  const TemperatureCard({super.key, this.deviceId});

  @override
  Widget build(BuildContext context) {
    return Consumer2<UnifiedDataService, SpoonRuntime>(
      builder: (context, dataService, ble, _) {
        final devId = deviceId ?? dataService.primaryDeviceId ?? '';
        return Row(
          children: [
            Expanded(
              child: PremiumGlassCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Icon(
                          Icons.thermostat,
                          color: AppTheme.honey,
                          size: 24.sp,
                        ),
                        Builder(
                          builder: (context) {
                            // Only light up when we actually have a live reading —
                            // a status dot shouldn't glow when there's nothing to report.
                            final hasLiveReading =
                                dataService.foodTempCFor(devId) > 0;
                            return Container(
                              width: 6.w,
                              height: 6.h,
                              decoration: BoxDecoration(
                                color: hasLiveReading
                                    ? AppTheme.honey
                                    : Theme.of(context).colorScheme.onSurface
                                          .withValues(alpha: 0.15),
                                shape: BoxShape.circle,
                              ),
                            );
                          },
                        ),
                      ],
                    ),
                    SizedBox(height: 12.h),
                    Text(
                      'Food Temp',
                      style: GoogleFonts.figtree(
                        fontSize: 12.sp,
                        color: Theme.of(
                          context,
                        ).colorScheme.onSurface.withValues(alpha: 0.6),
                      ),
                    ),
                    SizedBox(height: 4.h),
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 300),
                      child: Text(
                        dataService.foodTempCFor(devId) > 0
                            ? '${formatSpoonTempC(dataService.foodTempCFor(devId))}°'
                            : '—',
                        style: AppTheme.serif(
                          fontSize: 28.sp,
                          fontWeight: FontWeight.w600,
                          color: Theme.of(context).colorScheme.onSurface,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            // Heater card — only shown for iSpoon Pro
            if (ble.connectedDeviceHasHeater) ...[
              SizedBox(width: 16.w),
              Expanded(
                child: PremiumGlassCard(
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => const HeaterControlPage(),
                      ),
                    );
                  },
                  child: Consumer<UnifiedDataService>(
                    builder: (context, dataService, _) {
                      final devId =
                          deviceId ?? dataService.primaryDeviceId ?? '';
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Icon(
                                Icons.local_fire_department,
                                color: dataService.isHeaterOnFor(devId)
                                    ? AppTheme.paprika
                                    : Colors.grey,
                                size: 24.sp,
                              ),
                              Container(
                                width: 6.w,
                                height: 6.h,
                                decoration: BoxDecoration(
                                  color: dataService.isHeaterOnFor(devId)
                                      ? AppTheme.paprika
                                      : Colors.transparent,
                                  shape: BoxShape.circle,
                                  boxShadow: dataService.isHeaterOnFor(devId)
                                      ? [
                                          BoxShadow(
                                            color: Theme.of(context)
                                                .colorScheme
                                                .onSurface
                                                .withValues(alpha: 0.5),
                                            blurRadius: 6,
                                          ),
                                        ]
                                      : null,
                                ),
                              ),
                            ],
                          ),
                          SizedBox(height: 12.h),
                          Text(
                            'Heater',
                            style: GoogleFonts.figtree(
                              fontSize: 12.sp,
                              color: Theme.of(
                                context,
                              ).colorScheme.onSurface.withValues(alpha: 0.6),
                            ),
                          ),
                          SizedBox(height: 4.h),
                          Text(
                            dataService.heaterHomeLabelFor(devId),
                            style: AppTheme.serif(
                              fontSize: 28.sp,
                              fontWeight: FontWeight.w600,
                              color: dataService.isHeaterOnFor(devId)
                                  ? Theme.of(context).colorScheme.onSurface
                                  : Theme.of(context).colorScheme.onSurface
                                        .withValues(alpha: 0.7),
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ),
              ),
            ],
          ],
        ).animate().fadeIn(delay: 200.ms).slideY(begin: 0.1, end: 0);
      },
    );
  }
}

/// Eating Analysis Card
class EatingAnalysisCard extends StatelessWidget {
  final String? deviceId;
  const EatingAnalysisCard({super.key, this.deviceId});

  @override
  Widget build(BuildContext context) {
    return Consumer2<UnifiedDataService, InsightsController>(
      builder: (context, dataService, insights, _) {
        final devId = deviceId ?? dataService.primaryDeviceId ?? '';
        // Reading comes from the AI Lab model as soon as the spoon streams —
        // it no longer waits for a meal session to start.
        final hasTremorReading = dataService.hasTremorReadingFor(devId);
        final tremorIdx = dataService.tremorIndexFor(devId);
        final steadyPct = dataService.steadyPctFor(devId);
        // Gate on the number too, not just the flag: steadyPctFor() returns
        // null whenever there is no reading, and the old `steadyPct!` leaned
        // entirely on those two staying in lockstep.
        final hasReading = hasTremorReading && steadyPct != null;
        // Short value, qualitative label — the same shape as "0 / Total Bites"
        // and "--s / Bite Interval" beside it. "Steady 100%" as a single value was
        // three times the width of its neighbours and read as the headline of
        // the card, which is how a reading taken from a spoon lying still came
        // across as a confident verdict about the user's hand.
        final movementValue = hasReading ? '${steadyPct.round()}%' : '—';
        final movementLabel = !hasReading
            ? 'Hand movement'
            : tremorIdx <= TremorResult.moderateThreshold
            ? 'Steady hand'
            : tremorIdx <= TremorResult.highThreshold
            ? 'Some shake'
            : 'Shaky hand';

        bool hasData = dataService.totalBitesFor(devId) > 0;

        return PremiumGlassCard(
          padding: EdgeInsets.all(20),
          onTap: () {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => const MealsAnalysisPage(),
              ),
            );
          },
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'Eating Analysis',
                    style: GoogleFonts.figtree(
                      fontSize: 18.sp,
                      fontWeight: FontWeight.bold,
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                  ),
                  Icon(
                    Icons.arrow_forward_ios,
                    size: 16.sp,
                    color: Theme.of(
                      context,
                    ).colorScheme.onSurface.withValues(alpha: 0.6),
                  ),
                ],
              ),
              SizedBox(height: 24.h),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  _AnalysisItem(
                    label: 'Total Bites',
                    value: dataService.totalBitesFor(devId).toString(),
                    color: !hasData
                        ? Theme.of(
                            context,
                          ).colorScheme.onSurface.withValues(alpha: 0.6)
                        : AppTheme.caramel,
                  ),
                  Container(
                    width: 1.w,
                    height: 40.h,
                    color: Theme.of(
                      context,
                    ).dividerColor.withValues(alpha: 0.1),
                  ),
                  _AnalysisItem(
                    // "Avg Speed" was wrong, not just terse: the value is
                    // average SECONDS BETWEEN bites, so a bigger number means
                    // slower eating. Labelled "Speed", "8s" read as faster
                    // than "4s" — the opposite of the truth. "Bite Interval"
                    // says what the seconds measure.
                    label: 'Bite Interval',
                    value: hasData
                        ? '${dataService.avgBiteTimeFor(devId).toStringAsFixed(0)}s'
                        : '--s',
                    color: !hasData
                        ? Theme.of(
                            context,
                          ).colorScheme.onSurface.withValues(alpha: 0.6)
                        : AppTheme.emerald,
                  ),
                  Container(
                    width: 1.w,
                    height: 40.h,
                    color: Theme.of(
                      context,
                    ).dividerColor.withValues(alpha: 0.1),
                  ),
                  _AnalysisItem(
                    label: movementLabel,
                    // Not gated on bites: the reading is live from the spoon's
                    // movement, so it appears within a few seconds of the
                    // spoon actually being PICKED UP (a motionless spoon no
                    // longer produces a reading at all — see steadyPctOf).
                    value: movementValue,
                    // Colour follows the reading, not the bite count.
                    color: !hasReading
                        ? Theme.of(
                            context,
                          ).colorScheme.onSurface.withValues(alpha: 0.6)
                        : tremorIdx <= TremorResult.moderateThreshold
                        ? AppTheme.primary
                        : tremorIdx <= TremorResult.highThreshold
                        ? AppTheme.amber
                        : AppTheme.rose,
                  ),
                ],
              ),
              // ── Per-Meal Breakdown ───────────────────────────────
              if (hasData) ...[
                SizedBox(height: 20.h),
                Container(
                  height: 1.h,
                  color: Theme.of(context).dividerColor.withValues(alpha: 0.1),
                ),
                SizedBox(height: 16.h),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    _MealBiteChip(
                      icon: Icons.wb_twilight,
                      label: 'Breakfast',
                      bites: dataService.breakfastTotalBitesFor(devId),
                      isActive:
                          dataService.currentMealTypeFor(devId) == 'Breakfast',
                    ),
                    _MealBiteChip(
                      icon: Icons.wb_sunny,
                      label: 'Lunch',
                      bites: dataService.lunchTotalBitesFor(devId),
                      isActive:
                          dataService.currentMealTypeFor(devId) == 'Lunch',
                    ),
                    _MealBiteChip(
                      icon: Icons.nights_stay_outlined,
                      label: 'Dinner',
                      bites: dataService.dinnerTotalBitesFor(devId),
                      isActive:
                          dataService.currentMealTypeFor(devId) == 'Dinner',
                    ),
                    _MealBiteChip(
                      icon: Icons.local_dining,
                      label: 'Snack',
                      bites: dataService.snackTotalBitesFor(devId),
                      isActive:
                          dataService.currentMealTypeFor(devId) == 'Snack',
                    ),
                  ],
                ),
              ],
            ],
          ),
        ).animate().fadeIn(delay: 400.ms).slideY(begin: 0.1, end: 0);
      },
    );
  }
}

class _AnalysisItem extends StatelessWidget {
  final String label;
  final String value;
  final Color color;

  const _AnalysisItem({
    required this.label,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(
          value,
          style: AppTheme.serif(
            fontSize: 24.sp,
            fontWeight: FontWeight.w600,
            color: color,
          ),
        ),
        SizedBox(height: 4.h),
        Text(
          label,
          style: GoogleFonts.figtree(
            fontSize: 12.sp,
            color: Theme.of(
              context,
            ).colorScheme.onSurface.withValues(alpha: 0.6),
          ),
        ),
      ],
    );
  }
}

/// Per-meal bite chip for the Eating Analysis card
class _MealBiteChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final int bites;
  final bool isActive;

  const _MealBiteChip({
    required this.icon,
    required this.label,
    required this.bites,
    this.isActive = false,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          padding: EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: isActive
                ? AppTheme.emerald.withValues(alpha: 0.2)
                : Theme.of(
                    context,
                  ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
            shape: BoxShape.circle,
            border: isActive
                ? Border.all(color: AppTheme.emerald, width: 1.5.w)
                : null,
          ),
          child: Icon(
            icon,
            size: 16.sp,
            color: isActive
                ? AppTheme.emerald
                : Theme.of(
                    context,
                  ).colorScheme.onSurface.withValues(alpha: 0.5),
          ),
        ),
        SizedBox(height: 6.h),
        Text(
          '$bites',
          style: AppTheme.serif(
            fontSize: 16.sp,
            fontWeight: FontWeight.w600,
            color: bites > 0
                ? AppTheme.caramel
                : Theme.of(
                    context,
                  ).colorScheme.onSurface.withValues(alpha: 0.4),
          ),
        ),
        Text(
          label,
          style: GoogleFonts.figtree(
            fontSize: 10.sp,
            color: Theme.of(
              context,
            ).colorScheme.onSurface.withValues(alpha: 0.5),
          ),
        ),
      ],
    );
  }
}

/// Daily Tip Card
class DailyTipCard extends StatelessWidget {
  const DailyTipCard({super.key});

  /// Last resort only: shown when the spoon has measured nothing for this
  /// person yet, so there is no meal to say anything about. Every branch
  /// above this one comes from their own data. These are general mindful-
  /// eating practice, written so none of them claims to be about the reader.
  static const List<String> _tips = [
    'Mindful eating can help you recognize true hunger and fullness cues more effectively.',
    'Try putting your spoon down between bites — it gives your brain time to register fullness.',
    'Eating without screens lets you actually taste your food and notice when you\'ve had enough.',
    'Chewing slowly isn\'t just good manners — it aids digestion and helps prevent overeating.',
    'A glass of water before a meal can help you tell the difference between thirst and hunger.',
    'Notice the colors, smells, and textures of your food — engaging your senses slows you down naturally.',
    'Eating at a consistent time each day helps regulate hunger hormones and steadies your energy.',
    'It\'s okay to leave food on your plate — fullness matters more than finishing what\'s served.',
  ];

  String _tipOfTheDay() {
    final now = DateTime.now();
    final dayOfYear = now.difference(DateTime(now.year, 1, 1)).inDays;
    return _tips[dayOfYear % _tips.length];
  }

  @override
  Widget build(BuildContext context) {
    // Three sources, in descending order of how specific they are to this
    // person, and the card takes the first one that has something to say:
    //
    //   1. SuggestionEngine — the top suggestion from their actual recent
    //      meals (satiation, pause structure, pace against their own
    //      baseline). This is the only source that can describe what they
    //      just did.
    //   2. PersonalizedEatingModel.personalizedTip — their learned baseline,
    //      or how far off being able to personalise it still is. Available
    //      after one meal, before the engine has enough to find a pattern.
    //   3. The rotating general tip, for a spoon that has measured nothing.
    //
    // It used to be 2 then 3, which meant a person with twenty meals of
    // history still only ever read their average pace back to themselves.
    return ListenableBuilder(
      listenable: PersonalizedEatingModel(),
      builder: (context, _) {
        final spoonKey = context
            .watch<UnifiedDataService>()
            .selectedSpoonKey;
        final personalized =
            PersonalizedEatingModel().personalizedTip(spoonKey);
        final profile = PersonalizedEatingModel().profileFor(spoonKey);
        final isPersonalized = personalized != null;

        // The engine's own "no meals recorded yet" card is not a tip — it
        // says the same thing as having no data at all, so it falls through
        // to the sources below instead of displacing them.
        final suggestion = context
            .watch<InsightsController>()
            .suggestions
            .where((s) => s.id != 'no_data')
            .firstOrNull;

        final String title;
        final String message;
        if (suggestion != null) {
          title = suggestion.title;
          message = suggestion.body;
        } else {
          title = (profile?.isLearned ?? false)
              ? 'Personalized Insight'
              : isPersonalized
                  ? 'Learning Your Habits'
                  : 'Daily Tip';
          message = personalized ?? _tipOfTheDay();
        }

        return PremiumGlassCard(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: AppTheme.sageDeep.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(12.r),
                ),
                child: Icon(
                  Icons.lightbulb_outline,
                  color: AppTheme.sageDeep,
                  size: 24.sp,
                ),
              ),
              SizedBox(width: 16.w),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: GoogleFonts.figtree(
                        fontSize: 16.sp,
                        fontWeight: FontWeight.bold,
                        color: AppTheme.sageDeep,
                      ),
                    ),
                    SizedBox(height: 8.h),
                    Text(
                      message,
                      style: GoogleFonts.figtree(
                        fontSize: 14.sp,
                        height: 1.5.h,
                        color: Theme.of(
                          context,
                        ).colorScheme.onSurface.withValues(alpha: 0.6),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ).animate().fadeIn(delay: 600.ms).slideY(begin: 0.1, end: 0);
      },
    );
  }
}

/// Motivation Card
class MotivationCard extends StatelessWidget {
  const MotivationCard({super.key});

  static const List<String> _quotes = [
    '"Slow down, savor life, and nourish your body with intention."',
    '"Every mindful bite is a small act of self-care."',
    '"Progress isn\'t perfect meals — it\'s paying attention, one bite at a time."',
    '"Your body hears everything your mind says. Speak to it kindly at the table."',
    '"Small, consistent choices add up to lasting change."',
    '"Hunger is information, not an emergency — listen before you reach."',
    '"Nourishment is a form of respect you show yourself daily."',
    '"You don\'t have to eat perfectly to eat well — just stay present."',
  ];

  String _quoteOfTheDay() {
    final now = DateTime.now();
    final dayOfYear = now.difference(DateTime(now.year, 1, 1)).inDays;
    // Fixed offset keeps this out of sync with DailyTipCard's rotation.
    return _quotes[(dayOfYear + 3) % _quotes.length];
  }

  @override
  Widget build(BuildContext context) {
    return PremiumGlassCard(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: AppTheme.honey.withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(12.r),
            ),
            child: Icon(
              Icons.favorite_border,
              color: AppTheme.honey,
              size: 24.sp,
            ),
          ),
          SizedBox(width: 16.w),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Motivation',
                  style: GoogleFonts.figtree(
                    fontSize: 16.sp,
                    fontWeight: FontWeight.bold,
                    color: AppTheme.honey,
                  ),
                ),
                SizedBox(height: 8.h),
                Text(
                  _quoteOfTheDay(),
                  style: GoogleFonts.figtree(
                    fontSize: 14.sp,
                    height: 1.5.h,
                    fontStyle: FontStyle.italic,
                    color: Theme.of(
                      context,
                    ).colorScheme.onSurface.withValues(alpha: 0.6),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    ).animate().fadeIn(delay: 800.ms).slideY(begin: 0.1, end: 0);
  }
}

/// Today's Meals Table
class TodayMealsTable extends StatefulWidget {
  final String? deviceId;
  const TodayMealsTable({super.key, this.deviceId});

  @override
  State<TodayMealsTable> createState() => _TodayMealsTableState();
}

class _TodayMealsTableState extends State<TodayMealsTable> {
  late Future<List<MealSummary>> _mealsFuture;

  @override
  void initState() {
    super.initState();
    _fetchMeals();
  }

  void _fetchMeals() {
    final controller = context.read<InsightsController>();
    final today = DateTime.now();
    _mealsFuture = controller.getMealsForDate(
      DateTime(today.year, today.month, today.day),
    );
  }

  String _formatTime(DateTime? time) {
    if (time == null) return '--:--';
    final h = time.hour.toString().padLeft(2, '0');
    final m = time.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }

  IconData _getMealIcon(String type) {
    switch (type.toLowerCase()) {
      case 'breakfast':
        return Icons.wb_twilight;
      case 'lunch':
        return Icons.wb_sunny;
      case 'dinner':
        return Icons.nights_stay_outlined;
      default:
        return Icons.local_dining;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Today\'s Meals',
          style: GoogleFonts.figtree(
            fontSize: 18.sp,
            fontWeight: FontWeight.bold,
            color: Theme.of(context).colorScheme.onSurface,
          ),
        ),
        SizedBox(height: 12.h),
        PremiumGlassCard(
          backgroundColor: AppTheme.surface, // keeping table card surface color

          child: FutureBuilder<List<MealSummary>>(
            future: _mealsFuture,
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) {
                return const Center(
                  child: Padding(
                    padding: EdgeInsets.all(20.0),
                    child: CircularProgressIndicator(),
                  ),
                );
              }

              final meals = snapshot.data ?? [];

              if (meals.isEmpty) {
                return Center(
                  child: Padding(
                    padding: EdgeInsets.all(20),
                    child: Text(
                      'No meals recorded today yet.',
                      style: GoogleFonts.figtree(
                        color: Theme.of(
                          context,
                        ).colorScheme.onSurface.withValues(alpha: 0.5),
                      ),
                    ),
                  ),
                );
              }

              // Reverse to show most recent at top
              final displayMeals = meals.reversed.toList();

              return ListView.separated(
                shrinkWrap: true,
                padding: EdgeInsets.zero,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: displayMeals.length,
                separatorBuilder: (context, index) => Divider(
                  color: Theme.of(context).dividerColor.withValues(alpha: 0.1),
                  height: 24.h,
                ),
                itemBuilder: (context, index) {
                  final meal = displayMeals[index];
                  final type = meal.mealType ?? 'Meal';
                  final duration = meal.durationMinutes?.round() ?? 0;

                  return Consumer<UnifiedDataService>(
                    builder: (context, unifiedData, child) {
                      final devId =
                          widget.deviceId ?? unifiedData.primaryDeviceId ?? '';
                      int displayBites = meal.totalBites;
                      bool isLive = false;

                      if (unifiedData.isSessionActiveFor(devId) &&
                          unifiedData.currentMealTypeFor(devId) == type) {
                        displayBites = unifiedData.totalBitesFor(devId);
                        isLive = true;
                      }

                      return Row(
                        children: [
                          Container(
                            padding: EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: AppTheme.emerald.withValues(alpha: 0.15),
                              shape: BoxShape.circle,
                            ),
                            child: Icon(
                              _getMealIcon(type),
                              color: AppTheme.emerald,
                              size: 20.sp,
                            ),
                          ),
                          SizedBox(width: 12.w),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Text(
                                      type,
                                      style: GoogleFonts.figtree(
                                        fontWeight: FontWeight.bold,
                                        fontSize: 16.sp,
                                        color: Theme.of(
                                          context,
                                        ).colorScheme.onSurface,
                                      ),
                                    ),
                                    if (isLive) ...[
                                      SizedBox(width: 8.w),
                                      Container(
                                        padding: EdgeInsets.symmetric(
                                          horizontal: 6,
                                          vertical: 2,
                                        ),
                                        decoration: BoxDecoration(
                                          color: AppTheme.paprika.withValues(
                                            alpha: 0.1,
                                          ),
                                          borderRadius: BorderRadius.circular(
                                            4,
                                          ),
                                          border: Border.all(
                                            color: AppTheme.paprika.withValues(
                                              alpha: 0.3,
                                            ),
                                          ),
                                        ),
                                        child: Text(
                                          'LIVE',
                                          style: GoogleFonts.figtree(
                                            fontSize: 9.sp,
                                            color: AppTheme.paprika,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                                SizedBox(height: 4.h),
                                Row(
                                  children: [
                                    Icon(
                                      Icons.access_time,
                                      size: 12.sp,
                                      color: Theme.of(context)
                                          .colorScheme
                                          .onSurface
                                          .withValues(alpha: 0.5),
                                    ),
                                    SizedBox(width: 4.w),
                                    Text(
                                      '${_formatTime(meal.lastMealStart)} - ${_formatTime(meal.lastMealEnd)} ($duration min)',
                                      style: GoogleFonts.figtree(
                                        fontSize: 12.sp,
                                        color: Theme.of(context)
                                            .colorScheme
                                            .onSurface
                                            .withValues(alpha: 0.6),
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              Text(
                                '$displayBites',
                                style: AppTheme.serif(
                                  fontSize: 20.sp,
                                  fontWeight: FontWeight.w600,
                                  color: AppTheme.caramel,
                                ),
                              ),
                              Text(
                                'bites',
                                style: GoogleFonts.figtree(
                                  fontSize: 12.sp,
                                  color: Theme.of(context).colorScheme.onSurface
                                      .withValues(alpha: 0.5),
                                ),
                              ),
                            ],
                          ),
                        ],
                      );
                    },
                  );
                },
              );
            },
          ),
        ).animate().fadeIn(delay: 500.ms).slideY(begin: 0.1, end: 0),
      ],
    );
  }
}

/// Explain a tapped spoon that did not connect, and offer the one fix that
/// works — instead of a spinner that ends in "Connection Error". Shared by the
/// home screen's spoon chips and this card's Reconnect/Retry button.
Future<void> explainSpoonSwitch(
  BuildContext context,
  SpoonRuntime ble,
  String deviceId,
  String name,
  SwitchOutcome outcome,
) async {
  final messenger = ScaffoldMessenger.of(context);
  switch (outcome) {
    case SwitchOutcome.streaming:
    case SwitchOutcome.pending:
      messenger.hideCurrentSnackBar();
      return;
    case SwitchOutcome.notNearby:
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(
          content: Text(
            "$name isn't nearby or is switched off. Wake it (double-tap), "
            'keep it close, then tap it again.',
          ),
        ));
      return;
    case SwitchOutcome.needsRepair:
      messenger.hideCurrentSnackBar();
      final pair = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Pair this spoon again?'),
          content: Text(
            '$name was reset, so it no longer remembers this phone. '
            'Pair it again to keep using it.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Not now'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Pair again'),
            ),
          ],
        ),
      );
      if (pair != true) return;
      messenger.showSnackBar(SnackBar(content: Text('Pairing $name…')));
      final result = await ble.repairSavedDevice(deviceId);
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(
          content: Text(
            result.isSuccess
                ? '$name is paired again.'
                : (result.detail ??
                    'Pairing did not complete — please try again.'),
          ),
        ));
  }
}
