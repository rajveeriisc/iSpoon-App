// social_buttons_row.dart — third-party sign-in button row (Google / Apple / Facebook).
//
// SocialButtonsRow renders the SVG-iconed social login buttons and forwards
// taps via onGooglePressed / onApplePressed / onFacebookPressed callbacks,
// leaving the actual auth logic to the parent screen.
//
// Apple is iOS-only and required alongside Google by App Store Review
// Guideline 4.8 (an app offering third-party login must also offer Sign in
// with Apple) — it is omitted entirely on other platforms rather than shown
// disabled, since the native credential flow it wraps doesn't exist there.
import 'dart:io' show Platform;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:smartspoon/core/theme/app_theme.dart';

class SocialButtonsRow extends StatelessWidget {
  const SocialButtonsRow({
    super.key,
    required this.onGooglePressed,
    required this.onFacebookPressed,
    this.onApplePressed,
  });

  final VoidCallback onGooglePressed;
  final VoidCallback onFacebookPressed;
  final VoidCallback? onApplePressed;

  bool get _showAppleButton =>
      onApplePressed != null && !kIsWeb && Platform.isIOS;

  @override
  Widget build(BuildContext context) {
    final googleButton = _SocialButton(
      customIcon: SvgPicture.asset(
        'assets/images/google_logo.svg',
        width: 22,
        height: 22,
      ),
      icon: Icons.g_mobiledata,
      label: 'Google',
      iconColor: const Color(0xFFEA4335),
      onPressed: onGooglePressed,
    );
    final facebookButton = _SocialButton(
      icon: Icons.facebook,
      label: 'Facebook',
      iconColor: const Color(0xFF1877F2),
      onPressed: onFacebookPressed,
    );
    final appleButton = _showAppleButton
        ? _SocialButton(
            icon: Icons.apple,
            label: 'Apple',
            iconColor: Theme.of(context).colorScheme.onSurface,
            onPressed: onApplePressed!,
          )
        : null;

    final buttons = [googleButton, ?appleButton, facebookButton];

    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 340 || buttons.length > 2) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (int i = 0; i < buttons.length; i++) ...[
                if (i > 0) const SizedBox(height: AppTheme.spaceSm),
                buttons[i],
              ],
            ],
          );
        }

        return Row(
          children: [
            for (int i = 0; i < buttons.length; i++) ...[
              if (i > 0) const SizedBox(width: AppTheme.spaceSm),
              Expanded(child: buttons[i]),
            ],
          ],
        );
      },
    );
  }
}

class _SocialButton extends StatelessWidget {
  const _SocialButton({
    required this.icon,
    this.customIcon,
    required this.label,
    required this.iconColor,
    required this.onPressed,
  });

  final IconData icon;
  final Widget? customIcon;
  final String label;
  final Color iconColor;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.surface,
      borderRadius: BorderRadius.circular(AppTheme.radiusMd),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
        onTap: onPressed,
        child: Container(
          height: 52,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppTheme.radiusMd),
            border: Border.all(
              color: Theme.of(context).colorScheme.outlineVariant,
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              customIcon ?? Icon(icon, color: iconColor, size: 22),
              const SizedBox(width: 8),
              Text(
                label,
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  color: Theme.of(context).colorScheme.onSurface,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
