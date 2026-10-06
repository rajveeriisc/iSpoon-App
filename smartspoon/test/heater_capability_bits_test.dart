// Capability bits in the owner-status characteristic (f00d0006 byte 0).
//
// These guard a FIRMWARE CONTRACT: bit5 CAPS_VALID and bit6 HAS_HEATER must
// keep matching the OWNER_STAT_* defines in the firmware's main.c. The whole
// point of the pair is that "no heater" and "firmware too old to say" are
// different answers — collapsing them strips heater controls off an older Pro
// spoon, which is why heaterCapability is nullable rather than a plain bool.
import 'package:flutter_test/flutter_test.dart';
import 'package:smartspoon/ble/models/spoon_models.dart';

void main() {
  group('owner-status capability bits', () {
    test('heater SKU declares CAPS_VALID + HAS_HEATER', () {
      // bit5 | bit6 = 0x60
      final f = SpoonOwnerFlags.tryParse([0x60, 0])!;
      expect(f.capsValid, isTrue);
      expect(f.declaredHasHeater, isTrue);
      expect(f.heaterCapability, isTrue);
    });

    test('no-heater SKU declares CAPS_VALID only', () {
      final f = SpoonOwnerFlags.tryParse([0x20, 0])!;
      expect(f.capsValid, isTrue);
      expect(f.declaredHasHeater, isFalse);
      // The device positively states it has no heater.
      expect(f.heaterCapability, isFalse);
    });

    test('firmware without capability bits reports UNKNOWN, not false', () {
      // Old firmware: bits 5/6 clear. Reading this as "no heater" would hide
      // heater controls on a real Pro spoon, so it must stay null.
      final f = SpoonOwnerFlags.tryParse([0x01, 0])!;
      expect(f.capsValid, isFalse);
      expect(f.heaterCapability, isNull);
    });

    test('HAS_HEATER without CAPS_VALID is not trusted', () {
      // Defensive: a stray bit6 on firmware that does not implement the
      // contract must not be read as a capability claim.
      final f = SpoonOwnerFlags.tryParse([0x40, 0])!;
      expect(f.capsValid, isFalse);
      expect(f.heaterCapability, isNull);
    });

    test('capability bits do not disturb the existing owner flags', () {
      // owner + peerBonded + secured, plus caps/heater set.
      final f = SpoonOwnerFlags.tryParse([0x01 | 0x02 | 0x08 | 0x60, 0])!;
      expect(f.ownerPresent, isTrue);
      expect(f.peerBonded, isTrue);
      expect(f.secured, isTrue);
      expect(f.pairRejected, isFalse);
      expect(f.repairHold6s, isFalse);
      expect(f.heaterCapability, isTrue);
    });

    test('empty read still parses as null, not as a capability answer', () {
      expect(SpoonOwnerFlags.tryParse([]), isNull);
    });
  });
}
