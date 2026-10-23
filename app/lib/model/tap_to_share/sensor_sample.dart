/// Types of motion sensors recorded by the Tap-to-Share diagnostic recorder.
enum SensorType {
  /// Raw accelerometer including gravity ($m/s^2$).
  accelerometer('accel'),

  /// Linear acceleration excluding gravity ($m/s^2$).
  userAccelerometer('linear_accel'),

  /// Angular velocity from the gyroscope ($rad/s$).
  gyroscope('gyro')
  ;

  final String csvKey;

  const SensorType(this.csvKey);
}

/// Predefined scenario labels used to build a labeled Tap-to-Share dataset.
enum TapScenarioLabel {
  trueTapTopToTop('true_tap_top_to_top', isTrueTap: true),
  trueTapBackToBack('true_tap_back_to_back', isTrueTap: true),
  trueTapEdgeToEdge('true_tap_edge_to_edge', isTrueTap: true),
  falseWalkPocket('false_walk_pocket', isTrueTap: false),
  falseTransit('false_transit', isTrueTap: false),
  falseTableDrop('false_table_drop', isTrueTap: false),
  falseShake('false_shake', isTrueTap: false),
  falseScreenTap('false_screen_tap', isTrueTap: false),
  falseRingVibrate('false_ring_vibrate', isTrueTap: false)
  ;

  final String key;
  final bool isTrueTap;

  const TapScenarioLabel(this.key, {required this.isTrueTap});
}

/// A single motion sensor sample with both hardware sensor timestamp and arrival timestamp.
class SensorSample {
  final SensorType sensorType;

  /// Hardware sensor timestamp in microseconds (monotonic sensor clock).
  final int sensorTimestampUs;

  /// Application arrival timestamp in microseconds (monotonic Dart stopwatch/clock).
  final int arrivalTimestampUs;

  /// Normalized X-axis value ($+X$ points right of the screen).
  final double x;

  /// Normalized Y-axis value ($+Y$ points up along the screen).
  final double y;

  /// Normalized Z-axis value ($+Z$ points out of the screen).
  final double z;

  const SensorSample({
    required this.sensorType,
    required this.sensorTimestampUs,
    required this.arrivalTimestampUs,
    required this.x,
    required this.y,
    required this.z,
  });
}

/// Metadata describing a single labeled sensor recording session.
class RecordingSessionMeta {
  final String sessionId;
  final String deviceModel;
  final String osVersion;
  final TapScenarioLabel scenarioLabel;
  final bool hasCase;
  final double measuredAccelHz;
  final double measuredLinearAccelHz;
  final double measuredGyroHz;
  final DateTime recordedAtUtc;

  const RecordingSessionMeta({
    required this.sessionId,
    required this.deviceModel,
    required this.osVersion,
    required this.scenarioLabel,
    required this.hasCase,
    required this.measuredAccelHz,
    required this.measuredLinearAccelHz,
    required this.measuredGyroHz,
    required this.recordedAtUtc,
  });
}
