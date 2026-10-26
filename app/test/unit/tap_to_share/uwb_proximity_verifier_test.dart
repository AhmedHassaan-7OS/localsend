import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/util/tap_to_share/ble_proximity_evaluator.dart';
import 'package:localsend_app/util/tap_to_share/uwb_proximity_verifier.dart';

void main() {
  test('AC-1: Confirms centimeter contact (<= 15.0 cm) with confidence >= 0.95 when both peers support UWB', () {
    final verifier = UwbProximityVerifier();
    verifier.recordUwbSample(
      const UwbRangingSample(
        peerFingerprint: 'PEER_UWB_1',
        distanceCm: 4.5,
        azimuthDeg: 12.0,
        timestampUs: 1000000,
      ),
    );

    final result = verifier.verify(
      peerFingerprint: 'PEER_UWB_1',
      nowUs: 1050000,
      localSupportsUwb: true,
      peerSupportsUwb: true,
      isBleAvailable: true,
    );

    expect(result.verified, isTrue);
    expect(result.usedUwb, isTrue);
    expect(result.confidence, greaterThanOrEqualTo(0.95));
    expect(result.measuredDistanceCm, 4.5);
  });

  test('AC-2: Rejects non-contact peer at 65 cm on the same desk even if BLE RSSI is strong', () {
    final ble = BleProximityEvaluator()
      ..recordSample(
        const BleRssiSample(
          peerFingerprint: 'PEER_DESK_65CM',
          rssiDbm: -44,
          timestampUs: 1000000,
        ),
      );
    final verifier = UwbProximityVerifier(bleFallbackEvaluator: ble)
      ..recordUwbSample(
        const UwbRangingSample(
          peerFingerprint: 'PEER_DESK_65CM',
          distanceCm: 65.0,
          azimuthDeg: 5.0,
          timestampUs: 1000000,
        ),
      );

    final result = verifier.verify(
      peerFingerprint: 'PEER_DESK_65CM',
      nowUs: 1050000,
      localSupportsUwb: true,
      peerSupportsUwb: true,
      isBleAvailable: true,
    );

    expect(result.verified, isFalse);
    expect(result.usedUwb, isTrue);
    expect(result.measuredDistanceCm, 65.0);
  });

  test('AC-3: Falls back smoothly to BleProximityEvaluator when either peer lacks UWB', () {
    final ble = BleProximityEvaluator()
      ..recordSample(
        const BleRssiSample(
          peerFingerprint: 'PEER_NO_UWB',
          rssiDbm: -45,
          timestampUs: 2000000,
        ),
      );
    final verifier = UwbProximityVerifier(bleFallbackEvaluator: ble);

    final result = verifier.verify(
      peerFingerprint: 'PEER_NO_UWB',
      nowUs: 2050000,
      localSupportsUwb: false,
      peerSupportsUwb: true,
      isBleAvailable: true,
    );

    expect(result.verified, isTrue);
    expect(result.usedUwb, isFalse);
    expect(result.fallbackReason, UwbFallbackReason.localUwbUnsupported);
    expect(result.confidence, greaterThan(0.7));
  });
}
