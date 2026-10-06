// Re-claiming a spoon THIS phone already owns.
//
// Regression guard for the asymmetry between validateRestored() and
// validateForClaim(): the restored path guarded its ownership checks with
// isOwnedByThisPhone, the claim path did not. A user whose app record was gone
// (reinstall / cleared data / spoon removed and re-added) but whose phone still
// held the bond was told "already claimed by another owner — press & hold the
// pad 6s", i.e. factory-reset your own spoon to get it back.
import 'package:flutter_test/flutter_test.dart';
import 'package:smartspoon/ble/device_authenticator.dart';
import 'package:smartspoon/ble/models/spoon_models.dart';

SpoonIdentityReading _reading({
  bool? ownedByThisPhone,
  bool? pairRejected,
  bool? repairHold6s,
  bool? claimed,
}) =>
    SpoonIdentityReading(
      spoonSerial: 'aaaaaaaaaaaaaaa1',
      publicDeviceId: 'aaaaaaaaaaaaaaa1',
      isClaimed: claimed,
      isOwnedByThisPhone: ownedByThisPhone,
      pairRejected: pairRejected,
      repairHold6s: repairHold6s,
    );

void main() {
  final auth = DeviceAuthenticator();

  group('validateForClaim', () {
    test('allows re-claiming a spoon this phone is bonded to', () {
      // The decisive case: owner bond present, and it is OURS.
      final out = auth.validateForClaim(_reading(
        ownedByThisPhone: true,
        claimed: true,
        pairRejected: true,
        repairHold6s: true,
      ));
      expect(out.result, AuthResult.authorized,
          reason: 'the rightful owner must be able to re-add their own spoon '
              'without a physical factory reset');
    });

    test('still rejects a spoon owned by a DIFFERENT phone', () {
      final out = auth.validateForClaim(
          _reading(ownedByThisPhone: false, repairHold6s: true));
      expect(out.result, AuthResult.ownershipMismatch);
    });

    test('still rejects when pairing was refused and we are not the owner', () {
      final out = auth.validateForClaim(
          _reading(ownedByThisPhone: false, pairRejected: true));
      expect(out.result, AuthResult.ownershipMismatch);
    });

    test('unknown ownership with a reject signal stays rejected', () {
      // isOwnedByThisPhone null = firmware could not say. Unknown must not be
      // read as "it is ours".
      final out = auth.validateForClaim(_reading(pairRejected: true));
      expect(out.result, AuthResult.ownershipMismatch);
    });

    test('a free spoon is claimable', () {
      expect(auth.validateForClaim(_reading()).result, AuthResult.authorized);
    });

    test('no serial is still rejected even if we are the owner', () {
      final out = auth.validateForClaim(SpoonIdentityReading(
        spoonSerial: '',
        publicDeviceId: '',
        isOwnedByThisPhone: true,
      ));
      expect(out.result, AuthResult.ownershipMismatch);
    });
  });
}
