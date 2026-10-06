// login_screen.dart — email/password + Google sign-in screen.
//
// Collects credentials (validated via core validators), signs in through
// FirebaseAuthService, exchanges the Firebase token for a backend JWT via
// AuthService, seeds UserProvider, and navigates to HomePage on success.
// Surfaces email-verification and error states, and links to sign-up and
// forgot-password.
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:smartspoon/features/auth/index.dart';
import 'package:smartspoon/features/home/index.dart';
import 'package:smartspoon/core/core.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _isPasswordVisible = false;
  bool _isLoading = false;
  // Backend auth removed; using local navigation only

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }

    setState(() {
      _isLoading = true;
    });

    try {
      final fb = FirebaseAuthService();
      final result = await fb.signInWithEmail(
        email: _emailController.text,
        password: _passwordController.text,
      );
      if (result['success'] == true) {
        if (result['user'] is Map && result['user']['email'] != null) {
          // refresh user to ensure latest verification status
          try {
            await fb.currentUser?.reload();
          } catch (_) {}
        }
        if (fb.currentUser != null && fb.currentUser!.emailVerified == false) {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Please verify your email before logging in.'),
            ),
          );
          return;
        }
        final idToken = result['token'] as String;
        await _handleAuthSuccess(idToken: idToken);
      } else {
        throw AuthException(result['message'] as String? ?? 'Login failed');
      }
    } on AuthException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(e.message)));
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Login failed. Please try again.')),
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
            children: _buildFormContent(context),
          ),
        ),
      ),
    );
  }

  List<Widget> _buildFormContent(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final colorScheme = Theme.of(context).colorScheme;
    final themeProvider = Provider.of<ThemeProvider>(context);

    return [
      const SizedBox(height: AppTheme.spaceSm),
      const AuthFormHeader(
        title: 'Welcome back',
        subtitle: 'Sign in to continue to i-Spoon',
      ),
      AuthTextField(
        controller: _emailController,
        label: 'Email',
        icon: Icons.email_outlined,
        keyboardType: TextInputType.emailAddress,
        textInputAction: TextInputAction.next,
        autocorrect: false,
        autofillHints: const [AutofillHints.username, AutofillHints.email],
        validator: _validateEmail,
      ),
      const SizedBox(height: AppTheme.spaceMd),
      AuthTextField(
        controller: _passwordController,
        label: 'Password',
        icon: Icons.lock_outline,
        obscureText: !_isPasswordVisible,
        textInputAction: TextInputAction.done,
        autocorrect: false,
        autofillHints: const [AutofillHints.password],
        validator: _validatePassword,
        onFieldSubmitted: (_) {
          if (!_isLoading) _login();
        },
        suffix: IconButton(
          icon: Icon(
            _isPasswordVisible ? Icons.visibility : Icons.visibility_off,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
          onPressed: () =>
              setState(() => _isPasswordVisible = !_isPasswordVisible),
        ),
      ),
      const SizedBox(height: AppTheme.spaceXs),
      Align(
        alignment: Alignment.centerRight,
        child: TextButton(
          onPressed: () {
            Navigator.of(context).push(
              MaterialPageRoute(
                builder: (context) => const ForgotPasswordScreen(),
              ),
            );
          },
          child: Text(
            'Forgot Password?',
            style: textTheme.labelLarge?.copyWith(color: colorScheme.primary),
          ),
        ),
      ),
      const SizedBox(height: AppTheme.spaceSm),
      AuthPrimaryButton(
        label: 'Sign in',
        loading: _isLoading,
        onPressed: _isLoading ? null : _login,
      ),
      const SizedBox(height: AppTheme.spaceLg),
      const _AuthDivider(label: 'Or continue with'),
      const SizedBox(height: AppTheme.spaceMd),
      SocialButtonsRow(
        onFacebookPressed: () {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Facebook login coming soon')),
          );
        },
        onGooglePressed: _signInWithGoogle,
        onApplePressed: _signInWithApple,
      ),
      const SizedBox(height: AppTheme.spaceLg),
      Wrap(
        alignment: WrapAlignment.center,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text("Don't have an account?", style: textTheme.bodyMedium),
          TextButton(
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (context) => const SignUpScreen()),
              );
            },
            child: const Text('Sign Up'),
          ),
        ],
      ),
      Center(
        child: Tooltip(
          message: themeProvider.themeMode == ThemeMode.light
              ? 'Use dark theme'
              : 'Use light theme',
          child: IconButton(
            constraints: const BoxConstraints.tightFor(
              width: AppTheme.minTouchTarget,
              height: AppTheme.minTouchTarget,
            ),
            icon: Icon(
              themeProvider.themeMode == ThemeMode.light
                  ? Icons.dark_mode_outlined
                  : Icons.light_mode_outlined,
              size: 22,
            ),
            onPressed: () {
              Provider.of<ThemeProvider>(context, listen: false).toggleTheme();
            },
          ),
        ),
      ),
      const SizedBox(height: AppTheme.spaceSm),
    ];
  }

  /// Shared post-auth success logic: exchange token, fetch profile, navigate home
  Future<void> _handleAuthSuccess({required String idToken}) async {
    // Exchange Firebase token for backend JWT
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

    // Verify backend JWT was stored
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

    // Fetch user profile from backend — required before entering home.
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

  Future<void> _signInWithGoogle() async {
    setState(() => _isLoading = true);

    try {
      final firebaseAuth = FirebaseAuthService();
      final result = await firebaseAuth.signInWithGoogle();

      if (!mounted) return;

      if (result['success'] == true) {
        final idToken = result['token'] as String;
        await _handleAuthSuccess(idToken: idToken);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(result['message'] ?? 'Google sign-in failed')),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Google sign-in didn't go through. Please try again."),
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  Future<void> _signInWithApple() async {
    setState(() => _isLoading = true);

    try {
      final firebaseAuth = FirebaseAuthService();
      final result = await firebaseAuth.signInWithApple();

      if (!mounted) return;

      if (result['success'] == true) {
        final idToken = result['token'] as String;
        await _handleAuthSuccess(idToken: idToken);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(result['message'] ?? 'Apple sign-in failed')),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Apple sign-in didn't go through. Please try again."),
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  String? _validateEmail(String? value) => validateEmail(value);

  String? _validatePassword(String? value) {
    if (value == null || value.isEmpty) {
      return 'Please enter your password';
    }
    return null;
  }
}

class _AuthDivider extends StatelessWidget {
  const _AuthDivider({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        Expanded(child: Divider(color: colorScheme.outlineVariant)),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppTheme.spaceMd),
          child: Text(
            label,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        Expanded(child: Divider(color: colorScheme.outlineVariant)),
      ],
    );
  }
}
