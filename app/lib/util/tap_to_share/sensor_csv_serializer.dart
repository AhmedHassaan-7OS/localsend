import 'package:flutter/foundation.dart';
import 'package:localsend_app/model/tap_to_share/sensor_sample.dart';

/// Standard gravitational acceleration in $m/s^2$ used when converting iOS CoreMotion `G` units.
const double kStandardGravityMps2 = 9.80665;

/// Normalizes platform sensor readings into a single right-handed device frame:
/// - $+X$: right edge of the screen
/// - $+Y$: top edge of the screen
/// - $+Z$: pointing out of the front screen toward the user
///
/// Android `SensorEvent` reports acceleration in $m/s^2$ (`a = F_sensor / m - g`) where a device
/// resting face-up on a table reads $(0, 0, +9.81)$ and accelerating the phone forward along $+Y$
/// yields $+Y > 0$.
///
/// If a raw iOS CoreMotion stream is passed in `G` units where resting face-up reads $(0, 0, -1.0\text{ G})$,
/// set [iosRawInG] to `true` to invert sign and scale by [kStandardGravityMps2] so both platforms match.
({double x, double y, double z}) normalizeSensorAxes({
  required double rawX,
  required double rawY,
  required double rawZ,
  required TargetPlatform platform,
  required SensorType sensorType,
  bool iosRawInG = false,
}) {
  if (platform == TargetPlatform.iOS && iosRawInG && sensorType != SensorType.gyroscope) {
    return (
      x: -rawX * kStandardGravityMps2,
      y: -rawY * kStandardGravityMps2,
      z: -rawZ * kStandardGravityMps2,
    );
  }
  return (x: rawX, y: rawY, z: rawZ);
}

/// Computes the effective sampling rate in Hz from hardware sensor timestamps (`sensorTimestampUs`)
/// for a given [sensorType].
///
/// Uses `(count - 1) / ((lastTimestampUs - firstTimestampUs) / 1e6)` as required by `001-sensor-recorder` (`AC-3`),
/// avoiding arrival-time jitter on the UI isolate.
double computeMeasuredHz(Iterable<SensorSample> samples, SensorType sensorType) {
  int? firstTimestampUs;
  int? lastTimestampUs;
  int count = 0;

  for (final sample in samples) {
    if (sample.sensorType != sensorType) {
      continue;
    }
    firstTimestampUs ??= sample.sensorTimestampUs;
    lastTimestampUs = sample.sensorTimestampUs;
    count++;
  }

  if (count < 2 || firstTimestampUs == null || lastTimestampUs == null) {
    return 0.0;
  }

  final durationUs = lastTimestampUs - firstTimestampUs;
  if (durationUs <= 0) {
    return 0.0;
  }

  return (count - 1) * 1000000.0 / durationUs;
}

/// Serializes a labeled recording session into a CSV string with metadata header comments (`FR-6` / `AC-2`).
String formatSensorRecordingCsv({
  required RecordingSessionMeta meta,
  required List<SensorSample> samples,
}) {
  final buffer = StringBuffer()
    ..writeln('# session_id: ${meta.sessionId}')
    ..writeln('# recorded_at_utc: ${meta.recordedAtUtc.toUtc().toIso8601String()}')
    ..writeln('# device_model: ${_sanitizeHeaderValue(meta.deviceModel)}')
    ..writeln('# os_version: ${_sanitizeHeaderValue(meta.osVersion)}')
    ..writeln('# label: ${meta.scenarioLabel.key}')
    ..writeln('# is_true_tap: ${meta.scenarioLabel.isTrueTap}')
    ..writeln('# has_case: ${meta.hasCase}')
    ..writeln('# measured_accel_hz: ${meta.measuredAccelHz.toStringAsFixed(2)}')
    ..writeln('# measured_linear_accel_hz: ${meta.measuredLinearAccelHz.toStringAsFixed(2)}')
    ..writeln('# measured_gyro_hz: ${meta.measuredGyroHz.toStringAsFixed(2)}')
    ..writeln('sample_index,sensor_type,sensor_timestamp_us,arrival_timestamp_us,x,y,z');

  for (var i = 0; i < samples.length; i++) {
    final s = samples[i];
    buffer.writeln(
      '$i,${s.sensorType.csvKey},${s.sensorTimestampUs},${s.arrivalTimestampUs},'
      '${s.x.toStringAsFixed(6)},${s.y.toStringAsFixed(6)},${s.z.toStringAsFixed(6)}',
    );
  }

  return buffer.toString();
}

String _sanitizeHeaderValue(String input) {
  return input.replaceAll('\r', ' ').replaceAll('\n', ' ').trim();
}
