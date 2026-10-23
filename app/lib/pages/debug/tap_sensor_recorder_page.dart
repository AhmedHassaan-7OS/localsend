import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:localsend_app/model/tap_to_share/sensor_sample.dart';
import 'package:localsend_app/provider/tap_to_share/sensor_recorder_provider.dart';
import 'package:refena_flutter/refena_flutter.dart';

/// Developer diagnostic page for recording labeled motion-sensor datasets (Phase 1 / `001-sensor-recorder`).
///
/// Observes [AppLifecycleState] to automatically cancel sensor subscriptions when the app is backgrounded
/// or the screen turns off (`FR-7` / `AC-4`).
class TapSensorRecorderPage extends StatefulWidget {
  const TapSensorRecorderPage({super.key});

  @override
  State<TapSensorRecorderPage> createState() => _TapSensorRecorderPageState();
}

class _TapSensorRecorderPageState extends State<TapSensorRecorderPage> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    unawaited(_handleLifecycleChange(state));
  }

  Future<void> _handleLifecycleChange(AppLifecycleState state) async {
    await context.ref.notifier(sensorRecorderProvider).onAppLifecycleStateChanged(state);
  }

  @override
  Widget build(BuildContext context) {
    final recorderState = context.watch(sensorRecorderProvider);
    final notifier = context.ref.notifier(sensorRecorderProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Tap-to-Share Sensor Recorder'),
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        children: [
          Semantics(
            container: true,
            child: SwitchListTile(
              key: const ValueKey('tap_feature_flag_switch'),
              title: const Text('Enable Tap-to-Share (Experimental Flag)'),
              subtitle: const Text('Off by default. Must be enabled to subscribe to motion sensors.'),
              value: recorderState.featureEnabled,
              onChanged: (value) async {
                await notifier.setFeatureEnabled(value);
              },
            ),
          ),
          const Divider(),
          if (!recorderState.featureEnabled)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Text(
                'Tap-to-Share is disabled. Enable the experimental flag above to access the sensor recorder.',
                key: ValueKey('tap_recorder_disabled_notice'),
              ),
            )
          else ...[
            const Text(
              'Scenario Label',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            DropdownButtonFormField<TapScenarioLabel>(
              key: const ValueKey('tap_scenario_dropdown'),
              initialValue: recorderState.scenarioLabel,
              items: TapScenarioLabel.values
                  .map(
                    (label) => DropdownMenuItem<TapScenarioLabel>(
                      value: label,
                      child: Text('${label.key} (${label.isTrueTap ? "True" : "False"})'),
                    ),
                  )
                  .toList(),
              onChanged: recorderState.isRecording
                  ? null
                  : (label) {
                      if (label != null) {
                        notifier.setScenarioLabel(label);
                      }
                    },
            ),
            const SizedBox(height: 12),
            SwitchListTile(
              key: const ValueKey('tap_has_case_switch'),
              title: const Text('Protective case attached'),
              value: recorderState.hasCase,
              onChanged: recorderState.isRecording
                  ? null
                  : (value) {
                      notifier.setHasCase(hasCase: value);
                    },
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                SizedBox(
                  height: 48,
                  child: FilledButton.icon(
                    key: const ValueKey('tap_start_stop_button'),
                    onPressed: () async {
                      if (recorderState.isRecording) {
                        await notifier.stopRecording();
                      } else {
                        await notifier.startRecording();
                      }
                    },
                    icon: Icon(
                      recorderState.isRecording ? Icons.stop : Icons.fiber_manual_record,
                      semanticLabel: recorderState.isRecording ? 'Stop recording' : 'Start recording',
                    ),
                    label: Text(recorderState.isRecording ? 'Stop Recording' : 'Start Recording'),
                  ),
                ),
                SizedBox(
                  height: 48,
                  child: OutlinedButton.icon(
                    key: const ValueKey('tap_copy_csv_button'),
                    onPressed: recorderState.isRecording || recorderState.sampleCount == 0
                        ? null
                        : () async {
                            final csv = notifier.exportCsv(
                              deviceModel: Platform.localHostname,
                              osVersion: Platform.operatingSystemVersion,
                            );
                            await Clipboard.setData(ClipboardData(text: csv));
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text('Copied CSV (${recorderState.sampleCount} samples) to clipboard'),
                                ),
                              );
                            }
                          },
                    icon: const Icon(Icons.copy, semanticLabel: 'Copy CSV'),
                    label: const Text('Copy CSV'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Status: ${recorderState.isRecording ? "RECORDING" : "IDLE"}'),
                    Text('Buffered samples: ${recorderState.sampleCount}'),
                    Text('Measured Accelerometer: ${recorderState.measuredAccelHz.toStringAsFixed(1)} Hz'),
                    Text('Measured Linear Accel: ${recorderState.measuredLinearAccelHz.toStringAsFixed(1)} Hz'),
                    Text('Measured Gyroscope: ${recorderState.measuredGyroHz.toStringAsFixed(1)} Hz'),
                    if (recorderState.latestAccel != null) ...[
                      const SizedBox(height: 8),
                      Text(
                        'Accel (m/s²): X=${recorderState.latestAccel!.x.toStringAsFixed(2)}, '
                        'Y=${recorderState.latestAccel!.y.toStringAsFixed(2)}, '
                        'Z=${recorderState.latestAccel!.z.toStringAsFixed(2)}',
                      ),
                    ],
                    if (recorderState.latestGyro != null) ...[
                      Text(
                        'Gyro (rad/s): X=${recorderState.latestGyro!.x.toStringAsFixed(2)}, '
                        'Y=${recorderState.latestGyro!.y.toStringAsFixed(2)}, '
                        'Z=${recorderState.latestGyro!.z.toStringAsFixed(2)}',
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
