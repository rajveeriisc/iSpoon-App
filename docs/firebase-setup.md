# Firebase — what is configured, and what only the console can do

## Project

| | |
|---|---|
| Project | `i-spoon-auth` (number `129116938699`) |
| Products in use | Auth, Cloud Messaging |
| Not used | Firestore, Storage, Functions, Hosting |

`firestore.rules` / `storage.rules` are therefore absent on purpose — there is
no Firestore or Storage surface to protect.

## Config files — all three are tracked, deliberately

`lib/firebase_options.dart`, `android/app/google-services.json` and
`ios/Runner/GoogleService-Info.plist` carry **identical** values (verified
field by field). They are public client identifiers, not credentials:

> Google: *"API keys restricted to Firebase services do not need to be treated
> as secrets, and it's safe to include them in your code or configuration
> files."*

They are also recoverable from any release APK — the Android `apiKey` was
pulled out of `lib/arm64-v8a/libapp.so` with a one-line regex. Moving them to
`.env` or a `dart-define` protects nothing, because a dart-define is compiled
into that same binary.

Previously `firebase_options.dart` was tracked while the other two were
ignored, which hid nothing and broke fresh clones: the Google Services Gradle
plugin fails without `google-services.json`, so Android could not be built from
a clean checkout.

**The real secret is the service-account private key.** It lives in
`ispoon-backend/.env` and is gitignored.

## App Check — client is wired, enforcement is yours to switch on

`firebase_app_check` is activated in `lib/main.dart`:

- release: Play Integrity (Android), Device Check (iOS)
- debug: the debug provider, which prints a token to logcat

**It is deliberately non-fatal.** Until App Check is enabled per-app in the
console, attestation fails, and a failure must never stop the app starting.

This is the documented rollout order, and it matters:

1. **Ship the client first** (done). Attempts start appearing in the console.
2. **Watch the metrics** — Firebase Console → App Check. Confirm real traffic is
   attesting successfully before going further.
3. **Only then enforce.** Enforcing while real users are on a build without
   App Check locks them out of Auth.

### Console steps (the CLI cannot do these)

The CLI exposes only `firebase appcheck:debugtokens`. Registering providers and
turning on enforcement are console-only:

1. Console → **App Check** → Apps → the Android app → **Play Integrity** → Register
2. Same for the iOS app → **Device Check** (or App Attest)
3. For an emulator or debug build: run the app, copy the debug token from
   logcat, then **App Check → Manage debug tokens → Add**
4. After metrics look healthy: **Enforce** on Authentication

## API key restrictions (console-only)

GCP Console → APIs & Services → Credentials → the Android/iOS keys →
**Application restrictions**. Lock each key to its app (package name +
SHA-1 for Android, bundle id for iOS). This is what stops the public apiKey
being reused elsewhere, and it is independent of App Check.

## Android signing — why Google Sign-In broke

Google Sign-In failed with `ApiException: 10 (DEVELOPER_ERROR)` because the
certificate signing our builds was not registered.

There is **no release keystore configured** (no `android/key.properties`, no
`ANDROID_RELEASE_*` env vars), so `flutter build apk --release` falls back to
the local **debug** key. Registered SHA-1s are now:

```
e2f4ad4dea38e3a99797fc946eb8512f3eb7e0bd
c06351a326a68f36583b8536419082e30d1a6906
8a9d96561cff35dc0011a72295f40424af5e050d   <- this machine's debug key
```

To read the cert of an APK without a JRE (keytool/apksigner need Java, which is
not installed here): the APKs are signed v2/v3 only, so parse the APK Signing
Block — find `APK Sig Block 42`, walk the id-value pairs, take id `0x7109871a`
(v2) or `0xf05368c0` (v3), then signers → signer → signed_data → certs, and
SHA-1 the DER certificate.

Add a fingerprint with:

```
firebase apps:android:sha:create <appId> <sha1>
firebase apps:sdkconfig android <appId> --out android/app/google-services.json
```

## Before production

These are blockers, not polish:

- **`com.example.smartspoon`** — Google Play rejects any `com.example.*` id.
- **iOS bundle id is `ispoon`** — Apple requires reverse-DNS; its own test
  target is already `com.example.smartspoon.RunnerTests`, so the project is
  internally inconsistent.
- **No release keystore.** Builds are debug-signed.

Changing the package id forces re-registering the Firebase apps and re-adding
every SHA-1, so do it **once**, before investing further in signing config.
