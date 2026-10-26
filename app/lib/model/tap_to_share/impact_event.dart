import 'dart:math' as math;

/// Coarse device posture derived from the estimated gravity vector in the device frame.
enum DevicePosture {
  /// Screen facing up ($+Z$ aligned with upward reaction to gravity).
  faceUp,

  /// Screen facing down ($-Z$ aligned with upward reaction to gravity).
  faceDown,

  /// Device held upright or upside-down in portrait ($\pm Y$ dominant).
  verticalPortrait,

  /// Device held sideways in landscape ($\pm X$ dominant).
  verticalLandscape,

  /// Device held at an intermediate tilt angle.
  tilted,

  /// Orientation has not yet converged.
  unknown,
}

/// Unit quaternion $q = (w, x, y, z)$ representing 3D orientation without gimbal lock (`R4.5`).
class Quaternion {
  final double w;
  final double x;
  final double y;
  final double z;

  const Quaternion(this.w, this.x, this.y, this.z);

  static const Quaternion identity = Quaternion(1.0, 0.0, 0.0, 0.0);

  double get norm => math.sqrt((w * w) + (x * x) + (y * y) + (z * z));

  Quaternion normalized() {
    final n = norm;
    if (n <= 1e-12) {
      return identity;
    }
    return Quaternion(w / n, x / n, y / n, z / n);
  }

  Quaternion get conjugate => Quaternion(w, -x, -y, -z);

  /// Hamilton product $q_1 \otimes q_2$.
  Quaternion operator *(Quaternion other) {
    return Quaternion(
      (w * other.w) - (x * other.x) - (y * other.y) - (z * other.z),
      (w * other.x) + (x * other.w) + (y * other.z) - (z * other.y),
      (w * other.y) - (x * other.z) + (y * other.w) + (z * other.x),
      (w * other.z) + (x * other.y) - (y * other.x) + (z * other.w),
    );
  }

  /// Rotates a 3D vector $(vx, vy, vz)$ by $q \otimes (0, \vec{v}) \otimes q^*$.
  ({double x, double y, double z}) rotateVector(double vx, double vy, double vz) {
    final vQuat = Quaternion(0.0, vx, vy, vz);
    final rotated = (this * vQuat) * conjugate;
    return (x: rotated.x, y: rotated.y, z: rotated.z);
  }

  /// Integrates angular velocity $(\omega_x, \omega_y, \omega_z)$ in $rad/s$ over `dtSeconds`
  /// using the exact quaternion exponential map so large or rapid rotations stay on $SO(3)$.
  Quaternion integrateGyro(double wx, double wy, double wz, double dtSeconds) {
    if (dtSeconds <= 0.0) {
      return this;
    }
    final omegaMag = math.sqrt((wx * wx) + (wy * wy) + (wz * wz));
    if (omegaMag <= 1e-9) {
      return this;
    }
    final halfTheta = 0.5 * omegaMag * dtSeconds;
    final sinHalfTheta = math.sin(halfTheta);
    final dq = Quaternion(
      math.cos(halfTheta),
      (wx / omegaMag) * sinHalfTheta,
      (wy / omegaMag) * sinHalfTheta,
      (wz / omegaMag) * sinHalfTheta,
    );
    return (this * dq).normalized();
  }

  /// Constructs the shortest-arc unit quaternion rotating unit vector `from` to unit vector `to`.
  static Quaternion fromUnitVectors({
    required double fromX,
    required double fromY,
    required double fromZ,
    required double toX,
    required double toY,
    required double toZ,
  }) {
    final dot = (fromX * toX) + (fromY * toY) + (fromZ * toZ);
    if (dot >= 0.999999) {
      return identity;
    }
    if (dot <= -0.999999) {
      // 180-degree rotation: pick an orthogonal axis.
      var orthoX = 1.0;
      var orthoY = 0.0;
      var orthoZ = 0.0;
      if (fromX.abs() > 0.9) {
        orthoX = 0.0;
        orthoY = 1.0;
      }
      final cx = (fromY * orthoZ) - (fromZ * orthoY);
      final cy = (fromZ * orthoX) - (fromX * orthoZ);
      final cz = (fromX * orthoY) - (fromY * orthoX);
      return Quaternion(0.0, cx, cy, cz).normalized();
    }
    final cx = (fromY * toZ) - (fromZ * toY);
    final cy = (fromZ * toX) - (fromX * toZ);
    final cz = (fromX * toY) - (fromY * toX);
    return Quaternion(1.0 + dot, cx, cy, cz).normalized();
  }

  /// Normalized linear interpolation (`NLERP`) between this quaternion and [target] with factor [alpha] $\in [0, 1]$.
  Quaternion nlerpTo(Quaternion target, double alpha) {
    final clamped = alpha.clamp(0.0, 1.0);
    var tw = target.w;
    var tx = target.x;
    var ty = target.y;
    var tz = target.z;

    // Ensure shortest hemisphere path.
    final dot = (w * tw) + (x * tx) + (y * ty) + (z * tz);
    if (dot < 0.0) {
      tw = -tw;
      tx = -tx;
      ty = -ty;
      tz = -tz;
    }

    return Quaternion(
      w + (clamped * (tw - w)),
      x + (clamped * (tx - x)),
      y + (clamped * (ty - y)),
      z + (clamped * (tz - z)),
    ).normalized();
  }

  Map<String, dynamic> toMap() => {
    'w': w,
    'x': x,
    'y': y,
    'z': z,
  };

  factory Quaternion.fromMap(Map<String, dynamic> map) {
    return Quaternion(
      (map['w'] as num).toDouble(),
      (map['x'] as num).toDouble(),
      (map['y'] as num).toDouble(),
      (map['z'] as num).toDouble(),
    );
  }
}

/// Calibratable parameters for the Phase 2 single-device impact detector (`002-impact-detection`).
///
/// All numeric thresholds here are initial defaults designed to be calibrated against real recorded
/// CSV datasets via `ImpactDatasetEvaluator` (`R3.6`).
class ImpactDetectorConfig {
  /// Minimum linear acceleration spike magnitude ($m/s^2$) required to trigger a candidate tap.
  final double minPeakLinearAccelMps2;

  /// Multiplier applied to the adaptive noise standard deviation above the baseline mean.
  final double adaptiveNoiseSigmaMultiplier;

  /// Minimum instantaneous jerk magnitude ($\|\Delta \vec{a} / \Delta t\|$ in $m/s^3$) at the spike.
  final double minJerkMps3;

  /// Refractory period in microseconds after a confirmed tap during which new spikes are ignored (`500 ms`).
  final int refractoryPeriodUs;

  /// Pre-impact window duration before `t_spike` (`250 ms`).
  final int preImpactWindowUs;

  /// Margin before `t_spike` where the contact phase begins (`25 ms`).
  final int duringImpactPreMarginUs;

  /// Margin after `t_spike` where initial contact ring-down occurs (`45 ms`).
  final int duringImpactPostMarginUs;

  /// Offset after `t_spike` where post-impact stillness is evaluated (`60 ms`).
  final int postImpactStillnessStartOffsetUs;

  /// Total window after `t_spike` required before confirming a tap (`250 ms`).
  final int postImpactWindowUs;

  /// Maximum allowed gyroscope RMS ($rad/s$) in the pre-impact approach window (rejects shaking/waving).
  final double maxPreImpactGyroRmsRadPerSec;

  /// Maximum allowed gyroscope peak ($rad/s$) in the pre-impact approach window.
  final double maxPreImpactGyroPeakRadPerSec;

  /// Maximum allowed linear acceleration RMS ($m/s^2$) in the pre-impact window (rejects continuous walking/shaking).
  final double maxPreImpactAccelRmsMps2;

  /// Maximum allowed gyroscope peak ($rad/s$) during the impact contact window.
  final double maxDuringImpactGyroPeakRadPerSec;

  /// Maximum allowed gyroscope RMS ($rad/s$) in the post-impact stillness window.
  final double maxPostImpactGyroRmsRadPerSec;

  /// Maximum allowed linear acceleration RMS ($m/s^2$) in the post-impact stillness window.
  final double maxPostImpactAccelRmsMps2;

  /// Time constant $\tau$ (seconds) for the raw-accelerometer gravity high-pass filter.
  final double accelHighPassTimeConstantSec;

  /// Time constant $\tau$ (seconds) for the gyroscope noise low-pass filter.
  final double gyroLowPassTimeConstantSec;

  const ImpactDetectorConfig({
    this.minPeakLinearAccelMps2 = 6.5,
    this.adaptiveNoiseSigmaMultiplier = 5.0,
    this.minJerkMps3 = 350.0,
    this.refractoryPeriodUs = 500000,
    this.preImpactWindowUs = 250000,
    this.duringImpactPreMarginUs = 25000,
    this.duringImpactPostMarginUs = 45000,
    this.postImpactStillnessStartOffsetUs = 60000,
    this.postImpactWindowUs = 250000,
    this.maxPreImpactGyroRmsRadPerSec = 1.6,
    this.maxPreImpactGyroPeakRadPerSec = 3.0,
    this.maxPreImpactAccelRmsMps2 = 3.2,
    this.maxDuringImpactGyroPeakRadPerSec = 4.0,
    this.maxPostImpactGyroRmsRadPerSec = 1.0,
    this.maxPostImpactAccelRmsMps2 = 2.5,
    this.accelHighPassTimeConstantSec = 0.12,
    this.gyroLowPassTimeConstantSec = 0.015,
  });

  Map<String, dynamic> toMap() => {
    'minPeakLinearAccelMps2': minPeakLinearAccelMps2,
    'adaptiveNoiseSigmaMultiplier': adaptiveNoiseSigmaMultiplier,
    'minJerkMps3': minJerkMps3,
    'refractoryPeriodUs': refractoryPeriodUs,
    'preImpactWindowUs': preImpactWindowUs,
    'duringImpactPreMarginUs': duringImpactPreMarginUs,
    'duringImpactPostMarginUs': duringImpactPostMarginUs,
    'postImpactStillnessStartOffsetUs': postImpactStillnessStartOffsetUs,
    'postImpactWindowUs': postImpactWindowUs,
    'maxPreImpactGyroRmsRadPerSec': maxPreImpactGyroRmsRadPerSec,
    'maxPreImpactGyroPeakRadPerSec': maxPreImpactGyroPeakRadPerSec,
    'maxPreImpactAccelRmsMps2': maxPreImpactAccelRmsMps2,
    'maxDuringImpactGyroPeakRadPerSec': maxDuringImpactGyroPeakRadPerSec,
    'maxPostImpactGyroRmsRadPerSec': maxPostImpactGyroRmsRadPerSec,
    'maxPostImpactAccelRmsMps2': maxPostImpactAccelRmsMps2,
    'accelHighPassTimeConstantSec': accelHighPassTimeConstantSec,
    'gyroLowPassTimeConstantSec': gyroLowPassTimeConstantSec,
  };

  factory ImpactDetectorConfig.fromMap(Map<String, dynamic> map) {
    return ImpactDetectorConfig(
      minPeakLinearAccelMps2: (map['minPeakLinearAccelMps2'] as num).toDouble(),
      adaptiveNoiseSigmaMultiplier: (map['adaptiveNoiseSigmaMultiplier'] as num).toDouble(),
      minJerkMps3: (map['minJerkMps3'] as num).toDouble(),
      refractoryPeriodUs: (map['refractoryPeriodUs'] as num).toInt(),
      preImpactWindowUs: (map['preImpactWindowUs'] as num).toInt(),
      duringImpactPreMarginUs: (map['duringImpactPreMarginUs'] as num).toInt(),
      duringImpactPostMarginUs: (map['duringImpactPostMarginUs'] as num).toInt(),
      postImpactStillnessStartOffsetUs: (map['postImpactStillnessStartOffsetUs'] as num).toInt(),
      postImpactWindowUs: (map['postImpactWindowUs'] as num).toInt(),
      maxPreImpactGyroRmsRadPerSec: (map['maxPreImpactGyroRmsRadPerSec'] as num).toDouble(),
      maxPreImpactGyroPeakRadPerSec: (map['maxPreImpactGyroPeakRadPerSec'] as num).toDouble(),
      maxPreImpactAccelRmsMps2: (map['maxPreImpactAccelRmsMps2'] as num).toDouble(),
      maxDuringImpactGyroPeakRadPerSec: (map['maxDuringImpactGyroPeakRadPerSec'] as num).toDouble(),
      maxPostImpactGyroRmsRadPerSec: (map['maxPostImpactGyroRmsRadPerSec'] as num).toDouble(),
      maxPostImpactAccelRmsMps2: (map['maxPostImpactAccelRmsMps2'] as num).toDouble(),
      accelHighPassTimeConstantSec: (map['accelHighPassTimeConstantSec'] as num).toDouble(),
      gyroLowPassTimeConstantSec: (map['gyroLowPassTimeConstantSec'] as num).toDouble(),
    );
  }
}

/// Summary of a validated physical tap detected on a single device (`002-impact-detection`).
class DetectedTapEvent {
  /// Hardware sensor timestamp (microseconds) at the peak of the impact spike.
  final int impactTimestampUs;

  /// Peak linear acceleration magnitude ($m/s^2$) at the impact spike.
  final double peakLinearAccelMps2;

  /// Peak instantaneous jerk magnitude ($m/s^3$) at the impact spike.
  final double peakJerkMps3;

  /// Pre-impact gyroscope RMS ($rad/s$).
  final double preImpactGyroRms;

  /// Peak gyroscope magnitude ($rad/s$) during the impact contact window.
  final double duringImpactGyroPeak;

  /// Post-impact linear acceleration RMS ($m/s^2$) during the stillness window.
  final double postImpactAccelRms;

  /// Post-impact gyroscope RMS ($rad/s$) during the stillness window.
  final double postImpactGyroRms;

  /// Normalized unit vector $(dirX, dirY, dirZ)$ of the impact impulse in the device frame.
  final double dirX;
  final double dirY;
  final double dirZ;

  /// Estimated 3D orientation quaternion at the moment of impact.
  final Quaternion orientation;

  /// Classified device posture at the moment of impact.
  final DevicePosture posture;

  const DetectedTapEvent({
    required this.impactTimestampUs,
    required this.peakLinearAccelMps2,
    required this.peakJerkMps3,
    required this.preImpactGyroRms,
    required this.duringImpactGyroPeak,
    required this.postImpactAccelRms,
    required this.postImpactGyroRms,
    required this.dirX,
    required this.dirY,
    required this.dirZ,
    required this.orientation,
    required this.posture,
  });

  Map<String, dynamic> toMap() => {
    'impactTimestampUs': impactTimestampUs,
    'peakLinearAccelMps2': peakLinearAccelMps2,
    'peakJerkMps3': peakJerkMps3,
    'preImpactGyroRms': preImpactGyroRms,
    'duringImpactGyroPeak': duringImpactGyroPeak,
    'postImpactAccelRms': postImpactAccelRms,
    'postImpactGyroRms': postImpactGyroRms,
    'dirX': dirX,
    'dirY': dirY,
    'dirZ': dirZ,
    'orientation': orientation.toMap(),
    'posture': posture.name,
  };

  factory DetectedTapEvent.fromMap(Map<String, dynamic> map) {
    return DetectedTapEvent(
      impactTimestampUs: (map['impactTimestampUs'] as num).toInt(),
      peakLinearAccelMps2: (map['peakLinearAccelMps2'] as num).toDouble(),
      peakJerkMps3: (map['peakJerkMps3'] as num).toDouble(),
      preImpactGyroRms: (map['preImpactGyroRms'] as num).toDouble(),
      duringImpactGyroPeak: (map['duringImpactGyroPeak'] as num).toDouble(),
      postImpactAccelRms: (map['postImpactAccelRms'] as num).toDouble(),
      postImpactGyroRms: (map['postImpactGyroRms'] as num).toDouble(),
      dirX: (map['dirX'] as num).toDouble(),
      dirY: (map['dirY'] as num).toDouble(),
      dirZ: (map['dirZ'] as num).toDouble(),
      orientation: Quaternion.fromMap(Map<String, dynamic>.from(map['orientation'] as Map)),
      posture: DevicePosture.values.firstWhere((e) => e.name == map['posture']),
    );
  }
}
