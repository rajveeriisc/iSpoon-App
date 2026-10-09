// heater_control_page.dart — spoon heater configuration screen.
//
// Lets the user turn the heater on/off and set the target and activation
// temperatures, persisting preferences and sending heater commands to the spoon
// via SpoonRuntime (through UnifiedDataService). Shows current food temperature
// and heater status. Only meaningful for heater-equipped devices (iSpoon Pro).
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:smartspoon/features/devices/domain/heater_command.dart';
import 'package:smartspoon/ble/models/runtime_models.dart';
import 'package:smartspoon/ble/spoon_runtime.dart';
import 'package:smartspoon/features/insights/domain/services/unified_data_service.dart';
import 'package:smartspoon/core/theme/app_theme.dart';
import 'package:smartspoon/core/widgets/geometric_background.dart';
import 'package:smartspoon/core/widgets/premium_widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

class HeaterControlPage extends StatefulWidget {
  const HeaterControlPage({super.key});

  @override
  State<HeaterControlPage> createState() => _HeaterControlPageState();
}

class _HeaterControlPageState extends State<HeaterControlPage>
    with TickerProviderStateMixin {
  bool _isHeaterOn = false;
  double _maxTemp = 40.0; // Firmware default/minimum is 30

  late AnimationController _settingsController;
  late AnimationController _toggleController;
  late Animation<double> _settingsAnimation;

  @override
  void initState() {
    super.initState();

    _settingsController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 450),
    );

    _toggleController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );

    _settingsAnimation = CurvedAnimation(
      parent: _settingsController,
      curve: Curves.easeOutCubic,
    );

    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final mcuService = Provider.of<SpoonRuntime>(context, listen: false);
    final dataService = Provider.of<UnifiedDataService>(context, listen: false);
    final deviceId = mcuService.connectedDeviceId;
    if (deviceId == null) return;

    if (mounted) {
      setState(() {
        _isHeaterOn = dataService.isHeaterOn;
        _maxTemp = dataService.maxHeaterTemp;
        final liveSet = mcuService.heaterStatus?.setpointC ?? 0;
        if (liveSet >= 30 && liveSet <= 70) {
          _maxTemp = liveSet.toDouble();
        }
      });
      if (_isHeaterOn) {
        _settingsController.value = 1.0;
        _toggleController.value = 1.0;
      }
    }
  }

  Future<void> _saveToStorage() async {
    final mcuService = Provider.of<SpoonRuntime>(context, listen: false);
    final deviceId = mcuService.connectedDeviceId;
    if (deviceId == null) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('heater_on_$deviceId', _isHeaterOn);
    await prefs.setDouble('heater_max_$deviceId', _maxTemp.clamp(30.0, 70.0));
  }

  @override
  void dispose() {
    _settingsController.dispose();
    _toggleController.dispose();
    super.dispose();
  }

  void _toggleHeater(bool value) {
    setState(() => _isHeaterOn = value);
    if (value) {
      _settingsController.forward();
      _toggleController.forward();
    } else {
      _settingsController.reverse();
      _toggleController.reverse();
    }
  }

  Future<void> _saveSettings() async {
    final mcu = Provider.of<SpoonRuntime>(context, listen: false);
    final dataService = Provider.of<UnifiedDataService>(context, listen: false);

    if (!mcu.isConnected) {
      if (mounted) {
        _showSnackBar('No device connected', AppTheme.paprika);
      }
      return;
    }

    final bool commandSent;
    try {
      commandSent = await mcu.setHeaterParameters(
        _isHeaterOn ? _maxTemp.toInt() : 0,
        _isHeaterOn ? _maxTemp.toInt() : 0,
        deviceId: mcu.connectedDeviceId,
      );
    } catch (e) {
      debugPrint('Heater command failed: $e');
      if (mounted) {
        _showSnackBar(
          'Couldn\'t update the heater — check the connection and try again',
          AppTheme.paprika,
        );
      }
      return;
    }

    if (!commandSent) {
      if (mounted) {
        _showSnackBar(
          'Couldn\'t update the heater — check the connection and try again',
          AppTheme.paprika,
        );
      }
      return;
    }

    dataService.recordHeaterCommand(on: _isHeaterOn, maxTemp: _maxTemp);
    await _saveToStorage();

    if (mounted) {
      final status = mcu.heaterStatus;
      String message;
      Color color = _isHeaterOn ? AppTheme.sageDeep : AppTheme.textSecondary;
      if (!_isHeaterOn) {
        message = 'Heater turned off';
      } else if (status?.vbusPresent == true) {
        message = 'Command sent — unplug USB; heater stays off while charging';
        color = AppTheme.paprika;
      } else if (status?.ntcOk == false) {
        message = 'Command sent — check the food probe (NTC)';
        color = AppTheme.paprika;
      } else {
        message =
            'Holding ${_maxTemp.toInt()}°C — heats again if food drops 5°C';
      }
      _showSnackBar(message, color);
    }
  }

  void _showSnackBar(String message, Color color) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          message,
          style: GoogleFonts.figtree(
            color: Colors.white,
            fontWeight: FontWeight.w600,
          ),
        ),
        backgroundColor: color,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        margin: const EdgeInsets.all(16),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Do not rebuild this page on every 10 Hz IMU notify — that was crashing
    // the heater screen when Apply sent a GATT write. Rebuild only when the
    // heater-relevant snapshot changes.
    return Selector<SpoonRuntime, HeaterStatus?>(
      selector: (_, mcu) => mcu.heaterStatus,
      shouldRebuild: (prev, next) {
        if (identical(prev, next)) return false;
        return prev?.railOn != next?.railOn ||
            prev?.maintainOn != next?.maintainOn ||
            prev?.fault != next?.fault ||
            prev?.timeout != next?.timeout ||
            prev?.lowBattery != next?.lowBattery ||
            prev?.ntcOk != next?.ntcOk ||
            prev?.vbusPresent != next?.vbusPresent ||
            prev?.mode != next?.mode ||
            prev?.setpointC != next?.setpointC ||
            (prev?.tempC)?.round() != (next?.tempC)?.round();
      },
      builder: (context, heaterStatus, _) {
        final isDark = Theme.of(context).brightness == Brightness.dark;
        final statusBanner = _buildStatusBanner(heaterStatus);

        return Scaffold(
          extendBodyBehindAppBar: true,
          backgroundColor: Theme.of(context).scaffoldBackgroundColor,
          body: Stack(
            children: [
              Container(
                decoration: BoxDecoration(
                  gradient: isDark
                      ? AppTheme.darkBackgroundGradient
                      : AppTheme.backgroundGradient,
                ),
              ),
              const GeometricBackground(),
              SafeArea(
                child: Column(
                  children: [
                    _buildAppBar(context),
                    Expanded(
                      child: SingleChildScrollView(
                        physics: const BouncingScrollPhysics(),
                        padding: const EdgeInsets.symmetric(horizontal: 20.0),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            const SizedBox(height: 16),
                            if (statusBanner != null) ...[
                              statusBanner,
                              const SizedBox(height: 16),
                            ],
                            _buildInfoStrip(isDark, heaterStatus),
                            const SizedBox(height: 20),
                            _buildControlCard(isDark, heaterStatus),
                            const SizedBox(height: 20),
                            _buildSaveButton(),
                            const SizedBox(height: 36),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildAppBar(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
      child: Row(
        children: [
          Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () => Navigator.pop(context),
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: Icon(
                  Icons.arrow_back_ios_new_rounded,
                  color: Theme.of(context).colorScheme.onSurface,
                  size: 18,
                ),
              ),
            ),
          ),
          Expanded(
            child: Center(
              child: Text(
                'Heater Control',
                style: AppTheme.serif(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                  color: Theme.of(context).colorScheme.onSurface,
                ),
              ),
            ),
          ),
          Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () => _showInfoDialog(context),
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: Icon(
                  Icons.info_outline_rounded,
                  color: Theme.of(
                    context,
                  ).colorScheme.onSurface.withValues(alpha: 0.35),
                  size: 20,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _showInfoDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Theme.of(context).colorScheme.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(
          'About Heater Control',
          style: AppTheme.serif(
            fontSize: 18,
            color: Theme.of(context).colorScheme.onSurface,
            fontWeight: FontWeight.w600,
          ),
        ),
        content: Text(
          'Set a target (30–70°C) and turn the heater on. The spoon heats to that temperature, then holds it. If food cools by 5°C, heat comes back on by itself. It stays on until you turn it off here. Unplug USB before heating.',
          style: GoogleFonts.figtree(
            color: Theme.of(
              context,
            ).colorScheme.onSurface.withValues(alpha: 0.65),
            height: 1.6,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(
              'Got it',
              style: GoogleFonts.figtree(
                color: AppTheme.sageDeep,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Warning banner for a state the app can actually detect without a real
  /// rail-feedback packet from firmware (see HeaterStatus's doc comment):
  /// [timeout] is computed from firmware's own known runtime caps, and
  /// [lowBattery] from live battery telemetry — both real. [fault] is always
  /// false today; the firmware safety thread CAN latch a fault (NTC/TPS
  /// fault, implausible rise) that this banner cannot show until firmware
  /// starts transmitting that state over BLE. Returns null (no banner) for
  /// normal off/manual/setpoint operation.
  Widget? _buildStatusBanner(HeaterStatus? status) {
    if (status == null) return null;

    String message;
    IconData icon;
    if (status.fault) {
      message =
          'Heater fault — turn off and back on to clear. Check the food probe.';
      icon = Icons.error_outline_rounded;
    } else if (status.timeout) {
      message = 'Heater auto-stopped after its runtime limit.';
      icon = Icons.timer_off_outlined;
    } else if (status.lowBattery) {
      message = 'Battery too low to heat — charge the spoon.';
      icon = Icons.battery_alert_outlined;
    } else if (status.vbusPresent && (_isHeaterOn || status.maintainOn)) {
      message =
          'USB is plugged in — heating is paused. Unplug and it will hold your target again.';
      icon = Icons.power_off_outlined;
    } else if (_isHeaterOn &&
        !status.maintainOn &&
        !status.railOn &&
        status.mode == HeaterMode.off) {
      message =
          'Command sent — waiting for the spoon. Unplug USB and keep the app connected.';
      icon = Icons.local_fire_department_outlined;
    } else {
      return null;
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.paprika.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppTheme.paprika.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          Icon(icon, color: AppTheme.paprika, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: GoogleFonts.figtree(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: AppTheme.paprika,
                height: 1.3,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInfoStrip(bool isDark, HeaterStatus? heaterStatus) {
    // railOn downgrades to false once the runtime-cap timeout above trips —
    // that much is a real, computed fact about firmware behaviour. It still
    // cannot see a safety-thread fault or an interlock rejection at command
    // time (see HeaterStatus's doc comment), so this is closer to true than
    // a raw command echo, not a guarantee.
    final phase = heaterUiPhase(
      maintainOn: heaterStatus?.maintainOn ?? _isHeaterOn,
      railOn: heaterStatus?.railOn ?? false,
      vbusPresent: heaterStatus?.vbusPresent ?? false,
      fault: heaterStatus?.fault ?? false,
    );
    final statusLabel = heaterUiStatusLabel(phase, _maxTemp.toInt());
    final nowLabel = formatLiveTempC(
      heaterStatus?.tempC ?? 0,
      ntcOk: heaterStatus?.ntcOk ?? true,
    );
    final heating = phase == HeaterUiPhase.heating;
    final holding = phase == HeaterUiPhase.holding;

    return Row(
      children: [
        Expanded(
          child: _buildStatTile(
            label: 'Now',
            value: nowLabel,
            icon: Icons.thermostat_outlined,
            color: AppTheme.honey,
            isDark: isDark,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _buildStatTile(
            label: 'Target',
            value: '${_maxTemp.toInt()}°C',
            icon: Icons.flag_outlined,
            color: AppTheme.sageDeep,
            isDark: isDark,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _buildStatTile(
            label: 'Status',
            value: statusLabel,
            icon: heaterStatus?.fault == true
                ? Icons.error_outline_rounded
                : (heating
                      ? Icons.local_fire_department_rounded
                      : (holding
                            ? Icons.pause_circle_outlined
                            : Icons.power_settings_new_rounded)),
            color: heaterStatus?.fault == true
                ? AppTheme.paprika
                : (heating || holding
                      ? AppTheme.sageDeep
                      : AppTheme.textTertiary),
            isDark: isDark,
          ),
        ),
      ],
    );
  }

  Widget _buildStatTile({
    required String label,
    required String value,
    required IconData icon,
    required Color color,
    required bool isDark,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
      decoration: BoxDecoration(
        color: isDark ? AppTheme.darkSurfaceCard : AppTheme.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isDark ? AppTheme.darkBorder : AppTheme.border,
        ),
        boxShadow: [
          BoxShadow(
            color: color.withValues(alpha: 0.06),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 16),
          const SizedBox(height: 8),
          Text(
            value,
            style: GoogleFonts.figtree(
              fontSize: 15,
              fontWeight: FontWeight.w700,
              color: Theme.of(context).colorScheme.onSurface,
              letterSpacing: -0.3,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: GoogleFonts.figtree(
              fontSize: 10,
              fontWeight: FontWeight.w500,
              color: Theme.of(
                context,
              ).colorScheme.onSurface.withValues(alpha: 0.38),
              letterSpacing: 0.5,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildControlCard(bool isDark, HeaterStatus? heaterStatus) {
    final railOn = heaterStatus?.railOn ?? false;
    final phase = heaterUiPhase(
      maintainOn: heaterStatus?.maintainOn ?? _isHeaterOn,
      railOn: railOn,
      vbusPresent: heaterStatus?.vbusPresent ?? false,
      fault: heaterStatus?.fault ?? false,
    );
    final statusText = heaterUiStatusLabel(phase, _maxTemp.toInt());
    return PremiumGlassCard(
      padding: EdgeInsets.zero,
      // Fire/accent follow the spoon rail bit, not the local switch.
      accentColor: railOn ? AppTheme.sageDeep : null,
      child: Column(
        children: [
          // Toggle row
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 16, 20),
            child: Row(
              children: [
                AnimatedContainer(
                  duration: const Duration(milliseconds: 300),
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(14),
                    color: railOn
                        ? AppTheme.sageDeep.withValues(alpha: 0.12)
                        : Theme.of(
                            context,
                          ).colorScheme.onSurface.withValues(alpha: 0.05),
                    border: Border.all(
                      color: railOn
                          ? AppTheme.sageDeep.withValues(alpha: 0.25)
                          : Colors.transparent,
                    ),
                  ),
                  child: Icon(
                    Icons.local_fire_department_rounded,
                    color: railOn
                        ? AppTheme.sageDeep
                        : Theme.of(
                            context,
                          ).colorScheme.onSurface.withValues(alpha: 0.2),
                    size: 24,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Smart Heater',
                        style: GoogleFonts.figtree(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          color: Theme.of(context).colorScheme.onSurface,
                          letterSpacing: -0.2,
                        ),
                      ),
                      const SizedBox(height: 2),
                      AnimatedSwitcher(
                        duration: const Duration(milliseconds: 250),
                        child: Text(
                          statusText,
                          key: ValueKey(statusText),
                          style: GoogleFonts.figtree(
                            fontSize: 12,
                            color: railOn
                                ? AppTheme.sageDeep
                                : Theme.of(context).colorScheme.onSurface
                                      .withValues(alpha: 0.3),
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                Switch.adaptive(value: _isHeaterOn, onChanged: _toggleHeater),
              ],
            ),
          ),

          // Divider + sliders (animated)
          SizeTransition(
            sizeFactor: _settingsAnimation,
            child: Column(
              children: [
                Divider(
                  height: 1,
                  color: isDark ? AppTheme.darkBorder : AppTheme.border,
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 24, 20, 8),
                  child: _buildSliderRow(
                    label: 'Target temperature',
                    description: 'Holds this. Heats again if food drops 5°C.',
                    value: _maxTemp,
                    min: 30,
                    max: 70,
                    color: AppTheme.honey,
                    icon: Icons.local_fire_department_outlined,
                    onChanged: (v) => setState(() => _maxTemp = v),
                    onChangeEnd: (v) {
                      if (v > 60) {
                        _showSnackBar(
                          'High temperature — use with care',
                          AppTheme.paprika,
                        );
                      }
                    },
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSliderRow({
    required String label,
    required String description,
    required double value,
    required double min,
    required double max,
    required Color color,
    required IconData icon,
    required ValueChanged<double> onChanged,
    ValueChanged<double>? onChangeEnd,
  }) {
    final divisions = (max - min).toInt();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(7),
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(9),
                  ),
                  child: Icon(icon, color: color, size: 14),
                ),
                const SizedBox(width: 10),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: GoogleFonts.figtree(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: Theme.of(context).colorScheme.onSurface,
                        letterSpacing: -0.2,
                      ),
                    ),
                    Text(
                      description,
                      style: GoogleFonts.figtree(
                        fontSize: 10,
                        color: Theme.of(
                          context,
                        ).colorScheme.onSurface.withValues(alpha: 0.38),
                      ),
                    ),
                  ],
                ),
              ],
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(9),
                border: Border.all(color: color.withValues(alpha: 0.25)),
              ),
              child: Text(
                '${value.toInt()}°C',
                style: GoogleFonts.figtree(
                  fontWeight: FontWeight.w700,
                  fontSize: 13,
                  color: color,
                  letterSpacing: -0.3,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        SliderTheme(
          data: SliderThemeData(
            activeTrackColor: color,
            inactiveTrackColor: Theme.of(
              context,
            ).colorScheme.onSurface.withValues(alpha: 0.07),
            thumbColor: Colors.white,
            trackHeight: 6.0,
            overlayColor: color.withValues(alpha: 0.12),
            tickMarkShape: SliderTickMarkShape.noTickMark,
            thumbShape: _CleanThumbShape(ringColor: color),
            trackShape: const RoundedRectSliderTrackShape(),
          ),
          child: Slider(
            value: value,
            min: min,
            max: max,
            divisions: divisions,
            onChanged: onChanged,
            onChangeEnd: onChangeEnd,
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                '${min.toInt()}°C',
                style: GoogleFonts.figtree(
                  fontSize: 10,
                  color: Theme.of(
                    context,
                  ).colorScheme.onSurface.withValues(alpha: 0.28),
                ),
              ),
              Text(
                '${max.toInt()}°C',
                style: GoogleFonts.figtree(
                  fontSize: 10,
                  color: Theme.of(
                    context,
                  ).colorScheme.onSurface.withValues(alpha: 0.28),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildSaveButton() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return SizedBox(
      width: double.infinity,
      height: 54,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          gradient: _isHeaterOn
              ? LinearGradient(
                  colors: [
                    AppTheme.sageDeep,
                    AppTheme.sageDeep.withValues(alpha: 0.85),
                  ],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                )
              : LinearGradient(
                  colors: isDark
                      ? [AppTheme.darkCreamElevated, AppTheme.darkCream]
                      : [AppTheme.oat, AppTheme.line],
                ),
          boxShadow: _isHeaterOn
              ? [
                  BoxShadow(
                    color: AppTheme.sageDeep.withValues(alpha: 0.35),
                    blurRadius: 20,
                    offset: const Offset(0, 8),
                  ),
                ]
              : [],
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: _saveSettings,
            splashColor: Colors.white.withValues(alpha: 0.08),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 250),
                  child: Icon(
                    _isHeaterOn
                        ? Icons.check_rounded
                        : Icons.power_settings_new_rounded,
                    key: ValueKey(_isHeaterOn),
                    color: _isHeaterOn
                        ? Colors.white
                        : Theme.of(
                            context,
                          ).colorScheme.onSurface.withValues(alpha: 0.4),
                    size: 20,
                  ),
                ),
                const SizedBox(width: 10),
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 250),
                  child: Text(
                    _isHeaterOn ? 'Apply Settings' : 'Save as Inactive',
                    key: ValueKey(_isHeaterOn),
                    style: GoogleFonts.figtree(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.2,
                      color: _isHeaterOn
                          ? Colors.white
                          : Theme.of(
                              context,
                            ).colorScheme.onSurface.withValues(alpha: 0.4),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ─── Custom painters & shapes ─────────────────────────────────────────────────

class _CleanThumbShape extends SliderComponentShape {
  final double thumbRadius = 11.0;
  final Color ringColor;

  _CleanThumbShape({required this.ringColor});

  @override
  Size getPreferredSize(bool isEnabled, bool isDiscrete) =>
      Size.fromRadius(thumbRadius);

  @override
  void paint(
    PaintingContext context,
    Offset center, {
    required Animation<double> activationAnimation,
    required Animation<double> enableAnimation,
    required bool isDiscrete,
    required TextPainter labelPainter,
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required TextDirection textDirection,
    required double value,
    required double textScaleFactor,
    required Size sizeWithOverflow,
  }) {
    final canvas = context.canvas;

    // Drop shadow
    canvas.drawCircle(
      center + const Offset(0, 2),
      thumbRadius,
      Paint()
        ..color = Colors.black.withValues(alpha: 0.18)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5),
    );

    // White body
    canvas.drawCircle(center, thumbRadius, Paint()..color = Colors.white);

    // Colored accent dot
    canvas.drawCircle(center, 4.5, Paint()..color = ringColor);
  }
}
