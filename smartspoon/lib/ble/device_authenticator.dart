// device_authenticator.dart — decides whether a connected spoon actually
// belongs to this user, before any telemetry or command is allowed.
//
// Follows design §2 (Ownership and Claim Contract), §8.2 (DeviceAuthenticator)
// and §15 (Factory Reset Handling), plus edge cases #18, #22, #24, #25.
//
// ─────────────────────────────────────────────────────────────────────────
// HONEST STATEMENT OF WHAT THIS CAN AND CANNOT DO TODAY
// ─────────────────────────────────────────────────────────────────────────
// The design is explicit (§2): "A local Boolean such as isClaimed=true is not
// sufficient security." Real ownership needs one of — BLE bonding plus a
// firmware owner whitelist, a factory-provisioned device secret, a printed
// pairing secret, a challenge-response token, or a backend ownership record.
//
// This firmware currently provides:
//   • BLE bonding (LE Secure Connections with a fixed passkey)
//   • an owner/pair status characteristic (f00d0006), readable unencrypted
//   • a stable device identity characteristic (f00d0004)
//
// It does NOT yet provide a claim epoch or a challenge-response. So:
//   • identity matching works;
//   • ownership is enforced by BONDING, which is real but device-local;
//   • FACTORY RESET DETECTION IS NOT POSSIBLE (§15 needs claimEpoch).
//
// Everything epoch- and challenge-shaped below is written against the final
// contract and gated on FirmwareCapabilities, so the day firmware ships those
// characteristics this file starts enforcing them without a redesign.
library;

import 'package:smartspoon/ble/constants.dart';
import 'package:smartspoon/ble/models/spoon_models.dart';

/// Identity read from a connected spoon before it is trusted.
class SpoonIdentityReading {
  const SpoonIdentityReading({
    required this.spoonSerial,
    required this.publicDeviceId,
    this.claimEpoch,
    this.firmwareVersion,
    this.protocolMajor,
    this.isClaimed,
    this.isOwnedByThisPhone,
    this.pairRejected,
    this.repairHold6s,
    this.isSecured,
    this.declaredHasHeater,
  });

  final String spoonSerial;
  final String publicDeviceId;

  /// The device's OWN answer to "do I have a heater", from the owner-status
  /// capability bits. Null when the firmware is too old to say — which must
  /// NOT be read as false, or an old Pro spoon loses its heater controls.
  /// When non-null this outranks both the saved flag and any name guess,
  /// because the device knows and renaming a spoon defeats name parsing.
  final bool? declaredHasHeater;

  /// Null when firmware does not expose it — NOT the same as zero.
  final int? claimEpoch;
  final String? firmwareVersion;
  final int? protocolMajor;
  final bool? isClaimed;

  /// Derived from bonding state: does this phone hold the owner bond?
  final bool? isOwnedByThisPhone;
  final bool? pairRejected;
  final bool? repairHold6s;

  /// Firmware's own report that L2 encryption is up on THIS link. Null when
  /// the spoon does not expose owner status. It is the difference between "we
  /// are connected" and "the spoon will actually talk to us", and nothing else
  /// in the pipeline can substitute for it.
  final bool? isSecured;
}

/// Outcome plus the reason, so the coordinator can pick the right
/// DisconnectReason instead of guessing.
class AuthOutcome {
  const AuthOutcome(this.result, {this.reason, this.detail});

  final AuthResult result;
  final DisconnectReason? reason;
  final String? detail;

  bool get isAuthorized => result == AuthResult.authorized;

  @override
  String toString() =>
      'AuthOutcome(${result.name}${detail != null ? ": $detail" : ""})';
}

/// Validates a connected spoon against its saved record.
///
/// Owns no BLE: the caller reads the characteristics and hands the values in,
/// which keeps this testable and package-independent.
class DeviceAuthenticator {
  DeviceAuthenticator({
    FirmwareCapabilities capabilities = FirmwareCapabilities.current,
  }) : _caps = capabilities;

  final FirmwareCapabilities _caps;

  /// Full validation for a spoon we already have a record for.
  ///
  /// Order matters: identity first (cheapest and most fundamental), then
  /// claim epoch, then ownership. A failure at any step is PERMANENT per
  /// Rule 8 — the coordinator must quarantine, not retry.
  AuthOutcome validateKnownSpoon({
    required SpoonRecord saved,
    required SpoonIdentityReading reading,
  }) {
    // ── Identity (edge cases #18, #24) ───────────────────────────────────
    // A spoofed advertisement can claim any publicDeviceId; only the
    // post-connect serial read settles it.
    if (reading.spoonSerial.isEmpty) {
      return const AuthOutcome(
        AuthResult.ownershipMismatch,
        reason: DisconnectReason.identityMismatch,
        detail: 'spoon reported no serial',
      );
    }
    if (saved.spoonSerial.isNotEmpty &&
        reading.spoonSerial.toLowerCase() != saved.spoonSerial.toLowerCase()) {
      return AuthOutcome(
        AuthResult.ownershipMismatch,
        reason: DisconnectReason.identityMismatch,
        detail: 'serial ${reading.spoonSerial} != saved ${saved.spoonSerial}',
      );
    }

    // §10.3 validates serial AND publicDeviceId, and edge case #59 is exactly
    // the pair disagreeing: a cached remoteId that now points at a different
    // spoon. The advertisement is only a hint (§1.3) — this post-connect read
    // is what settles it, and it must reject rather than quietly re-point the
    // saved record at whatever answered.
    if (saved.publicDeviceId.isNotEmpty &&
        reading.publicDeviceId.isNotEmpty &&
        reading.publicDeviceId.toLowerCase() != saved.publicDeviceId.toLowerCase()) {
      return AuthOutcome(
        AuthResult.ownershipMismatch,
        reason: DisconnectReason.identityMismatch,
        detail: 'publicDeviceId ${reading.publicDeviceId} != saved '
            '${saved.publicDeviceId}',
      );
    }

    // ── Claim epoch / factory reset (§15, edge case #22) ─────────────────
    // A factory reset keeps the serial and BUMPS the epoch. Without an epoch
    // we cannot tell a reset spoon from the same spoon, so we must not
    // pretend we can — we simply skip this gate and say so.
    if (_caps.hasClaimEpoch) {
      final epoch = reading.claimEpoch;
      if (epoch == null) {
        return const AuthOutcome(
          AuthResult.requiresReclaim,
          reason: DisconnectReason.claimEpochMismatch,
          detail: 'claim epoch expected but not readable',
        );
      }
      if (epoch != saved.claimEpoch) {
        return AuthOutcome(
          AuthResult.requiresReclaim,
          reason: DisconnectReason.claimEpochMismatch,
          detail: 'epoch $epoch != saved ${saved.claimEpoch} '
              '(spoon was factory reset — must be re-claimed)',
        );
      }
    }

    // ── Ownership ────────────────────────────────────────────────────────
    // For a saved spoon whose hardware serial number matches our saved record,
    // this IS the user's spoon. We must NOT reject our own saved spoon just
    // because the phone has not established an OS SMP bond (the spoon streams on open CCC).
    // Reject if the spoon explicitly reported that pairing was rejected,
    // or if the firmware reports that an owner bond exists and belongs to another phone.
    // PAIR_REJECTED means the spoon's single-owner policy refused a pairing on
    // THIS link — which firmware only does when it holds an owner bond that is
    // not this phone. If this phone IS the bonded owner, the flag cannot be
    // about us, and rejecting here would quarantine the user's own spoon.
    if (reading.pairRejected == true && reading.isOwnedByThisPhone != true) {
      return const AuthOutcome(
        AuthResult.ownershipMismatch,
        reason: DisconnectReason.ownershipMismatch,
        detail: 'spoon refused pairing — it belongs to another phone',
      );
    }
    if (reading.isClaimed == true && reading.isOwnedByThisPhone == false) {
      return const AuthOutcome(
        AuthResult.ownershipMismatch,
        reason: DisconnectReason.ownershipMismatch,
        detail: 'spoon is owned by a different phone',
      );
    }

    // §15 / case 7.2 — the spoon we have saved now reports NO owner at all.
    // On this firmware that is what a factory reset looks like: the 6-second
    // long hold clears the owner bond and keeps the same identity address, so
    // the serial still matches and only this bit gives it away. It is the
    // equivalent of the design's claimEpoch change, and the response is the
    // same: do not stream, make the user claim it again.
    //
    // Silently re-bonding instead would be wrong in the one case that matters
    // — a spoon that was reset because it is being handed to somebody else.
    //
    // A spoon being claimed for the FIRST time goes through validateForClaim,
    // not here, so this cannot block normal pairing.
    if (reading.isClaimed == false) {
      return const AuthOutcome(
        AuthResult.requiresReclaim,
        reason: DisconnectReason.claimEpochMismatch,
        detail: 'spoon reports no owner — it was reset and must be re-claimed',
      );
    }

    return const AuthOutcome(AuthResult.authorized);
  }

  /// Protocol compatibility (§26, design bug #30: the old check accepted any
  /// non-empty version).
  ///
  /// Enforced only when firmware exposes a protocol characteristic; otherwise
  /// we deliberately assume compatible rather than inventing a version.
  AuthOutcome validateProtocol(SpoonIdentityReading reading) {
    if (!_caps.hasProtocolCharacteristic) {
      return const AuthOutcome(AuthResult.authorized);
    }
    final major = reading.protocolMajor;
    if (major == null) {
      return const AuthOutcome(
        AuthResult.ownershipMismatch,
        reason: DisconnectReason.protocolIncompatible,
        detail: 'protocol characteristic unreadable',
      );
    }
    if (!BleConstants.isProtocolCompatible(major)) {
      return AuthOutcome(
        AuthResult.ownershipMismatch,
        reason: DisconnectReason.protocolIncompatible,
        detail: 'protocol major $major, app supports '
            '${BleConstants.protocolMajorSupported}',
      );
    }
    return const AuthOutcome(AuthResult.authorized);
  }

  /// Provisioning path (§14). A spoon with no saved record may only be
  /// adopted through the explicit Add/Claim flow — never by auto-connect
  /// (Rule 7).
  AuthOutcome validateForClaim(SpoonIdentityReading reading) {
    if (reading.spoonSerial.isEmpty) {
      return const AuthOutcome(
        AuthResult.ownershipMismatch,
        reason: DisconnectReason.identityMismatch,
        detail: 'no serial',
      );
    }
    // Re-adopting a spoon THIS phone is already bonded to is legitimate, and
    // must not be mistaken for someone else's spoon.
    //
    // The app's record can be gone while both the OS bond and the spoon's
    // owner bond survive: the app was reinstalled, its data cleared, or the
    // spoon was removed from the app and is being added back. The user then
    // arrives here, on the claim path, as the rightful owner.
    //
    // Both signals below describe a DIFFERENT phone owning the spoon —
    // REPAIR_HOLD_6S is literally `owner && !peer_bonded`, and PAIR_REJECTED
    // is latched when firmware refuses a peer that holds no bond. Neither can
    // be about us when we ARE the bonded peer, so rejecting here told the
    // rightful owner to factory-reset their own spoon to get it back.
    //
    // validateRestored() already guards both of its equivalent checks with
    // isOwnedByThisPhone for exactly this reason ("rejecting here would
    // quarantine the user's own spoon"); this path was missing that guard.
    if (reading.isOwnedByThisPhone == true) {
      return const AuthOutcome(AuthResult.authorized);
    }
    if (reading.pairRejected == true || reading.repairHold6s == true) {
      return const AuthOutcome(
        AuthResult.ownershipMismatch,
        reason: DisconnectReason.deviceBusy,
        detail: 'already claimed by another owner (press & hold spoon pad 6s to clear owner)',
      );
    }
    return const AuthOutcome(AuthResult.authorized);
  }
}
