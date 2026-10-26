import 'dart:async';
import 'dart:isolate';

import 'package:localsend_app/model/tap_to_share/impact_event.dart';
import 'package:localsend_app/model/tap_to_share/sensor_sample.dart';
import 'package:localsend_app/util/tap_to_share/impact_detector.dart';

/// Runs [ImpactDetector] inside a dedicated background [Isolate] (`002-impact-detection` `FR-5` / `R4.1`)
/// so high-frequency (`100–200 Hz`) sensor filtering and quaternion math never run on the UI isolate.
class ImpactDetectorIsolate {
  Isolate? _isolate;
  ReceivePort? _receivePort;
  SendPort? _workerSendPort;
  StreamController<DetectedTapEvent>? _eventController;
  final List<Map<String, dynamic>> _pendingBeforeReady = <Map<String, dynamic>>[];

  bool get isRunning => _isolate != null;

  /// Spawns the background impact-detector isolate and returns a broadcast stream of [DetectedTapEvent]s.
  Future<Stream<DetectedTapEvent>> start({
    ImpactDetectorConfig config = const ImpactDetectorConfig(),
  }) async {
    await stop();

    final receivePort = ReceivePort();
    final eventController = StreamController<DetectedTapEvent>.broadcast();
    final readyCompleter = Completer<SendPort>();

    _receivePort = receivePort;
    _eventController = eventController;

    receivePort.listen((dynamic message) {
      if (message is SendPort) {
        _workerSendPort = message;
        for (final queued in _pendingBeforeReady) {
          message.send(queued);
        }
        _pendingBeforeReady.clear();
        if (!readyCompleter.isCompleted) {
          readyCompleter.complete(message);
        }
      } else if (message is Map) {
        final map = Map<String, dynamic>.from(message);
        if (!eventController.isClosed) {
          eventController.add(DetectedTapEvent.fromMap(map));
        }
      }
    });

    _isolate = await Isolate.spawn<_IsolateInitPayload>(
      _impactDetectorIsolateEntry,
      _IsolateInitPayload(
        replyPort: receivePort.sendPort,
        configMap: config.toMap(),
      ),
      debugName: 'TapToShareImpactDetectorIsolate',
    );

    await readyCompleter.future;
    return eventController.stream;
  }

  /// Sends a [SensorSample] to the background isolate for processing.
  void addSample(SensorSample sample) {
    final msg = <String, dynamic>{
      'cmd': 'sample',
      'sensorType': sample.sensorType.name,
      'sensorTimestampUs': sample.sensorTimestampUs,
      'arrivalTimestampUs': sample.arrivalTimestampUs,
      'x': sample.x,
      'y': sample.y,
      'z': sample.z,
    };

    final port = _workerSendPort;
    if (port != null) {
      port.send(msg);
    } else if (_isolate != null) {
      _pendingBeforeReady.add(msg);
    }
  }

  /// Resets the detector state inside the background isolate.
  void reset() {
    _workerSendPort?.send(const <String, dynamic>{'cmd': 'reset'});
  }

  /// Terminates the background isolate and closes all ports/streams.
  Future<void> stop() async {
    _pendingBeforeReady.clear();
    _workerSendPort?.send(const <String, dynamic>{'cmd': 'stop'});
    _workerSendPort = null;
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _receivePort?.close();
    _receivePort = null;
    await _eventController?.close();
    _eventController = null;
  }
}

class _IsolateInitPayload {
  final SendPort replyPort;
  final Map<String, dynamic> configMap;

  const _IsolateInitPayload({
    required this.replyPort,
    required this.configMap,
  });
}

void _impactDetectorIsolateEntry(_IsolateInitPayload init) {
  final workerPort = ReceivePort();
  final detector = ImpactDetector(
    config: ImpactDetectorConfig.fromMap(init.configMap),
  );

  init.replyPort.send(workerPort.sendPort);

  workerPort.listen((dynamic message) {
    if (message is! Map) {
      return;
    }
    final cmd = message['cmd'] as String?;
    if (cmd == 'stop') {
      workerPort.close();
      return;
    }
    if (cmd == 'reset') {
      detector.reset();
      return;
    }
    if (cmd == 'sample') {
      final typeName = message['sensorType'] as String;
      final sensorType = SensorType.values.firstWhere((e) => e.name == typeName);
      final sample = SensorSample(
        sensorType: sensorType,
        sensorTimestampUs: (message['sensorTimestampUs'] as num).toInt(),
        arrivalTimestampUs: (message['arrivalTimestampUs'] as num).toInt(),
        x: (message['x'] as num).toDouble(),
        y: (message['y'] as num).toDouble(),
        z: (message['z'] as num).toDouble(),
      );
      final detected = detector.processSample(sample);
      if (detected != null) {
        init.replyPort.send(detected.toMap());
      }
    }
  });
}
