import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/model/tap_to_share/impact_event.dart';
import 'package:localsend_app/provider/tap_to_share/tap_transfer_state_machine.dart';
import 'package:localsend_app/widget/tap_to_share/tap_to_share_overlay.dart';
import 'package:refena_flutter/refena_flutter.dart';

DetectedTapEvent _sampleTap() {
  return const DetectedTapEvent(
    impactTimestampUs: 1000000,
    peakLinearAccelMps2: 16.0,
    peakJerkMps3: 1800.0,
    preImpactGyroRms: 0.2,
    duringImpactGyroPeak: 0.4,
    postImpactAccelRms: 0.15,
    postImpactGyroRms: 0.25,
    posture: DevicePosture.tilted,
    orientation: Quaternion.identity,
    dirX: 0.5,
    dirY: 0.866,
    dirZ: 0.0,
  );
}

void main() {
  group('Spec 006 — TapToShareOverlayCard & TapRipplePainter', () {
    testWidgets('AC-1 & AC-2: decoupled from animation (reduceMotion=true), triggers haptic once on match, and confirms transfer', (tester) async {
      final container = RefenaContainer();
      final controller = container.notifier(tapTransferStateMachineProvider);
      var hapticCount = 0;

      await tester.pumpWidget(
        RefenaScope.withContainer(
          container: container,
          child: MaterialApp(
            home: Scaffold(
              body: TapToShareOverlayCard(
                reduceMotion: true,
                peerDisplayName: 'Office Pixel',
                onHapticFeedback: () {
                  hapticCount++;
                },
              ),
            ),
          ),
        ),
      );

      // Initially idle -> hidden.
      expect(find.byType(Card), findsNothing);

      controller.arm(selectedFiles: const ['/doc1.pdf', '/doc2.pdf']);
      controller.onLocalTapDetected(_sampleTap(), localNonce: 'local-n-1');
      await tester.pump();
      expect(find.textContaining('Tap Detected'), findsOneWidget);
      expect(hapticCount, 0);

      controller.onPeerMatched(
        peerFingerprint: '1234567890ABCDEF11223344',
        peerNonce: 'peer-n-1',
        peerHasFiles: false,
      );
      await tester.pump();

      // Haptic fires once on match and shows truncated 8-char fingerprint + locked file count.
      expect(hapticCount, 1);
      expect(find.textContaining('Office Pixel (12345678)'), findsOneWidget);
      expect(find.textContaining('2 locked file(s)'), findsOneWidget);

      await tester.tap(find.text('Confirm Transfer'));
      await tester.pumpAndSettle();

      expect(container.read(tapTransferStateMachineProvider).phase, TapTransferPhase.done);
      expect(find.text('Tap-to-Share Complete'), findsOneWidget);
    });

    testWidgets('AC-3: resolves TapTransferRole.conflict via overlay buttons', (tester) async {
      final container = RefenaContainer();
      final controller = container.notifier(tapTransferStateMachineProvider);

      controller.arm(selectedFiles: const ['/photo.png']);
      controller.onLocalTapDetected(_sampleTap(), localNonce: 'conflict-local');
      controller.onPeerMatched(
        peerFingerprint: 'AABBCCDDEEFF0011',
        peerNonce: 'conflict-peer',
        peerHasFiles: true,
      );

      await tester.pumpWidget(
        RefenaScope.withContainer(
          container: container,
          child: MaterialApp(
            home: Scaffold(
              body: TapToShareOverlayCard(
                reduceMotion: true,
                onHapticFeedback: () {},
              ),
            ),
          ),
        ),
      );

      expect(find.text('Send My Files (1)'), findsOneWidget);
      expect(find.text('Receive Peer Files'), findsOneWidget);

      await tester.tap(find.text('Send My Files (1)'));
      await tester.pump();

      expect(container.read(tapTransferStateMachineProvider).role, TapTransferRole.sender);
      expect(container.read(tapTransferStateMachineProvider).phase, TapTransferPhase.confirming);
    });

    testWidgets('AC-4 & AC-5: renders cleanly in Dark theme + RTL + 1.8x text scale and passes WCAG guidelines', (tester) async {
      final container = RefenaContainer();
      final controller = container.notifier(tapTransferStateMachineProvider);

      controller.arm(selectedFiles: const ['/arabic_rtl_test.pdf']);
      controller.onLocalTapDetected(_sampleTap(), localNonce: 'rtl-local');
      controller.onPeerMatched(
        peerFingerprint: 'FEDCBA9876543210',
        peerNonce: 'rtl-peer',
        peerHasFiles: false,
      );

      await tester.pumpWidget(
        RefenaScope.withContainer(
          container: container,
          child: MaterialApp(
            theme: ThemeData.dark(useMaterial3: true),
            builder: (context, child) {
              return Directionality(
                textDirection: TextDirection.rtl,
                child: MediaQuery(
                  data: MediaQuery.of(context).copyWith(
                    textScaler: const TextScaler.linear(1.8),
                    disableAnimations: true,
                  ),
                  child: child!,
                ),
              );
            },
            home: Scaffold(
              body: SingleChildScrollView(
                child: TapToShareOverlayCard(
                  peerDisplayName: 'جهاز أحمد',
                  onHapticFeedback: () {},
                ),
              ),
            ),
          ),
        ),
      );

      expect(tester.takeException(), isNull);
      expect(find.textContaining('FEDCBA98'), findsOneWidget);

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
