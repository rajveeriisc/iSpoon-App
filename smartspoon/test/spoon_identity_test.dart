import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:smartspoon/ble/models/runtime_models.dart';
import 'package:smartspoon/features/devices/domain/spoon_identity.dart';

void main() {
  group('parseIspoonProductId', () {
    test('reads the 8-byte hwinfo id from manufacturer data', () {
      final data = Uint8List.fromList([
        0xFF, 0xFF, // company id 0xFFFF LE
        0x01, // device-id type
        0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF,
      ]);
      expect(parseIspoonProductId(data), '0123456789abcdef');
    });

    test('rejects the wrong company id, type, or truncated payload', () {
      expect(
        parseIspoonProductId(
          Uint8List.fromList([0x59, 0x00, 0x01, 1, 2, 3, 4, 5, 6, 7, 8]),
        ),
        isNull,
      );
      expect(
        parseIspoonProductId(
          Uint8List.fromList([0xFF, 0xFF, 0x02, 1, 2, 3, 4, 5, 6, 7, 8]),
        ),
        isNull,
      );
      expect(
        parseIspoonProductId(Uint8List.fromList([0xFF, 0xFF, 0x01, 1, 2, 3])),
        isNull,
      );
    });
  });

  group('productIdFromGattBytes', () {
    test('formats an 8-byte GATT value as lowercase hex', () {
      expect(
        productIdFromGattBytes([0xDE, 0xAD, 0xBE, 0xEF, 0, 1, 2, 3]),
        'deadbeef00010203',
      );
    });

    test('rejects empty or short GATT values', () {
      expect(productIdFromGattBytes(const []), isNull);
      expect(productIdFromGattBytes([1, 2, 3]), isNull);
    });
  });

  group('savedSpoonsStorageKey', () {
    test('scopes the store to the signed-in user', () {
      expect(
        savedSpoonsStorageKey('firebase-uid-1'),
        'ble_saved_devices_v2_firebase-uid-1',
      );
      expect(savedSpoonsStorageKey(''), 'ble_saved_devices_v2');
      expect(savedSpoonsStorageKey(null), 'ble_saved_devices_v2');
    });
  });

  group('adoptSavedSpoon', () {
    const a = SavedSpoonRef(id: 'aa:aa', productId: '0123456789abcdef');
    const b = SavedSpoonRef(id: 'bb:bb', productId: 'ffffffffffffffff');
    const unnamed = SavedSpoonRef(id: 'cc:cc');

    test('re-anchors the saved spoon whose product id matches', () {
      expect(
        adoptSavedSpoon(
          discoveredId: 'new-mac',
          discoveredProductId: '0123456789ABCDEF',
          saved: const [a, b],
        )?.id,
        'aa:aa',
      );
    });

    test('does not adopt by name or because only one spoon is saved', () {
      expect(
        adoptSavedSpoon(
          discoveredId: 'new-mac',
          discoveredProductId: null,
          saved: const [unnamed],
        ),
        isNull,
      );
      expect(
        adoptSavedSpoon(
          discoveredId: 'new-mac',
          discoveredProductId: '',
          saved: const [a],
        ),
        isNull,
      );
    });

    test('replacement takes over the only saved spoon for a new PCB', () {
      expect(
        adoptReplacementSpoon(
          discoveredId: 'new-pcb',
          saved: const [unnamed],
        )?.id,
        'cc:cc',
      );
      expect(
        adoptReplacementSpoon(
          discoveredId: 'new-pcb',
          saved: const [a, b],
        ),
        isNull,
      );
      expect(
        adoptReplacementSpoon(
          discoveredId: 'aa:aa',
          saved: const [a],
        ),
        isNull,
      );
      expect(
        adoptReplacementSpoon(
          discoveredId: 'new-pcb',
          saved: const [a],
          connectedIds: {'aa:aa'},
        ),
        isNull,
      );
    });

    test('does not steal a spoon that is already saved at this address', () {
      expect(
        adoptSavedSpoon(
          discoveredId: 'aa:aa',
          discoveredProductId: '0123456789abcdef',
          saved: const [a, b],
        ),
        isNull,
      );
    });
  });

  group('pickReconnectBleId', () {
    test('keeps the saved address when that spoon is still advertising', () {
      expect(
        pickReconnectBleId(
          savedId: 'old',
          savedProductId: '0123456789abcdef',
          nearby: const [
            NearbySpoon(id: 'old', productId: '0123456789abcdef'),
            NearbySpoon(id: 'other', productId: 'ffffffffffffffff'),
          ],
          disconnectedSavedCount: 2,
        ),
        'old',
      );
    });

    test('follows the product id after a reflash changes the BLE address', () {
      expect(
        pickReconnectBleId(
          savedId: 'old',
          savedProductId: '0123456789abcdef',
          nearby: const [
            NearbySpoon(id: 'new-mac', productId: '0123456789abcdef'),
          ],
          disconnectedSavedCount: 1,
        ),
        'new-mac',
      );
    });

    test('pairs the only nearby spoon when this is the only saved record', () {
      expect(
        pickReconnectBleId(
          savedId: 'stale-mac',
          savedProductId: null,
          nearby: const [NearbySpoon(id: 'fresh-pcb')],
          disconnectedSavedCount: 1,
        ),
        'fresh-pcb',
      );
    });

    test('does not guess when several saved spoons could match', () {
      expect(
        pickReconnectBleId(
          savedId: 'stale-mac',
          savedProductId: null,
          nearby: const [NearbySpoon(id: 'fresh-pcb')],
          disconnectedSavedCount: 2,
        ),
        isNull,
      );
    });
  });

  group('advertisedSpoonName', () {
    test('keeps the advertised name when present', () {
      expect(advertisedSpoonName('iSpoon Pro', Uint8List(0)), 'iSpoon Pro');
    });

    test('falls back when iOS emits an empty name with our manufacturer id', () {
      final data = Uint8List.fromList([
        0xFF, 0xFF, 0x01, 1, 2, 3, 4, 5, 6, 7, 8,
      ]);
      expect(advertisedSpoonName('  ', data), 'iSpoon Pro');
    });
  });

  group('SavedBleDevice productId persistence', () {
    test('round-trips the stable product id through JSON', () {
      final saved = SavedBleDevice(
        id: 'ble-id',
        name: 'iSpoon Pro',
        lastConnected: DateTime.utc(2026, 8, 19),
        productId: '0123456789abcdef',
        hasHeater: true,
      );
      final restored = SavedBleDevice.fromJsonString(jsonEncode(saved.toJson()));
      expect(restored, isNotNull);
      expect(restored!.productId, '0123456789abcdef');
      expect(restored.hasHeater, isTrue);
    });
  });
}
