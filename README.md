# iSpoon

A connected spoon that counts bites and tracks hand steadiness while you eat,
with a Flutter app, a Node backend and a marketing site.

iSpoon is a **wellness and self-tracking product. It is not a medical device.**
It does not diagnose, treat or prevent anything, and its measurements are not a
clinical assessment. Several parts of this repository exist specifically to
keep that line honest — see [Accuracy and honesty](#accuracy-and-honesty).

## What is in here

| Path | What it is |
|---|---|
| `smartspoon/` | The Flutter app (Android + iOS). Bite detection, steadiness analysis, BLE, local SQLite, cloud sync. |
| `ispoon-backend/` | Node 22 + Express API. Firebase ID-token verification, own JWTs, Neon Postgres, migrations. |
| `smartspoon-website/` | Next.js 16 marketing site. |
| `tools/` | Python for training the bite model (`train_bite_model.py`) and the AI Lab dataset tooling. |
| `docs/` | Design specs and plans, plus firmware reference copies under `docs/firmware_ref/`. |

**The firmware is not in this repository.** It lives in two PlatformIO
projects outside it, one per SKU:

- `spoon-firmware` — the heater model ("iSpoon Pro")
- `spoon-firmware-no-heater` — the standard model

Both are Zephyr / nRF Connect SDK on an nRF52840, built with sysbuild and
MCUboot. The app tells the two apart from a capability bit the spoon reports,
so there is no build-time switch on the app side.

## Getting it running

### Backend

```bash
cd ispoon-backend
cp env.example .env     # then fill it in — every REQUIRED key must be set
npm ci
npm run migrate         # migrations are NOT run automatically on boot
npm start
```

Node 22 or newer. The server refuses to start if the security configuration is
incomplete — that is deliberate, not a bug. In particular `HMAC_SECRET` is
required in production and the server will not accept the old development
value.

### App

```bash
cd smartspoon
flutter pub get
flutter run --dart-define=API_BASE_URL=http://127.0.0.1:5001
```

On a physical Android device over USB, `adb reverse tcp:5001 tcp:5001` makes
loopback work. A physical iPhone cannot reach your Mac's loopback, so pass your
LAN address instead.

### Website

```bash
cd smartspoon-website
npm ci && npm run dev
```

## Release builds

```bash
cd smartspoon
TARGETS=apk \
API_BASE_URL=https://your-api.example.com \
HMAC_SECRET=<the same value the server has> \
  ./scripts/build_release.sh
```

Both variables are **required** and the script refuses to build without them.
That guard exists because `AppConfig.baseUrl` falls back to
`http://127.0.0.1:5001`, so a release built without `API_BASE_URL` silently
ships an app that tries to reach a backend on the handset itself and fails
every sign-in.

`HMAC_SECRET` must match the server's. Rotating it needs a coordinated release,
or installed apps start getting 401s on signed routes.

`TARGETS` selects what to build — `apk`, `appbundle`, `ipa`, or a comma-joined
subset. It defaults to all three.

Keep `build/debug-info/`. Release builds are obfuscated and crash reports will
not symbolicate without it.

## Tests

```bash
cd smartspoon      && flutter test   # 361 pass, 1 known failure
cd ispoon-backend  && npm test       # 49 pass
```

The one failing Flutter test is `screens_render_test.dart` — a `flutter_animate`
timer still pending when the widget tree is torn down. It is a leak in the
test, not a crash on a device.

CI runs the backend only (`.github/workflows/backend-ci.yml`). There is no
Flutter or website CI yet.

## Accuracy and honesty

This product measures people, so several decisions here are about not
overclaiming. If you change them, change them deliberately.

- **Bite-cycle validation ships switched off.** `biteCycle.enforce` is `false`
  in `assets/models/ai_lab_model.json`. The phase machine computes and logs a
  verdict for every proposed bite, but every proposal still counts. It stays
  off until there are enough labelled meals to tune it — an untuned gate that
  silently undercounts someone's meals is worse than the false positives it
  replaces. See `docs/superpowers/specs/2026-10-02-bite-cycle-validation-design.md`.
- **Thresholds are measured, not chosen.** The personalised model's constants
  came from simulations that are kept as tests
  (`test/ai_lab/personalized_eating_model_test.dart`). The steadiness bands are
  derived from a single pair of constants so the screens cannot disagree with
  each other, and a test fails if anyone re-hardcodes either side.
- **The bite model has never been tested on people with a tremor.** It was
  trained on 160 labelled bites from 8 people. The app says so where it
  reports steadiness, and that wording should stay.
- **The site must not make clinical claims.** Unsourced efficacy figures,
  invented testimonials and "clinically validated" were removed; a medical
  disclaimer sits in the footer. Do not reintroduce them without evidence you
  can show.

## Known open items

Tracked here rather than in issues, so they are not lost:

- Daily rollups bucket by UTC rather than the local date, so meals near
  midnight can land on the wrong day.
- The Android application id is still `com.example.smartspoon` and the iOS
  bundle id is `ispoon`. Both block store submission, and changing them
  invalidates the registered Firebase SHA certificates — do it in one go.
- No release keystore is configured, so release builds are signed with the
  debug key.
- There is no data-export endpoint and no retention job.
- Logout revokes the refresh token; the access token stays valid for its
  remaining ~15 minutes.
- The website has no privacy policy, terms, or warranty pages — several footer
  links still point at `#`.

## Licence

No licence has been chosen yet. Until one is added, default copyright applies
and no permission to reuse this code is granted.
