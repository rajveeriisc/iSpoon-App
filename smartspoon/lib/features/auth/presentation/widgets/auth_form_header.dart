// auth_form_header.dart — title + subtitle header for auth screens.
//
// AuthFormHeader is a small StatelessWidget that renders the styled heading
// (title + subtitle) at the top of the login/signup/forgot-password forms,
// keeping their headings visually consistent.
import 'package:flutter/material.dart';
import 'package:smartspoon/core/widgets/bowl_spoon_icon.dart';
import 'package:smartspoon/core/theme/app_theme.dart';

class AuthFormHeader extends StatelessWidget {
  const AuthFormHeader({
    super.key,
    required this.title,
    required this.subtitle,
  });

  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Column(
      children: [
        Container(
          width: 64,
          height: 64,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppTheme.radiusLg),
            color: colorScheme.primaryContainer,
            border: Border.all(
              color: colorScheme.primary.withValues(alpha: 0.18),
            ),
            boxShadow: [
              BoxShadow(
                color: colorScheme.primary.withValues(alpha: 0.12),
                blurRadius: 20,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: BowlSpoonIcon(
            color: colorScheme.onPrimaryContainer,
            size: 30,
          ),
        ),
        const SizedBox(height: AppTheme.spaceLg),
        Text(
          title,
          style: theme.textTheme.headlineMedium?.copyWith(
            color: colorScheme.onSurface,
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: AppTheme.spaceSm),
        Text(
          subtitle,
          style: theme.textTheme.bodyLarge?.copyWith(
            color: colorScheme.onSurfaceVariant,
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: AppTheme.spaceXl),
      ],
    );
  }
}
