import 'package:localsend_app/model/tap_to_share/impact_event.dart';
import 'package:localsend_app/model/tap_to_share/sensor_sample.dart';
import 'package:localsend_app/util/tap_to_share/impact_detector.dart';

/// Parsed representation of a Phase 1 sensor recording CSV file.
class ParsedSensorRecording {
  final String sessionId;
  final TapScenarioLabel scenarioLabel;
  final bool isTrueTap;
  final bool hasCase;
  final List<SensorSample> samples;

  const ParsedSensorRecording({
    required this.sessionId,
    required this.scenarioLabel,
    required this.isTrueTap,
    required this.hasCase,
    required this.samples,
  });
}

/// Summary metrics from evaluating [ImpactDetector] over a labeled dataset of CSV recordings (`002-impact-detection` `FR-6`).
class DatasetEvaluationResult {
  final int truePositives;
  final int falsePositives;
  final int trueNegatives;
  final int falseNegatives;

  const DatasetEvaluationResult({
    required this.truePositives,
    required this.falsePositives,
    required this.trueNegatives,
    required this.falseNegatives,
  });

  /// True Positive Rate (`TP / (TP + FN)`), or `0.0` if no positive recordings exist.
  double get tpr {
    final totalPositives = truePositives + falseNegatives;
    return totalPositives == 0 ? 0.0 : truePositives / totalPositives;
  }

  /// False Positive Rate (`FP / (FP + TN)`), or `0.0` if no negative recordings exist.
  double get fpr {
    final totalNegatives = falsePositives + trueNegatives;
    return totalNegatives == 0 ? 0.0 : falsePositives / totalNegatives;
  }
}

/// Parses a CSV string produced by `formatSensorRecordingCsv` (`001-sensor-recorder`) back into
/// metadata and ordered [SensorSample]s.
ParsedSensorRecording parseSensorRecordingCsv(String csvContent) {
  String sessionId = 'unknown';
  TapScenarioLabel scenarioLabel = TapScenarioLabel.trueTapTopToTop;
  bool? explicitIsTrueTap;
  bool hasCase = false;
  final samples = <SensorSample>[];

  for (final rawLine in csvContent.split('\n')) {
    final line = rawLine.trim();
    if (line.isEmpty) {
      continue;
    }
    if (line.startsWith('#')) {
      final content = line.substring(1).trim();
      final colonIdx = content.indexOf(':');
      if (colonIdx <= 0) {
        continue;
      }
      final key = content.substring(0, colonIdx).trim();
      final value = content.substring(colonIdx + 1).trim();
      switch (key) {
        case 'session_id':
          sessionId = value;
        case 'label':
          for (final candidate in TapScenarioLabel.values) {
            if (candidate.key == value) {
              scenarioLabel = candidate;
              break;
            }
          }
        case 'is_true_tap':
          explicitIsTrueTap = value.toLowerCase() == 'true';
        case 'has_case':
          hasCase = value.toLowerCase() == 'true';
      }
      continue;
    }

    if (line.startsWith('sample_index,')) {
      continue;
    }

    final parts = line.split(',');
    if (parts.length < 6) {
      continue;
    }

    final sensorKey = parts[1].trim();
    final sensorType = switch (sensorKey) {
      'accel' => SensorType.accelerometer,
      'linear_accel' => SensorType.userAccelerometer,
      'gyro' => SensorType.gyroscope,
      _ => null,
    };
    if (sensorType == null) {
      continue;
    }

    final sensorTimestampUs = int.tryParse(parts[2].trim());
    final arrivalTimestampUs = int.tryParse(parts[3].trim());
    final x = double.tryParse(parts[4].trim());
    final y = double.tryParse(parts[5].trim());
    final z = double.tryParse(parts[6].trim());
    if (sensorTimestampUs == null || arrivalTimestampUs == null || x == null || y == null || z == null) {
      continue;
    }

    samples.add(
      SensorSample(
        sensorType: sensorType,
        sensorTimestampUs: sensorTimestampUs,
        arrivalTimestampUs: arrivalTimestampUs,
        x: x,
        y: y,
        z: z,
      ),
    );
  }

  return ParsedSensorRecording(
    sessionId: sessionId,
    scenarioLabel: scenarioLabel,
    isTrueTap: explicitIsTrueTap ?? scenarioLabel.isTrueTap,
    hasCase: hasCase,
    samples: samples,
  );
}

/// Evaluates [ImpactDetector] over a batch of labeled CSV recordings to measure `TPR` and `FPR` (`AC-6`).
class ImpactDatasetEvaluator {
  final ImpactDetectorConfig config;

  const ImpactDatasetEvaluator({
    this.config = const ImpactDetectorConfig(),
  });

  /// Replays a single [ParsedSensorRecording] through a fresh [ImpactDetector] and returns all detected tap events.
  List<DetectedTapEvent> replayRecording(ParsedSensorRecording recording) {
    final detector = ImpactDetector(config: config);
    final events = <DetectedTapEvent>[];
    for (final sample in recording.samples) {
      final event = detector.processSample(sample);
      if (event != null) {
        events.add(event);
      }
    }
    return events;
  }

  /// Evaluates a collection of CSV strings and computes confusion-matrix metrics (`TPR` and `FPR`).
  DatasetEvaluationResult evaluateCsvDataset(Iterable<String> csvRecordings) {
    int tp = 0;
    int fp = 0;
    int tn = 0;
    int fn = 0;

    for (final csv in csvRecordings) {
      final parsed = parseSensorRecordingCsv(csv);
      final detectedEvents = replayRecording(parsed);
      final detectedAnyTap = detectedEvents.isNotEmpty;

      if (parsed.isTrueTap) {
        if (detectedAnyTap) {
          tp++;
        } else {
          fn++;
        }
      } else {
        if (detectedAnyTap) {
          fp++;
        } else {
          tn++;
        }
      }
    }

    return DatasetEvaluationResult(
      truePositives: tp,
      falsePositives: fp,
      trueNegatives: tn,
      falseNegatives: fn,
    );
  }
}
