import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/model/persistence/favorite_device.dart';
import 'package:localsend_app/model/tap_to_share/impact_event.dart';
import 'package:localsend_app/pages/tabs/settings_tab_tap_to_share_section.dart';
import 'package:localsend_app/provider/tap_to_share/tap_security_provider.dart';
import 'package:localsend_app/util/tap_to_share/peer_tap_matcher.dart';
import 'package:localsend_app/util/tap_to_share/tap_security_policy.dart';
import 'package:refena_flutter/refena_flutter.dart';

PeerTapAnnouncement _packet({
  required String senderFingerprint,
  required String nonce,
  required int timestampUs,
}) {
  return PeerTapAnnouncement(
    senderFingerprint: senderFingerprint,
    impactTimestampUs: timestampUs,
    nonce: nonce,
    peakLinearAccelMps2: 16.0,
    posture: DevicePosture.tilted,
    dirX: 0,
    dirY: 1,
    dirZ: 0,
    hasSelectedFiles: true,
  );
}

void main() {
  group('Spec 005 — TapSecurityPolicyGuard & TapToShareSettings', () {
    const localFp = 'LOCAL_CERT_SHA256_FINGERPRINT_0001';
    const trustedFavFp = 'TRUSTED_FAV_SHA256_FINGERPRINT_9999';
    const attackerFp = 'ATTACKER_SHA256_FINGERPRINT_6666';

    final favorites = <FavoriteDevice>[
      FavoriteDevice.fromValues(
        fingerprint: trustedFavFp,
        ip: '192.168.1.25',
        port: 53317,
        alias: 'Ahmed iPhone',
      ),
    ];

    test('AC-1: defaults to disabled + autoAcceptFavorites=false, and enabling defaults to favoritesOnly', () {
      const initial = TapToShareSettings();
      expect(initial.securityMode, TapToShareSecurityMode.disabled);
      expect(initial.isEnabled, isFalse);
      expect(initial.autoAcceptFavorites, isFalse);

      final enabled = initial.withEnabled(true);
      expect(enabled.isEnabled, isTrue);
      expect(enabled.securityMode, TapToShareSecurityMode.favoritesOnly);

      final guard = TapSecurityPolicyGuard(localFingerprint: localFp);
      final decisionWhenDisabled = guard.evaluateAnnouncement(
        announcement: _packet(senderFingerprint: trustedFavFp, nonce: 'n-1', timestampUs: 1000000),
        settings: initial,
        favorites: favorites,
        correctedPeerTimestampUs: 1000000,
        nowLocalUs: 1005000,
      );
      expect(decisionWhenDisabled.allowed, isFalse);
      expect(decisionWhenDisabled.reason, TapSecurityDecisionReason.featureDisabled);
    });

    test('AC-2: blocks alias-spoofing attacker whose TLS certificate fingerprint is not in Favorites', () {
      final guard = TapSecurityPolicyGuard(localFingerprint: localFp);
      const settings = TapToShareSettings(
        securityMode: TapToShareSecurityMode.favoritesOnly,
        autoAcceptFavorites: true,
      );

      // Attacker claims the exact same alias ("Ahmed iPhone") as the user's Favorite device,
      // but presents a different TLS certificate fingerprint (`attackerFp`).
      final spoofDecision = guard.evaluateAnnouncement(
        announcement: _packet(senderFingerprint: attackerFp, nonce: 'spoof-nonce-1', timestampUs: 2000000),
        settings: settings,
        favorites: favorites,
        correctedPeerTimestampUs: 2000000,
        nowLocalUs: 2010000,
        claimedAlias: 'Ahmed iPhone',
      );
      expect(spoofDecision.allowed, isFalse);
      expect(spoofDecision.reason, TapSecurityDecisionReason.untrustedPeer);
      expect(spoofDecision.sanitizedLogMessage.contains(attackerFp), isFalse); // Truncated for privacy

      // Real favorite with matching TLS fingerprint succeeds.
      final validFavDecision = guard.evaluateAnnouncement(
        announcement: _packet(senderFingerprint: trustedFavFp, nonce: 'fav-nonce-1', timestampUs: 2000000),
        settings: settings,
        favorites: favorites,
        correctedPeerTimestampUs: 2000000,
        nowLocalUs: 2010000,
        claimedAlias: 'Renamed Device',
      );
      expect(validFavDecision.allowed, isTrue);
      expect(validFavDecision.isFavoritePeer, isTrue);
    });

    test('AC-3: blocks stale packets older than maxAnnouncementAgeUs (3s) and replayed nonces', () {
      final guard = TapSecurityPolicyGuard(
        localFingerprint: localFp,
        maxAnnouncementAgeUs: 3000000,
      );
      const settings = TapToShareSettings(securityMode: TapToShareSecurityMode.favoritesOnly);

      // Subcase A: Stale packet (age = 4.5 seconds > 3.0 seconds).
      final staleDecision = guard.evaluateAnnouncement(
        announcement: _packet(senderFingerprint: trustedFavFp, nonce: 'stale-nonce', timestampUs: 1000000),
        settings: settings,
        favorites: favorites,
        correctedPeerTimestampUs: 1000000,
        nowLocalUs: 5500000,
      );
      expect(staleDecision.allowed, isFalse);
      expect(staleDecision.reason, TapSecurityDecisionReason.expiredTimestamp);

      // Subcase B: Fresh packet succeeds once, then replay is rejected.
      final freshPacket = _packet(senderFingerprint: trustedFavFp, nonce: 'replay-nonce-7', timestampUs: 6000000);
      final firstAttempt = guard.evaluateAnnouncement(
        announcement: freshPacket,
        settings: settings,
        favorites: favorites,
        correctedPeerTimestampUs: 6000000,
        nowLocalUs: 6020000,
      );
      expect(firstAttempt.allowed, isTrue);

      final replayAttempt = guard.evaluateAnnouncement(
        announcement: freshPacket,
        settings: settings,
        favorites: favorites,
        correctedPeerTimestampUs: 6000000,
        nowLocalUs: 6100000,
      );
      expect(replayAttempt.allowed, isFalse);
      expect(replayAttempt.reason, TapSecurityDecisionReason.replayedNonce);
    });

    test('AC-4: enforces per-peer sliding-window rate limiting against packet flooding', () {
      final guard = TapSecurityPolicyGuard(
        localFingerprint: localFp,
        maxAttemptsPerWindow: 3,
        rateLimitWindowUs: 10000000, // 10s
      );
      const settings = TapToShareSettings(securityMode: TapToShareSecurityMode.everyoneWithConfirmation);

      for (var i = 1; i <= 3; i++) {
        final decision = guard.evaluateAnnouncement(
          announcement: _packet(
            senderFingerprint: attackerFp,
            nonce: 'flood-nonce-$i',
            timestampUs: 1000000 + (i * 100000),
          ),
          settings: settings,
          favorites: favorites,
          correctedPeerTimestampUs: 1000000 + (i * 100000),
          nowLocalUs: 1000000 + (i * 100000) + 5000,
        );
        expect(decision.allowed, isTrue);
      }

      // 4th attempt within 10 seconds is blocked with `rateLimited`.
      final fourthDecision = guard.evaluateAnnouncement(
        announcement: _packet(
          senderFingerprint: attackerFp,
          nonce: 'flood-nonce-4',
          timestampUs: 1500000,
        ),
        settings: settings,
        favorites: favorites,
        correctedPeerTimestampUs: 1500000,
        nowLocalUs: 1505000,
      );
      expect(fourthDecision.allowed, isFalse);
      expect(fourthDecision.reason, TapSecurityDecisionReason.rateLimited);
    });

    test('AC-5: non-favorite peers in everyoneWithConfirmation always require manual confirmation even when autoAcceptFavorites=true', () {
      final guard = TapSecurityPolicyGuard(localFingerprint: localFp);
      const settings = TapToShareSettings(
        securityMode: TapToShareSecurityMode.everyoneWithConfirmation,
        autoAcceptFavorites: true,
      );

      final strangerDecision = guard.evaluateAnnouncement(
        announcement: _packet(senderFingerprint: attackerFp, nonce: 'stranger-1', timestampUs: 2000000),
        settings: settings,
        favorites: favorites,
        correctedPeerTimestampUs: 2000000,
        nowLocalUs: 2010000,
      );
      expect(strangerDecision.allowed, isTrue);
      expect(strangerDecision.isFavoritePeer, isFalse);
      expect(strangerDecision.requiresManualConfirmation, isTrue);

      final favoriteDecision = guard.evaluateAnnouncement(
        announcement: _packet(senderFingerprint: trustedFavFp, nonce: 'fav-auto-1', timestampUs: 2000000),
        settings: settings,
        favorites: favorites,
        correctedPeerTimestampUs: 2000000,
        nowLocalUs: 2010000,
      );
      expect(favoriteDecision.allowed, isTrue);
      expect(favoriteDecision.isFavoritePeer, isTrue);
      expect(favoriteDecision.requiresManualConfirmation, isFalse);
    });

    testWidgets('AC-6: TapToShareSettingsSection toggles modes and satisfies WCAG accessibility guidelines', (tester) async {
      final container = RefenaContainer();

      await tester.pumpWidget(
        RefenaScope.withContainer(
          container: container,
          child: MaterialApp(
            theme: ThemeData.light(useMaterial3: true),
            home: const Scaffold(
              body: SingleChildScrollView(
                child: TapToShareSettingsSection(),
              ),
            ),
          ),
        ),
      );

      expect(find.text('Tap-to-Share Security'), findsOneWidget);
      expect(container.read(tapToShareSettingsProvider).isEnabled, isFalse);

      // Enable Tap-to-Share -> defaults to favoritesOnly.
      await tester.tap(find.byType(SwitchListTile).first);
      await tester.pumpAndSettle();

      expect(container.read(tapToShareSettingsProvider).isEnabled, isTrue);
      expect(container.read(tapToShareSettingsProvider).securityMode, TapToShareSecurityMode.favoritesOnly);

      // Switch to Everyone mode.
      await tester.tap(find.text('Everyone (Ask Every Time)'));
      await tester.pumpAndSettle();
      expect(
        container.read(tapToShareSettingsProvider).securityMode,
        TapToShareSecurityMode.everyoneWithConfirmation,
      );

      final semanticsHandle = tester.ensureSemantics();
      try {
        await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
        await expectLater(tester, meetsGuideline(iOSTapTargetGuideline));
        await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
        await expectLater(tester, meetsGuideline(textContrastGuideline));
      } finally {
        semanticsHandle.dispose();
      }
    });
  });
}
