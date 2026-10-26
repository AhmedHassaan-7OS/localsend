import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/model/tap_to_share/impact_event.dart';
import 'package:localsend_app/util/tap_to_share/peer_tap_matcher.dart';

DetectedTapEvent _sampleLocalTap({
  required int timestampUs,
  double peakLinearAccelMps2 = 16.0,
}) {
  return DetectedTapEvent(
    impactTimestampUs: timestampUs,
    peakLinearAccelMps2: peakLinearAccelMps2,
    peakJerkMps3: 1800.0,
    preImpactGyroRms: 0.2,
    duringImpactGyroPeak: 0.4,
    postImpactAccelRms: 0.15,
    postImpactGyroRms: 0.25,
    posture: DevicePosture.tilted,
    orientation: Quaternion.identity,
    dirX: 0.0,
    dirY: 1.0,
    dirZ: 0.0,
  );
}

void main() {
  group('Spec 003 — PeerTapMatcher & PeerClockEstimator', () {
    test('AC-1: matches two devices accurately despite a deliberate +45 s clock skew after NTP ping/pong', () {
      const localFp = 'AAAA1111BBBB2222CCCC3333DDDD4444EEEE5555FFFF66660000111122223333';
      const peerFp = '9999888877776666555544443333222211110000AAAABBBBCCCCDDDDEEEEFFFF';
      const skewUs = 45 * 1000 * 1000; // +45 seconds on peer clock
      const oneWayDelayUs = 12000; // 12 ms one-way latency

      final matcher = PeerTapMatcher(localFingerprint: localFp);

      // Exchange 3 ping/pong samples to calibrate clock offset.
      for (var i = 0; i < 3; i++) {
        final t1 = 1000000 + (i * 500000);
        final t2 = t1 + oneWayDelayUs + skewUs;
        final t3 = t2 + 1000; // 1 ms peer processing time
        final t4 = t1 + (oneWayDelayUs * 2) + 1000;
        matcher.clockEstimator.recordSample(
          peerFp,
          ClockSyncSample(
            t1LocalSendUs: t1,
            t2PeerRecvUs: t2,
            t3PeerSendUs: t3,
            t4LocalRecvUs: t4,
          ),
        );
      }

      final estimate = matcher.clockEstimator.estimateFor(peerFp)!;
      expect(estimate.clockOffsetUs, skewUs);
      expect(estimate.minRttUs, oneWayDelayUs * 2);

      // Physical tap happens at t_local = 5,000,000 us.
      // Peer records the same tap at t_peer = 5,000,000 + 45,000,000 + 8,000 us.
      const tapLocalUs = 5000000;
      matcher.recordLocalTap(
        _sampleLocalTap(timestampUs: tapLocalUs, peakLinearAccelMps2: 18.0),
        localNonce: 'nonce-local-1',
        hasSelectedFiles: true,
      );

      final accepted = matcher.receivePeerAnnouncement(
        const PeerTapAnnouncement(
          senderFingerprint: peerFp,
          impactTimestampUs: tapLocalUs + skewUs + 8000,
          nonce: 'nonce-peer-1',
          peakLinearAccelMps2: 17.2,
          posture: DevicePosture.tilted,
          dirX: 0.0,
          dirY: -1.0,
          dirZ: 0.0,
          hasSelectedFiles: false,
        ),
        receivedAtLocalUs: tapLocalUs + 20000,
      );
      expect(accepted, isTrue);

      final result = matcher.evaluate(nowLocalUs: tapLocalUs + 25000);
      expect(result.status, PeerMatchStatus.matched);
      expect(result.matchedCandidate, isNotNull);
      expect(result.matchedCandidate!.announcement.senderFingerprint, peerFp);
      expect(result.matchedCandidate!.timestampDeltaUs, 8000);
    });

    test('AC-2: dynamically widens the matching window under high network latency/jitter up to maxMatchingWindowUs', () {
      const localFp = 'LOCAL_FP_001';
      const peerFp = 'PEER_FP_002';

      final matcher = PeerTapMatcher(
        localFingerprint: localFp,
        baseMatchingWindowUs: 120000,
        maxMatchingWindowUs: 400000,
      );

      // Simulate high RTT (240 ms) and jitter.
      matcher.clockEstimator.recordSample(
        peerFp,
        const ClockSyncSample(
          t1LocalSendUs: 1000000,
          t2PeerRecvUs: 1080000,
          t3PeerSendUs: 1082000,
          t4LocalRecvUs: 1162000, // RTT = 160 ms
        ),
      );
      matcher.clockEstimator.recordSample(
        peerFp,
        const ClockSyncSample(
          t1LocalSendUs: 2000000,
          t2PeerRecvUs: 2140000,
          t3PeerSendUs: 2142000,
          t4LocalRecvUs: 2282000, // RTT = 280 ms
        ),
      );

      final widenedWindowUs = matcher.effectiveWindowUsForPeer(peerFp);
      expect(widenedWindowUs, greaterThan(200000));
      expect(widenedWindowUs, lessThanOrEqualTo(400000));

      // A delta of 180 ms (180,000 us) would fail the base 120 ms window, but succeeds with the widened window.
      matcher.recordLocalTap(
        _sampleLocalTap(timestampUs: 5000000),
        localNonce: 'local-n2',
        hasSelectedFiles: true,
      );
      matcher.receivePeerAnnouncement(
        const PeerTapAnnouncement(
          senderFingerprint: peerFp,
          impactTimestampUs: 5000000 + 180000,
          nonce: 'peer-n2',
          peakLinearAccelMps2: 15.5,
          posture: DevicePosture.tilted,
          dirX: 0.0,
          dirY: 1.0,
          dirZ: 0.0,
          hasSelectedFiles: false,
        ),
        receivedAtLocalUs: 5250000,
      );

      final result = matcher.evaluate(nowLocalUs: 5260000);
      expect(result.status, PeerMatchStatus.matched);
      expect(result.matchedCandidate!.estimatedRttUs, 280000);
      expect(result.matchedCandidate!.effectiveWindowUs, widenedWindowUs);
    });

    test('AC-3: rejects single-sided impacts (local tap without peer tap, or peer tap without local tap)', () {
      const localFp = 'LOCAL_FP_001';
      const peerFp = 'PEER_FP_002';

      final matcher = PeerTapMatcher(localFingerprint: localFp);

      // Case A: Peer reports a tap, but local phone never tapped.
      matcher.receivePeerAnnouncement(
        const PeerTapAnnouncement(
          senderFingerprint: peerFp,
          impactTimestampUs: 3000000,
          nonce: 'peer-only-nonce',
          peakLinearAccelMps2: 16.0,
          posture: DevicePosture.tilted,
          dirX: 0.0,
          dirY: 1.0,
          dirZ: 0.0,
          hasSelectedFiles: true,
        ),
        receivedAtLocalUs: 3010000,
      );
      final peerOnlyResult = matcher.evaluate(nowLocalUs: 3020000);
      expect(peerOnlyResult.status, PeerMatchStatus.noMatch);
      expect(peerOnlyResult.rejectionReason, 'no_local_tap');

      // Case B: Local phone bumps a desk long after the peer announcement expired, with no matching peer tap.
      matcher.recordLocalTap(
        _sampleLocalTap(timestampUs: 9000000),
        localNonce: 'local-only-nonce',
        hasSelectedFiles: true,
      );
      final localOnlyResult = matcher.evaluate(nowLocalUs: 9050000);
      expect(localOnlyResult.status, PeerMatchStatus.noMatch);
      expect(localOnlyResult.rejectionReason, 'no_peer_within_window');
    });

    test('AC-4: disambiguates 3+ simultaneous devices or flags ambiguous when top two scores are too close', () {
      const localFp = 'DEVICE_A';
      const peerB = 'DEVICE_B';
      const peerC = 'DEVICE_C';

      final matcher = PeerTapMatcher(
        localFingerprint: localFp,
        ambiguityScoreMargin: 0.15,
      );

      // Subcase 1: Device B is clearly aligned (delta = 5 ms, matching peak), Device C is far (delta = 105 ms, weak peak).
      matcher.recordLocalTap(
        _sampleLocalTap(timestampUs: 1000000, peakLinearAccelMps2: 18.0),
        localNonce: 'nonce-a-1',
        hasSelectedFiles: true,
      );
      matcher.receivePeerAnnouncement(
        const PeerTapAnnouncement(
          senderFingerprint: peerB,
          impactTimestampUs: 1005000,
          nonce: 'nonce-b-1',
          peakLinearAccelMps2: 17.8,
          posture: DevicePosture.tilted,
          dirX: 0,
          dirY: 1,
          dirZ: 0,
          hasSelectedFiles: false,
        ),
        receivedAtLocalUs: 1010000,
      );
      matcher.receivePeerAnnouncement(
        const PeerTapAnnouncement(
          senderFingerprint: peerC,
          impactTimestampUs: 1105000,
          nonce: 'nonce-c-1',
          peakLinearAccelMps2: 6.0,
          posture: DevicePosture.tilted,
          dirX: 0,
          dirY: 1,
          dirZ: 0,
          hasSelectedFiles: false,
        ),
        receivedAtLocalUs: 1110000,
      );

      final clearResult = matcher.evaluate(nowLocalUs: 1115000);
      expect(clearResult.status, PeerMatchStatus.matched);
      expect(clearResult.matchedCandidate!.announcement.senderFingerprint, peerB);

      // Subcase 2: Device B and Device C report nearly identical timestamps and magnitudes -> ambiguous.
      matcher.recordLocalTap(
        _sampleLocalTap(timestampUs: 3000000, peakLinearAccelMps2: 16.0),
        localNonce: 'nonce-a-2',
        hasSelectedFiles: true,
      );
      matcher.receivePeerAnnouncement(
        const PeerTapAnnouncement(
          senderFingerprint: peerB,
          impactTimestampUs: 3008000,
          nonce: 'nonce-b-2',
          peakLinearAccelMps2: 15.8,
          posture: DevicePosture.tilted,
          dirX: 0,
          dirY: 1,
          dirZ: 0,
          hasSelectedFiles: false,
        ),
        receivedAtLocalUs: 3015000,
      );
      matcher.receivePeerAnnouncement(
        const PeerTapAnnouncement(
          senderFingerprint: peerC,
          impactTimestampUs: 3010000,
          nonce: 'nonce-c-2',
          peakLinearAccelMps2: 16.1,
          posture: DevicePosture.tilted,
          dirX: 0,
          dirY: 1,
          dirZ: 0,
          hasSelectedFiles: false,
        ),
        receivedAtLocalUs: 3016000,
      );

      final ambiguousResult = matcher.evaluate(nowLocalUs: 3020000);
      expect(ambiguousResult.status, PeerMatchStatus.ambiguous);
      expect(ambiguousResult.candidates.length, 2);
    });

    test('AC-5: rejects self-echo announcements and replayed (senderFingerprint, nonce) pairs', () {
      const localFp = 'LOCAL_DEVICE_FP';
      const peerFp = 'PEER_DEVICE_FP';

      final matcher = PeerTapMatcher(localFingerprint: localFp);

      // Self-echo must be rejected.
      final selfAccepted = matcher.receivePeerAnnouncement(
        const PeerTapAnnouncement(
          senderFingerprint: localFp,
          impactTimestampUs: 1000000,
          nonce: 'self-nonce',
          peakLinearAccelMps2: 15.0,
          posture: DevicePosture.tilted,
          dirX: 0,
          dirY: 1,
          dirZ: 0,
          hasSelectedFiles: true,
        ),
        receivedAtLocalUs: 1005000,
      );
      expect(selfAccepted, isFalse);

      // First legitimate peer announcement is accepted.
      const packet = PeerTapAnnouncement(
        senderFingerprint: peerFp,
        impactTimestampUs: 2000000,
        nonce: 'unique-nonce-42',
        peakLinearAccelMps2: 15.0,
        posture: DevicePosture.tilted,
        dirX: 0,
        dirY: 1,
        dirZ: 0,
        hasSelectedFiles: true,
      );
      expect(matcher.receivePeerAnnouncement(packet, receivedAtLocalUs: 2005000), isTrue);

      // Replaying the exact same (senderFingerprint, nonce) within TTL is rejected.
      expect(matcher.receivePeerAnnouncement(packet, receivedAtLocalUs: 2500000), isFalse);
      expect(truncateFingerprint('AABBCCDDEEFF00112233'), 'AABBCCDD');
    });
  });
}
