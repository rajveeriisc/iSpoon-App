// auth_gate.dart — root auth router deciding login vs. home on launch.
//
// AuthGate is the first screen after startup. It watches Firebase's auth state,
// shows an animated splash while resolving the session, and routes to HomePage
// when a verified user + valid backend token exist, or to LoginScreen otherwise.
// Also seeds UserProvider from the backend profile once authenticated.
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:provider/provider.dart';
import 'package:smartspoon/core/theme/app_theme.dart';
import 'package:smartspoon/features/auth/domain/services/auth_service.dart';
import 'package:smartspoon/features/auth/domain/services/firebase_auth_service.dart';
import 'package:smartspoon/features/auth/presentation/screens/login_screen.dart';
import 'package:smartspoon/features/auth/application/user_provider.dart';
import 'package:smartspoon/features/home/presentation/screens/home_page.dart';
import 'package:smartspoon/ble/spoon_runtime.dart';

class AuthGate extends StatefulWidget {
  const AuthGate({super.key});

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> with TickerProviderStateMixin {
  late final AnimationController _pulseController;
  late final AnimationController _orbitController;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    )..repeat(reverse: true);
    _orbitController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    )..repeat();
    WidgetsBinding.instance.addPostFrameCallback((_) => _bootstrap());
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _orbitController.dispose();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    Widget next = const LoginScreen();
    final minimumLoading = Future<void>.delayed(
      const Duration(milliseconds: 950),
    );

    try {
      final fbService = FirebaseAuthService();
      final fbUser = await fbService.authStateChanges.first.timeout(
        const Duration(seconds: 5),
        onTimeout: () => null,
      );

      if (fbUser != null) {
        if (!fbUser.emailVerified) {
          await AuthService.clearLocalTokens();
          await fbService.signOut();
          throw AuthException('Email verification is required');
        }

        Map<String, dynamic>? userMap = {
          'email': fbUser.email,
          'name': fbUser.displayName,
          'avatar_url': fbUser.photoURL,
        };

        try {
          userMap = await _loadBackendUserForFirebase(fbUser);
        } catch (_) {
          // Firebase is still a valid local session for offline BLE use.
          // Never retain an unproven backend JWT across a Firebase account switch.
          // SyncService will re-exchange tokens when the network returns.
          await AuthService.clearLocalTokens();
          userMap = {
            'email': fbUser.email,
            'name': fbUser.displayName,
            'avatar_url': fbUser.photoURL,
            'firebase_uid': fbUser.uid,
          };
        }

        if (mounted && userMap != null) {
          context.read<UserProvider>().setFromMap(userMap);
        }
        await SpoonRuntime().bindOwner(fbUser.uid);
        next = const HomePage();
      }
    } catch (_) {
      next = const LoginScreen();
    }

    await minimumLoading;
    if (!mounted) return;
    Navigator.of(
      context,
    ).pushReplacement(MaterialPageRoute(builder: (_) => next));
  }

  Future<Map<String, dynamic>?> _loadBackendUserForFirebase(User fbUser) async {
    final storedToken = await AuthService.getToken();
    if (storedToken == null) {
      await _exchangeFirebaseToken(fbUser, forceRefresh: false);
    }

    var userMap = await _fetchBackendUser();
    if (_matchesFirebaseUser(userMap, fbUser.uid)) {
      return userMap;
    }

    await AuthService.clearLocalTokens();
    await _exchangeFirebaseToken(fbUser, forceRefresh: true);
    userMap = await _fetchBackendUser();
    if (!_matchesFirebaseUser(userMap, fbUser.uid)) {
      await AuthService.clearLocalTokens();
      throw AuthException('Backend session does not match Firebase user');
    }
    return userMap;
  }

  Future<void> _exchangeFirebaseToken(
    User fbUser, {
    required bool forceRefresh,
  }) async {
    final idToken = await fbUser.getIdToken(forceRefresh);
    if (idToken == null) {
      throw AuthException('Firebase ID token unavailable');
    }
    await AuthService.verifyFirebaseToken(
      idToken: idToken,
    ).timeout(const Duration(seconds: 8));
  }

  Future<Map<String, dynamic>> _fetchBackendUser() async {
    final me = await AuthService.getMe().timeout(const Duration(seconds: 6));
    return me['user'] as Map<String, dynamic>? ?? me;
  }

  bool _matchesFirebaseUser(Map<String, dynamic>? userMap, String firebaseUid) {
    final backendFirebaseUid = userMap?['firebase_uid'] as String?;
    return backendFirebaseUid != null && backendFirebaseUid == firebaseUid;
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: isDark ? AppTheme.darkBg : AppTheme.bgTop,
      body: DecoratedBox(
        decoration: BoxDecoration(
          gradient: isDark
              ? AppTheme.darkBackgroundGradient
              : AppTheme.backgroundGradient,
        ),
        child: SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  AnimatedBuilder(
                    animation: Listenable.merge([
                      _pulseController,
                      _orbitController,
                    ]),
                    builder: (context, child) {
                      final pulse = Curves.easeInOut.transform(
                        _pulseController.value,
                      );

                      return SizedBox(
                        width: 188,
                        height: 188,
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            Transform.scale(
                              scale: 0.92 + (pulse * 0.05),
                              child: Container(
                                width: 162,
                                height: 162,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  gradient: RadialGradient(
                                    colors: [
                                      AppTheme.primary.withValues(
                                        alpha: isDark ? 0.34 : 0.18,
                                      ),
                                      AppTheme.tertiary.withValues(
                                        alpha: isDark ? 0.16 : 0.10,
                                      ),
                                      Colors.transparent,
                                    ],
                                  ),
                                ),
                              ),
                            ),
                            Transform.rotate(
                              angle: _orbitController.value * 6.28318530718,
                              child: CustomPaint(
                                size: const Size.square(178),
                                painter: _LoadingRingPainter(
                                  isDark: isDark,
                                  progress: _orbitController.value,
                                ),
                              ),
                            ),
                            Container(
                              width: 118,
                              height: 118,
                              padding: const EdgeInsets.all(20),
                              decoration: BoxDecoration(
                                color: isDark
                                    ? AppTheme.darkSurface.withValues(
                                        alpha: 0.90,
                                      )
                                    : Colors.white.withValues(alpha: 0.92),
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: isDark
                                      ? Colors.white.withValues(alpha: 0.10)
                                      : Colors.white,
                                  width: 1.2,
                                ),
                                boxShadow: [
                                  BoxShadow(
                                    color: AppTheme.primary.withValues(
                                      alpha: isDark ? 0.28 : 0.18,
                                    ),
                                    blurRadius: 32,
                                    offset: const Offset(0, 18),
                                  ),
                                ],
                              ),
                              child: child,
                            ),
                          ],
                        ),
                      );
                    },
                    child: ClipOval(
                      child: Image.asset(
                        'assets/images/app_logo.png',
                        fit: BoxFit.contain,
                      ),
                    ),
                  ),
                  const SizedBox(height: 28),
                  Text(
                    'Preparing i-Spoon',
                    textAlign: TextAlign.center,
                    style: AppTheme.serif(
                      fontSize: 26,
                      fontWeight: FontWeight.w700,
                      color: isDark ? AppTheme.darkText : AppTheme.textPrimary,
                      height: 1.05,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    'Syncing your session securely',
                    textAlign: TextAlign.center,
                    style: AppTheme.sans(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: isDark
                          ? AppTheme.darkSubText
                          : AppTheme.textSecondary,
                      height: 1.35,
                    ),
                  ),
                  const SizedBox(height: 30),
                  _LoadingTrack(animation: _orbitController, isDark: isDark),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _LoadingTrack extends StatelessWidget {
  final Animation<double> animation;
  final bool isDark;

  const _LoadingTrack({required this.animation, required this.isDark});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 168,
      height: 4,
      child: AnimatedBuilder(
        animation: animation,
        builder: (context, _) {
          return CustomPaint(
            painter: _LoadingTrackPainter(
              progress: animation.value,
              isDark: isDark,
            ),
          );
        },
      ),
    );
  }
}

class _LoadingRingPainter extends CustomPainter {
  final bool isDark;
  final double progress;

  const _LoadingRingPainter({required this.isDark, required this.progress});

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.width / 2 - 7;
    final base = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4
      ..color = isDark
          ? Colors.white.withValues(alpha: 0.10)
          : AppTheme.primary.withValues(alpha: 0.12);

    canvas.drawCircle(center, radius, base);

    final sweep = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 4
      ..shader = SweepGradient(
        startAngle: 0,
        endAngle: 6.28318530718,
        colors: const [
          AppTheme.primary,
          AppTheme.tertiary,
          AppTheme.secondary,
          AppTheme.primary,
        ],
        stops: const [0.0, 0.36, 0.72, 1.0],
        transform: GradientRotation(progress * 6.28318530718),
      ).createShader(Offset.zero & size);

    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      -1.57079632679,
      1.45,
      false,
      sweep,
    );
  }

  @override
  bool shouldRepaint(covariant _LoadingRingPainter oldDelegate) {
    return oldDelegate.progress != progress || oldDelegate.isDark != isDark;
  }
}

class _LoadingTrackPainter extends CustomPainter {
  final double progress;
  final bool isDark;

  const _LoadingTrackPainter({required this.progress, required this.isDark});

  @override
  void paint(Canvas canvas, Size size) {
    final radius = Radius.circular(size.height / 2);
    final trackRect = Offset.zero & size;
    final trackPaint = Paint()
      ..color = isDark
          ? Colors.white.withValues(alpha: 0.11)
          : AppTheme.textPrimary.withValues(alpha: 0.08);

    canvas.drawRRect(RRect.fromRectAndRadius(trackRect, radius), trackPaint);

    const segmentWidthFactor = 0.38;
    final segmentWidth = size.width * segmentWidthFactor;
    final left = (size.width + segmentWidth) * progress - segmentWidth;
    final segmentRect = Rect.fromLTWH(left, 0, segmentWidth, size.height);

    final segmentPaint = Paint()
      ..shader = const LinearGradient(
        colors: [AppTheme.primary, AppTheme.tertiary],
      ).createShader(trackRect);

    canvas.save();
    canvas.clipRRect(RRect.fromRectAndRadius(trackRect, radius));
    canvas.drawRRect(
      RRect.fromRectAndRadius(segmentRect, radius),
      segmentPaint,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _LoadingTrackPainter oldDelegate) {
    return oldDelegate.progress != progress || oldDelegate.isDark != isDark;
  }
}
