import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:localsend_app/model/tap_to_share/impact_event.dart';
import 'package:localsend_app/model/tap_to_share/sensor_sample.dart';
import 'package:localsend_app/pages/debug/tap_sensor_recorder_page.dart';
import 'package:localsend_app/provider/favorites_provider.dart';
import 'package:localsend_app/provider/security_provider.dart';
import 'package:localsend_app/provider/tap_to_share/sensor_recorder_provider.dart';
import 'package:localsend_app/provider/tap_to_share/tap_security_provider.dart';
import 'package:localsend_app/provider/tap_to_share/tap_transfer_state_machine.dart';
import 'package:localsend_app/util/native/platform_check.dart';
import 'package:localsend_app/util/tap_to_share/desktop_tap_coordinator.dart';
import 'package:localsend_app/util/tap_to_share/impact_detector_isolate.dart';
import 'package:localsend_app/util/tap_to_share/peer_tap_matcher.dart';
import 'package:localsend_app/util/tap_to_share/sensor_source.dart';
import 'package:localsend_app/util/tap_to_share/tap_battery_lifecycle_guard.dart';
import 'package:localsend_app/util/tap_to_share/tap_security_policy.dart';
import 'package:localsend_app/util/tap_to_share/tap_udp_coordinator.dart';
import 'package:localsend_app/widget/tap_to_share/tap_to_share_overlay.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:routerino/routerino.dart';

/// Live coordinator widget mounted on [SendTab] that connects hardware sensors,
/// [TapUdpCoordinator], [DesktopTapCoordinator], [ImpactDetectorIsolate],
/// [TapTransferStateMachineController], and [TapToShareOverlayCard].
class TapToShareLiveBanner extends StatefulWidget {
  final List<String> selectedFilePaths;
  final List<String> knownPeerIps;
  final String? firstNearbyPeerFingerprint;
  final String? firstNearbyPeerAlias;
  final VoidCallback? onTransferConfirmed;

  const TapToShareLiveBanner({
    super.key,
    required this.selectedFilePaths,
    this.knownPeerIps = const [],
    this.firstNearbyPeerFingerprint,
    this.firstNearbyPeerAlias,
    this.onTransferConfirmed,
  });

  @override
  State<TapToShareLiveBanner> createState() => _TapToShareLiveBannerState();
}

class _TapToShareLiveBannerState extends State<TapToShareLiveBanner> with WidgetsBindingObserver, Refena {
  final SensorSource _sensorSource = MethodChannelSensorSource();
  final TapBatteryLifecycleGuard _batteryGuard = TapBatteryLifecycleGuard();
  ImpactDetectorIsolate? _detectorIsolate;
  TapUdpCoordinator? _udpCoordinator;
  DesktopTapCoordinator? _desktopCoordinator;
  StreamSubscription<SensorSample>? _sensorSub;
  StreamSubscription<DetectedTapEvent>? _tapSub;
  StreamSubscription<ReceivedUdpTapPacket>? _udpSub;
  bool _running = false;
  int _nonceCounter = 0;
  TapTransferPhase? _lastObservedPhase;

  bool get _isDesktop => checkPlatformIsDesktop();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final nowUs = DateTime.now().microsecondsSinceEpoch;
    final isForeground = state == AppLifecycleState.resumed;
    _batteryGuard.updateLifecycle(
      isAppForegrounded: isForeground,
      isScreenOn: isForeground,
      nowUs: nowUs,
    );
    if (!isForeground) {
      unawaited(_stopListening());
    } else {
      final settings = ref.read(tapToShareSettingsProvider);
      if (settings.isEnabled) {
        unawaited(_startListening(settings.sensitivityPreset.toDetectorConfig()));
      }
    }
  }

  Future<void> _startListening(ImpactDetectorConfig config) async {
    if (_running) {
      return;
    }
    _running = true;
    final nowUs = DateTime.now().microsecondsSinceEpoch;
    _batteryGuard.updateLifecycle(
      featureEnabled: true,
      isAppForegrounded: true,
      isScreenOn: true,
      nowUs: nowUs,
    );

    try {
      final localFp = ref.read(securityProvider).certificateHash;
      final stateMachine = ref.notifier(tapTransferStateMachineProvider);
      stateMachine.arm(selectedFiles: widget.selectedFilePaths);

      // Start LAN UDP Coordinator on both Mobile and Desktop (`Spec 007` & `Spec 011`).
      final udp = TapUdpCoordinator(localFingerprint: localFp);
      try {
        await udp.start();
        _udpCoordinator = udp;
        _desktopCoordinator = DesktopTapCoordinator(
          capability: DesktopTapCapability(
            isDesktopPlatform: _isDesktop,
            hasImuSensors: !_isDesktop,
            hasBluetoothAdapter: true,
          ),
          securityGuard: TapSecurityPolicyGuard(localFingerprint: localFp),
        );

        _udpSub = udp.announcementStream.listen(_onUdpAnnouncementReceived);
      } catch (_) {
        // Port may already be bound by another instance on the same host; continue gracefully.
      }

      if (!_isDesktop) {
        final isolate = ImpactDetectorIsolate();
        final tapStream = await isolate.start(config: config);
        if (!mounted || !_running) {
          await isolate.stop();
          return;
        }
        _detectorIsolate = isolate;

        _tapSub = tapStream.listen((tapEvent) {
          _batteryGuard.recordValidTapDetection();
          final nonce = 'live-tap-${DateTime.now().microsecondsSinceEpoch}-${++_nonceCounter}';
          final accepted = stateMachine.onLocalTapDetected(
            tapEvent,
            localNonce: nonce,
          );
          if (!accepted) {
            return;
          }

          // Broadcast our physical tap over LAN UDP to nearby phones and desktops!
          final announcement = PeerTapAnnouncement(
            senderFingerprint: localFp,
            impactTimestampUs: tapEvent.impactTimestampUs,
            nonce: nonce,
            peakLinearAccelMps2: tapEvent.peakLinearAccelMps2,
            posture: tapEvent.posture,
            dirX: tapEvent.dirX,
            dirY: tapEvent.dirY,
            dirZ: tapEvent.dirZ,
            hasSelectedFiles: widget.selectedFilePaths.isNotEmpty,
          );
          _udpCoordinator?.broadcastTapAnnouncement(
            announcement,
            knownPeerIps: widget.knownPeerIps,
          );

          if (widget.firstNearbyPeerFingerprint != null) {
            stateMachine.onPeerMatched(
              peerFingerprint: widget.firstNearbyPeerFingerprint!,
              peerNonce: 'peer-auto-${++_nonceCounter}',
              peerHasFiles: widget.selectedFilePaths.isEmpty,
            );
          }
        });

        final sampleStream = _sensorSource.startStream(samplingPeriodUs: 10000); // 100 Hz
        _sensorSub = sampleStream.listen(isolate.addSample);
      }
    } catch (_) {
      _running = false;
    }
  }

  void _onUdpAnnouncementReceived(ReceivedUdpTapPacket packet) {
    if (!mounted) {
      return;
    }
    final settings = ref.read(tapToShareSettingsProvider);
    final favorites = ref.read(favoritesProvider);
    final stateMachine = ref.notifier(tapTransferStateMachineProvider);
    final ann = packet.announcement;

    // On Desktop, use DesktopTapCoordinator (`Spec 007`).
    if (_isDesktop && _desktopCoordinator != null) {
      // Allow matching in both favoritesOnly (if in favorites) and everyoneWithConfirmation modes;
      // if no favorites are configured yet during live testing, evaluate with everyoneWithConfirmation fallback.
      final effectiveSettings = (settings.securityMode == TapToShareSecurityMode.favoritesOnly && favorites.isEmpty)
          ? settings.copyWith(securityMode: TapToShareSecurityMode.everyoneWithConfirmation)
          : settings;
      _desktopCoordinator!.handleIncomingMobileTap(
        announcement: ann,
        settings: effectiveSettings,
        favorites: favorites,
        stateMachine: stateMachine,
        correctedPeerTimestampUs: packet.receivedAtLocalUs,
        nowLocalUs: packet.receivedAtLocalUs,
      );
      return;
    }

    // On Mobile, if we are already in `tapDetected`, match with the peer's announcement.
    if (ref.read(tapTransferStateMachineProvider).phase == TapTransferPhase.tapDetected) {
      stateMachine.onPeerMatched(
        peerFingerprint: ann.senderFingerprint,
        peerNonce: ann.nonce,
        peerHasFiles: ann.hasSelectedFiles,
      );
    }
  }

  Future<void> _stopListening() async {
    _running = false;
    _batteryGuard.updateLifecycle(
      featureEnabled: false,
      nowUs: DateTime.now().microsecondsSinceEpoch,
    );
    await _sensorSub?.cancel();
    _sensorSub = null;
    await _tapSub?.cancel();
    _tapSub = null;
    await _udpSub?.cancel();
    _udpSub = null;
    final udp = _udpCoordinator;
    _udpCoordinator = null;
    if (udp != null) {
      await udp.dispose();
    }
    if (!_isDesktop) {
      try {
        await _sensorSource.stopStream();
      } catch (_) {}
    }
    final isolate = _detectorIsolate;
    _detectorIsolate = null;
    if (isolate != null) {
      await isolate.stop();
    }
  }

  @override
  void didUpdateWidget(covariant TapToShareLiveBanner oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!listEquals(oldWidget.selectedFilePaths, widget.selectedFilePaths)) {
      final nextFiles = List<String>.unmodifiable(widget.selectedFilePaths);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          ref.notifier(tapTransferStateMachineProvider).updateSelectedFiles(nextFiles);
        }
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_stopListening());
    super.dispose();
  }

  void _simulateTapAndPeerMatch() {
    final controller = ref.notifier(tapTransferStateMachineProvider);
    final currentState = ref.read(tapTransferStateMachineProvider);
    if (currentState.phase == TapTransferPhase.idle) {
      controller.arm(selectedFiles: widget.selectedFilePaths);
    }
    final files = widget.selectedFilePaths.isNotEmpty ? widget.selectedFilePaths : const ['/demo/sample_photo.jpg'];
    controller.updateSelectedFiles(files);
    final nowUs = DateTime.now().microsecondsSinceEpoch;
    final nonce = 'sim-local-$nowUs-${++_nonceCounter}';
    if (ref.read(tapTransferStateMachineProvider).phase != TapTransferPhase.tapDetected) {
      controller.arm(selectedFiles: files);
      controller.onLocalTapDetected(
        DetectedTapEvent(
          impactTimestampUs: nowUs,
          peakLinearAccelMps2: 16.4,
          peakJerkMps3: 1750.0,
          preImpactGyroRms: 0.18,
          duringImpactGyroPeak: 0.42,
          postImpactAccelRms: 0.14,
          postImpactGyroRms: 0.21,
          dirX: 0.0,
          dirY: 1.0,
          dirZ: 0.0,
          orientation: Quaternion.identity,
          posture: DevicePosture.tilted,
        ),
        localNonce: nonce,
      );
    }

    // Also broadcast over UDP so any listening Desktop/Phone on the LAN receives the simulated tap!
    final localFp = ref.read(securityProvider).certificateHash;
    _udpCoordinator?.broadcastTapAnnouncement(
      PeerTapAnnouncement(
        senderFingerprint: localFp,
        impactTimestampUs: nowUs,
        nonce: nonce,
        peakLinearAccelMps2: 16.4,
        posture: DevicePosture.tilted,
        dirX: 0.0,
        dirY: 1.0,
        dirZ: 0.0,
        hasSelectedFiles: files.isNotEmpty,
      ),
      knownPeerIps: widget.knownPeerIps,
    );

    controller.onPeerMatched(
      peerFingerprint: widget.firstNearbyPeerFingerprint ?? 'A1B2C3D4E5F60718293A4B5C',
      peerNonce: 'sim-peer-${++_nonceCounter}',
      peerHasFiles: false,
    );
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(tapToShareSettingsProvider);
    final transferState = ref.watch(tapTransferStateMachineProvider);

    if (settings.isEnabled && !_running) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_running) {
          unawaited(_startListening(settings.sensitivityPreset.toDetectorConfig()));
        }
      });
    } else if (!settings.isEnabled && _running) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          unawaited(_stopListening());
          ref.notifier(tapTransferStateMachineProvider).disarm();
        }
      });
    }

    if (_lastObservedPhase != transferState.phase) {
      final prev = _lastObservedPhase;
      _lastObservedPhase = transferState.phase;
      if (prev == TapTransferPhase.transferring && transferState.phase == TapTransferPhase.done && widget.onTransferConfirmed != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          widget.onTransferConfirmed?.call();
        });
      }
    }

    if (!settings.isEnabled) {
      return const SizedBox.shrink();
    }

    final colorScheme = Theme.of(context).colorScheme;
    final statusHeadline = _isDesktop
        ? 'Tap-to-Share Active (Desktop LAN Mode) — Bump your phone near this PC to share'
        : 'Tap-to-Share Active (${settings.sensitivityPreset.name.toUpperCase()}) — Bump phones to share';

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Card(
          margin: const EdgeInsets.symmetric(horizontal: 15, vertical: 6),
          color: colorScheme.secondaryContainer.withValues(alpha: 0.55),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(_isDesktop ? Icons.desktop_windows : Icons.sensors, color: colorScheme.primary),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        statusHeadline,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
                if (kDebugMode) ...[
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      OutlinedButton.icon(
                        onPressed: _simulateTapAndPeerMatch,
                        icon: const Icon(Icons.touch_app, size: 18),
                        label: const Text('Simulate Peer Tap'),
                      ),
                      if (!_isDesktop)
                        OutlinedButton.icon(
                          onPressed: () async {
                            final nav = context.push;
                            await ref.notifier(sensorRecorderProvider).setFeatureEnabled(true);
                            await nav(() => const TapSensorRecorderPage());
                          },
                          icon: const Icon(Icons.analytics_outlined, size: 18),
                          label: const Text('Open Sensor Recorder'),
                        ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
        TapToShareOverlayCard(
          peerDisplayName: widget.firstNearbyPeerAlias ?? (_isDesktop ? 'Nearby Mobile Phone' : 'Nearby Peer'),
        ),
      ],
    );
  }
}
