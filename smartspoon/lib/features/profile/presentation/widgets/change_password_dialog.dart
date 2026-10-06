// change_password_dialog.dart — change-password dialog for email accounts.
//
// Presents a dialog to collect the current + new password and updates it via
// FirebaseAuthService (with re-authentication). Only meaningful for email/
// password accounts, so callers gate it behind that provider check.
import 'package:flutter/material.dart';
import 'package:smartspoon/core/theme/app_theme.dart';
import 'package:smartspoon/features/auth/domain/services/firebase_auth_service.dart';

/// "Change Password" flow for email/password accounts.
///
/// Only meaningful for users who actually signed up with email/password —
/// callers should gate showing this behind
/// `FirebaseAuthService().hasPasswordProvider`.
class ChangePasswordDialog {
  static void show(BuildContext context) {
    showDialog(
      context: context,
      builder: (_) => const _ChangePasswordDialog(),
    );
  }
}

class _ChangePasswordDialog extends StatefulWidget {
  const _ChangePasswordDialog();

  @override
  State<_ChangePasswordDialog> createState() => _ChangePasswordDialogState();
}

class _ChangePasswordDialogState extends State<_ChangePasswordDialog> {
  final _formKey = GlobalKey<FormState>();
  final _currentPasswordController = TextEditingController();
  final _newPasswordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();

  bool _obscureCurrent = true;
  bool _obscureNew = true;
  bool _obscureConfirm = true;
  bool _isLoading = false;

  @override
  void dispose() {
    _currentPasswordController.dispose();
    _newPasswordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }

  /// Sends a reset link to the signed-in address.
  ///
  /// Changing a password requires re-authenticating with the CURRENT one, so
  /// without this the dialog is a dead end for exactly the person most likely
  /// to open it — someone who has forgotten it. The email comes from the
  /// signed-in user rather than a field, so this cannot be used to probe
  /// whether some other address has an account.
  Future<void> _sendResetEmail() async {
    final email = FirebaseAuthService().currentUser?.email;
    if (email == null || email.isEmpty) {
      _toast('No email address is attached to this account.', ok: false);
      return;
    }

    setState(() => _isLoading = true);
    final result = await FirebaseAuthService().resetPassword(email);
    if (!mounted) return;
    setState(() => _isLoading = false);

    final success = result['success'] == true;
    _toast(
      success
          ? 'Reset link sent to $email. Open it, set a new password, then sign in again.'
          : (result['message'] as String? ?? 'Could not send the reset email.'),
      ok: success,
    );
    if (success && mounted) Navigator.of(context).pop();
  }

  void _toast(String message, {required bool ok}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message, style: AppTheme.sans(color: Colors.white)),
        backgroundColor: ok ? AppTheme.sageDeep : AppTheme.paprika,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    );
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _isLoading = true);

    final result = await FirebaseAuthService().changePassword(
      currentPassword: _currentPasswordController.text,
      newPassword: _newPasswordController.text,
    );

    if (!mounted) return;
    setState(() => _isLoading = false);

    final success = result['success'] == true;
    final message = result['message'] as String? ?? '';

    if (success) {
      Navigator.of(context).pop();
    }

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          message,
          style: AppTheme.sans(color: Colors.white),
        ),
        backgroundColor: success ? AppTheme.sageDeep : AppTheme.paprika,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    );
  }

  String? _validateCurrentPassword(String? value) {
    if (value == null || value.isEmpty) {
      return 'Please enter your current password';
    }
    return null;
  }

  String? _validateNewPassword(String? value) {
    if (value == null || value.isEmpty) {
      return 'Please enter a new password';
    }
    if (value.length < 8) {
      return 'Password must be at least 8 characters';
    }
    if (value == _currentPasswordController.text) {
      return 'New password must be different from your current one';
    }
    return null;
  }

  String? _validateConfirmPassword(String? value) {
    if (value != _newPasswordController.text) {
      return 'Passwords do not match';
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Text(
        'Change Password',
        style: AppTheme.serif(
          fontSize: 18,
          fontWeight: FontWeight.w600,
          color: isDark ? AppTheme.darkTextPrimary : null,
        ),
      ),
      content: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Enter your current password, then choose a new one.',
                style: AppTheme.sans(
                  fontSize: 13,
                  color: isDark ? AppTheme.darkTextSecondary : AppTheme.roastSoft,
                ),
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _currentPasswordController,
                obscureText: _obscureCurrent,
                autofillHints: const [AutofillHints.password],
                decoration: InputDecoration(
                  labelText: 'Current Password',
                  suffixIcon: IconButton(
                    icon: Icon(_obscureCurrent ? Icons.visibility_off : Icons.visibility),
                    onPressed: () => setState(() => _obscureCurrent = !_obscureCurrent),
                  ),
                ),
                validator: _validateCurrentPassword,
                enabled: !_isLoading,
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: _isLoading ? null : _sendResetEmail,
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: Text(
                    'Forgot your current password?',
                    style: AppTheme.sans(
                      color: AppTheme.caramel,
                      fontSize: 13,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 4),
              TextFormField(
                controller: _newPasswordController,
                obscureText: _obscureNew,
                autofillHints: const [AutofillHints.newPassword],
                decoration: InputDecoration(
                  labelText: 'New Password',
                  suffixIcon: IconButton(
                    icon: Icon(_obscureNew ? Icons.visibility_off : Icons.visibility),
                    onPressed: () => setState(() => _obscureNew = !_obscureNew),
                  ),
                ),
                validator: _validateNewPassword,
                enabled: !_isLoading,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _confirmPasswordController,
                obscureText: _obscureConfirm,
                autofillHints: const [AutofillHints.newPassword],
                decoration: InputDecoration(
                  labelText: 'Confirm New Password',
                  suffixIcon: IconButton(
                    icon: Icon(_obscureConfirm ? Icons.visibility_off : Icons.visibility),
                    onPressed: () => setState(() => _obscureConfirm = !_obscureConfirm),
                  ),
                ),
                validator: _validateConfirmPassword,
                enabled: !_isLoading,
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _isLoading ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _isLoading ? null : _submit,
          style: FilledButton.styleFrom(backgroundColor: AppTheme.caramel),
          child: _isLoading
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                )
              : const Text('Update Password'),
        ),
      ],
    );
  }
}
