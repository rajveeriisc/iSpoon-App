// temperature_section.dart — food/heater temperature visualization widget.
//
// TemperatureSection renders the current food temperature (and, for
// heater-equipped spoons, heater state) from TemperatureStats as a gauge/section
// on the Insights dashboard. The hasHeater flag toggles heater-specific UI.
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:smartspoon/core/widgets/bowl_spoon_icon.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:smartspoon/core/theme/app_theme.dart';
import '../../domain/models.dart';
import 'package:smartspoon/core/utils/temperature_format.dart';

class TemperatureSection extends StatefulWidget {
  const TemperatureSection({
    super.key,
    required this.stats,
    this.hasHeater = false,
  });

  final TemperatureStats? stats;

  /// When false, the heater gauge is hidden (basic iSpoon connected).
  final bool hasHeater;

  @override
  State<TemperatureSection> createState() => _TemperatureSectionState();
}

class _TemperatureSectionState extends State<TemperatureSection>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final food = (widget.stats?.foodTempC ?? 0.0);
    final heater = widget.stats?.heaterTempC ?? 60;
    final alert = food > 60;

    return Container(
      // margin handled by parent
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: isDark
              ? [AppTheme.darkCreamElevated, AppTheme.darkCream]
              : [AppTheme.cream, AppTheme.oat],
        ),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(
          color: isDark ? AppTheme.darkBorder : AppTheme.border,
          width: 1,
        ),
        boxShadow: [
          BoxShadow(
            color: isDark ? Colors.transparent : AppTheme.cardShadow,
            blurRadius: 20,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [AppTheme.caramel, AppTheme.honey],
                  ),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(
                  Icons.whatshot_rounded,
                  color: Colors.white,
                  size: 20,
                ),
              ),
              const SizedBox(width: 12),
              Text(
                'Temperature Monitor',
                style: GoogleFonts.figtree(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.5,
                  color: Theme.of(context).colorScheme.onSurface,
                ),
              ),
            ],
          ),
          const SizedBox(height: 28),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _AnimatedCircularTempGauge(
                label: 'Food Temp',
                value: food,
                maxValue: 100,
                color: AppTheme.sageDeep,
                animation: _controller,
                icon: const BowlSpoonIcon(),
              ),
              if (widget.hasHeater)
                _AnimatedCircularTempGauge(
                  label: 'Heater',
                  value: heater,
                  maxValue: 100,
                  color: AppTheme.paprika,
                  animation: _controller,
                  icon: const Icon(Icons.local_fire_department_rounded),
                ),
            ],
          ),
          if (alert) ...[
            const SizedBox(height: 20),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    AppTheme.paprika.withValues(alpha: 0.15),
                    AppTheme.honey.withValues(alpha: 0.1),
                  ],
                ),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: AppTheme.paprika.withValues(alpha: 0.3),
                  width: 1,
                ),
              ),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: AppTheme.paprika,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Icon(
                      Icons.warning_amber_rounded,
                      color: Colors.white,
                      size: 20,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'Food is hot! Wait 60 seconds before next bite',
                      style: GoogleFonts.figtree(
                        fontWeight: FontWeight.w500,
                        fontSize: 13,
                        color: Theme.of(context).colorScheme.onSurface,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _AnimatedCircularTempGauge extends StatelessWidget {
  const _AnimatedCircularTempGauge({
    required this.label,
    required this.value,
    required this.maxValue,
    required this.color,
    required this.animation,
    required this.icon,
  });

  final String label;
  final double value;
  final double maxValue;
  final Color color;
  final Animation<double> animation;
  final Widget icon;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final progress = (value / maxValue).clamp(0.0, 1.0);

    return AnimatedBuilder(
      animation: animation,
      builder: (context, child) {
        final animatedProgress = progress * animation.value;

        return Column(
          children: [
            SizedBox(
              width: 130,
              height: 130,
              child: CustomPaint(
                painter: _CircularGaugePainter(
                  progress: animatedProgress,
                  color: color,
                  isDark: isDark,
                ),
                child: Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: color.withValues(alpha: 0.15),
                          shape: BoxShape.circle,
                        ),
                        child: IconTheme(
                          data: IconThemeData(color: color, size: 24),
                          child: icon,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        value > 0
                            ? formatSpoonTempWithUnit(value * animation.value)
                            : '—',
                        style: GoogleFonts.figtree(
                          fontSize: 20,
                          fontWeight: FontWeight.w600,
                          color: Theme.of(context).colorScheme.onSurface,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              label,
              style: GoogleFonts.figtree(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: Theme.of(
                  context,
                ).colorScheme.onSurface.withValues(alpha: isDark ? 0.75 : 0.65),
              ),
            ),
            const SizedBox(height: 4),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                _getStatusText(progress),
                style: GoogleFonts.figtree(
                  fontSize: 11,
                  color: color,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  String _getStatusText(double progress) {
    if (progress < 0.3) return 'Cool';
    if (progress < 0.5) return 'Warm';
    if (progress < 0.7) return 'Hot';
    return 'Very Hot';
  }
}

class _CircularGaugePainter extends CustomPainter {
  final double progress;
  final Color color;
  final bool isDark;

  _CircularGaugePainter({
    required this.progress,
    required this.color,
    required this.isDark,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2 - 10;
    final strokeWidth = 12.0;

    // Background circle
    final bgPaint = Paint()
      ..color = isDark
          ? AppTheme.darkBorder.withValues(alpha: 0.5)
          : AppTheme.line
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;

    canvas.drawCircle(center, radius, bgPaint);

    // Progress arc with gradient
    final rect = Rect.fromCircle(center: center, radius: radius);
    const startAngle = -math.pi / 2; // Start from top
    final sweepAngle = 2 * math.pi * progress;

    if (progress > 0) {
      final gradientShader = SweepGradient(
        startAngle: startAngle,
        endAngle: startAngle + sweepAngle,
        colors: [
          color.withValues(alpha: 0.5),
          color,
          color.withValues(alpha: 0.8),
        ],
        stops: const [0.0, 0.5, 1.0],
      ).createShader(rect);

      final progressPaint = Paint()
        ..shader = gradientShader
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..strokeCap = StrokeCap.round;

      canvas.drawArc(rect, startAngle, sweepAngle, false, progressPaint);
    }

    // Glow effect at the end of progress
    if (progress > 0) {
      final endAngle = startAngle + sweepAngle;
      final glowX = center.dx + radius * math.cos(endAngle);
      final glowY = center.dy + radius * math.sin(endAngle);
      final glowCenter = Offset(glowX, glowY);

      final glowPaint = Paint()
        ..color = color.withValues(alpha: 0.4)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8);

      canvas.drawCircle(glowCenter, 8, glowPaint);
    }
  }

  @override
  bool shouldRepaint(_CircularGaugePainter oldDelegate) =>
      progress != oldDelegate.progress || color != oldDelegate.color;
}
