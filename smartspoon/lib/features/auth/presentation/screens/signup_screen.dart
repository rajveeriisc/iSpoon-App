// signup_screen.dart — new-account registration screen.
//
// Collects name/email/password (validated via core validators), creates the
// account through FirebaseAuthService, triggers the email-verification flow, and
// on success exchanges the token for a backend JWT and continues to the app.
// Links back to login for existing users.
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:smartspoon/features/auth/index.dart';
import 'package:smartspoon/core/core.dart';
import 'package:smartspoon/features/home/presentation/screens/home_page.dart';

// SignUpScreen widget provides a form for users to create a new account
class SignUpScreen extends StatefulWidget {
  const SignUpScreen({super.key});

  @override
  State<SignUpScreen> createState() => _SignUpScreenState();
}

class _SignUpScreenState extends State<SignUpScreen> {
  final _formKey = GlobalKey<FormState>();

  final _nameController = TextEditingController();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();

  bool _isLoading = false;
  bool _isPasswordVisible = false;
  bool _isConfirmPasswordVisible = false;

  @override
  void dispose() {
    _nameController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }

  Future<void> _handleSignUp() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _isLoading = true;
    });
    try {
      final email = _emailController.text.trim();
      final password = _passwordController.text;
      final name = _nameController.text.trim();

      final fb = FirebaseAuthService();
      final result = await fb.signUpWithEmail(
        email: email,
        password: password,
        name: name.isNotEmpty ? name : email.split('@').first,
      );

      if (result['success'] == true) {
        if (result['emailVerified'] == false) {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Account created! Please verify your email, then log in.',
              ),
              duration: Duration(seconds: 4),
            ),
          );
          Navigator.of(context).pushReplacement(
            MaterialPageRoute(builder: (_) => const LoginScreen()),
          );
          return;
        }

        final idToken = result['token'] as String;
        await _handleAuthSuccess(idToken: idToken);
      } else {
        throw AuthException(result['message'] as String? ?? 'Signup failed');
      }
    } on AuthException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(e.message)));
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Signup failed. Please try again.')),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AuthLayout(
      child: Form(
        key: _formKey,
        child: AutofillGroup(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: AppTheme.spaceSm),
              Align(
                alignment: Alignment.centerLeft,
                child: Tooltip(
                  message: 'Back to sign in',
                  child: IconButton.filledTonal(
                    constraints: const BoxConstraints.tightFor(
                      width: AppTheme.minTouchTarget,
                      height: AppTheme.minTouchTarget,
                    ),
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.arrow_back_rounded, size: 20),
                  ),
                ),
              ),
              const SizedBox(height: AppTheme.spaceMd),
              const AuthFormHeader(
                title: 'Create your account',
                subtitle: 'Set up i-Spoon in just a moment',
              ),
              AuthTextField(
                controller: _nameController,
                label: 'Full Name',
                icon: Icons.person_outline,
                textInputAction: TextInputAction.next,
                textCapitalization: TextCapitalization.words,
                validator: _validateName,
              ),
              const SizedBox(height: AppTheme.spaceMd),
              AuthTextField(
                controller: _emailController,
                label: 'Email',
                icon: Icons.email_outlined,
                keyboardType: TextInputType.emailAddress,
                textInputAction: TextInputAction.next,
                autocorrect: false,
                autofillHints: const [
                  AutofillHints.username,
                  AutofillHints.email,
                ],
                validator: _validateEmail,
              ),
              const SizedBox(height: AppTheme.spaceMd),
              AuthTextField(
                controller: _passwordController,
                label: 'Password',
                icon: Icons.lock_outline,
                obscureText: !_isPasswordVisible,
                textInputAction: TextInputAction.next,
                autocorrect: false,
                autofillHints: const [AutofillHints.newPassword],
                validator: validatePassword,
                suffix: IconButton(
                  icon: Icon(
                    _isPasswordVisible
                        ? Icons.visibility
                        : Icons.visibility_off,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    size: 20,
                  ),
                  onPressed: () =>
                      setState(() => _isPasswordVisible = !_isPasswordVisible),
                ),
              ),
              const SizedBox(height: AppTheme.spaceMd),
              AuthTextField(
                controller: _confirmPasswordController,
                label: 'Confirm Password',
                icon: Icons.lock_outline,
                obscureText: !_isConfirmPasswordVisible,
                textInputAction: TextInputAction.done,
                autocorrect: false,
                autofillHints: const [AutofillHints.password],
                validator: (value) =>
                    validateConfirmPassword(value, _passwordController.text),
                onFieldSubmitted: (_) {
                  if (!_isLoading) _handleSignUp();
                },
                suffix: IconButton(
                  icon: Icon(
                    _isConfirmPasswordVisible
                        ? Icons.visibility
                        : Icons.visibility_off,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    size: 20,
                  ),
                  onPressed: () => setState(
                    () =>
                        _isConfirmPasswordVisible = !_isConfirmPasswordVisible,
                  ),
                ),
              ),
              const SizedBox(height: AppTheme.spaceLg),
              AuthPrimaryButton(
                label: 'Sign Up',
                loading: _isLoading,
                onPressed: _isLoading ? null : _handleSignUp,
              ),
              const SizedBox(height: AppTheme.spaceMd),
              Wrap(
                alignment: WrapAlignment.center,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(
                    'Already have an account?',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                  TextButton(
                    onPressed: () {
                      Navigator.of(context).pop();
                    },
                    child: const Text('Sign in'),
                  ),
                ],
              ),
              const SizedBox(height: AppTheme.spaceSm),
            ],
          ),
        ),
      ),
    );
  }

  /// Shared post-auth success logic: exchange token, fetch profile, navigate home.
  Future<void> _handleAuthSuccess({required String idToken}) async {
    try {
      await AuthService.verifyFirebaseToken(idToken: idToken);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("We couldn't sync your account. Please try again."),
        ),
      );
      return;
    }

    final storedJwt = await AuthService.getToken();
    if (storedJwt == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Authentication failed. Please try again.'),
        ),
      );
      return;
    }

    try {
      final me = await AuthService.getMe();
      if (!mounted) return;
      final userMap = me['user'] as Map<String, dynamic>? ?? me;
      Provider.of<UserProvider>(context, listen: false).setFromMap(userMap);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("We couldn't load your profile. Please try again."),
        ),
      );
      return;
    }

    if (!mounted) return;
    Navigator.of(
      context,
    ).pushReplacement(MaterialPageRoute(builder: (_) => const HomePage()));
  }

  String? _validateName(String? value) {
    if (value == null || value.trim().isEmpty) {
      return 'Please enter your full name';
    }
    if (value.trim().length < 2) {
      return 'Name must be at least 2 characters';
    }
    return null;
  }

  String? _validateEmail(String? value) {
    return validateEmail(value);
  }
}
