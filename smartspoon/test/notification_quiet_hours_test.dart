// notification_quiet_hours_test.dart — the quiet-hours window check added to
// NotificationService's notification-suppression gate.
//
// Mirrored here (private instance methods on NotificationService, which also
// pulls in Firebase/platform channels this suite doesn't mock) as a pure
// function of (start, end, now) rather than "now" — overnight wraparound
// (22:00–07:00) is exactly the kind of thing that looks right for the
// same-day case and silently inverts for the wraparound case, so it gets its
// own regression coverage.
import 'package:flutter_test/flutter_test.dart';

int? parseMinutesOfDay(String hhmm) {
  final parts = hhmm.split(':');
  if (parts.length != 2) return null;
  final h = int.tryParse(parts[0]);
  final m = int.tryParse(parts[1]);
  if (h == null || m == null) return null;
  return h * 60 + m;
}

bool isWithinQuietHours(String start, String end, DateTime now) {
  final s = parseMinutesOfDay(start);
  final e = parseMinutesOfDay(end);
  if (s == null || e == null || s == e) return false;

  final nowMin = now.hour * 60 + now.minute;
  if (s < e) return nowMin >= s && nowMin < e;
  return nowMin >= s || nowMin < e; // overnight wraparound
}

DateTime at(int hour, [int minute = 0]) =>
    DateTime(2026, 8, 20, hour, minute);

void main() {
  group('quiet hours — overnight window (22:00–07:00)', () {
    test('inside the window, late night', () {
      expect(isWithinQuietHours('22:00', '07:00', at(23)), isTrue);
    });

    test('inside the window, after midnight', () {
      expect(isWithinQuietHours('22:00', '07:00', at(3)), isTrue);
    });

    test(
      'THE REGRESSION: right at the start boundary counts as inside',
      () {
        expect(isWithinQuietHours('22:00', '07:00', at(22, 0)), isTrue);
      },
    );

    test('right at the end boundary counts as OUTSIDE (exclusive)', () {
      expect(isWithinQuietHours('22:00', '07:00', at(7, 0)), isFalse);
    });

    test('clearly daytime — outside the window', () {
      expect(isWithinQuietHours('22:00', '07:00', at(14)), isFalse);
    });

    test('one minute before start — still outside', () {
      expect(isWithinQuietHours('22:00', '07:00', at(21, 59)), isFalse);
    });
  });

  group('quiet hours — same-day window (e.g. 13:00–14:00)', () {
    test('inside a same-day window does NOT use overnight logic', () {
      // THE REGRESSION this guards: if the wraparound branch were used for a
      // same-day window by mistake, this would incorrectly read as "outside"
      // for the one hour it's meant to cover, and "inside" for the other 23.
      expect(isWithinQuietHours('13:00', '14:00', at(13, 30)), isTrue);
    });

    test('outside a same-day window', () {
      expect(isWithinQuietHours('13:00', '14:00', at(15)), isFalse);
      expect(isWithinQuietHours('13:00', '14:00', at(2)), isFalse);
    });
  });

  group('quiet hours — disabled / malformed', () {
    test('zero-length window (start == end) reads as disabled, not "always"', () {
      expect(isWithinQuietHours('22:00', '22:00', at(23)), isFalse);
      expect(isWithinQuietHours('22:00', '22:00', at(3)), isFalse);
    });

    test('malformed time strings read as disabled rather than throwing', () {
      expect(isWithinQuietHours('garbage', '07:00', at(23)), isFalse);
      expect(isWithinQuietHours('22:00', '', at(23)), isFalse);
    });
  });
}
