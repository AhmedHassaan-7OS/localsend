/// Proximity classification based on smoothed BLE RSSI (`Spec 008`).
enum BleProximityZone {
  /// Physically touching or within ~5–10 cm ($\ge -48\text{ dBm}$).
  touching,

  /// Immediate proximity within ~10–35 cm ($-49\text{ to }-62\text{ dBm}$).
  near,

  /// Desk distance within ~35–100 cm ($-63\text{ to }-75\text{ dBm}$).
  medium,

  /// Too far away for a physical tap ($< -75\text{ dBm}$).
  far,

  /// No recent BLE advertisement sample or BLE unavailable.
  unknown,
}

/// Raw BLE advertisement RSSI reading from a nearby peer (`Spec 008`).
class BleRssiSample {
  final String peerFingerprint;
  final int rssiDbm;
  final int timestampUs;

  const BleRssiSample({
    required this.peerFingerprint,
    required this.rssiDbm,
    required this.timestampUs,
  });
}

/// Proximity evaluation result for a candidate peer (`Spec 008`).
class BleProximityAssessment {
  final String peerFingerprint;
  final BleProximityZone zone;
  final double? smoothedRssiDbm;

  /// Normalized proximity score $\in [0.0, 1.0]$ (or `0.5` neutral fallback when BLE is unavailable).
  final double proximityScore;

  /// Whether the peer passes proximity verification.
  final bool allowed;

  /// Whether evaluation used the graceful no-BLE fallback (`AC-3`).
  final bool usedFallback;

  const BleProximityAssessment({
    required this.peerFingerprint,
    required this.zone,
    required this.smoothedRssiDbm,
    required this.proximityScore,
    required this.allowed,
    required this.usedFallback,
  });
}

class _PeerRssiState {
  double emaRssiDbm;
  int lastUpdatedUs;

  _PeerRssiState({
    required this.emaRssiDbm,
    required this.lastUpdatedUs,
  });
}

/// Smooths BLE RSSI readings via Exponential Moving Average (EMA) and filters out non-proximate peers (`Spec 008`).
class BleProximityEvaluator {
  final double emaAlpha;
  final double touchingThresholdDbm;
  final double nearThresholdDbm;
  final double minAllowedRssiDbm;
  final int sampleTtlUs;

  final Map<String, _PeerRssiState> _stateByPeer = {};

  BleProximityEvaluator({
    this.emaAlpha = 0.4,
    this.touchingThresholdDbm = -48.0,
    this.nearThresholdDbm = -62.0,
    this.minAllowedRssiDbm = -75.0,
    this.sampleTtlUs = 5000000, // 5 seconds
  });

  /// Records a new BLE RSSI sample for `sample.peerFingerprint` and updates its EMA filter.
  double recordSample(BleRssiSample sample) {
    final key = sample.peerFingerprint.trim().toUpperCase();
    final existing = _stateByPeer[key];
    if (existing == null || (sample.timestampUs - existing.lastUpdatedUs).abs() > sampleTtlUs) {
      final created = _PeerRssiState(
        emaRssiDbm: sample.rssiDbm.toDouble(),
        lastUpdatedUs: sample.timestampUs,
      );
      _stateByPeer[key] = created;
      return created.emaRssiDbm;
    }

    existing.emaRssiDbm = (emaAlpha * sample.rssiDbm) + ((1.0 - emaAlpha) * existing.emaRssiDbm);
    existing.lastUpdatedUs = sample.timestampUs;
    return existing.emaRssiDbm;
  }

  /// Classifies a smoothed RSSI value into a [BleProximityZone].
  BleProximityZone classifyRssi(double rssiDbm) {
    if (rssiDbm >= touchingThresholdDbm) {
      return BleProximityZone.touching;
    }
    if (rssiDbm >= nearThresholdDbm) {
      return BleProximityZone.near;
    }
    if (rssiDbm >= minAllowedRssiDbm) {
      return BleProximityZone.medium;
    }
    return BleProximityZone.far;
  }

  /// Evaluates whether [peerFingerprint] is physically close enough to match a tap at [nowUs].
  BleProximityAssessment evaluatePeer(
    String peerFingerprint, {
    required int nowUs,
    required bool isBleAvailable,
  }) {
    final key = peerFingerprint.trim().toUpperCase();
    if (!isBleAvailable) {
      // AC-3: Graceful fallback when BLE is off or unsupported on the device.
      return BleProximityAssessment(
        peerFingerprint: key,
        zone: BleProximityZone.unknown,
        smoothedRssiDbm: null,
        proximityScore: 0.5,
        allowed: true,
        usedFallback: true,
      );
    }

    final state = _stateByPeer[key];
    if (state == null || (nowUs - state.lastUpdatedUs).abs() > sampleTtlUs) {
      return BleProximityAssessment(
        peerFingerprint: key,
        zone: BleProximityZone.unknown,
        smoothedRssiDbm: null,
        proximityScore: 0.5,
        allowed: true,
        usedFallback: true,
      );
    }

    final rssi = state.emaRssiDbm;
    final zone = classifyRssi(rssi);
    if (zone == BleProximityZone.far) {
      return BleProximityAssessment(
        peerFingerprint: key,
        zone: zone,
        smoothedRssiDbm: rssi,
        proximityScore: 0.0,
        allowed: false,
        usedFallback: false,
      );
    }

    // Map [-75 dBm .. -35 dBm] linearly to [0.0 .. 1.0].
    final normalized = ((rssi - minAllowedRssiDbm) / (-35.0 - minAllowedRssiDbm)).clamp(0.0, 1.0);
    return BleProximityAssessment(
      peerFingerprint: key,
      zone: zone,
      smoothedRssiDbm: rssi,
      proximityScore: normalized,
      allowed: true,
      usedFallback: false,
    );
  }

  void clear() => _stateByPeer.clear();
}
