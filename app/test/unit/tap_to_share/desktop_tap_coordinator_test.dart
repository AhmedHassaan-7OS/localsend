import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/model/persistence/favorite_device.dart';
import 'package:localsend_app/model/tap_to_share/impact_event.dart';
import 'package:localsend_app/provider/tap_to_share/tap_transfer_state_machine.dart';
import 'package:localsend_app/util/tap_to_share/desktop_tap_coordinator.dart';
import 'package:localsend_app/util/tap_to_share/peer_tap_matcher.dart';
import 'package:localsend_app/util/tap_to_share/tap_security_policy.dart';

void main() {
  const desktopFp = 'DESKTOP00112233445566778899AABBCCDDEEFF';
  const phoneFp = 'PHONE00112233445566778899AABBCCDDEEFF00';

  const favoritePhone = FavoriteDevice(
    id: 'fav-phone-1',
    fingerprint: phoneFp,
    ip: '192.168.1.50',
    port: 53317,
    alias: 'Ahmed Samsung',
  );

  test('AC-1: Phone -> Desktop transitions armed desktop to matched as receiver', () {
    final coordinator = DesktopTapCoordinator(
      capability: const DesktopTapCapability(
        isDesktopPlatform: true,
        hasImuSensors: false,
        hasBluetoothAdapter: true,
      ),
      securityGuard: TapSecurityPolicyGuard(localFingerprint: desktopFp),
    );
    final stateMachine = TapTransferStateMachineController()..arm(selectedFiles: const []);

    final eval = coordinator.handleIncomingMobileTap(
      announcement: const PeerTapAnnouncement(
        senderFingerprint: phoneFp,
        impactTimestampUs: 1000000,
        nonce: 'phone-nonce-1',
        peakLinearAccelMps2: 14.2,
        posture: DevicePosture.tilted,
        dirX: 0.0,
        dirY: 1.0,
        dirZ: 0.0,
        hasSelectedFiles: true,
      ),
      settings: const TapToShareSettings(
        securityMode: TapToShareSecurityMode.favoritesOnly,
      ),
      favorites: const [favoritePhone],
      stateMachine: stateMachine,
      correctedPeerTimestampUs: 1000000,
      nowLocalUs: 1020000,
    );

    expect(eval.accepted, isTrue);
    expect(eval.role, TapTransferRole.receiver);
    expect(eval.requiresManualConfirmation, isTrue);
    expect(stateMachine.state.phase, TapTransferPhase.matched);
    expect(stateMachine.state.role, TapTransferRole.receiver);
    stateMachine.dispose();
  });

  test('AC-2: Desktop -> Phone transitions armed desktop with files to matched as sender with lockedFiles frozen', () {
    final coordinator = DesktopTapCoordinator(
      capability: const DesktopTapCapability(
        isDesktopPlatform: true,
        hasImuSensors: false,
        hasBluetoothAdapter: true,
      ),
      securityGuard: TapSecurityPolicyGuard(localFingerprint: desktopFp),
    );
    final stateMachine = TapTransferStateMachineController()..arm(selectedFiles: const ['D:/docs/report.pdf', 'D:/docs/slides.pptx']);

    final eval = coordinator.handleIncomingMobileTap(
      announcement: const PeerTapAnnouncement(
        senderFingerprint: phoneFp,
        impactTimestampUs: 2000000,
        nonce: 'phone-nonce-2',
        peakLinearAccelMps2: 15.0,
        posture: DevicePosture.tilted,
        dirX: 0.0,
        dirY: 1.0,
        dirZ: 0.0,
        hasSelectedFiles: false,
      ),
      settings: const TapToShareSettings(
        securityMode: TapToShareSecurityMode.favoritesOnly,
      ),
      favorites: const [favoritePhone],
      stateMachine: stateMachine,
      correctedPeerTimestampUs: 2000000,
      nowLocalUs: 2015000,
    );

    expect(eval.accepted, isTrue);
    expect(eval.role, TapTransferRole.sender);
    expect(stateMachine.state.phase, TapTransferPhase.matched);
    expect(stateMachine.state.lockedFiles, const ['D:/docs/report.pdf', 'D:/docs/slides.pptx']);
    stateMachine.dispose();
  });

  test('AC-3: Mandatory manual confirmation (R4.8) enforced even when autoAcceptFavorites is true', () {
    final coordinator = DesktopTapCoordinator(
      capability: const DesktopTapCapability(
        isDesktopPlatform: true,
        hasImuSensors: false,
        hasBluetoothAdapter: true,
      ),
      securityGuard: TapSecurityPolicyGuard(localFingerprint: desktopFp),
    );
    final stateMachine = TapTransferStateMachineController()..arm(selectedFiles: const []);

    final eval = coordinator.handleIncomingMobileTap(
      announcement: const PeerTapAnnouncement(
        senderFingerprint: phoneFp,
        impactTimestampUs: 3000000,
        nonce: 'phone-nonce-3',
        peakLinearAccelMps2: 13.5,
        posture: DevicePosture.tilted,
        dirX: 0.0,
        dirY: 1.0,
        dirZ: 0.0,
        hasSelectedFiles: true,
      ),
      settings: const TapToShareSettings(
        securityMode: TapToShareSecurityMode.favoritesOnly,
        autoAcceptFavorites: true,
      ),
      favorites: const [favoritePhone],
      stateMachine: stateMachine,
      correctedPeerTimestampUs: 3000000,
      nowLocalUs: 3010000,
    );

    expect(eval.accepted, isTrue);
    expect(eval.requiresManualConfirmation, isTrue);
    stateMachine.dispose();
  });

  test('AC-4: Works identically in LAN-only mode when desktop has no Bluetooth adapter', () {
    final coordinator = DesktopTapCoordinator(
      capability: const DesktopTapCapability(
        isDesktopPlatform: true,
        hasImuSensors: false,
        hasBluetoothAdapter: false,
      ),
      securityGuard: TapSecurityPolicyGuard(localFingerprint: desktopFp),
    );
    final stateMachine = TapTransferStateMachineController()..arm(selectedFiles: const ['D:/archive.zip']);

    final eval = coordinator.handleIncomingMobileTap(
      announcement: const PeerTapAnnouncement(
        senderFingerprint: phoneFp,
        impactTimestampUs: 4000000,
        nonce: 'phone-nonce-4',
        peakLinearAccelMps2: 16.0,
        posture: DevicePosture.tilted,
        dirX: 0.0,
        dirY: 1.0,
        dirZ: 0.0,
        hasSelectedFiles: false,
      ),
      settings: const TapToShareSettings(
        securityMode: TapToShareSecurityMode.favoritesOnly,
      ),
      favorites: const [favoritePhone],
      stateMachine: stateMachine,
      correctedPeerTimestampUs: 4000000,
      nowLocalUs: 4020000,
    );

    expect(eval.accepted, isTrue);
    expect(eval.usedLanOnlyFallback, isTrue);
    expect(eval.role, TapTransferRole.sender);
    stateMachine.dispose();
  });
}
