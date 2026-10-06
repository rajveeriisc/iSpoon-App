// delete_account_dialog.dart — account-deletion confirmation + execution flow.
//
// A guarded, multi-step confirmation dialog for the destructive, irreversible
// "delete account" action: it re-authenticates the user, deletes the backend
// account (AuthService) and the Firebase user (FirebaseAuthService), and signs
// out. Deliberately never fires from a single tap.
import 'package:flutter/material.dart';
import 'package:smartspoon/core/theme/app_theme.dart';
import 'package:smartspoon/features/auth/domain/services/auth_service.dart';
import 'package:smartspoon/features/auth/domain/services/firebase_auth_service.dart';

/// "Delete Account" confirmation + execution flow.
///
/// A destructive, irreversible account action must never fire from a single
/// accidental tap, so this requires the user to read an explicit warning and
/// type a confirmation phrase before the request is sent.
///
/// On success, calls [onDeleted] so the caller can navigate back to the
/// login/signup screen and clear in-memory user state.
class DeleteAccountDialog {
  static Future<void> show(
    BuildContext context, {
    required VoidCallback onDeleted,
  }) async {
    final firebaseAuth = FirebaseAuthService();
    final confirmation = await showDialog<String?>(
      context: context,
      builder: (_) => _DeleteAccountConfirmDialog(
        requiresPassword: firebaseAuth.hasPasswordProvider,
      ),
    );

    if (confirmation == null) return;
    if (!context.mounted) return;

    await _performDelete(
      context,
      currentPassword: confirmation.isEmpty ? null : confirmation,
      onDeleted: onDeleted,
    );
  }

  static Future<void> _performDelete(
    BuildContext context, {
    String? currentPassword,
    required VoidCallback onDeleted,
  }) async {
    var progressVisible = false;
    try {
      final reauth = await FirebaseAuthService()
          .reauthenticateForAccountDeletion(currentPassword: currentPassword);
      if (reauth['success'] != true || reauth['idToken'] is! String) {
        throw AuthException(
          reauth['message'] as String? ?? 'Could not verify your identity.',
        );
      }
      if (!context.mounted) return;

      // Re-authentication may need to open a provider popup/account chooser,
      // so only cover the subsequent irreversible server operation.
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (_) => const Center(
          child: CircularProgressIndicator(color: AppTheme.caramel),
        ),
      );
      progressVisible = true;

      await AuthService.deleteAccount(
        firebaseIdToken: reauth['idToken'] as String,
      );
      if (!context.mounted) return;
      Navigator.of(context).pop(); // dismiss progress dialog
      progressVisible = false;
      onDeleted();
    } catch (e) {
      if (!context.mounted) return;
      if (progressVisible) {
        Navigator.of(context).pop(); // dismiss progress dialog
      }
      final message = e is AuthException
          ? e.message
          : 'Could not delete your account. Please try again.';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(message, style: AppTheme.sans(color: Colors.white)),
          backgroundColor: AppTheme.paprika,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
      );
    }
  }
}

class _DeleteAccountConfirmDialog extends StatefulWidget {
  const _DeleteAccountConfirmDialog({required this.requiresPassword});

  final bool requiresPassword;

  @override
  State<_DeleteAccountConfirmDialog> createState() =>
      _DeleteAccountConfirmDialogState();
}

class _DeleteAccountConfirmDialogState
    extends State<_DeleteAccountConfirmDialog> {
  static const _confirmPhrase = 'DELETE';
  final _confirmationController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _canConfirm = false;

  void _updateCanConfirm() {
    setState(() {
      _canConfirm =
          _confirmationController.text.trim() == _confirmPhrase &&
          (!widget.requiresPassword || _passwordController.text.isNotEmpty);
    });
  }

  @override
  void dispose() {
    _confirmationController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Row(
        children: [
          Icon(Icons.warning_amber_rounded, color: AppTheme.paprika),
          const SizedBox(width: 8),
          Text(
            'Delete Account?',
            style: AppTheme.serif(
              fontSize: 18,
              fontWeight: FontWeight.w600,
              color: isDark ? AppTheme.darkTextPrimary : null,
            ),
          ),
        ],
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'This permanently deletes your account and ALL associated data — '
              'meals, bites, devices, and settings — from our servers and this '
              'device. This cannot be undone.',
              style: AppTheme.sans(
                fontSize: 14,
                color: isDark ? AppTheme.darkTextSecondary : AppTheme.roastSoft,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'Type DELETE to confirm:',
              style: AppTheme.sans(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: isDark ? AppTheme.darkTextPrimary : AppTheme.roast,
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _confirmationController,
              textCapitalization: TextCapitalization.characters,
              decoration: const InputDecoration(hintText: 'DELETE'),
              onChanged: (_) => _updateCanConfirm(),
            ),
            if (widget.requiresPassword) ...[
              const SizedBox(height: 16),
              Text(
                'Current password:',
                style: AppTheme.sans(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: isDark ? AppTheme.darkTextPrimary : AppTheme.roast,
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _passwordController,
                obscureText: true,
                enableSuggestions: false,
                autocorrect: false,
                decoration: const InputDecoration(
                  hintText: 'Enter your password',
                ),
                onChanged: (_) => _updateCanConfirm(),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: _canConfirm
              ? () => Navigator.pop(
                  context,
                  widget.requiresPassword ? _passwordController.text : '',
                )
              : null,
          style: TextButton.styleFrom(foregroundColor: AppTheme.paprika),
          child: const Text('Delete Permanently'),
        ),
      ],
    );
  }
}
