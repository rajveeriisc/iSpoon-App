// Stable spoon identity helpers.
//
// Firmware advertises the nRF hwinfo 8-byte Device ID in manufacturer data
// (company 0xFFFF, type 0x01). BLE addresses rotate after a settings-erase
// flash; this product id does not. Matching, storage keys, and cloud register
// all use it so one account can keep several spoons and reconnect after flash.
import 'dart:typed_data';

/// Bluetooth Company Identifier used in iSpoon manufacturer data (unassigned).
const int kIspoonMfgCompanyId = 0xFFFF;

/// Manufacturer payload type: 8-byte hwinfo Device ID follows.
const int kIspoonMfgTypeDeviceId = 0x01;

const String kSavedSpoonsStorageKey = 'ble_saved_devices_v2';
const String kFallbackSpoonName = 'iSpoon Pro';

/// Minimal saved-spoon record used by [adoptSavedSpoon] (no Flutter/BLE types).
class SavedSpoonRef {
  final String id;
  final String? productId;

  const SavedSpoonRef({required this.id, this.productId});
}

String? _normalizeProductId(String? raw) {
  if (raw == null) return null;
  final hex = raw.trim().toLowerCase();
  if (hex.length != 16) return null;
  if (!RegExp(r'^[0-9a-f]{16}$').hasMatch(hex)) return null;
  return hex;
}

String? parseIspoonProductId(Uint8List manufacturerData) {
  if (manufacturerData.length < 11) return null;
  final company =
      manufacturerData[0] | (manufacturerData[1] << 8);
  if (company != kIspoonMfgCompanyId) return null;
  if (manufacturerData[2] != kIspoonMfgTypeDeviceId) return null;
  return productIdFromGattBytes(manufacturerData.sublist(3, 11));
}

String? productIdFromGattBytes(List<int> bytes) {
  if (bytes.length < 8) return null;
  final hex = bytes
      .take(8)
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join();
  return _normalizeProductId(hex);
}

String savedSpoonsStorageKey(String? userId) {
  final uid = userId?.trim() ?? '';
  if (uid.isEmpty) return kSavedSpoonsStorageKey;
  return '${kSavedSpoonsStorageKey}_$uid';
}

/// Hardware swap: a new PCB (new MAC and new chip id) should take over the
/// one saved spoon on this phone so the user does not Forget first.
///
/// Only when this account has exactly one saved spoon and it is not
/// currently connected. Two saved spoons, or a live first spoon, must
/// not be stolen.
SavedSpoonRef? adoptReplacementSpoon({
  required String discoveredId,
  required List<SavedSpoonRef> saved,
  Set<String> connectedIds = const {},
}) {
  if (saved.any((d) => d.id == discoveredId)) return null;
  if (saved.length != 1) return null;
  final only = saved.single;
  if (connectedIds.contains(only.id)) return null;
  return only;
}

/// Re-anchor a saved spoon that reappeared at a new BLE address.
///
/// A matching 8-byte product id is the same chip after a reflash. If that
/// fails, [adoptReplacementSpoon] covers a brand-new PCB when this account
/// only has one saved spoon.
SavedSpoonRef? adoptSavedSpoon({
  required String discoveredId,
  required String? discoveredProductId,
  required List<SavedSpoonRef> saved,
  Set<String> connectedIds = const {},
}) {
  if (saved.any((d) => d.id == discoveredId)) return null;
  final productId = _normalizeProductId(discoveredProductId);
  if (productId == null) return null;

  final matches = saved.where((d) {
    if (connectedIds.contains(d.id)) return false;
    return _normalizeProductId(d.productId) == productId;
  }).toList();
  if (matches.length != 1) return null;
  return matches.first;
}

/// A spoon seen in the current scan, used to pick a reconnect address.
class NearbySpoon {
  final String id;
  final String? productId;

  const NearbySpoon({required this.id, this.productId});
}

/// Choose which BLE address to connect after the user taps Reconnect.
///
/// After a settings-erase flash the saved address is dead. Prefer a product-id
/// match. If this account has only one disconnected saved spoon and exactly one
/// iSpoon is nearby, use that address — that is the new-PCB / reflash case.
String? pickReconnectBleId({
  required String savedId,
  required String? savedProductId,
  required List<NearbySpoon> nearby,
  required int disconnectedSavedCount,
}) {
  if (nearby.any((n) => n.id == savedId)) return savedId;

  final want = _normalizeProductId(savedProductId);
  if (want != null) {
    final matches = nearby
        .where((n) => _normalizeProductId(n.productId) == want)
        .toList();
    if (matches.length == 1) return matches.first.id;
  }

  if (disconnectedSavedCount == 1 && nearby.length == 1) {
    return nearby.single.id;
  }
  return null;
}

String advertisedSpoonName(String name, Uint8List manufacturerData) {
  final trimmed = name.trim();
  if (trimmed.isNotEmpty) return trimmed;
  if (parseIspoonProductId(manufacturerData) != null) return kFallbackSpoonName;
  return name;
}
