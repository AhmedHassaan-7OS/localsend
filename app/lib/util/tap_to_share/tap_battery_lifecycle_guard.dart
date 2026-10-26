/// Enforces rule `R4.2` (foreground & screen-on sensor discipline) and tracks active duty-cycle telemetry (`Spec 011`).
///
/// Sensors and UDP listeners are permitted to run **if and only if**:
/// `featureEnabled && isAppForegrounded && isScreenOn && !isIdleTimedOut`.
class TapBatteryLifecycleGuard {
  /// Maximum idle duration in microseconds before automatically suspending sensors (`5 minutes` default).
  final int idleTimeoutUs;

  bool _featureEnabled = false;
  bool _isAppForegrounded = true;
  bool _isScreenOn = true;
  bool _isIdleTimedOut = false;

  int? _activeSegmentStartUs;
  int _lastUserActivityUs = 0;
  int _cumulativeActiveUs = 0;
  int _falsePositiveRejections = 0;
  int _validTapDetections = 0;

  TapBatteryLifecycleGuard({
    this.idleTimeoutUs = 300000000, // 5 minutes
  });

  bool get featureEnabled => _featureEnabled;
  bool get isAppForegrounded => _isAppForegrounded;
  bool get isScreenOn => _isScreenOn;
  bool get isIdleTimedOut => _isIdleTimedOut;

  /// Whether hardware motion sensors and background UDP listeners are allowed to run (`R4.2`).
  bool get shouldRunSensors => _featureEnabled && _isAppForegrounded && _isScreenOn && !_isIdleTimedOut;

  int get falsePositiveRejections => _falsePositiveRejections;
  int get validTapDetections => _validTapDetections;

  /// Updates lifecycle state and accumulates active sensor time up to [nowUs].
  bool updateLifecycle({
    bool? featureEnabled,
    bool? isAppForegrounded,
    bool? isScreenOn,
    required int nowUs,
  }) {
    _flushActiveTime(nowUs);

    if (featureEnabled != null) {
      _featureEnabled = featureEnabled;
    }
    if (isAppForegrounded != null) {
      _isAppForegrounded = isAppForegrounded;
    }
    if (isScreenOn != null) {
      _isScreenOn = isScreenOn;
    }

    if (_featureEnabled && _isAppForegrounded && _isScreenOn) {
      if (_lastUserActivityUs == 0) {
        _lastUserActivityUs = nowUs;
      }
      if ((nowUs - _lastUserActivityUs) >= idleTimeoutUs) {
        _isIdleTimedOut = true;
      }
    }

    if (shouldRunSensors) {
      _activeSegmentStartUs ??= nowUs;
    } else {
      _activeSegmentStartUs = null;
    }

    return shouldRunSensors;
  }

  /// Records user interaction or screen wake, resetting any idle timeout.
  bool recordUserActivity({required int nowUs}) {
    _flushActiveTime(nowUs);
    _lastUserActivityUs = nowUs;
    _isIdleTimedOut = false;
    if (shouldRunSensors) {
      _activeSegmentStartUs ??= nowUs;
    }
    return shouldRunSensors;
  }

  /// Checks whether the idle timeout has elapsed at [nowUs] and suspends sensors if so.
  bool checkIdleTimeout({required int nowUs}) {
    return updateLifecycle(nowUs: nowUs);
  }

  void recordFalsePositiveRejection() {
    _falsePositiveRejections++;
  }

  void recordValidTapDetection() {
    _validTapDetections++;
  }

  /// Returns total cumulative time in microseconds during which sensors were active up to [nowUs].
  int totalActiveMicroseconds({required int nowUs}) {
    _flushActiveTime(nowUs);
    if (shouldRunSensors) {
      _activeSegmentStartUs = nowUs;
    }
    return _cumulativeActiveUs;
  }

  void _flushActiveTime(int nowUs) {
    final start = _activeSegmentStartUs;
    if (start != null && nowUs > start) {
      _cumulativeActiveUs += (nowUs - start);
      _activeSegmentStartUs = nowUs;
    }
  }
}
