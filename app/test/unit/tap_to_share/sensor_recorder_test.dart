import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/model/tap_to_share/sensor_sample.dart';
import 'package:localsend_app/pages/debug/tap_sensor_recorder_page.dart';
import 'package:localsend_app/provider/tap_to_share/sensor_recorder_provider.dart';
import 'package:localsend_app/util/tap_to_share/sensor_csv_serializer.dart';
import 'package:localsend_app/util/tap_to_share/sensor_source.dart';
import 'package:refena_flutter/refena_flutter.dart';

class _FakeSensorSource implements SensorSource {
  StreamController<SensorSample>? controller;
  int startCount = 0;
  int stopCount = 0;

  @override
  Stream<SensorSample> startStream({int samplingPeriodUs = 5000}) {
    startCount++;
    controller = StreamController<SensorSample>.broadcast();
    return controller!.stream;
  }

  @override
  Future<void> stopStream() async {
    stopCount++;
    await controller?.close();
    controller = null;
  }

  void emit(SensorSample sample) {
    controller?.add(sample);
  }
}

void main() {
  group('001-sensor-recorder unit & widget tests', () {
    test('AC-1: With feature flag false (default), no sensor streams are subscribed', () async {
      final fakeSource = _FakeSensorSource();
      final container = RefenaContainer(
        overrides: [
          sensorSourceProvider.overrideWithValue(fakeSource),
        ],
      );

      final state = container.read(sensorRecorderProvider);
      expect(state.featureEnabled, isFalse);
      expect(state.isRecording, isFalse);

      final started = await container.notifier(sensorRecorderProvider).startRecording();
      expect(started, isFalse);
      expect(fakeSource.startCount, 0);
      expect(container.read(sensorRecorderProvider).isRecording, isFalse);
    });

    test('AC-2: Recording with a mock sensor stream produces valid CSV with metadata and hardware timestamps', () async {
      final fakeSource = _FakeSensorSource();
      final container = RefenaContainer(
        overrides: [
          sensorSourceProvider.overrideWithValue(fakeSource),
        ],
      );

      final notifier = container.notifier(sensorRecorderProvider);
      await notifier.setFeatureEnabled(true);
      notifier.setScenarioLabel(TapScenarioLabel.trueTapBackToBack);
      notifier.setHasCase(hasCase: true);

      final started = await notifier.startRecording();
      expect(started, isTrue);
      expect(fakeSource.startCount, 1);

      fakeSource.emit(
        const SensorSample(
          sensorType: SensorType.accelerometer,
          sensorTimestampUs: 1000000,
          arrivalTimestampUs: 1000120,
          x: 0.125,
          y: -0.5,
          z: 9.81,
        ),
      );
      fakeSource.emit(
        const SensorSample(
          sensorType: SensorType.gyroscope,
          sensorTimestampUs: 1005000,
          arrivalTimestampUs: 1005090,
          x: 0.01,
          y: 0.02,
          z: -0.03,
        ),
      );
      fakeSource.emit(
        const SensorSample(
          sensorType: SensorType.accelerometer,
          sensorTimestampUs: 1010000,
          arrivalTimestampUs: 1010200,
          x: 0.25,
          y: -0.75,
          z: 14.2,
        ),
      );

      await Future<void>.delayed(Duration.zero);
      await notifier.stopRecording();

      final csv = notifier.exportCsv(
        deviceModel: 'Pixel 7',
        osVersion: 'Android 15',
        recordedAtUtc: DateTime.utc(2026, 10, 24, 0, 0, 0),
        sessionId: 'test-session-001',
      );

      expect(csv, contains('# session_id: test-session-001'));
      expect(csv, contains('# device_model: Pixel 7'));
      expect(csv, contains('# os_version: Android 15'));
      expect(csv, contains('# label: true_tap_back_to_back'));
      expect(csv, contains('# is_true_tap: true'));
      expect(csv, contains('# has_case: true'));
      expect(csv, contains('# measured_accel_hz: 100.00'));
      expect(csv, contains('sample_index,sensor_type,sensor_timestamp_us,arrival_timestamp_us,x,y,z'));
      expect(csv, contains('0,accel,1000000,1000120,0.125000,-0.500000,9.810000'));
      expect(csv, contains('1,gyro,1005000,1005090,0.010000,0.020000,-0.030000'));
      expect(csv, contains('2,accel,1010000,1010200,0.250000,-0.750000,14.200000'));
    });

    test('AC-3: Measured sampling rate (Hz) is accurately calculated from sensor_timestamp_us deltas', () {
      // 101 samples spaced by 10,000 us (10 ms) -> exactly 1.0 second span -> 100.0 Hz,
      // even if arrivalTimestampUs has heavy UI jitter.
      final samples = List<SensorSample>.generate(
        101,
        (i) => SensorSample(
          sensorType: SensorType.accelerometer,
          sensorTimestampUs: 500000 + (i * 10000),
          arrivalTimestampUs: 500000 + (i * 10000) + (i.isEven ? 3500 : -2000),
          x: 0.0,
          y: 0.0,
          z: 9.81,
        ),
      );

      final hz = computeMeasuredHz(samples, SensorType.accelerometer);
      expect(hz, closeTo(100.0, 0.01));
      expect(computeMeasuredHz(samples, SensorType.gyroscope), 0.0);
    });

    test('AC-4: Pausing the app (AppLifecycleState.paused) immediately cancels active sensor subscriptions', () async {
      final fakeSource = _FakeSensorSource();
      final container = RefenaContainer(
        overrides: [
          sensorSourceProvider.overrideWithValue(fakeSource),
        ],
      );

      final notifier = container.notifier(sensorRecorderProvider);
      await notifier.setFeatureEnabled(true);
      await notifier.startRecording();
      expect(container.read(sensorRecorderProvider).isRecording, isTrue);

      await notifier.onAppLifecycleStateChanged(AppLifecycleState.paused);
      expect(container.read(sensorRecorderProvider).isRecording, isFalse);
      expect(fakeSource.stopCount, greaterThanOrEqualTo(1));
    });

    test('AC-5: Axis normalization converts iOS raw G units to matching right-handed m/s^2 signs', () {
      final androidSample = normalizeSensorAxes(
        rawX: 1.5,
        rawY: -2.0,
        rawZ: kStandardGravityMps2,
        platform: TargetPlatform.android,
        sensorType: SensorType.accelerometer,
      );
      // On iOS CoreMotion raw G, a face-up phone has Z = -1.0 G and opposite reaction sign.
      final iosSample = normalizeSensorAxes(
        rawX: -1.5 / kStandardGravityMps2,
        rawY: 2.0 / kStandardGravityMps2,
        rawZ: -1.0,
        platform: TargetPlatform.iOS,
        sensorType: SensorType.accelerometer,
        iosRawInG: true,
      );

      expect(iosSample.x, closeTo(androidSample.x, 1e-6));
      expect(iosSample.y, closeTo(androidSample.y, 1e-6));
      expect(iosSample.z, closeTo(androidSample.z, 1e-6));
    });

    testWidgets('AC-1 & a11y: Recorder controls are hidden when flag is off, and meet tap target / semantics guidelines when enabled', (
      tester,
    ) async {
      final fakeSource = _FakeSensorSource();
      final container = RefenaContainer(
        overrides: [
          sensorSourceProvider.overrideWithValue(fakeSource),
        ],
      );

      await tester.pumpWidget(
        RefenaScope.withContainer(
          container: container,
          child: const MaterialApp(
            home: TapSensorRecorderPage(),
          ),
        ),
      );

      // Initially disabled: controls hidden, notice visible.
      expect(find.byKey(const ValueKey('tap_recorder_disabled_notice')), findsOneWidget);
      expect(find.byKey(const ValueKey('tap_start_stop_button')), findsNothing);

      // Enable the experimental flag switch.
      await tester.tap(find.byKey(const ValueKey('tap_feature_flag_switch')));
      await tester.pumpAndSettle();

      final startStopFinder = find.byKey(const ValueKey('tap_start_stop_button'));
      expect(startStopFinder, findsOneWidget);

      // Verify minimum 48dp height for interactive buttons (RULES R4.10).
      final buttonSize = tester.getSize(startStopFinder);
      expect(buttonSize.height, greaterThanOrEqualTo(48.0));

      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
    });
  });
}
