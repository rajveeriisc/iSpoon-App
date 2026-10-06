// heater_status_timeout_test.dart — the deterministic heater-timeout
// downgrade added to McuBleService._refreshHeaterStatusFromTelemetry.
//
// Production TX carries no rail-feedback packet, so HeaterStatus.railOn was
// previously a raw echo of the last command sent — never corrected even
// after firmware's own safety thread force-shuts the heater off on its
// runtime cap (HEATER_NO_TARGET_MAX_MS=5min / HEATER_TARGET_MAX_MS=10min in
// main.c). heater_control_page.dart's timeout warning banner existed but was
// unreachable dead code, since HeaterStatus.timeout was hardcoded false.
//
// Mirrored here as a pure function of (commandedOn, setpoint, commandedAt,
// now) — the private method itself lives on McuBleService, which pulls in
// live BLE plugin channels this suite doesn't mock.
import 'package:flutter_test/flutter_test.dart';

const heaterNoTargetMaxRuntime = Duration(minutes: 5);
const heaterTargetMaxRuntime = Duration(minutes: 10);

({bool railOn, bool timeout}) resolveHeaterState({
  required bool commandedOn,
  required int setpoint,
  required DateTime? commandedAt,
  required DateTime now,
}) {
  var on = commandedOn;
  var timedOut = false;
  if (commandedOn && commandedAt != null) {
    final maxRuntime =
        setpoint > 0 ? heaterTargetMaxRuntime : heaterNoTargetMaxRuntime;
    if (now.difference(commandedAt) >= maxRuntime) {
      timedOut = true;
      on = false;
    }
  }
  return (railOn: on, timeout: timedOut);
}

void main() {
  final t0 = DateTime(2026, 8, 21, 12, 0, 0);

  group('heater timeout — no target (5 min cap)', () {
    test('still on well within the cap', () {
      final r = resolveHeaterState(
        commandedOn: true,
        setpoint: 0,
        commandedAt: t0,
        now: t0.add(const Duration(minutes: 2)),
      );
      expect(r.railOn, isTrue);
      expect(r.timeout, isFalse);
    });

    test(
      'THE REGRESSION: past the 5-minute cap, no longer claims on',
      () {
        final r = resolveHeaterState(
          commandedOn: true,
          setpoint: 0,
          commandedAt: t0,
          now: t0.add(const Duration(minutes: 6)),
        );
        expect(
          r.railOn,
          isFalse,
          reason: 'firmware will have force-shut this off by now — the app '
              'must not keep showing "Active"',
        );
        expect(r.timeout, isTrue);
      },
    );

    test('exactly at the boundary counts as timed out', () {
      final r = resolveHeaterState(
        commandedOn: true,
        setpoint: 0,
        commandedAt: t0,
        now: t0.add(heaterNoTargetMaxRuntime),
      );
      expect(r.timeout, isTrue);
    });
  });

  group('heater timeout — with target (10 min cap)', () {
    test('still on at 6 minutes with a setpoint (would be timed out without one)', () {
      final r = resolveHeaterState(
        commandedOn: true,
        setpoint: 45,
        commandedAt: t0,
        now: t0.add(const Duration(minutes: 6)),
      );
      expect(
        r.railOn,
        isTrue,
        reason: 'a setpoint gets the longer 10-minute cap, not the 5-minute one',
      );
      expect(r.timeout, isFalse);
    });

    test('times out past 10 minutes with a setpoint', () {
      final r = resolveHeaterState(
        commandedOn: true,
        setpoint: 45,
        commandedAt: t0,
        now: t0.add(const Duration(minutes: 11)),
      );
      expect(r.railOn, isFalse);
      expect(r.timeout, isTrue);
    });
  });

  group('heater timeout — not applicable', () {
    test('already off never reports timeout', () {
      final r = resolveHeaterState(
        commandedOn: false,
        setpoint: 0,
        commandedAt: t0,
        now: t0.add(const Duration(hours: 1)),
      );
      expect(r.railOn, isFalse);
      expect(r.timeout, isFalse);
    });

    test('no commandedAt (never tracked) does not spuriously time out', () {
      final r = resolveHeaterState(
        commandedOn: true,
        setpoint: 0,
        commandedAt: null,
        now: t0,
      );
      expect(r.railOn, isTrue);
      expect(r.timeout, isFalse);
    });
  });
}
