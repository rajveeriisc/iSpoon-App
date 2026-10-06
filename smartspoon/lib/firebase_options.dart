// firebase_options.dart -- generated Firebase CLIENT configuration.
//
// Do NOT move these into .env or a dart-define. It would not protect them.
// `String.fromEnvironment` is baked into the binary at compile time, and the
// values are already recoverable from a release build: the Android apiKey was
// pulled out of lib/arm64-v8a/libapp.so with a one-line regex.
//
// They are also not credentials. apiKey / appId / messagingSenderId /
// projectId / storageBucket are public client identifiers; an apiKey grants no
// authority on its own and cannot read data or impersonate a user. What
// actually protects the project is API key restrictions (GCP console), Firebase
// App Check, and server-side authorization. The genuine secret is the Firebase
// SERVICE ACCOUNT private key, which lives in ispoon-backend/.env.
//
// NOTE ON GIT: this file is TRACKED, while android/app/google-services.json and
// ios/Runner/GoogleService-Info.plist are gitignored -- even though all three
// carry the same values (verified field-by-field). So the "keep keys out of the
// public repo" rule is already defeated by this file, while still breaking a
// fresh clone's Android build. That inconsistency needs a decision; it has not
// been made here.
import 'package:firebase_core/firebase_core.dart' show FirebaseOptions;
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;

class DefaultFirebaseOptions {
  static FirebaseOptions get currentPlatform {
    if (kIsWeb) {
      throw UnsupportedError(
        'Firebase is configured only for the Android and iOS SmartSpoon apps.',
      );
    }
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return android;
      case TargetPlatform.iOS:
        return ios;
      case TargetPlatform.macOS:
      case TargetPlatform.windows:
      case TargetPlatform.linux:
        throw UnsupportedError(
          'Firebase is configured only for the Android and iOS SmartSpoon apps.',
        );
      default:
        throw UnsupportedError(
          'DefaultFirebaseOptions are not supported for this platform.',
        );
    }
  }

  static const FirebaseOptions android = FirebaseOptions(
    apiKey: 'AIzaSyCIWOCzZd82_Mf0zWGVpjN8CzGc5FYFMmY',
    appId: '1:129116938699:android:efe45e648dda46c74e564e',
    messagingSenderId: '129116938699',
    projectId: 'i-spoon-auth',
    storageBucket: 'i-spoon-auth.firebasestorage.app',
  );

  static const FirebaseOptions ios = FirebaseOptions(
    apiKey: 'AIzaSyD-HMf9KZuO1aowSFZGS1uD1rfdSbfJTPE',
    appId: '1:129116938699:ios:e4473d913c0cd9624e564e',
    messagingSenderId: '129116938699',
    projectId: 'i-spoon-auth',
    storageBucket: 'i-spoon-auth.firebasestorage.app',
    iosBundleId: 'ispoon',
  );
}
