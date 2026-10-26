import 'dart:collection';
import 'dart:math' as math;

import 'package:localsend_app/model/tap_to_share/impact_event.dart';
import 'package:localsend_app/model/tap_to_share/sensor_sample.dart';
import 'package:localsend_app/util/tap_to_share/quaternion_orientation_tracker.dart';

class _TimedScalarSample {
  final int timestampUs;
  final double magnitude;

  const _TimedScalarSample({
    required this.timestampUs,
    required this.magnitude,
  });
}

class _PendingSpikeCandidate {
  final int initialSpikeTimestampUs;
  int peakTimestampUs;
  double peakLinearAccelMps2;
  double peakJerkMps3;
  double dirX;
  double dirY;
  double dirZ;
  Quaternion orientation;
  DevicePosture posture;

  _PendingSpikeCandidate({
    required this.initialSpikeTimestampUs,
    required this.peakTimestampUs,
    required this.peakLinearAccelMps2,
    required this.peakJerkMps3,
    required this.dirX,
    required this.dirY,
    required this.dirZ,
    required this.orientation,
    required this.posture,
  });
}

/// Stateful single-device impact detector combining accelerometer spike/jerk detection,
/// gyroscope pre/during/post window confirmation, post-impact stillness verification,
/// and quaternion orientation tracking (`002-impact-detection`).
///
/// Pure Dart with zero UI dependencies so it can execute inside a background `Isolate` (`R4.1`).
class ImpactDetector {
  final ImpactDetectorConfig config;
  final QuaternionOrientationTracker orientationTracker;

  static const int _maxHistoryDurationUs = 1000000; // 1.0 s bounded ring window

  final Queue<_TimedScalarSample> _linearAccelHistory = Queue<_TimedScalarSample>();
  final Queue<_TimedScalarSample> _gyroHistory = Queue<_TimedScalarSample>();

  // High-pass filter state for raw accelerometer (used when userAccelerometer is unavailable).
  int? _lastRawAccelUs;
  double _prevRawAx = 0.0;
  double _prevRawAy = 0.0;
  double _prevRawAz = 0.0;
  double _hpAx = 0.0;
  double _hpAy = 0.0;
  double _hpAz = 0.0;
  bool _hasRawAccelSample = false;

  // Low-pass filter state for gyroscope.
  int? _lastGyroUs;
  double _lpGx = 0.0;
  double _lpGy = 0.0;
  double _lpGz = 0.0;
  bool _hasGyroSample = false;

  // Previous linear acceleration sample for instantaneous jerk calculation.
  int? _lastLinearAccelUs;
  double _prevLinAx = 0.0;
  double _prevLinAy = 0.0;
  double _prevLinAz = 0.0;
  int? _lastUserAccelSeenUs;

  // Adaptive baseline noise floor (EMA of quiet linear acceleration magnitude).
  double _noiseMeanMps2 = 0.25;
  double _noiseVarMps4 = 0.04;

  // Refractory & candidate tracking.
  int? _lastConfirmedImpactUs;
  _PendingSpikeCandidate? _pendingCandidate;

  ImpactDetector({
    this.config = const ImpactDetectorConfig(),
    QuaternionOrientationTracker? orientationTracker,
  }) : orientationTracker = orientationTracker ?? QuaternionOrientationTracker();

  /// Current adaptive linear acceleration threshold ($m/s^2$).
  double get currentEffectiveAccelThresholdMps2 {
    final adaptive = _noiseMeanMps2 + (config.adaptiveNoiseSigmaMultiplier * math.sqrt(_noiseVarMps4));
    return math.max(config.minPeakLinearAccelMps2, adaptive);
  }

  /// Processes a single hardware-timestamped [SensorSample].
  ///
  /// Returns a [DetectedTapEvent] when a candidate impact spike has completed its post-impact
  /// confirmation window and passed all gyroscope and stillness checks; otherwise returns `null`.
  DetectedTapEvent? processSample(SensorSample sample) {
    switch (sample.sensorType) {
      case SensorType.gyroscope:
        _onGyroSample(sample);
        return _checkPendingCandidate(sample.sensorTimestampUs);

      case SensorType.userAccelerometer:
        _lastUserAccelSeenUs = sample.sensorTimestampUs;
        return _onLinearAccelSample(
          ax: sample.x,
          ay: sample.y,
          az: sample.z,
          timestampUs: sample.sensorTimestampUs,
        );

      case SensorType.accelerometer:
        orientationTracker.updateAccelerometer(
          ax: sample.x,
          ay: sample.y,
          az: sample.z,
        );
        final filtered = _highPassFilterRawAccel(sample);
        // If dedicated userAccelerometer stream is active (within last 100ms), don't double-feed.
        if (_lastUserAccelSeenUs != null && (sample.sensorTimestampUs - _lastUserAccelSeenUs!).abs() <= 100000) {
          return _checkPendingCandidate(sample.sensorTimestampUs);
        }
        if (filtered == null) {
          return null;
        }
        return _onLinearAccelSample(
          ax: filtered.x,
          ay: filtered.y,
          az: filtered.z,
          timestampUs: sample.sensorTimestampUs,
        );
    }
  }

  void _onGyroSample(SensorSample sample) {
    orientationTracker.updateGyro(
      wx: sample.x,
      wy: sample.y,
      wz: sample.z,
      timestampUs: sample.sensorTimestampUs,
    );

    if (!_hasGyroSample || _lastGyroUs == null) {
      _lpGx = sample.x;
      _lpGy = sample.y;
      _lpGz = sample.z;
      _lastGyroUs = sample.sensorTimestampUs;
      _hasGyroSample = true;
    } else {
      final dtUs = sample.sensorTimestampUs - _lastGyroUs!;
      _lastGyroUs = sample.sensorTimestampUs;
      if (dtUs > 0 && dtUs <= 500000) {
        final dtSec = dtUs / 1000000.0;
        final alpha = dtSec / (config.gyroLowPassTimeConstantSec + dtSec);
        _lpGx = _lpGx + (alpha * (sample.x - _lpGx));
        _lpGy = _lpGy + (alpha * (sample.y - _lpGy));
        _lpGz = _lpGz + (alpha * (sample.z - _lpGz));
      } else {
        _lpGx = sample.x;
        _lpGy = sample.y;
        _lpGz = sample.z;
      }
    }

    final gyroMag = math.sqrt((_lpGx * _lpGx) + (_lpGy * _lpGy) + (_lpGz * _lpGz));
    _gyroHistory.addLast(
      _TimedScalarSample(
        timestampUs: sample.sensorTimestampUs,
        magnitude: gyroMag,
      ),
    );
    _pruneHistory(_gyroHistory, sample.sensorTimestampUs);
  }

  ({double x, double y, double z})? _highPassFilterRawAccel(SensorSample sample) {
    if (!_hasRawAccelSample || _lastRawAccelUs == null) {
      _prevRawAx = sample.x;
      _prevRawAy = sample.y;
      _prevRawAz = sample.z;
      _hpAx = 0.0;
      _hpAy = 0.0;
      _hpAz = 0.0;
      _lastRawAccelUs = sample.sensorTimestampUs;
      _hasRawAccelSample = true;
      return (x: 0.0, y: 0.0, z: 0.0);
    }

    final dtUs = sample.sensorTimestampUs - _lastRawAccelUs!;
    _lastRawAccelUs = sample.sensorTimestampUs;
    if (dtUs <= 0 || dtUs > 500000) {
      _prevRawAx = sample.x;
      _prevRawAy = sample.y;
      _prevRawAz = sample.z;
      _hpAx = 0.0;
      _hpAy = 0.0;
      _hpAz = 0.0;
      return null;
    }

    final dtSec = dtUs / 1000000.0;
    final tau = config.accelHighPassTimeConstantSec;
    final alpha = tau / (tau + dtSec);

    _hpAx = alpha * (_hpAx + sample.x - _prevRawAx);
    _hpAy = alpha * (_hpAy + sample.y - _prevRawAy);
    _hpAz = alpha * (_hpAz + sample.z - _prevRawAz);

    _prevRawAx = sample.x;
    _prevRawAy = sample.y;
    _prevRawAz = sample.z;

    return (x: _hpAx, y: _hpAy, z: _hpAz);
  }

  DetectedTapEvent? _onLinearAccelSample({
    required double ax,
    required double ay,
    required double az,
    required int timestampUs,
  }) {
    final mag = math.sqrt((ax * ax) + (ay * ay) + (az * az));

    double jerkMps3 = 0.0;
    if (_lastLinearAccelUs != null) {
      final dtUs = timestampUs - _lastLinearAccelUs!;
      if (dtUs > 0 && dtUs <= 200000) {
        final dx = ax - _prevLinAx;
        final dy = ay - _prevLinAy;
        final dz = az - _prevLinAz;
        final deltaMag = math.sqrt((dx * dx) + (dy * dy) + (dz * dz));
        jerkMps3 = (deltaMag * 1000000.0) / dtUs;
      }
    }
    _lastLinearAccelUs = timestampUs;
    _prevLinAx = ax;
    _prevLinAy = ay;
    _prevLinAz = az;

    _linearAccelHistory.addLast(
      _TimedScalarSample(
        timestampUs: timestampUs,
        magnitude: mag,
      ),
    );
    _pruneHistory(_linearAccelHistory, timestampUs);

    // 1. Check if an existing pending candidate has finished its post-impact window.
    final confirmedEvent = _checkPendingCandidate(timestampUs);

    // 2. Update adaptive baseline noise floor during quiet periods when no spike is pending.
    if (_pendingCandidate == null && mag < 2.0) {
      const emaGain = 0.02;
      final diff = mag - _noiseMeanMps2;
      _noiseMeanMps2 += emaGain * diff;
      _noiseVarMps4 = ((1.0 - emaGain) * _noiseVarMps4) + (emaGain * diff * diff);
    }

    // 3. Enforce refractory period after a confirmed tap (FR-2 / AC-2).
    if (_lastConfirmedImpactUs != null && (timestampUs - _lastConfirmedImpactUs!) < config.refractoryPeriodUs) {
      return confirmedEvent;
    }

    // 4. Update peak of an in-flight candidate within the initial contact window, or trigger a new candidate.
    final pending = _pendingCandidate;
    if (pending != null) {
      if ((timestampUs - pending.initialSpikeTimestampUs) <= config.duringImpactPostMarginUs) {
        if (mag > pending.peakLinearAccelMps2) {
          pending.peakTimestampUs = timestampUs;
          pending.peakLinearAccelMps2 = mag;
          if (mag > 1e-6) {
            pending.dirX = ax / mag;
            pending.dirY = ay / mag;
            pending.dirZ = az / mag;
          }
        }
        if (jerkMps3 > pending.peakJerkMps3) {
          pending.peakJerkMps3 = jerkMps3;
        }
      }
      return confirmedEvent;
    }

    final threshold = currentEffectiveAccelThresholdMps2;
    if (mag >= threshold && jerkMps3 >= config.minJerkMps3) {
      final invMag = mag > 1e-6 ? (1.0 / mag) : 0.0;
      _pendingCandidate = _PendingSpikeCandidate(
        initialSpikeTimestampUs: timestampUs,
        peakTimestampUs: timestampUs,
        peakLinearAccelMps2: mag,
        peakJerkMps3: jerkMps3,
        dirX: ax * invMag,
        dirY: ay * invMag,
        dirZ: az * invMag,
        orientation: orientationTracker.orientation,
        posture: orientationTracker.classifyPosture(),
      );
    }

    return confirmedEvent;
  }

  DetectedTapEvent? _checkPendingCandidate(int currentTimestampUs) {
    final candidate = _pendingCandidate;
    if (candidate == null) {
      return null;
    }

    final windowEndUs = candidate.initialSpikeTimestampUs + config.postImpactWindowUs;
    if (currentTimestampUs < windowEndUs) {
      return null;
    }

    _pendingCandidate = null;
    final tSpike = candidate.initialSpikeTimestampUs;

    // Evaluate pre-impact window: [tSpike - preImpactWindowUs, tSpike - duringImpactPreMarginUs]
    final preStartUs = tSpike - config.preImpactWindowUs;
    final preEndUs = tSpike - config.duringImpactPreMarginUs;

    final preGyroStats = _computeWindowStats(_gyroHistory, preStartUs, preEndUs);
    if (preGyroStats.rms > config.maxPreImpactGyroRmsRadPerSec || preGyroStats.peak > config.maxPreImpactGyroPeakRadPerSec) {
      return null;
    }

    final preAccelStats = _computeWindowStats(_linearAccelHistory, preStartUs, preEndUs);
    if (preAccelStats.rms > config.maxPreImpactAccelRmsMps2) {
      return null;
    }

    // Evaluate during-impact window: [tSpike - duringImpactPreMarginUs, tSpike + duringImpactPostMarginUs]
    final duringStartUs = tSpike - config.duringImpactPreMarginUs;
    final duringEndUs = tSpike + config.duringImpactPostMarginUs;
    final duringGyroStats = _computeWindowStats(_gyroHistory, duringStartUs, duringEndUs);
    if (duringGyroStats.peak > config.maxDuringImpactGyroPeakRadPerSec) {
      return null;
    }

    // Evaluate post-impact stillness window: [tSpike + postImpactStillnessStartOffsetUs, tSpike + postImpactWindowUs]
    final postStartUs = tSpike + config.postImpactStillnessStartOffsetUs;
    final postEndUs = tSpike + config.postImpactWindowUs;

    final postGyroStats = _computeWindowStats(_gyroHistory, postStartUs, postEndUs);
    if (postGyroStats.rms > config.maxPostImpactGyroRmsRadPerSec) {
      return null;
    }

    final postAccelStats = _computeWindowStats(_linearAccelHistory, postStartUs, postEndUs);
    if (postAccelStats.rms > config.maxPostImpactAccelRmsMps2) {
      return null;
    }

    _lastConfirmedImpactUs = candidate.peakTimestampUs;
    return DetectedTapEvent(
      impactTimestampUs: candidate.peakTimestampUs,
      peakLinearAccelMps2: candidate.peakLinearAccelMps2,
      peakJerkMps3: candidate.peakJerkMps3,
      preImpactGyroRms: preGyroStats.rms,
      duringImpactGyroPeak: duringGyroStats.peak,
      postImpactAccelRms: postAccelStats.rms,
      postImpactGyroRms: postGyroStats.rms,
      dirX: candidate.dirX,
      dirY: candidate.dirY,
      dirZ: candidate.dirZ,
      orientation: candidate.orientation,
      posture: candidate.posture,
    );
  }

  static ({double rms, double peak, int count}) _computeWindowStats(
    Iterable<_TimedScalarSample> history,
    int startUs,
    int endUs,
  ) {
    double sumSquares = 0.0;
    double peak = 0.0;
    int count = 0;

    for (final sample in history) {
      if (sample.timestampUs < startUs) {
        continue;
      }
      if (sample.timestampUs > endUs) {
        break;
      }
      sumSquares += sample.magnitude * sample.magnitude;
      if (sample.magnitude > peak) {
        peak = sample.magnitude;
      }
      count++;
    }

    if (count == 0) {
      return (rms: 0.0, peak: 0.0, count: 0);
    }
    return (
      rms: math.sqrt(sumSquares / count),
      peak: peak,
      count: count,
    );
  }

  static void _pruneHistory(Queue<_TimedScalarSample> queue, int currentTimestampUs) {
    final cutoffUs = currentTimestampUs - _maxHistoryDurationUs;
    while (queue.isNotEmpty && queue.first.timestampUs < cutoffUs) {
      queue.removeFirst();
    }
  }

  void reset() {
    _linearAccelHistory.clear();
    _gyroHistory.clear();
    _lastRawAccelUs = null;
    _hasRawAccelSample = false;
    _lastGyroUs = null;
    _hasGyroSample = false;
    _lastLinearAccelUs = null;
    _lastUserAccelSeenUs = null;
    _noiseMeanMps2 = 0.25;
    _noiseVarMps4 = 0.04;
    _lastConfirmedImpactUs = null;
    _pendingCandidate = null;
    orientationTracker.reset();
  }
}
