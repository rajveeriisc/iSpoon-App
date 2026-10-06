import 'dart:typed_data';

/// MCUboot image header (`bootutil/image.h`).
///
/// Factory programming uses `merged.hex` (bootloader + app). Mobile OTA uses
/// the signed application only (`zephyr.signed.bin`), which starts with this
/// header. Nordic / Zephyr DFU clients MUST reject anything else before SMP
/// upload — a truncated download or a ZIP uploaded as a BIN bricks the
/// secondary slot until the next reset rolls it back.
class McubootImage {
  McubootImage._({
    required this.magic,
    required this.headerSize,
    required this.imageSize,
    required this.major,
    required this.minor,
    required this.revision,
    required this.buildNumber,
  });

  static const int magicValue = 0x96F3B83D;

  /// Secondary slot size from firmware `pm_static.yml` (`mcuboot_secondary`).
  static const int maxSlotBytes = 0x79000;

  static const int headerLength = 32;

  final int magic;
  final int headerSize;
  final int imageSize;
  final int major;
  final int minor;
  final int revision;
  final int buildNumber;

  String get versionLabel {
    final core = '$major.$minor.$revision';
    return buildNumber == 0 ? core : '$core+$buildNumber';
  }

  /// Parse and validate a signed MCUboot BIN. Throws [FormatException] with a
  /// user-safe message when the buffer is not a flashable image.
  static McubootImage parse(Uint8List bytes) {
    if (bytes.length < headerLength) {
      throw const FormatException(
        'File is too small to be a signed MCUboot image.',
      );
    }
    if (bytes.length > maxSlotBytes) {
      throw FormatException(
        'Image is ${bytes.length} bytes; spoon slot is $maxSlotBytes.',
      );
    }

    final data = ByteData.sublistView(bytes);
    final magic = data.getUint32(0, Endian.little);
    if (magic != magicValue) {
      throw const FormatException(
        'Not a signed MCUboot image (bad magic). Use zephyr.signed.bin, '
        'not merged.hex or dfu_application.zip.',
      );
    }

    final headerSize = data.getUint16(8, Endian.little);
    final imageSize = data.getUint32(12, Endian.little);
    if (headerSize < headerLength ||
        headerSize + imageSize > bytes.length) {
      throw const FormatException(
        'MCUboot header size does not match the file.',
      );
    }

    return McubootImage._(
      magic: magic,
      headerSize: headerSize,
      imageSize: imageSize,
      major: bytes[20],
      minor: bytes[21],
      revision: data.getUint16(22, Endian.little),
      buildNumber: data.getUint32(24, Endian.little),
    );
  }
}
