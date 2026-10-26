import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/model/persistence/favorite_device.dart';
import 'package:localsend_app/model/tap_to_share/impact_event.dart';
import 'package:localsend_app/provider/tap_to_share/tap_transfer_state_machine.dart';
import 'package:localsend_app/util/tap_to_share/desktop_tap_coordinator.dart';
import 'package:localsend_app/util/tap_to_share/peer_tap_matcher.dart';
import 'package:localsend_app/util/tap_to_share/tap_battery_lifecycle_guard.dart';
import 'package:localsend_app/util/tap_to_share/tap_security_policy.dart';
import 'package:localsend_app/util/tap_to_share/tap_udp_coordinator.dart';

void main() {
  test('AC-1: TapBatteryLifecycleGuard enforces R4.2 foreground + screen-on + idle timeout discipline', () {
    final guard = TapBatteryLifecycleGuard(idleTimeoutUs: 60000000); // 60s idle timeout

    // Disabled initially (`R2.2`).
    expect(guard.shouldRunSensors, isFalse);

    // Enabled while foregrounded and screen on at t = 10s.
    expect(
      guard.updateLifecycle(
        featureEnabled: true,
        isAppForegrounded: true,
        isScreenOn: true,
        nowUs: 10000000,
      ),
      isTrue,
    );

    // Transition to background at t = 25s (+15s active).
    expect(
      guard.updateLifecycle(
        isAppForegrounded: false,
        nowUs: 25000000,
      ),
      isFalse,
    );
    expect(guard.totalActiveMicroseconds(nowUs: 40000000), 15000000);

    // Return to foreground at t = 40s, then idle past 60s threshold at t = 110s.
    guard.recordUserActivity(nowUs: 40000000);
    expect(
      guard.updateLifecycle(
        isAppForegrounded: true,
        nowUs: 40000000,
      ),
      isTrue,
    );
    expect(guard.checkIdleTimeout(nowUs: 105000000), isFalse);
    expect(guard.isIdleTimedOut, isTrue);

    // User activity wakes sensors back up.
    expect(guard.recordUserActivity(nowUs: 106000000), isTrue);
    expect(guard.isIdleTimedOut, isFalse);
  });

  test('AC-2: TapUdpCoordinator exchanges live NTP clock_ping/clock_pong and tap_announce over loopback UDP', () async {
    final coordA = TapUdpCoordinator(
      localFingerprint: 'PEER_ALPHA_11223344',
      listenPort: 0,
    );
    final coordB = TapUdpCoordinator(
      localFingerprint: 'PEER_BETA_55667788',
      listenPort: 0,
    );

    await coordA.start(bindAddress: InternetAddress.loopbackIPv4);
    await coordB.start(bindAddress: InternetAddress.loopbackIPv4);

    try {
      final clockSyncFuture = coordA.clockSyncStream.first.timeout(const Duration(seconds: 3));
      coordA.sendClockPing(
        targetAddress: InternetAddress.loopbackIPv4,
        targetPort: coordB.boundPort,
      );
      final estimate = await clockSyncFuture;
      expect(estimate.peerFingerprint, 'PEER_BETA_55667788');
      expect(estimate.sampleCount, 1);

      final receivedFuture = coordB.announcementStream.first.timeout(const Duration(seconds: 3));
      coordA.broadcastTapAnnouncement(
        const PeerTapAnnouncement(
          senderFingerprint: 'PEER_ALPHA_11223344',
          impactTimestampUs: 123456789,
          nonce: 'udp-live-nonce-1',
          peakLinearAccelMps2: 15.8,
          posture: DevicePosture.tilted,
          dirX: 0.0,
          dirY: 1.0,
          dirZ: 0.0,
          hasSelectedFiles: true,
        ),
        knownPeerIps: const ['127.0.0.1'],
        targetPort: coordB.boundPort,
        includeSubnetBroadcast: false,
      );

      final packet = await receivedFuture;
      expect(packet.announcement.senderFingerprint, 'PEER_ALPHA_11223344');
      expect(packet.announcement.nonce, 'udp-live-nonce-1');
      expect(packet.announcement.hasSelectedFiles, isTrue);
    } finally {
      await coordA.dispose();
      await coordB.dispose();
    }
  });

  test('AC-3: End-to-end Mobile<->Desktop flow over live UDP completes transfer and rejects replayed packet', () async {
    const phoneFp = 'PHONE_SAMSUNG_A366B_FINGERPRINT';
    const desktopFp = 'WINDOWS_PC_DESKTOP_FINGERPRINT';

    final phoneUdp = TapUdpCoordinator(localFingerprint: phoneFp, listenPort: 0);
    final desktopUdp = TapUdpCoordinator(localFingerprint: desktopFp, listenPort: 0);

    await phoneUdp.start(bindAddress: InternetAddress.loopbackIPv4);
    await desktopUdp.start(bindAddress: InternetAddress.loopbackIPv4);

    final desktopStateMachine = TapTransferStateMachineController()..arm(selectedFiles: const []);
    final desktopCoordinator = DesktopTapCoordinator(
      capability: const DesktopTapCapability(
        isDesktopPlatform: true,
        hasImuSensors: false,
        hasBluetoothAdapter: false,
      ),
      securityGuard: TapSecurityPolicyGuard(localFingerprint: desktopFp),
    );

    const favPhone = FavoriteDevice(
      id: 'fav-samsung',
      fingerprint: phoneFp,
      ip: '127.0.0.1',
      port: 53317,
      alias: 'Samsung SM-A366B',
    );
    const settings = TapToShareSettings(
      securityMode: TapToShareSecurityMode.favoritesOnly,
      autoAcceptFavorites: true,
    );

    try {
      final sub = desktopUdp.announcementStream.listen((packet) {
        desktopCoordinator.handleIncomingMobileTap(
          announcement: packet.announcement,
          settings: settings,
          favorites: const [favPhone],
          stateMachine: desktopStateMachine,
          correctedPeerTimestampUs: packet.receivedAtLocalUs,
          nowLocalUs: packet.receivedAtLocalUs,
        );
      });

      final nowUs = DateTime.now().microsecondsSinceEpoch;
      final announcement = PeerTapAnnouncement(
        senderFingerprint: phoneFp,
        impactTimestampUs: nowUs,
        nonce: 'e2e-nonce-99',
        peakLinearAccelMps2: 14.9,
        posture: DevicePosture.tilted,
        dirX: 0.0,
        dirY: 1.0,
        dirZ: 0.0,
        hasSelectedFiles: true,
      );

      final packetFuture = desktopUdp.announcementStream.first.timeout(const Duration(seconds: 3));
      phoneUdp.broadcastTapAnnouncement(
        announcement,
        knownPeerIps: const ['127.0.0.1'],
        targetPort: desktopUdp.boundPort,
        includeSubnetBroadcast: false,
      );
      await packetFuture;
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(desktopStateMachine.state.phase, TapTransferPhase.matched);
      expect(desktopStateMachine.state.role, TapTransferRole.receiver);

      // Confirm transfer on desktop -> completes to `done`.
      final ok = await desktopStateMachine.confirmTransfer();
      expect(ok, isTrue);
      expect(desktopStateMachine.state.phase, TapTransferPhase.done);

      // Replay the exact same announcement -> rejected by nonce replay defense.
      desktopStateMachine.arm(selectedFiles: const []);
      final replayEval = desktopCoordinator.handleIncomingMobileTap(
        announcement: announcement,
        settings: settings,
        favorites: const [favPhone],
        stateMachine: desktopStateMachine,
        correctedPeerTimestampUs: nowUs + 1000,
        nowLocalUs: nowUs + 1000,
      );
      expect(replayEval.accepted, isFalse);
      expect(replayEval.reason, TapSecurityDecisionReason.replayedNonce.name);

      await sub.cancel();
    } finally {
      desktopStateMachine.dispose();
      await phoneUdp.dispose();
      await desktopUdp.dispose();
    }
  });
}
