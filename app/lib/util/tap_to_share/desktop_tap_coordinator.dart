import 'package:localsend_app/model/persistence/favorite_device.dart';
import 'package:localsend_app/model/tap_to_share/impact_event.dart';
import 'package:localsend_app/provider/tap_to_share/tap_transfer_state_machine.dart';
import 'package:localsend_app/util/tap_to_share/peer_tap_matcher.dart';
import 'package:localsend_app/util/tap_to_share/tap_security_policy.dart';

/// Hardware capability descriptor for a desktop peer (`Spec 007`).
class DesktopTapCapability {
  final bool isDesktopPlatform;
  final bool hasImuSensors;
  final bool hasBluetoothAdapter;

  const DesktopTapCapability({
    required this.isDesktopPlatform,
    this.hasImuSensors = false,
    this.hasBluetoothAdapter = true,
  });
}

/// Evaluation result when a desktop receives a mobile peer's tap announcement (`Spec 007`).
class DesktopTapEvaluation {
  final bool accepted;
  final TapTransferRole role;

  /// Per rule `R4.8`, single-device impact matching with a desktop target ALWAYS requires manual confirmation.
  final bool requiresManualConfirmation;

  final bool usedLanOnlyFallback;
  final String reason;

  const DesktopTapEvaluation({
    required this.accepted,
    required this.role,
    required this.requiresManualConfirmation,
    required this.usedLanOnlyFallback,
    required this.reason,
  });
}

/// Coordinates Phone → Desktop and Desktop → Phone tap-to-share sessions (`Spec 007`).
///
/// Because desktop computers (Windows, macOS, Linux) generally lack IMU motion sensors
/// and sometimes lack Bluetooth hardware, rule `R4.8` permits single-sided impact matching
/// when one peer is a desktop, provided **mandatory manual confirmation** is enforced.
class DesktopTapCoordinator {
  final DesktopTapCapability capability;
  final TapSecurityPolicyGuard securityGuard;
  final double minPlausiblePeakAccelMps2;
  final double maxPlausiblePeakAccelMps2;
  int _desktopSyntheticSeq = 0;

  DesktopTapCoordinator({
    required this.capability,
    required this.securityGuard,
    this.minPlausiblePeakAccelMps2 = 3.5,
    this.maxPlausiblePeakAccelMps2 = 85.0,
  });

  /// Evaluates an incoming mobile [announcement] on a desktop host and drives [stateMachine] if accepted.
  DesktopTapEvaluation handleIncomingMobileTap({
    required PeerTapAnnouncement announcement,
    required TapToShareSettings settings,
    required List<FavoriteDevice> favorites,
    required TapTransferStateMachineController stateMachine,
    required int correctedPeerTimestampUs,
    required int nowLocalUs,
  }) {
    if (!capability.isDesktopPlatform) {
      return const DesktopTapEvaluation(
        accepted: false,
        role: TapTransferRole.none,
        requiresManualConfirmation: true,
        usedLanOnlyFallback: false,
        reason: 'not_desktop_platform',
      );
    }

    if (announcement.peakLinearAccelMps2 < minPlausiblePeakAccelMps2 || announcement.peakLinearAccelMps2 > maxPlausiblePeakAccelMps2) {
      return const DesktopTapEvaluation(
        accepted: false,
        role: TapTransferRole.none,
        requiresManualConfirmation: true,
        usedLanOnlyFallback: false,
        reason: 'implausible_impact_magnitude',
      );
    }

    final securityDecision = securityGuard.evaluateAnnouncement(
      announcement: announcement,
      settings: settings,
      favorites: favorites,
      correctedPeerTimestampUs: correctedPeerTimestampUs,
      nowLocalUs: nowLocalUs,
    );

    if (!securityDecision.allowed) {
      return DesktopTapEvaluation(
        accepted: false,
        role: TapTransferRole.none,
        requiresManualConfirmation: true,
        usedLanOnlyFallback: !capability.hasBluetoothAdapter,
        reason: securityDecision.reason.name,
      );
    }

    // Create a desktop anchor tap event so the shared state machine transitions cleanly (`armed -> tapDetected -> matched`).
    final desktopAnchorTap = DetectedTapEvent(
      impactTimestampUs: nowLocalUs,
      peakLinearAccelMps2: announcement.peakLinearAccelMps2,
      peakJerkMps3: 1000.0,
      preImpactGyroRms: 0.0,
      duringImpactGyroPeak: 0.0,
      postImpactAccelRms: 0.0,
      postImpactGyroRms: 0.0,
      dirX: 0.0,
      dirY: 0.0,
      dirZ: 1.0,
      orientation: Quaternion.identity,
      posture: DevicePosture.faceUp,
    );

    final desktopNonce = 'desktop-anchor-$nowLocalUs-${++_desktopSyntheticSeq}';
    final tapStarted = stateMachine.onLocalTapDetected(
      desktopAnchorTap,
      localNonce: desktopNonce,
    );
    if (!tapStarted) {
      return DesktopTapEvaluation(
        accepted: false,
        role: TapTransferRole.none,
        requiresManualConfirmation: true,
        usedLanOnlyFallback: !capability.hasBluetoothAdapter,
        reason: 'state_machine_not_armed_or_busy',
      );
    }

    final matched = stateMachine.onPeerMatched(
      peerFingerprint: announcement.senderFingerprint,
      peerNonce: announcement.nonce,
      peerHasFiles: announcement.hasSelectedFiles,
    );

    if (!matched) {
      return DesktopTapEvaluation(
        accepted: false,
        role: TapTransferRole.none,
        requiresManualConfirmation: true,
        usedLanOnlyFallback: !capability.hasBluetoothAdapter,
        reason: stateMachine.state.lastReason ?? 'match_rejected',
      );
    }

    // R4.8: Single-device impact matching with a desktop ALWAYS requires manual confirmation,
    // even if the phone is a Favorite and `autoAcceptFavorites == true`.
    return DesktopTapEvaluation(
      accepted: true,
      role: stateMachine.state.role,
      requiresManualConfirmation: true,
      usedLanOnlyFallback: !capability.hasBluetoothAdapter,
      reason: 'desktop_matched',
    );
  }
}
