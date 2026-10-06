// heater_capability_prompt.dart — spoon-type resolution.
//
// THE DEVICE DECIDES. Firmware reports its own heater capability in the
// owner-status characteristic (f00d0006) capability bits, which the app reads
// on every connect before bonding. ConnectionCoordinator writes that answer
// straight into the device record, so capability needs no user input and
// self-corrects on the first connect to capability-reporting firmware.
//
// This used to ask the user "does this spoon have a heater?" on a bottom sheet
// during pairing. It asked because nothing on the air distinguished the two
// SKUs: both advertise the primary-AD short name "iSpoon" and both report
// hardware revision "A1". That question was never the user's to answer, and
// name parsing — the only alternative — silently mislabels any renamed spoon.
// Firmware now answers it, so the sheet is gone from the connect path.
//
// What remains here:
//   - provisionalHeaterCapability(): a no-prompt, name-derived guess used ONLY
//     for the instant between tapping connect and the device declaring itself.
//     It is overwritten by the device's answer moments later.
//   - askHeaterCapability(): the sheet, kept for a MANUAL override on firmware
//     too old to report capabilities. Do not reintroduce it into connect.
//
// Previously this resolution only existed inline in AddDeviceScreen's pairing
// flow. The Home page's "New spoon nearby" quick-connect tile — a second,
// equally normal way to connect a newly discovered spoon — called
// SavedBleDevice.detectHeater(name) directly with no ambiguous-name check, so
// a renamed Pro spoon (anything not containing "pro") connected from Home
// silently lost its heater controls. Both entry points now share this single
// resolution path so they can't diverge again.
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:smartspoon/core/theme/app_theme.dart';
import 'package:smartspoon/ble/models/runtime_models.dart';

/// A provisional, NEVER-PROMPTING guess from the advertised [deviceName],
/// used only to seed the record between tapping connect and the device
/// declaring its real capability over GATT.
///
/// Deliberately returns a plain bool rather than asking: the connect flow must
/// not block on a question the device answers by itself a moment later.
/// ConnectionCoordinator overwrites this from the owner-status capability bits
/// on every validated connect, so a wrong guess here is transient — except on
/// firmware too old to report capabilities, where [askHeaterCapability] is the
/// manual escape hatch.
bool provisionalHeaterCapability(String deviceName) =>
    SavedBleDevice.detectHeater(deviceName);

/// Manual spoon-type override for firmware that predates the capability bits.
/// Returns null if dismissed. NOT for the connect path — see the file header.
Future<bool?> askHeaterCapability(BuildContext context, String deviceName) {
  return showModalBottomSheet<bool>(
    context: context,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (ctx) => Padding(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: AppTheme.border,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 20),
          Text(
            'Select Spoon Type',
            style: AppTheme.serif(fontSize: 18, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          Text(
            'Does "$deviceName" have a built-in heater?',
            style: GoogleFonts.figtree(
              fontSize: 14,
              color: AppTheme.textSecondary,
            ),
          ),
          const SizedBox(height: 24),
          SpoonTypeOption(
            label: 'i-Spoon Pro — with heater',
            icon: Icons.local_fire_department_rounded,
            iconColor: AppTheme.paprika,
            onTap: () => Navigator.pop(ctx, true),
          ),
          const SizedBox(height: 12),
          SpoonTypeOption(
            label: 'i-Spoon Basic — no heater',
            icon: Icons.restaurant_rounded,
            iconColor: AppTheme.caramel,
            onTap: () => Navigator.pop(ctx, false),
          ),
        ],
      ),
    ),
  );
}

class SpoonTypeOption extends StatelessWidget {
  const SpoonTypeOption({
    super.key,
    required this.label,
    required this.icon,
    required this.iconColor,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final Color iconColor;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        decoration: BoxDecoration(
          border: Border.all(color: AppTheme.border),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          children: [
            Icon(icon, color: iconColor, size: 22),
            const SizedBox(width: 16),
            Expanded(
              child: Text(
                label,
                style: GoogleFonts.figtree(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: AppTheme.textPrimary,
                ),
              ),
            ),
            Icon(
              Icons.arrow_forward_ios_rounded,
              size: 14,
              color: AppTheme.textTertiary,
            ),
          ],
        ),
      ),
    );
  }
}
