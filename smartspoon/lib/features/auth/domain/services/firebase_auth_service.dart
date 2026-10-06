// firebase_auth_service.dart — thin wrapper over Firebase Auth + Google/Apple Sign-In.
//
// Owns all direct FirebaseAuth interaction: email/password sign-in and sign-up,
// Google sign-in, Apple sign-in, email verification, password reset/change,
// account deletion, and the authStateChanges stream. Sign-in enforces email
// verification (signs out and reports needsVerification if unverified) and
// returns a fresh Firebase ID token, which the caller then exchanges for a
// backend JWT via AuthService.
import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';

class FirebaseAuthService {
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final GoogleSignIn _googleSignIn = GoogleSignIn();

  // Get current user
  User? get currentUser => _auth.currentUser;

  // Stream of auth state changes
  Stream<User?> get authStateChanges => _auth.authStateChanges();

  /// Sign in with Email and Password (Firebase Auth)
  ///
  /// AUTH FLOW:
  /// 1. Called from login_screen.dart → _login()
  /// 2. Signs in with Firebase via _auth.signInWithEmailAndPassword
  /// 3. Reloads user to get latest verification status from Firebase
  /// 4. If NOT verified → signs out and returns { needsVerification: true }
  /// 5. If verified → gets fresh ID token via user.getIdToken(true)
  /// 6. Returns { success: true, user, token, emailVerified }
  ///
  /// NEXT STEP: login_screen.dart calls AuthService.verifyFirebaseToken()
  ///            to sync with backend and get backend JWT
  Future<Map<String, dynamic>> signInWithEmail({
    required String email,
    required String password,
  }) async {
    try {
      final credential = await _auth.signInWithEmailAndPassword(
        email: email,
        password: password,
      );

      final user = credential.user;
      if (user != null) {
        // ✅ Reload user to get latest verification status from Firebase servers
        await user.reload();
        final currentUser = _auth.currentUser;

        // Check if email is verified
        if (currentUser != null && !currentUser.emailVerified) {
          await _auth.signOut(); // Sign out unverified user
          return {
            'success': false,
            'message':
                'Please verify your email before logging in. Check your inbox.',
            'needsVerification': true,
          };
        }

        // ✅ Force refresh the ID token to get updated claims
        final idToken = await currentUser?.getIdToken(
          true,
        ); // true = force refresh

        return {
          'success': true,
          'user': {
            'uid': currentUser!.uid,
            'email': currentUser.email,
            'name': currentUser.displayName,
            'avatar_url': currentUser.photoURL,
          },
          'token': idToken!,
          'emailVerified': currentUser.emailVerified,
        };
      }
      throw Exception('User not found');
    } on FirebaseAuthException catch (e) {
      return {'success': false, 'message': _getErrorMessage(e.code)};
    } catch (e) {
      return {
        'success': false,
        'message': 'An error occurred. Please try again.',
      };
    }
  }

  /// Sign up with Email and Password (Firebase Auth)
  ///
  /// AUTH FLOW:
  /// 1. Called from signup_screen.dart → _handleSignUp()
  /// 2. Creates user in Firebase via _auth.createUserWithEmailAndPassword
  /// 3. Updates display name via user.updateDisplayName(name)
  /// 4. Sends verification email via user.sendEmailVerification()
  /// 5. Returns { success: true, user, token, emailVerified: false }
  ///
  /// NEXT STEP: signup_screen.dart shows success message and navigates to LoginScreen
  ///            User must verify email before they can log in
  Future<Map<String, dynamic>> signUpWithEmail({
    required String email,
    required String password,
    required String name,
  }) async {
    try {
      final credential = await _auth.createUserWithEmailAndPassword(
        email: email,
        password: password,
      );

      final user = credential.user;
      if (user != null) {
        // Update display name
        await user.updateDisplayName(name);

        // ✨ SEND VERIFICATION EMAIL (This was missing!)
        if (!user.emailVerified) {
          await user.sendEmailVerification();
          debugPrint('✅ Verification email sent to: $email');
        }

        // Return user data (backend will require verification before issuing JWT)
        return {
          'success': true,
          'user': {
            'uid': user.uid,
            'email': email,
            'name': name,
            'avatar_url': null,
          },
          'token': await user.getIdToken(),
          'emailVerified': user.emailVerified,
        };
      }
      throw Exception('User creation failed');
    } on FirebaseAuthException catch (e) {
      return {'success': false, 'message': _getErrorMessage(e.code)};
    } catch (e) {
      return {
        'success': false,
        'message': 'An error occurred. Please try again.',
      };
    }
  }

  /// Sign in with Google (OAuth)
  ///
  /// AUTH FLOW:
  /// 1. Called from login_screen.dart → _signInWithGoogle()
  /// 2. Opens Google Sign-In dialog via _googleSignIn.signIn()
  /// 3. Gets Google auth credentials (accessToken, idToken)
  /// 4. Signs into Firebase via _auth.signInWithCredential()
  /// 5. Returns { success: true, user, token, firebase_token }
  ///
  /// NEXT STEP: login_screen.dart calls AuthService.verifyFirebaseToken()
  ///            to sync with backend and get backend JWT
  ///            (Google users are auto-verified, no email verification needed)
  Future<Map<String, dynamic>> signInWithGoogle() async {
    try {
      UserCredential userCredential;
      if (kIsWeb) {
        // On web prefer popup-based auth to avoid redirects and blocked popups
        final provider = GoogleAuthProvider();
        userCredential = await _auth.signInWithPopup(provider);
      } else {
        // Trigger the authentication flow on mobile/desktop
        final GoogleSignInAccount? googleUser = await _googleSignIn.signIn();
        if (googleUser == null) {
          return {'success': false, 'message': 'Google sign-in cancelled'};
        }
        // Obtain the auth details from the request
        final GoogleSignInAuthentication googleAuth =
            await googleUser.authentication;
        // Create a new credential
        final credential = GoogleAuthProvider.credential(
          accessToken: googleAuth.accessToken,
          idToken: googleAuth.idToken,
        );
        // Sign in to Firebase with the Google credential
        userCredential = await _auth.signInWithCredential(credential);
      }
      final user = userCredential.user;

      if (user != null) {
        final idToken = await user.getIdToken();
        // Return user data from Firebase Auth (no Firestore needed)
        return {
          'success': true,
          'user': {
            'uid': user.uid,
            'email': user.email,
            'name': user.displayName,
            'avatar_url': user.photoURL,
            'auth_provider': 'google',
          },
          'token': idToken,
          'firebase_token': idToken, // For backend verification
        };
      }
      throw Exception('Google sign-in failed');
    } catch (e) {
      return {
        'success': false,
        'message': 'Google sign-in failed: ${e.toString()}',
      };
    }
  }

  /// Cryptographically random nonce for the Apple Sign-In flow. Firebase's
  /// OAuthCredential carries the RAW nonce; Apple's request carries only its
  /// SHA-256 hash. Firebase verifies the raw value against the ID token's
  /// embedded hash server-side, which is what stops a captured Apple identity
  /// token from being replayed against a Firebase sign-in it wasn't issued
  /// for. Required by the sign_in_with_apple package's own security guidance,
  /// not optional hardening.
  String _generateNonce([int length = 32]) {
    const charset =
        '0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._';
    final random = Random.secure();
    return List.generate(
      length,
      (_) => charset[random.nextInt(charset.length)],
    ).join();
  }

  String _sha256(String input) =>
      sha256.convert(utf8.encode(input)).toString();

  /// Sign in with Apple (Sign in with Apple / OAuth via Firebase).
  ///
  /// Required by App Store Review Guideline 4.8: an app offering third-party
  /// login (Google, above) must also offer Sign in with Apple. iOS only —
  /// AppleIDAuthorizationAppleIDButton and the native credential flow don't
  /// apply on Android/web.
  ///
  /// AUTH FLOW:
  /// 1. Called from login_screen.dart → _signInWithApple()
  /// 2. Requests an Apple ID credential (native Apple UI) with a hashed nonce
  /// 3. Wraps it in a Firebase OAuthProvider('apple.com') credential with the
  ///    matching RAW nonce and signs into Firebase via signInWithCredential
  /// 4. Apple only ever returns givenName/familyName on the FIRST authorization
  ///    for this app — persist it to the Firebase profile immediately, since
  ///    it will be withheld (null) on every subsequent sign-in from the same
  ///    Apple ID, even after a fresh app install.
  /// 5. Returns { success: true, user, token } — same shape as signInWithGoogle
  ///
  /// NEXT STEP: login_screen.dart calls AuthService.verifyFirebaseToken()
  ///            to sync with backend and get backend JWT
  ///            (Apple users are auto-verified, no email verification needed)
  Future<Map<String, dynamic>> signInWithApple() async {
    try {
      final rawNonce = _generateNonce();
      final hashedNonce = _sha256(rawNonce);

      final appleCredential = await SignInWithApple.getAppleIDCredential(
        scopes: [
          AppleIDAuthorizationScopes.email,
          AppleIDAuthorizationScopes.fullName,
        ],
        nonce: hashedNonce,
      );

      final oauthCredential = OAuthProvider('apple.com').credential(
        idToken: appleCredential.identityToken,
        rawNonce: rawNonce,
        accessToken: appleCredential.authorizationCode,
      );

      final userCredential = await _auth.signInWithCredential(
        oauthCredential,
      );
      final user = userCredential.user;
      if (user == null) {
        throw Exception('Apple sign-in failed');
      }

      // First-authorization-only name — Firebase never learns it on its own
      // for the 'apple.com' provider, so set it explicitly while we have it.
      final givenName = appleCredential.givenName;
      final familyName = appleCredential.familyName;
      if ((user.displayName == null || user.displayName!.isEmpty) &&
          (givenName != null || familyName != null)) {
        final fullName = [
          givenName,
          familyName,
        ].where((n) => n != null && n.isNotEmpty).join(' ');
        if (fullName.isNotEmpty) {
          await user.updateDisplayName(fullName);
          await user.reload();
        }
      }

      final freshUser = _auth.currentUser ?? user;
      final idToken = await freshUser.getIdToken();

      return {
        'success': true,
        'user': {
          'uid': freshUser.uid,
          'email': freshUser.email,
          'name': freshUser.displayName,
          'avatar_url': freshUser.photoURL,
          'auth_provider': 'apple',
        },
        'token': idToken,
        'firebase_token': idToken,
      };
    } on SignInWithAppleAuthorizationException catch (e) {
      if (e.code == AuthorizationErrorCode.canceled) {
        return {'success': false, 'message': 'Apple sign-in cancelled'};
      }
      return {
        'success': false,
        'message': 'Apple sign-in failed: ${e.message}',
      };
    } catch (e) {
      return {
        'success': false,
        'message': 'Apple sign-in failed: ${e.toString()}',
      };
    }
  }

  // Sign out
  Future<void> signOut() async {
    await Future.wait([_auth.signOut(), _googleSignIn.signOut()]);
  }

  /// Whether the current Firebase user signed up with email/password.
  ///
  /// A user authenticated purely via Google (or another OAuth provider) has no
  /// password to change, so "Change Password" should only be offered when this
  /// returns true. We check `providerData` on the live Firebase user rather
  /// than trusting a possibly-stale `auth_provider` column in our own DB,
  /// since a user can link multiple providers over time.
  bool get hasPasswordProvider {
    final user = _auth.currentUser;
    if (user == null) return false;
    return user.providerData.any((info) => info.providerId == 'password');
  }

  /// Re-authenticate immediately before permanent account deletion and return
  /// a fresh Firebase ID token carrying a recent `auth_time` claim. The backend
  /// binds this proof to the account's stored Firebase UID.
  Future<Map<String, dynamic>> reauthenticateForAccountDeletion({
    String? currentPassword,
  }) async {
    try {
      final user = _auth.currentUser;
      if (user == null) {
        return {
          'success': false,
          'message': 'Please log in again to continue.',
        };
      }

      final providerIds = user.providerData
          .map((provider) => provider.providerId)
          .toSet();

      if (providerIds.contains('password')) {
        final password = currentPassword ?? '';
        if (user.email == null || password.isEmpty) {
          return {
            'success': false,
            'message': 'Enter your current password to delete your account.',
          };
        }
        final credential = EmailAuthProvider.credential(
          email: user.email!,
          password: password,
        );
        await user.reauthenticateWithCredential(credential);
      } else if (providerIds.contains('google.com')) {
        if (kIsWeb) {
          await user.reauthenticateWithPopup(GoogleAuthProvider());
        } else {
          // Disconnect cached authorization first so deletion requires an
          // interactive account choice instead of silently reusing old state.
          try {
            await _googleSignIn.disconnect();
          } catch (_) {}
          final googleUser = await _googleSignIn.signIn();
          if (googleUser == null) {
            return {
              'success': false,
              'message': 'Re-authentication was cancelled.',
            };
          }
          final googleAuth = await googleUser.authentication;
          final credential = GoogleAuthProvider.credential(
            accessToken: googleAuth.accessToken,
            idToken: googleAuth.idToken,
          );
          await user.reauthenticateWithCredential(credential);
        }
      } else if (providerIds.contains('apple.com')) {
        // Without this branch an Apple-signed-in user hit the generic
        // "sign out and sign in again" message below on every attempt —
        // signing back in still leaves them on the apple.com provider, so
        // that message describes no action that ever gets them past this
        // point. Directly violates Guideline 5.1.1(v) (in-app account
        // deletion) for exactly the users Apple's OWN Guideline 4.8 required
        // this sign-in method for.
        final rawNonce = _generateNonce();
        final hashedNonce = _sha256(rawNonce);
        final appleCredential = await SignInWithApple.getAppleIDCredential(
          scopes: [AppleIDAuthorizationScopes.email],
          nonce: hashedNonce,
        );
        final credential = OAuthProvider('apple.com').credential(
          idToken: appleCredential.identityToken,
          rawNonce: rawNonce,
        );
        await user.reauthenticateWithCredential(credential);
      } else {
        return {
          'success': false,
          'message':
              'Please sign out, sign in again, and retry account deletion.',
        };
      }

      final idToken = await _auth.currentUser?.getIdToken(true);
      if (idToken == null || idToken.isEmpty) {
        return {'success': false, 'message': 'Could not verify your identity.'};
      }
      return {'success': true, 'idToken': idToken};
    } on FirebaseAuthException catch (e) {
      return {'success': false, 'message': _getErrorMessage(e.code)};
    } catch (_) {
      return {
        'success': false,
        'message': 'Could not verify your identity. Please try again.',
      };
    }
  }

  /// Change the current user's password (email/password accounts only).
  ///
  /// AUTH FLOW:
  /// 1. Re-authenticates with the current password — Firebase requires a
  ///    "recent login" before allowing sensitive operations like updatePassword.
  /// 2. Calls currentUser.updatePassword(newPassword).
  /// 3. Returns { success: true } or { success: false, message } with a
  ///    user-facing message (never a raw FirebaseAuthException string).
  ///
  /// CALLED BY: profile_page.dart "Change Password" action
  Future<Map<String, dynamic>> changePassword({
    required String currentPassword,
    required String newPassword,
  }) async {
    try {
      final user = _auth.currentUser;
      if (user == null || user.email == null) {
        return {'success': false, 'message': 'No user logged in'};
      }

      final credential = EmailAuthProvider.credential(
        email: user.email!,
        password: currentPassword,
      );

      // Required by Firebase before sensitive operations like updatePassword.
      await user.reauthenticateWithCredential(credential);
      await user.updatePassword(newPassword);

      return {'success': true, 'message': 'Your password has been updated.'};
    } on FirebaseAuthException catch (e) {
      return {'success': false, 'message': _getErrorMessage(e.code)};
    } catch (e) {
      return {
        'success': false,
        'message': 'Something went wrong. Please try again.',
      };
    }
  }

  // Send Firebase password reset email.
  Future<Map<String, dynamic>> resetPassword(String email) async {
    try {
      await _auth.sendPasswordResetEmail(email: email.trim());
      return {
        'success': true,
        'message': 'If an account exists, a reset email has been sent.',
      };
    } on FirebaseAuthException catch (e) {
      return {'success': false, 'message': _getErrorMessage(e.code)};
    } catch (e) {
      return {
        'success': false,
        'message': 'An error occurred. Please try again.',
      };
    }
  }

  /// Send Email Verification Link
  ///
  /// AUTH FLOW:
  /// 1. Called from login_screen.dart → _sendEmailVerificationLink()
  /// 2. Gets current Firebase user
  /// 3. Checks if already verified (returns error if yes)
  /// 4. Calls user.sendEmailVerification() - Firebase sends email directly
  /// 5. Returns { success: true, message }
  ///
  /// NEXT STEP: login_screen.dart shows success/error snackbar
  Future<Map<String, dynamic>> sendEmailVerificationLink() async {
    try {
      final user = _auth.currentUser;

      if (user == null) {
        return {'success': false, 'message': 'No user logged in'};
      }

      if (user.emailVerified) {
        return {'success': false, 'message': 'Email already verified'};
      }

      await user.sendEmailVerification();
      debugPrint('✅ Verification email sent to: ${user.email}');

      return {
        'success': true,
        'message': 'Verification email sent! Please check your inbox.',
      };
    } on FirebaseAuthException catch (e) {
      if (e.code == 'too-many-requests') {
        return {
          'success': false,
          'message':
              'Too many requests. Please wait a few minutes and try again.',
        };
      }
      return {'success': false, 'message': _getErrorMessage(e.code)};
    } catch (e) {
      return {
        'success': false,
        'message': 'Failed to send verification email. Please try again.',
      };
    }
  }

  // ✨ Check if current user email is verified (reload from Firebase)
  Future<bool> isEmailVerified() async {
    try {
      final user = _auth.currentUser;
      if (user == null) return false;

      await user.reload(); // Refresh user data from Firebase
      return _auth.currentUser?.emailVerified ?? false;
    } catch (e) {
      debugPrint('Error checking email verification: $e');
      return false;
    }
  }

  // Error message helper - comprehensive handling of all Firebase error codes
  String _getErrorMessage(String code) {
    switch (code) {
      // User not found / Account doesn't exist
      case 'user-not-found':
        return 'No account found with this email. Please sign up first.';

      // Wrong password / Invalid credentials
      case 'wrong-password':
        return 'Incorrect password. Please try again.';
      case 'invalid-credential':
        return 'Invalid email or password. Please check your credentials.';
      case 'invalid-login-credentials':
        return 'Invalid email or password. Please check your credentials.';

      // Email related errors
      case 'email-already-in-use':
        return 'This email is already registered. Try logging in instead.';
      case 'invalid-email':
        return 'Please enter a valid email address.';

      // Password errors
      case 'weak-password':
        return 'Password is too weak. Use at least 8 characters with uppercase, lowercase, number, and special character.';

      // Account status
      case 'user-disabled':
        return 'This account has been disabled. Please contact support.';
      case 'account-exists-with-different-credential':
        return 'An account already exists with this email using a different sign-in method.';

      // Rate limiting / Too many attempts
      case 'too-many-requests':
        return 'Too many failed attempts. Please wait a few minutes and try again.';

      // Network errors
      case 'network-request-failed':
        return 'Network error. Please check your internet connection.';

      // Session expired
      case 'requires-recent-login':
        return 'Please log in again to complete this action.';

      // Email verification
      case 'email-not-verified':
        return 'Please verify your email before logging in. Check your inbox.';

      // Operation errors
      case 'operation-not-allowed':
        return 'This sign-in method is not enabled. Please contact support.';
      case 'popup-closed-by-user':
        return 'Sign-in was cancelled. Please try again.';
      case 'cancelled-popup-request':
        return 'Sign-in popup was closed. Please try again.';

      // Token errors
      case 'expired-action-code':
        return 'This link has expired. Please request a new one.';
      case 'invalid-action-code':
        return 'This link is invalid. Please request a new one.';

      default:
        return 'Something went wrong. Please try again.';
    }
  }
}
