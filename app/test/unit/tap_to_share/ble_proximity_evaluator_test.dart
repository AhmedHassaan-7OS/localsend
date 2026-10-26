import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/util/tap_to_share/ble_proximity_evaluator.dart';

void main() {
  test('AC-1: EMA filter smooths RSSI samples and classifies touching, near, and far zones', () {
    final evaluator = BleProximityEvaluator(emaAlpha: 0.5);

    evaluator.recordSample(
      const BleRssiSample(
        peerFingerprint: 'PEER_TOUCHING',
        rssiDbm: -42,
        timestampUs: 100000,
      ),
    );
    evaluator.recordSample(
      const BleRssiSample(
        peerFingerprint: 'PEER_TOUCHING',
        rssiDbm: -46,
        timestampUs: 150000,
      ),
    );

    final touching = evaluator.evaluatePeer(
      'PEER_TOUCHING',
      nowUs: 200000,
      isBleAvailable: true,
    );
    expect(touching.zone, BleProximityZone.touching);
    expect(touching.smoothedRssiDbm, closeTo(-44.0, 1e-6));
    expect(touching.allowed, isTrue);

    evaluator.recordSample(
      const BleRssiSample(
        peerFingerprint: 'PEER_NEAR',
        rssiDbm: -55,
        timestampUs: 100000,
      ),
    );
    final near = evaluator.evaluatePeer(
      'PEER_NEAR',
      nowUs: 200000,
      isBleAvailable: true,
    );
    expect(near.zone, BleProximityZone.near);
    expect(near.allowed, isTrue);

    evaluator.recordSample(
      const BleRssiSample(
        peerFingerprint: 'PEER_FAR',
        rssiDbm: -85,
        timestampUs: 100000,
      ),
    );
    final far = evaluator.evaluatePeer(
      'PEER_FAR',
      nowUs: 200000,
      isBleAvailable: true,
    );
    expect(far.zone, BleProximityZone.far);
    expect(far.allowed, isFalse);
  });

  test('AC-2: Touching peer (-42 dBm) outranks simultaneous peer in another room (-82 dBm, rejected)', () {
    final evaluator = BleProximityEvaluator();
    evaluator.recordSample(
      const BleRssiSample(
        peerFingerprint: 'ROOM_A_PEER',
        rssiDbm: -42,
        timestampUs: 500000,
      ),
    );
    evaluator.recordSample(
      const BleRssiSample(
        peerFingerprint: 'ROOM_B_PEER',
        rssiDbm: -82,
        timestampUs: 500000,
      ),
    );

    final peerA = evaluator.evaluatePeer('ROOM_A_PEER', nowUs: 550000, isBleAvailable: true);
    final peerB = evaluator.evaluatePeer('ROOM_B_PEER', nowUs: 550000, isBleAvailable: true);

    expect(peerA.allowed, isTrue);
    expect(peerB.allowed, isFalse);
    expect(peerA.proximityScore, greaterThan(0.75));
    expect(peerB.proximityScore, 0.0);
  });

  test('AC-3: Degrades gracefully without blocking LAN matching when BLE is unavailable', () {
    final evaluator = BleProximityEvaluator();
    final fallback = evaluator.evaluatePeer(
      'ANY_LAN_PEER',
      nowUs: 1000000,
      isBleAvailable: false,
    );

    expect(fallback.allowed, isTrue);
    expect(fallback.usedFallback, isTrue);
    expect(fallback.zone, BleProximityZone.unknown);
    expect(fallback.proximityScore, 0.5);
  });
}
