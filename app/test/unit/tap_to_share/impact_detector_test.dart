import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/model/tap_to_share/impact_event.dart';
import 'package:localsend_app/model/tap_to_share/sensor_sample.dart';
import 'package:localsend_app/util/tap_to_share/impact_dataset_evaluator.dart';
import 'package:localsend_app/util/tap_to_share/impact_detector.dart';
import 'package:localsend_app/util/tap_to_share/impact_detector_isolate.dart';
import 'package:localsend_app/util/tap_to_share/quaternion_orientation_tracker.dart';
import 'package:localsend_app/util/tap_to_share/sensor_csv_serializer.dart';

/// Generates a 200 Hz (`5000 us` step) realistic tap stream:
/// - `0..300 ms`: steady face-up posture, quiet approach (low linear accel, low gyro).
/// - `300 ms`: sharp contact spike along $-Y$ (top edge collision) with rapid rise/fall (`15 ms` wide).
/// - `315..700 ms`: post-impact stillness while the two phones are held together.
List<SensorSample> _buildRealisticTapSamples({
  int durationMs = 700,
  List<int> spikeAtMs = const [300],
  double peakAccelMps2 = 12.0,
  bool includeUserAccel = true,
}) {
  final samples = <SensorSample>[];
  const stepUs = 5000; // 200 Hz
  final totalSteps = (durationMs * 1000) ~/ stepUs;

  for (var i = 0; i <= totalSteps; i++) {
    final tUs = i * stepUs;
    final tMs = tUs / 1000.0;

    double linAy = 0.05 * math.sin(i * 0.2);
    double gyroX = 0.08 * math.cos(i * 0.15);

    for (final spikeMs in spikeAtMs) {
      final dtMs = (tMs - spikeMs).abs();
      if (dtMs < 1e-6) {
        linAy = -peakAccelMps2;
        gyroX = 0.45;
      } else if (dtMs <= 5.0) {
        linAy = -peakAccelMps2 * 0.45;
        gyroX = 0.25;
      }
    }

    // Raw accelerometer includes +9.80665 m/s^2 on Z (face up).
    samples.add(
      SensorSample(
        sensorType: SensorType.accelerometer,
        sensorTimestampUs: tUs,
        arrivalTimestampUs: tUs + 100,
        x: 0.0,
        y: linAy,
        z: kStandardGravityMps2,
      ),
    );

    if (includeUserAccel) {
      samples.add(
        SensorSample(
          sensorType: SensorType.userAccelerometer,
          sensorTimestampUs: tUs,
          arrivalTimestampUs: tUs + 110,
          x: 0.0,
          y: linAy,
          z: 0.0,
        ),
      );
    }

    samples.add(
      SensorSample(
        sensorType: SensorType.gyroscope,
        sensorTimestampUs: tUs,
        arrivalTimestampUs: tUs + 120,
        x: gyroX,
        y: 0.02,
        z: -0.02,
      ),
    );
  }

  return samples;
}

/// Generates a false-positive vigorous shaking stream (high pre/during/post gyro and repeated spikes).
List<SensorSample> _buildShakeFalsePositiveSamples() {
  final samples = <SensorSample>[];
  const stepUs = 5000;
  for (var i = 0; i <= 160; i++) {
    final tUs = i * stepUs;
    final phase = i * 0.45;
    final linAx = 11.0 * math.sin(phase);
    final gyroZ = 4.5 * math.cos(phase);

    samples.add(
      SensorSample(
        sensorType: SensorType.accelerometer,
        sensorTimestampUs: tUs,
        arrivalTimestampUs: tUs,
        x: linAx,
        y: 0.0,
        z: kStandardGravityMps2,
      ),
    );
    samples.add(
      SensorSample(
        sensorType: SensorType.userAccelerometer,
        sensorTimestampUs: tUs,
        arrivalTimestampUs: tUs,
        x: linAx,
        y: 0.0,
        z: 0.0,
      ),
    );
    samples.add(
      SensorSample(
        sensorType: SensorType.gyroscope,
        sensorTimestampUs: tUs,
        arrivalTimestampUs: tUs,
        x: 1.5,
        y: -1.8,
        z: gyroZ,
      ),
    );
  }
  return samples;
}

/// Generates a false-positive phone drop / tumbling stream (spike followed by chaotic post-impact bouncing and rotation).
List<SensorSample> _buildDropFalsePositiveSamples() {
  final samples = <SensorSample>[];
  const stepUs = 5000;
  for (var i = 0; i <= 160; i++) {
    final tUs = i * stepUs;
    final tMs = tUs / 1000.0;

    double linAz = 0.1;
    double gyroY = 0.2;
    if ((tMs - 300.0).abs() < 1e-6) {
      linAz = 16.0;
      gyroY = 2.0;
    } else if (tMs > 300.0 && tMs <= 600.0) {
      // Sustained chaotic bouncing & tumbling after hitting the floor/table.
      linAz = 6.5 * math.sin(i * 0.7);
      gyroY = 2.8 * math.cos(i * 0.5);
    }

    samples.add(
      SensorSample(
        sensorType: SensorType.userAccelerometer,
        sensorTimestampUs: tUs,
        arrivalTimestampUs: tUs,
        x: 0.0,
        y: 0.0,
        z: linAz,
      ),
    );
    samples.add(
      SensorSample(
        sensorType: SensorType.gyroscope,
        sensorTimestampUs: tUs,
        arrivalTimestampUs: tUs,
        x: 0.5,
        y: gyroY,
        z: 0.5,
      ),
    );
  }
  return samples;
}

/// Generates a false-positive walking-in-pocket stream (continuous rhythmic acceleration before and after peaks).
List<SensorSample> _buildWalkingFalsePositiveSamples() {
  final samples = <SensorSample>[];
  const stepUs = 5000;
  for (var i = 0; i <= 160; i++) {
    final tUs = i * stepUs;
    // Continuous high pre/post oscillation (~5.5 m/s^2 RMS) with a spike at 300 ms.
    var linAy = 6.0 * math.sin(i * 0.25);
    if (i == 60) {
      linAy = 11.5;
    }
    samples.add(
      SensorSample(
        sensorType: SensorType.userAccelerometer,
        sensorTimestampUs: tUs,
        arrivalTimestampUs: tUs,
        x: 2.5,
        y: linAy,
        z: 2.0,
      ),
    );
    samples.add(
      SensorSample(
        sensorType: SensorType.gyroscope,
        sensorTimestampUs: tUs,
        arrivalTimestampUs: tUs,
        x: 1.2 * math.sin(i * 0.2),
        y: 0.9,
        z: 0.8,
      ),
    );
  }
  return samples;
}

void main() {
  group('002-impact-detection unit tests', () {
    test('AC-1: Intentional tap signal emits 1 DetectedTapEvent (both userAccelerometer and raw high-pass fallback)', () {
      // 1. With userAccelerometer stream
      final detector = ImpactDetector();
      final samples = _buildRealisticTapSamples(includeUserAccel: true);
      final events = <DetectedTapEvent>[];

      for (final s in samples) {
        final ev = detector.processSample(s);
        if (ev != null) {
          events.add(ev);
        }
      }

      expect(events, hasLength(1));
      final tap = events.single;
      expect(tap.impactTimestampUs, 300000);
      expect(tap.peakLinearAccelMps2, closeTo(12.0, 0.2));
      expect(tap.peakJerkMps3, greaterThan(1000.0));
      expect(tap.posture, DevicePosture.faceUp);
      expect(tap.dirY, closeTo(-1.0, 0.05));

      // 2. Fallback to raw accelerometer high-pass filter when userAccelerometer is absent
      final rawOnlyDetector = ImpactDetector();
      final rawOnlySamples = _buildRealisticTapSamples(includeUserAccel: false);
      final rawOnlyEvents = <DetectedTapEvent>[];

      for (final s in rawOnlySamples) {
        final ev = rawOnlyDetector.processSample(s);
        if (ev != null) {
          rawOnlyEvents.add(ev);
        }
      }

      expect(rawOnlyEvents, hasLength(1));
      expect(rawOnlyEvents.single.impactTimestampUs, 300000);
      expect(rawOnlyEvents.single.posture, DevicePosture.faceUp);
    });

    test('AC-2: Refractory period suppresses bounce spikes within 500 ms and allows a new tap after 600 ms', () {
      final detector = ImpactDetector();
      // Two spikes 60 ms apart (300 ms and 360 ms) -> mechanical bounce -> must emit only 1 tap.
      final bounceSamples = _buildRealisticTapSamples(
        durationMs: 800,
        spikeAtMs: const [300, 360],
      );
      final bounceEvents = <DetectedTapEvent>[];
      for (final s in bounceSamples) {
        final ev = detector.processSample(s);
        if (ev != null) {
          bounceEvents.add(ev);
        }
      }
      expect(bounceEvents, hasLength(1));

      // Two distinct taps separated by 650 ms (300 ms and 950 ms) -> must emit 2 taps.
      detector.reset();
      final twoTapSamples = _buildRealisticTapSamples(
        durationMs: 1300,
        spikeAtMs: const [300, 950],
      );
      final twoTapEvents = <DetectedTapEvent>[];
      for (final s in twoTapSamples) {
        final ev = detector.processSample(s);
        if (ev != null) {
          twoTapEvents.add(ev);
        }
      }
      expect(twoTapEvents, hasLength(2));
      expect(twoTapEvents[0].impactTimestampUs, 300000);
      expect(twoTapEvents[1].impactTimestampUs, 950000);
    });

    test('AC-3: False-positive patterns (shaking, drop/tumbling, walking in pocket) emit 0 DetectedTapEvents', () {
      final detector = ImpactDetector();

      // (a) Vigorous shaking
      for (final s in _buildShakeFalsePositiveSamples()) {
        expect(detector.processSample(s), isNull);
      }

      // (b) Phone drop / post-impact tumbling
      detector.reset();
      for (final s in _buildDropFalsePositiveSamples()) {
        expect(detector.processSample(s), isNull);
      }

      // (c) Walking in pocket
      detector.reset();
      for (final s in _buildWalkingFalsePositiveSamples()) {
        expect(detector.processSample(s), isNull);
      }
    });

    test(
      'AC-4: QuaternionOrientationTracker stays normalized, avoids gimbal lock at 90-deg pitch, gates high linear accel, and classifies posture',
      () {
        final tracker = QuaternionOrientationTracker();
        expect(tracker.classifyPosture(), DevicePosture.unknown);

        // 1. Face-up stationary gravity fix: (0, 0, +9.80665)
        final accepted = tracker.updateAccelerometer(ax: 0.0, ay: 0.0, az: kStandardGravityMps2);
        expect(accepted, isTrue);
        expect(tracker.orientation.norm, closeTo(1.0, 1e-9));
        expect(tracker.classifyPosture(), DevicePosture.faceUp);

        // 2. High linear acceleration spike (e.g. 25 m/s^2 on X) MUST be rejected by the gravity gate!
        final rejected = tracker.updateAccelerometer(ax: 25.0, ay: 0.0, az: kStandardGravityMps2);
        expect(rejected, isFalse);
        expect(tracker.classifyPosture(), DevicePosture.faceUp);

        // 3. Rotate +90 degrees around X-axis via gyro (gimbal-lock region for Euler angles: vertical portrait)
        // Pitch rate = pi/2 rad/s for 1.0 second in 100 steps of 10 ms.
        const rateRadPerSec = math.pi / 2.0;
        for (var i = 0; i <= 100; i++) {
          tracker.updateGyro(
            wx: rateRadPerSec,
            wy: 0.0,
            wz: 0.0,
            timestampUs: i * 10000,
          );
        }
        expect(tracker.orientation.norm, closeTo(1.0, 1e-9));
        expect(tracker.classifyPosture(), DevicePosture.verticalPortrait);

        // 4. Rotate another +90 degrees around X-axis -> now upside-down (faceDown)
        for (var i = 101; i <= 200; i++) {
          tracker.updateGyro(
            wx: rateRadPerSec,
            wy: 0.0,
            wz: 0.0,
            timestampUs: i * 10000,
          );
        }
        expect(tracker.classifyPosture(), DevicePosture.faceDown);

        // 5. Reset and verify verticalLandscape classification when gravity points along +X
        tracker.reset();
        tracker.updateAccelerometer(ax: kStandardGravityMps2, ay: 0.0, az: 0.0);
        expect(tracker.classifyPosture(), DevicePosture.verticalLandscape);
      },
    );

    test('AC-5: ImpactDetectorIsolate processes SensorSamples in a background Isolate and emits DetectedTapEvents', () async {
      final isolateRunner = ImpactDetectorIsolate();
      final stream = await isolateRunner.start();
      expect(isolateRunner.isRunning, isTrue);

      final received = <DetectedTapEvent>[];
      final sub = stream.listen(received.add);

      for (final sample in _buildRealisticTapSamples()) {
        isolateRunner.addSample(sample);
      }

      // Allow isolate message loop to deliver the detected tap event.
      await Future<void>.delayed(const Duration(milliseconds: 120));

      expect(received, hasLength(1));
      expect(received.single.impactTimestampUs, 300000);
      expect(received.single.posture, DevicePosture.faceUp);

      await sub.cancel();
      await isolateRunner.stop();
      expect(isolateRunner.isRunning, isFalse);
    });

    test('AC-6: ImpactDatasetEvaluator parses Phase 1 CSV recordings and computes TPR = 1.0 and FPR = 0.0', () {
      final trueTapTopCsv = formatSensorRecordingCsv(
        meta: RecordingSessionMeta(
          sessionId: 'true-01',
          deviceModel: 'Pixel 7',
          osVersion: 'Android 15',
          scenarioLabel: TapScenarioLabel.trueTapTopToTop,
          hasCase: true,
          measuredAccelHz: 200.0,
          measuredLinearAccelHz: 200.0,
          measuredGyroHz: 200.0,
          recordedAtUtc: DateTime.utc(2026, 10, 26),
        ),
        samples: _buildRealisticTapSamples(peakAccelMps2: 11.5),
      );

      final trueTapBackCsv = formatSensorRecordingCsv(
        meta: RecordingSessionMeta(
          sessionId: 'true-02',
          deviceModel: 'iPhone 15',
          osVersion: 'iOS 18',
          scenarioLabel: TapScenarioLabel.trueTapBackToBack,
          hasCase: false,
          measuredAccelHz: 200.0,
          measuredLinearAccelHz: 200.0,
          measuredGyroHz: 200.0,
          recordedAtUtc: DateTime.utc(2026, 10, 26),
        ),
        samples: _buildRealisticTapSamples(peakAccelMps2: 14.0),
      );

      final falseShakeCsv = formatSensorRecordingCsv(
        meta: RecordingSessionMeta(
          sessionId: 'false-01',
          deviceModel: 'Pixel 7',
          osVersion: 'Android 15',
          scenarioLabel: TapScenarioLabel.falseShake,
          hasCase: true,
          measuredAccelHz: 200.0,
          measuredLinearAccelHz: 200.0,
          measuredGyroHz: 200.0,
          recordedAtUtc: DateTime.utc(2026, 10, 26),
        ),
        samples: _buildShakeFalsePositiveSamples(),
      );

      final falseDropCsv = formatSensorRecordingCsv(
        meta: RecordingSessionMeta(
          sessionId: 'false-02',
          deviceModel: 'Budget Android',
          osVersion: 'Android 13',
          scenarioLabel: TapScenarioLabel.falseTableDrop,
          hasCase: false,
          measuredAccelHz: 200.0,
          measuredLinearAccelHz: 200.0,
          measuredGyroHz: 200.0,
          recordedAtUtc: DateTime.utc(2026, 10, 26),
        ),
        samples: _buildDropFalsePositiveSamples(),
      );

      final falseWalkCsv = formatSensorRecordingCsv(
        meta: RecordingSessionMeta(
          sessionId: 'false-03',
          deviceModel: 'Pixel 7',
          osVersion: 'Android 15',
          scenarioLabel: TapScenarioLabel.falseWalkPocket,
          hasCase: true,
          measuredAccelHz: 200.0,
          measuredLinearAccelHz: 200.0,
          measuredGyroHz: 200.0,
          recordedAtUtc: DateTime.utc(2026, 10, 26),
        ),
        samples: _buildWalkingFalsePositiveSamples(),
      );

      const evaluator = ImpactDatasetEvaluator();
      final result = evaluator.evaluateCsvDataset([
        trueTapTopCsv,
        trueTapBackCsv,
        falseShakeCsv,
        falseDropCsv,
        falseWalkCsv,
      ]);

      expect(result.truePositives, 2);
      expect(result.falseNegatives, 0);
      expect(result.trueNegatives, 3);
      expect(result.falsePositives, 0);
      expect(result.tpr, 1.0);
      expect(result.fpr, 0.0);
    });
  });
}
