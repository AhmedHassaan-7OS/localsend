import 'package:localsend_app/util/tap_to_share/ble_proximity_evaluator.dart';

/// Centimeter-precision Ultra-Wideband (UWB) ranging reading (`Spec 010`).
class UwbRangingSample {
  final String peerFingerprint;
  final double distanceCm;
  final double azimuthDeg;
  final int timestampUs;

  const UwbRangingSample({
    required this.peerFingerprint,
    required this.distanceCm,
    required this.azimuthDeg,
    required this.timestampUs,
  });
}

/// Reason why [UwbProximityVerifier] fell back to BLE/LAN evaluation (`Spec 010`).
enum UwbFallbackReason {
  none,
  localUwbUnsupported,
  peerUwbUnsupported,
  noRecentUwbSample,
}

/// Result of UWB centimeter contact verification with automatic BLE fallback (`Spec 010`).
class UwbVerificationResult {
  final bool verified;
  final bool usedUwb;
  final UwbFallbackReason fallbackReason;
  final double confidence;
  final double? measuredDistanceCm;

  const UwbVerificationResult({
    required this.verified,
    required this.usedUwb,
    required this.fallbackReason,
    required this.confidence,
    this.measuredDistanceCm,
  });
}

/// Verifies physical device contact (`<= 15 cm`) via UWB when supported by both peers,
/// or delegates smoothly to [BleProximityEvaluator] (`Spec 010`).
class UwbProximityVerifier {
  final double maxContactDistanceCm;
  final double maxAzimuthDeg;
  final int sampleTtlUs;
  final BleProximityEvaluator bleFallbackEvaluator;

  final Map<String, UwbRangingSample> _latestByPeer = {};

  UwbProximityVerifier({
    this.maxContactDistanceCm = 15.0,
    this.maxAzimuthDeg = 60.0,
    this.sampleTtlUs = 2000000, // 2 seconds
    BleProximityEvaluator? bleFallbackEvaluator,
  }) : bleFallbackEvaluator = bleFallbackEvaluator ?? BleProximityEvaluator();

  void recordUwbSample(UwbRangingSample sample) {
    final key = sample.peerFingerprint.trim().toUpperCase();
    _latestByPeer[key] = sample;
  }

  /// Evaluates whether [peerFingerprint] is within physical tap distance (`<= maxContactDistanceCm`).
  UwbVerificationResult verify({
    required String peerFingerprint,
    required int nowUs,
    required bool localSupportsUwb,
    required bool peerSupportsUwb,
    required bool isBleAvailable,
  }) {
    final key = peerFingerprint.trim().toUpperCase();

    if (!localSupportsUwb) {
      return _delegateToBle(
        peerFingerprint: key,
        nowUs: nowUs,
        isBleAvailable: isBleAvailable,
        reason: UwbFallbackReason.localUwbUnsupported,
      );
    }

    if (!peerSupportsUwb) {
      return _delegateToBle(
        peerFingerprint: key,
        nowUs: nowUs,
        isBleAvailable: isBleAvailable,
        reason: UwbFallbackReason.peerUwbUnsupported,
      );
    }

    final sample = _latestByPeer[key];
    if (sample == null || (nowUs - sample.timestampUs).abs() > sampleTtlUs) {
      return _delegateToBle(
        peerFingerprint: key,
        nowUs: nowUs,
        isBleAvailable: isBleAvailable,
        reason: UwbFallbackReason.noRecentUwbSample,
      );
    }

    final withinDistance = sample.distanceCm >= 0.0 && sample.distanceCm <= maxContactDistanceCm;
    final withinAngle = sample.azimuthDeg.abs() <= maxAzimuthDeg;
    if (!withinDistance || !withinAngle) {
      return UwbVerificationResult(
        verified: false,
        usedUwb: true,
        fallbackReason: UwbFallbackReason.none,
        confidence: 0.0,
        measuredDistanceCm: sample.distanceCm,
      );
    }

    // Confidence in [0.95 .. 1.0] for valid centimeter contact (<= 15 cm).
    final distFactor = (1.0 - (sample.distanceCm / maxContactDistanceCm)).clamp(0.0, 1.0);
    final confidence = 0.95 + (0.05 * distFactor);

    return UwbVerificationResult(
      verified: true,
      usedUwb: true,
      fallbackReason: UwbFallbackReason.none,
      confidence: confidence,
      measuredDistanceCm: sample.distanceCm,
    );
  }

  UwbVerificationResult _delegateToBle({
    required String peerFingerprint,
    required int nowUs,
    required bool isBleAvailable,
    required UwbFallbackReason reason,
  }) {
    final bleAssessment = bleFallbackEvaluator.evaluatePeer(
      peerFingerprint,
      nowUs: nowUs,
      isBleAvailable: isBleAvailable,
    );
    return UwbVerificationResult(
      verified: bleAssessment.allowed,
      usedUwb: false,
      fallbackReason: reason,
      confidence: bleAssessment.proximityScore,
    );
  }

  void clear() => _latestByPeer.clear();
}
