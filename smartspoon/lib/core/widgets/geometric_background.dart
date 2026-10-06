// geometric_background.dart — decorative full-screen background painter.
//
// GeometricBackground is a StatelessWidget that draws soft, organic pastel
// "blob" orbs behind screen content via a CustomPaint/_OrganicBlobPainter. It
// reads the current brightness and picks light- or dark-tuned colors, giving
// pages their signature ambient glow without any layout cost. Purely visual —
// no state, no interaction.
import 'package:flutter/material.dart';
import 'package:smartspoon/core/theme/app_theme.dart';

/// Very subtle monochromatic ambient background.
class GeometricBackground extends StatelessWidget {
  const GeometricBackground({super.key});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return CustomPaint(
      painter: _OrganicBlobPainter(isDark: isDark),
      child: const SizedBox.expand(),
    );
  }
}

class _OrganicBlobPainter extends CustomPainter {
  final bool isDark;
  _OrganicBlobPainter({required this.isDark});

  @override
  void paint(Canvas canvas, Size size) {
    // Ultra-soft pastel glow
    final double alpha = isDark ? 0.05 : 0.10;

    // Both glows stay inside the brand family.
    _blob(
      canvas,
      Offset(-size.width * 0.1, -size.height * 0.05),
      size.width * 0.6,
      isDark ? AppTheme.primary : AppTheme.brandTintStrong,
      alpha,
    );

    _blob(
      canvas,
      Offset(size.width * 1.1, size.height * 0.8),
      size.width * 0.5,
      isDark ? AppTheme.primary : AppTheme.brandTint,
      alpha * 0.7,
    );
  }

  void _blob(
    Canvas canvas,
    Offset center,
    double radius,
    Color color,
    double alpha,
  ) {
    final paint = Paint()
      ..shader = RadialGradient(
        colors: [
          color.withValues(alpha: alpha),
          color.withValues(alpha: 0.0),
        ],
      ).createShader(Rect.fromCircle(center: center, radius: radius));
    canvas.drawCircle(center, radius, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
