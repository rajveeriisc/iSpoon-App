// premium_widgets.dart — shared building-block UI widgets ("premium" design kit).
//
// Reusable presentation primitives used across every feature, most notably
// PremiumGlassCard — the signature soft-shadow/glass card (optional tap,
// gradient, accent color, and one-time fade-and-rise appear animation) that
// wraps nearly all dashboard content. Centralizing these keeps cards, buttons,
// and containers visually consistent app-wide.
import 'package:flutter/material.dart';
import 'package:smartspoon/core/theme/app_theme.dart';

/// Neutral product card shared across dashboard and settings surfaces.
class PremiumGlassCard extends StatefulWidget {
  final Widget child;
  final EdgeInsetsGeometry? padding;
  final EdgeInsetsGeometry? margin;
  final VoidCallback? onTap;
  final double borderRadius;
  final List<Color>? gradientColors;
  final double? width;
  final double? height;

  /// Optional category color for the card's boundary
  final Color? accentColor;

  /// Optional background color for the colorful modern aesthetic
  final Color? backgroundColor;

  /// Plays a one-time fade + rise-in animation when the card first mounts.
  final bool animateOnAppear;

  const PremiumGlassCard({
    super.key,
    required this.child,
    this.padding,
    this.margin,
    this.onTap,
    this.borderRadius = AppTheme.radiusLg,
    this.gradientColors,
    this.width,
    this.height,
    this.accentColor,
    this.backgroundColor,
    this.animateOnAppear = true,
  });

  @override
  State<PremiumGlassCard> createState() => _PremiumGlassCardState();
}

class _PremiumGlassCardState extends State<PremiumGlassCard>
    with SingleTickerProviderStateMixin {
  bool _isPressed = false;
  late final AnimationController _appearController;
  late final Animation<double> _fade;
  late final Animation<Offset> _rise;

  @override
  void initState() {
    super.initState();
    _appearController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 240),
    );
    _fade = CurvedAnimation(parent: _appearController, curve: Curves.easeOut);
    _rise = Tween<Offset>(begin: const Offset(0, 0.03), end: Offset.zero)
        .animate(
          CurvedAnimation(
            parent: _appearController,
            curve: Curves.easeOutCubic,
          ),
        );
    if (widget.animateOnAppear) {
      _appearController.forward();
    } else {
      _appearController.value = 1.0;
    }
  }

  @override
  void dispose() {
    _appearController.dispose();
    super.dispose();
  }

  BoxDecoration _decoration(BuildContext context) {
    if (widget.gradientColors != null) {
      return BoxDecoration(
        borderRadius: BorderRadius.circular(widget.borderRadius),
        gradient: const LinearGradient(
          colors: [AppTheme.primary, AppTheme.primaryDeep],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        boxShadow: [
          BoxShadow(
            color: Theme.of(context).brightness == Brightness.dark
                ? Colors.transparent
                : AppTheme.primary.withValues(alpha: 0.18),
            blurRadius: 16,
            offset: const Offset(0, 6),
          ),
        ],
      );
    }

    if (widget.backgroundColor != null) {
      // Use the colorful card decoration if a background color is provided
      return AppTheme.coloredCardDecoration(
        context,
        widget.backgroundColor!,
      ).copyWith(borderRadius: BorderRadius.circular(widget.borderRadius));
    }

    // Default neutral card decoration (no borders)
    return AppTheme.cardDecoration(
      context,
    ).copyWith(borderRadius: BorderRadius.circular(widget.borderRadius));
  }

  @override
  Widget build(BuildContext context) {
    Widget inner = Container(
      width: widget.width,
      height: widget.height,
      margin: widget.margin,
      padding: widget.padding ?? const EdgeInsets.all(AppTheme.spaceMd),
      decoration: _decoration(context),
      child: widget.child,
    );

    if (widget.onTap != null) {
      inner = GestureDetector(
        onTapDown: (_) => setState(() => _isPressed = true),
        onTapUp: (_) {
          setState(() => _isPressed = false);
          widget.onTap!();
        },
        onTapCancel: () => setState(() => _isPressed = false),
        child: AnimatedScale(
          scale: _isPressed ? 0.96 : 1.0,
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOutCubic,
          child: inner,
        ),
      );
    }

    return FadeTransition(
      opacity: _fade,
      child: SlideTransition(position: _rise, child: inner),
    );
  }
}

/// Gradient text (indigo→sky or emerald→sky)
class PremiumGradientText extends StatelessWidget {
  final String text;
  final List<Color> gradient;
  final TextStyle? style;

  const PremiumGradientText(
    this.text, {
    super.key,
    required this.gradient,
    this.style,
  });

  @override
  Widget build(BuildContext context) {
    return ShaderMask(
      shaderCallback: (bounds) => LinearGradient(
        colors: gradient,
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
      ).createShader(bounds),
      child: Text(
        text,
        style: (style ?? const TextStyle()).copyWith(color: Colors.white),
      ),
    );
  }
}

/// Icon in a tinted soft-color circle — used for list items, feature cards
class PremiumIconBox extends StatelessWidget {
  final IconData icon;
  final Color color;
  final double size;

  const PremiumIconBox({
    super.key,
    required this.icon,
    required this.color,
    this.size = 24,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withValues(alpha: 0.15), width: 0.5),
      ),
      child: Icon(icon, color: color, size: size),
    );
  }
}
