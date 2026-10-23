import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:localsend_app/model/tap_to_share/sensor_sample.dart';
import 'package:localsend_app/util/tap_to_share/sensor_csv_serializer.dart';

/// Abstraction over device motion sensors (`accelerometer`, `userAccelerometer`, `gyroscope`)
/// so unit and widget tests can inject deterministic streams without hardware.
abstract class SensorSource {
  /// Starts listening to motion sensors at the requested [samplingPeriodUs] (default `5000` us = 200 Hz).
  Stream<SensorSample> startStream({int samplingPeriodUs = 5000});

  /// Stops active sensor subscriptions immediately.
  Future<void> stopStream();
}

/// Platform-channel [SensorSource] communicating with `org.localsend.localsend_app/tap_sensors`.
///
/// On desktop or when native sensor channels are unavailable, callers can either use the no-op fallback
/// or inject a synthetic [SensorSource] in tests.
class MethodChannelSensorSource implements SensorSource {
  static const MethodChannel _controlChannel = MethodChannel('org.localsend.localsend_app/tap_sensors_control');
  static const EventChannel _eventChannel = EventChannel('org.localsend.localsend_app/tap_sensors_events');

  StreamSubscription<dynamic>? _subscription;
  StreamController<SensorSample>? _controller;

  @override
  Stream<SensorSample> startStream({int samplingPeriodUs = 5000}) {
    final controller = StreamController<SensorSample>.broadcast(
      onCancel: () async {
        await stopStream();
      },
    );
    _controller = controller;

    final stopwatch = Stopwatch()..start();

    _subscription = _eventChannel
        .receiveBroadcastStream({'samplingPeriodUs': samplingPeriodUs})
        .listen(
          (dynamic event) {
            if (event is! Map) {
              return;
            }
            final typeStr = event['type'] as String?;
            final sensorType = switch (typeStr) {
              'accel' => SensorType.accelerometer,
              'linear_accel' => SensorType.userAccelerometer,
              'gyro' => SensorType.gyroscope,
              _ => null,
            };
            if (sensorType == null) {
              return;
            }

            final sensorTimestampUs = (event['timestampUs'] as num?)?.toInt() ?? stopwatch.elapsedMicroseconds;
            final rawX = (event['x'] as num?)?.toDouble() ?? 0.0;
            final rawY = (event['y'] as num?)?.toDouble() ?? 0.0;
            final rawZ = (event['z'] as num?)?.toDouble() ?? 0.0;
            final iosRawInG = (event['iosRawInG'] as bool?) ?? false;

            final normalized = normalizeSensorAxes(
              rawX: rawX,
              rawY: rawY,
              rawZ: rawZ,
              platform: defaultTargetPlatform,
              sensorType: sensorType,
              iosRawInG: iosRawInG,
            );

            controller.add(
              SensorSample(
                sensorType: sensorType,
                sensorTimestampUs: sensorTimestampUs,
                arrivalTimestampUs: stopwatch.elapsedMicroseconds,
                x: normalized.x,
                y: normalized.y,
                z: normalized.z,
              ),
            );
          },
          onError: (Object error, StackTrace stackTrace) {
            if (!controller.isClosed) {
              controller.addError(error, stackTrace);
            }
          },
        );

    return controller.stream;
  }

  @override
  Future<void> stopStream() async {
    await _subscription?.cancel();
    _subscription = null;
    await _controller?.close();
    _controller = null;
    try {
      await _controlChannel.invokeMethod<void>('stop');
    } on MissingPluginException {
      // Safe no-op when running on desktop or in widget tests without native sensor handlers.
    } on PlatformException {
      // Ignore stop errors on teardown.
    }
  }
}
