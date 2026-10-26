import 'dart:math' as math;

import 'package:localsend_app/model/tap_to_share/impact_event.dart';
import 'package:localsend_app/util/tap_to_share/sensor_csv_serializer.dart';

/// Tracks 3D device orientation using a Quaternion Complementary Filter (`002-impact-detection` `FR-4`).
///
/// - Integrates high-rate gyroscope angular velocity $(\omega_x, \omega_y, \omega_z)$ in $rad/s$ using
///   quaternions (`R4.5`, immune to gimbal lock).
/// - Corrects pitch/roll tilt drift from the raw accelerometer **only** when the acceleration magnitude is within
///   [gravityGateToleranceMps2] of $1g$ (`9.80665 m/s^2`), preventing linear acceleration or impact spikes from
///   corrupting the tilt estimate.
class QuaternionOrientationTracker {
  /// Maximum deviation of $\|\vec{a}_{\text{raw}}\|$ from $1g$ ($m/s^2$) allowed for gravity tilt correction.
  final double gravityGateToleranceMps2;

  /// Complementary filter correction gain $\alpha \in (0, 1]$ applied per quasi-stationary accelerometer sample.
  final double complementaryGain;

  Quaternion _orientation = Quaternion.identity;
  int? _lastGyroTimestampUs;
  bool _hasInitialGravityFix = false;

  QuaternionOrientationTracker({
    this.gravityGateToleranceMps2 = 1.5,
    this.complementaryGain = 0.06,
  });

  /// Current body-to-world unit quaternion $q$.
  Quaternion get orientation => _orientation;

  /// Whether at least one quasi-stationary gravity reading or gyro update has been processed.
  bool get isInitialized => _hasInitialGravityFix || _lastGyroTimestampUs != null;

  /// Estimated upward reaction unit vector $(\hat{g}_x, \hat{g}_y, \hat{g}_z)$ in the device frame.
  ///
  /// When the device rests face-up on a horizontal surface, this vector is $(0, 0, +1)$.
  ({double x, double y, double z}) get bodyUpVector {
    return _orientation.conjugate.rotateVector(0.0, 0.0, 1.0);
  }

  /// Integrates a gyroscope sample $(\omega_x, \omega_y, \omega_z)$ in $rad/s$ at hardware timestamp [timestampUs].
  void updateGyro({
    required double wx,
    required double wy,
    required double wz,
    required int timestampUs,
  }) {
    final prevUs = _lastGyroTimestampUs;
    _lastGyroTimestampUs = timestampUs;
    if (prevUs == null) {
      return;
    }
    final dtUs = timestampUs - prevUs;
    // Ignore negative/zero deltas or gaps > 0.5s (e.g. sensor resume).
    if (dtUs <= 0 || dtUs > 500000) {
      return;
    }
    final dtSeconds = dtUs / 1000000.0;
    _orientation = _orientation.integrateGyro(wx, wy, wz, dtSeconds);
  }

  /// Updates tilt using a raw accelerometer sample $(a_x, a_y, a_z)$ in $m/s^2$ (including gravity).
  ///
  /// Returns `true` if the sample passed the quasi-stationary gravity gate and corrected tilt,
  /// or `false` if the sample was rejected due to linear acceleration / impact (`FR-4`).
  bool updateAccelerometer({
    required double ax,
    required double ay,
    required double az,
  }) {
    final mag = math.sqrt((ax * ax) + (ay * ay) + (az * az));
    if (mag <= 1e-6) {
      return false;
    }

    // Do not trust the accelerometer for tilt during linear motion or impact spikes!
    if ((mag - kStandardGravityMps2).abs() > gravityGateToleranceMps2) {
      return false;
    }

    final ux = ax / mag;
    final uy = ay / mag;
    final uz = az / mag;

    if (!_hasInitialGravityFix) {
      // Snap directly to the initial gravity vector on the first stationary reading.
      _orientation = Quaternion.fromUnitVectors(
        fromX: ux,
        fromY: uy,
        fromZ: uz,
        toX: 0.0,
        toY: 0.0,
        toZ: 1.0,
      );
      _hasInitialGravityFix = true;
      return true;
    }

    // Rotate the measured body-frame upward unit vector into the current world frame.
    final worldMeasuredUp = _orientation.rotateVector(ux, uy, uz);
    final fullTiltCorrection = Quaternion.fromUnitVectors(
      fromX: worldMeasuredUp.x,
      fromY: worldMeasuredUp.y,
      fromZ: worldMeasuredUp.z,
      toX: 0.0,
      toY: 0.0,
      toZ: 1.0,
    );

    final partialCorrection = Quaternion.identity.nlerpTo(fullTiltCorrection, complementaryGain);
    _orientation = (partialCorrection * _orientation).normalized();
    return true;
  }

  /// Classifies the current coarse device posture (`FR-4` / `AC-4`).
  DevicePosture classifyPosture() {
    if (!isInitialized) {
      return DevicePosture.unknown;
    }
    final up = bodyUpVector;
    const dominantThreshold = 0.75;

    if (up.z >= dominantThreshold) {
      return DevicePosture.faceUp;
    }
    if (up.z <= -dominantThreshold) {
      return DevicePosture.faceDown;
    }
    if (up.y.abs() >= dominantThreshold && up.y.abs() >= up.x.abs()) {
      return DevicePosture.verticalPortrait;
    }
    if (up.x.abs() >= dominantThreshold && up.x.abs() > up.y.abs()) {
      return DevicePosture.verticalLandscape;
    }
    return DevicePosture.tilted;
  }

  void reset() {
    _orientation = Quaternion.identity;
    _lastGyroTimestampUs = null;
    _hasInitialGravityFix = false;
  }
}
