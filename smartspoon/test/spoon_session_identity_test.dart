import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:smartspoon/ble/device_registry.dart';
import 'package:smartspoon/ble/models/spoon_models.dart';
import 'package:smartspoon/features/devices/domain/spoon_identity.dart';

void main() {
  group('SpoonRecord.refersTo', () {
    final record = SpoonRecord(
      spoonSerial: 'aaaaaaaaaaaaaaa1',
      publicDeviceId: 'aaaaaaaaaaaaaaa1',
      bleRemoteId: 'ble-remote-a',
    );

    test('matches serial, public id and cached BLE address', () {
      expect(record.refersTo('aaaaaaaaaaaaaaa1'), isTrue);
      expect(record.refersTo('ble-remote-a'), isTrue);
      expect(record.refersTo('other'), isFalse);
      expect(record.refersTo(''), isFalse);
    });
  });

  group('sessionRefersTo', () {
    final record = SpoonRecord(
      spoonSerial: 'aaaaaaaaaaaaaaa1',
      publicDeviceId: 'aaaaaaaaaaaaaaa1',
      bleRemoteId: 'ble-remote-a',
    );

    test('Home/manager serial id is the same live session as the BLE address', () {
      expect(
        sessionRefersTo(
          queryId: 'aaaaaaaaaaaaaaa1',
          sessionRemoteId: 'ble-remote-a',
          sessionRecord: record,
        ),
        isTrue,
      );
      expect(
        sessionRefersTo(
          queryId: 'ble-remote-a',
          sessionRemoteId: 'ble-remote-a',
          sessionRecord: record,
        ),
        isTrue,
      );
    });

    test('in-progress link with no record yet still matches the remote id', () {
      expect(
        sessionRefersTo(
          queryId: 'ble-remote-a',
          sessionRemoteId: 'ble-remote-a',
        ),
        isTrue,
      );
    });

    test('a different spoon is not the live session', () {
      expect(
        sessionRefersTo(
          queryId: 'bbbbbbbbbbbbbbb2',
          sessionRemoteId: 'ble-remote-a',
          sessionRecord: record,
        ),
        isFalse,
      );
    });
  });

  group('uniqueSpoonDisplayIds', () {
    test('collapses serial and BLE address of the same saved spoon to one row', () {
      final records = [
        SpoonRecord(
          spoonSerial: 'aaaaaaaaaaaaaaa1',
          publicDeviceId: 'aaaaaaaaaaaaaaa1',
          bleRemoteId: 'ble-remote-a',
          displayName: 'Kitchen',
        ),
        SpoonRecord(
          spoonSerial: 'bbbbbbbbbbbbbbb2',
          publicDeviceId: 'bbbbbbbbbbbbbbb2',
          bleRemoteId: 'ble-remote-b',
          displayName: 'Office',
        ),
      ];
      expect(
        uniqueSpoonDisplayIds(
          ids: ['aaaaaaaaaaaaaaa1', 'ble-remote-a', 'ble-remote-b'],
          records: records,
        ),
        ['ble-remote-a', 'ble-remote-b'],
      );
    });
  });

  group('DeviceRegistry owner bind', () {
    test('adopts unscoped migrated spoons when the user key is empty', () async {
      SharedPreferences.setMockInitialValues({
        DeviceRegistry.storageKey: jsonEncode({
          'version': 2,
          'records': [
            {
              'spoonSerial': 'aaaaaaaaaaaaaaa1',
              'publicDeviceId': 'aaaaaaaaaaaaaaa1',
              'bleRemoteId': 'ble-a',
              'displayName': 'Kitchen',
              'hasHeater': true,
              'enabled': true,
              'isPrimary': true,
              'priority': 0,
              'claimEpoch': 0,
            },
          ],
        }),
      });
      final registry = DeviceRegistry();
      await registry.bindOwner('user-1');
      expect(registry.all, hasLength(1));
      expect(registry.all.single.displayName, 'Kitchen');
    });

    test('migrates per-user legacy saved spoons', () async {
      SharedPreferences.setMockInitialValues({
        savedSpoonsStorageKey('user-1'): [
          jsonEncode({
            'id': 'ble-a',
            'name': 'iSpoon Pro',
            'productId': 'aaaaaaaaaaaaaaa1',
            'hasHeater': true,
            'autoConnect': true,
            'lastConnected': DateTime.utc(2026, 9, 1).toIso8601String(),
          }),
        ],
      });
      final registry = DeviceRegistry();
      await registry.bindOwner('user-1');
      expect(registry.all, hasLength(1));
      expect(registry.all.single.spoonSerial, 'aaaaaaaaaaaaaaa1');
      expect(registry.all.single.bleRemoteId, 'ble-a');
    });
  });
}
