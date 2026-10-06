import 'package:flutter_test/flutter_test.dart';
import 'package:smartspoon/features/insights/domain/session_integrity.dart';

void main() {
  group('pinSessionDeviceId', () {
    test('never pins an empty string', () {
      expect(pinSessionDeviceId(null), isNull);
      expect(pinSessionDeviceId(''), isNull);
      expect(pinSessionDeviceId('   '), isNull);
    });

    test('keeps a real BLE id', () {
      expect(pinSessionDeviceId('AA:BB'), 'AA:BB');
    });
  });

  group('mealWriteUserId', () {
    test('uses the Firebase UID', () {
      expect(mealWriteUserId('abcXYZ123'), 'abcXYZ123');
    });

    test('never writes a numeric backend JWT id', () {
      expect(mealWriteUserId('2'), 'offline_user');
      expect(mealWriteUserId(null), 'offline_user');
      expect(mealWriteUserId(''), 'offline_user');
    });
  });

  group('TodayBiteBuckets.overlaySession', () {
    test('adds a second breakfast instead of replacing the snapshot', () {
      const snapshot = TodayBiteBuckets(
        breakfast: 20,
        lunch: 0,
        dinner: 0,
        snack: 0,
      );
      final live = snapshot.overlaySession(
        mealType: 'Breakfast',
        sessionBites: 1,
      );
      expect(live.breakfast, 21);
      expect(live.total, 21);
    });
  });

  group('shouldCountHardwareDelta', () {
    test('counts a monotonic catch-up burst instead of dropping it', () {
      expect(shouldCountHardwareDelta(12), isTrue);
      expect(shouldCountHardwareDelta(0), isFalse);
      expect(shouldCountHardwareDelta(-3), isFalse);
    });
  });
  group('decideBiteTick', () {
    test('waits until the model has actually seen sensor data', () {
      final d = decideBiteTick(total: null, anchor: 0, initialized: false);
      expect(d.action, BiteTickAction.waitForData);
    });

    test('first reading only baselines, it never counts', () {
      final d = decideBiteTick(total: 7, anchor: 0, initialized: false);
      expect(d.action, BiteTickAction.baseline);
      expect(d.anchor, 7);
      expect(d.newBites, 0);
    });

    test('an unchanged total does nothing', () {
      expect(decideBiteTick(total: 7, anchor: 7, initialized: true).action,
          BiteTickAction.ignore);
    });

    test('new bites are counted as the delta', () {
      final d = decideBiteTick(total: 9, anchor: 7, initialized: true);
      expect(d.action, BiteTickAction.count);
      expect(d.newBites, 2);
      expect(d.anchor, 9);
    });

    test('a catch-up burst is counted in full, not dropped', () {
      final d = decideBiteTick(total: 40, anchor: 7, initialized: true);
      expect(d.action, BiteTickAction.count);
      expect(d.newBites, 33);
    });

    test('a total that went backwards re-anchors instead of stalling forever',
        () {
      // App restarted: the model counts from zero again while the session
      // anchor still holds the old total. Counting must resume from here.
      final d = decideBiteTick(total: 0, anchor: 41, initialized: true);
      expect(d.action, BiteTickAction.rebaseline);
      expect(d.anchor, 0);
      expect(d.newBites, 0);
      final next = decideBiteTick(total: 1, anchor: d.anchor, initialized: true);
      expect(next.action, BiteTickAction.count);
      expect(next.newBites, 1);
    });
  });

}
