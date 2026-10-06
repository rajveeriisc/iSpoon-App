import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:smartspoon/features/devices/domain/mcuboot_image.dart';

Uint8List _header({
  int magic = McubootImage.magicValue,
  int hdrSize = 32,
  int imgSize = 64,
  int major = 2,
  int minor = 2,
  int revision = 15,
  int build = 0,
  int total = 96,
}) {
  final bytes = Uint8List(total);
  final data = ByteData.sublistView(bytes);
  data.setUint32(0, magic, Endian.little);
  data.setUint16(8, hdrSize, Endian.little);
  data.setUint32(12, imgSize, Endian.little);
  bytes[20] = major;
  bytes[21] = minor;
  data.setUint16(22, revision, Endian.little);
  data.setUint32(24, build, Endian.little);
  return bytes;
}

void main() {
  test('accepts a little-endian MCUboot header', () {
    final img = McubootImage.parse(_header());
    expect(img.versionLabel, '2.2.15');
    expect(img.imageSize, 64);
  });

  test('rejects a file that is not a signed BIN', () {
    expect(
      () => McubootImage.parse(Uint8List.fromList([0x00, 0x01, 0x02, 0x03])),
      throwsFormatException,
    );
  });

  test('rejects ZIP/HEX magic so the user cannot flash merged.hex', () {
    final zip = _header(magic: 0x04034B50); // PK..
    expect(() => McubootImage.parse(zip), throwsFormatException);
  });

  test('rejects an image larger than the secondary slot', () {
    final huge = Uint8List(McubootImage.maxSlotBytes + 1);
    final data = ByteData.sublistView(huge);
    data.setUint32(0, McubootImage.magicValue, Endian.little);
    data.setUint16(8, 32, Endian.little);
    data.setUint32(12, 64, Endian.little);
    expect(() => McubootImage.parse(huge), throwsFormatException);
  });
}
