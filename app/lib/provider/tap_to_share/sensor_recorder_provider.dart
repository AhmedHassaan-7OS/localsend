import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:localsend_app/model/tap_to_share/sensor_sample.dart';
import 'package:localsend_app/util/tap_to_share/sensor_csv_serializer.dart';
import 'package:localsend_app/util/tap_to_share/sensor_source.dart';
import 'package:logging/logging.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:uuid/uuid.dart';

final _logger = Logger('TapToShare');

/// Immutable state for the Phase 1 Tap-to-Share diagnostic sensor recorder.
class SensorRecorderState {
  /// Master feature flag for Tap-to-Share (`OFF` by default per `R2.2` / `AC-1`).
  final bool featureEnabled;

  /// Whether a recording session is currently active.
  final bool isRecording;

  /// Selected scenario label for the current or next session.
  final TapScenarioLabel scenarioLabel;

  /// Whether the device currently has a protective case on.
  final bool hasCase;

  /// Total buffered samples in the current/last session.
  final int sampleCount;

  /// Measured accelerometer rate in Hz from hardware timestamps.
  final double measuredAccelHz;

  /// Measured linear acceleration rate in Hz from hardware timestamps.
  final double measuredLinearAccelHz;

  /// Measured gyroscope rate in Hz from hardware timestamps.
  final double measuredGyroHz;

  /// Latest normalized accelerometer sample (for axis verification UI).
  final SensorSample? latestAccel;

  /// Latest normalized gyroscope sample (for axis verification UI).
  final SensorSample? latestGyro;

  const SensorRecorderState({
    this.featureEnabled = false,
    this.isRecording = false,
    this.scenarioLabel = TapScenarioLabel.trueTapTopToTop,
    this.hasCase = false,
    this.sampleCount = 0,
    this.measuredAccelHz = 0.0,
    this.measuredLinearAccelHz = 0.0,
    this.measuredGyroHz = 0.0,
    this.latestAccel,
    this.latestGyro,
  });

  SensorRecorderState copyWith({
    bool? featureEnabled,
    bool? isRecording,
    TapScenarioLabel? scenarioLabel,
    bool? hasCase,
    int? sampleCount,
    double? measuredAccelHz,
    double? measuredLinearAccelHz,
    double? measuredGyroHz,
    SensorSample? latestAccel,
    SensorSample? latestGyro,
  }) {
    return SensorRecorderState(
      featureEnabled: featureEnabled ?? this.featureEnabled,
      isRecording: isRecording ?? this.isRecording,
      scenarioLabel: scenarioLabel ?? this.scenarioLabel,
      hasCase: hasCase ?? this.hasCase,
      sampleCount: sampleCount ?? this.sampleCount,
      measuredAccelHz: measuredAccelHz ?? this.measuredAccelHz,
      measuredLinearAccelHz: measuredLinearAccelHz ?? this.measuredLinearAccelHz,
      measuredGyroHz: measuredGyroHz ?? this.measuredGyroHz,
      latestAccel: latestAccel ?? this.latestAccel,
      latestGyro: latestGyro ?? this.latestGyro,
    );
  }
}

final sensorSourceProvider = Provider<SensorSource>((ref) {
  return MethodChannelSensorSource();
});

final sensorRecorderProvider = NotifierProvider<SensorRecorderController, SensorRecorderState>((ref) {
  return SensorRecorderController(ref.read(sensorSourceProvider));
});

/// Controller managing labeled sensor recording sessions, rate measurement, and lifecycle safety (`FR-1`..`FR-7`).
class SensorRecorderController extends Notifier<SensorRecorderState> {
  final SensorSource _sensorSource;
  final List<SensorSample> _buffer = <SensorSample>[];
  StreamSubscription<SensorSample>? _subscription;
  int _lastUiUpdateUs = 0;

  /// Minimum interval between UI state updates during high-rate recording (`100 ms` = 10 Hz per `001-sensor-recorder` §5).
  static const int uiThrottleIntervalUs = 100000;

  SensorRecorderController(this._sensorSource);

  @override
  SensorRecorderState init() => const SensorRecorderState();

  /// Returns an unmodifiable snapshot of the recorded samples in the buffer.
  List<SensorSample> get bufferedSamples => List<SensorSample>.unmodifiable(_buffer);

  /// Enables or disables the Tap-to-Share feature flag (`OFF` by default).
  /// Disabling immediately stops any active recording.
  Future<void> setFeatureEnabled(bool enabled) async {
    if (!enabled && state.isRecording) {
      await stopRecording();
    }
    state = state.copyWith(featureEnabled: enabled);
    _logger.info('Tap-to-Share feature flag set to: $enabled');
  }

  void setScenarioLabel(TapScenarioLabel label) {
    state = state.copyWith(scenarioLabel: label);
  }

  void setHasCase({required bool hasCase}) {
    state = state.copyWith(hasCase: hasCase);
  }

  /// Starts recording motion sensors if and only if [SensorRecorderState.featureEnabled] is `true` (`AC-1`).
  Future<bool> startRecording({int samplingPeriodUs = 5000}) async {
    if (!state.featureEnabled) {
      _logger.warning('Attempted to start sensor recording while feature flag is disabled.');
      return false;
    }
    if (state.isRecording) {
      return true;
    }

    _buffer.clear();
    _lastUiUpdateUs = 0;

    state = state.copyWith(
      isRecording: true,
      sampleCount: 0,
      measuredAccelHz: 0.0,
      measuredLinearAccelHz: 0.0,
      measuredGyroHz: 0.0,
    );

    _logger.info('Starting sensor recording for scenario=${state.scenarioLabel.key}, hasCase=${state.hasCase}');

    final stream = _sensorSource.startStream(samplingPeriodUs: samplingPeriodUs);
    _subscription = stream.listen(
      _onSample,
      onError: (Object error, StackTrace stackTrace) {
        _logger.warning('Sensor stream error', error, stackTrace);
      },
    );
    return true;
  }

  void _onSample(SensorSample sample) {
    _buffer.add(sample);

    final latestAccel = sample.sensorType == SensorType.accelerometer ? sample : state.latestAccel;
    final latestGyro = sample.sensorType == SensorType.gyroscope ? sample : state.latestGyro;

    if (_lastUiUpdateUs == 0 || (sample.arrivalTimestampUs - _lastUiUpdateUs) >= uiThrottleIntervalUs) {
      _lastUiUpdateUs = sample.arrivalTimestampUs;
      state = state.copyWith(
        sampleCount: _buffer.length,
        measuredAccelHz: computeMeasuredHz(_buffer, SensorType.accelerometer),
        measuredLinearAccelHz: computeMeasuredHz(_buffer, SensorType.userAccelerometer),
        measuredGyroHz: computeMeasuredHz(_buffer, SensorType.gyroscope),
        latestAccel: latestAccel,
        latestGyro: latestGyro,
      );
    }
  }

  /// Stops active sensor subscriptions and computes final sampling rates.
  Future<void> stopRecording() async {
    if (!state.isRecording && _subscription == null) {
      return;
    }
    await _subscription?.cancel();
    _subscription = null;
    await _sensorSource.stopStream();

    state = state.copyWith(
      isRecording: false,
      sampleCount: _buffer.length,
      measuredAccelHz: computeMeasuredHz(_buffer, SensorType.accelerometer),
      measuredLinearAccelHz: computeMeasuredHz(_buffer, SensorType.userAccelerometer),
      measuredGyroHz: computeMeasuredHz(_buffer, SensorType.gyroscope),
    );
    _logger.info(
      'Stopped sensor recording: samples=${_buffer.length}, '
      'accelHz=${state.measuredAccelHz.toStringAsFixed(1)}, '
      'gyroHz=${state.measuredGyroHz.toStringAsFixed(1)}',
    );
  }

  /// Handles app lifecycle changes (`FR-7` / `AC-4`): immediately stops sensor streams when paused or inactive.
  Future<void> onAppLifecycleStateChanged(AppLifecycleState lifecycleState) async {
    if (lifecycleState == AppLifecycleState.paused ||
        lifecycleState == AppLifecycleState.inactive ||
        lifecycleState == AppLifecycleState.detached ||
        lifecycleState == AppLifecycleState.hidden) {
      if (state.isRecording) {
        _logger.info('App lifecycle changed to $lifecycleState; auto-stopping sensor recording.');
        await stopRecording();
      }
    }
  }

  /// Exports the currently buffered recording session as a CSV string (`FR-6` / `AC-2`).
  String exportCsv({
    required String deviceModel,
    required String osVersion,
    DateTime? recordedAtUtc,
    String? sessionId,
  }) {
    final meta = RecordingSessionMeta(
      sessionId: sessionId ?? const Uuid().v4(),
      deviceModel: deviceModel,
      osVersion: osVersion,
      scenarioLabel: state.scenarioLabel,
      hasCase: state.hasCase,
      measuredAccelHz: computeMeasuredHz(_buffer, SensorType.accelerometer),
      measuredLinearAccelHz: computeMeasuredHz(_buffer, SensorType.userAccelerometer),
      measuredGyroHz: computeMeasuredHz(_buffer, SensorType.gyroscope),
      recordedAtUtc: (recordedAtUtc ?? DateTime.now()).toUtc(),
    );
    return formatSensorRecordingCsv(meta: meta, samples: _buffer);
  }

  @override
  void dispose() {
    unawaited(stopRecording());
    super.dispose();
  }
}
