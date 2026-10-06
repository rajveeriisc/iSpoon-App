// auth_primary_button.dart — primary call-to-action button for auth forms.
//
// AuthPrimaryButton is the full-width themed submit button (Sign In / Sign Up /
// Send Reset) with a built-in loading state that shows a spinner and disables
// taps while an auth request is in flight.
import 'package:flutter/material.dart';

class AuthPrimaryButton extends StatelessWidget {
  const AuthPrimaryButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.loading = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final enabled = !loading && onPressed != null;

    return Semantics(
      button: true,
      enabled: enabled,
      label: loading ? '$label, loading' : label,
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 180),
        opacity: enabled || loading ? 1 : 0.5,
        child: SizedBox(
          width: double.infinity,
          height: 52,
          child: FilledButton(
            onPressed: enabled ? onPressed : null,
            child: loading
                ? SizedBox.square(
                    dimension: 22,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.5,
                      color: colorScheme.onPrimary,
                    ),
                  )
                : Text(label),
          ),
        ),
      ),
    );
  }
}
