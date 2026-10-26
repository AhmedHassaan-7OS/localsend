import 'dart:async';

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:localsend_app/model/tap_to_share/impact_event.dart';
import 'package:localsend_app/model/tap_to_share/sensor_sample.dart';
import 'package:localsend_app/pages/debug/tap_sensor_recorder_page.dart';
import 'package:localsend_app/pages/progress_page.dart';
import 'package:localsend_app/provider/device_info_provider.dart';
import 'package:localsend_app/provider/favorites_provider.dart';
import 'package:localsend_app/provider/network/nearby_devices_provider.dart';
import 'package:localsend_app/provider/network/scan_facade.dart';
import 'package:localsend_app/provider/network/send_provider.dart';
import 'package:localsend_app/provider/network/server/server_provider.dart';
import 'package:localsend_app/provider/security_provider.dart';
import 'package:localsend_app/provider/selection/selected_sending_files_provider.dart';
import 'package:localsend_app/provider/settings_provider.dart';
import 'package:localsend_app/provider/tap_to_share/sensor_recorder_provider.dart';
import 'package:localsend_app/provider/tap_to_share/tap_security_provider.dart';
import 'package:localsend_app/provider/tap_to_share/tap_transfer_state_machine.dart';
import 'package:localsend_app/util/native/file_picker.dart';
import 'package:localsend_app/util/native/platform_check.dart';
import 'package:localsend_app/util/tap_to_share/desktop_tap_coordinator.dart';
import 'package:localsend_app/util/tap_to_share/impact_detector_isolate.dart';
import 'package:localsend_app/util/tap_to_share/peer_tap_matcher.dart';
import 'package:localsend_app/util/tap_to_share/sensor_source.dart';
import 'package:localsend_app/util/tap_to_share/tap_battery_lifecycle_guard.dart';
import 'package:localsend_app/util/tap_to_share/tap_security_policy.dart';
import 'package:localsend_app/util/tap_to_share/tap_udp_coordinator.dart';
import 'package:localsend_app/widget/dialogs/add_file_dialog.dart';
import 'package:localsend_app/widget/tap_to_share/tap_to_share_overlay.dart';
import 'package:localsend_isolates/constants.dart';
import 'package:localsend_isolates/isolate.dart';
import 'package:localsend_isolates/model/device.dart';
import 'package:localsend_isolates/model/session_status.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:routerino/routerino.dart';

/// Live coordinator widget mounted on [ReceiveTab] and [SendTab] that connects hardware sensors,
/// [TapUdpCoordinator], [DesktopTapCoordinator], [ImpactDetectorIsolate],
/// [TapTransferStateMachineController], and LocalSend's real transfer pipeline ([SendProvider] & [ServerProvider]).
class TapToShareLiveBanner extends StatefulWidget {
  final List<String>? selectedFilePaths;
  final List<String> knownPeerIps;
  final String? firstNearbyPeerFingerprint;
  final String? firstNearbyPeerAlias;
  final VoidCallback? onTransferConfirmed;

  const TapToShareLiveBanner({
    super.key,
    this.selectedFilePaths,
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
  final Map<String, Device> _peerDevicesByFingerprint = {};
  final List<ReceivedUdpTapPacket> _recentIncomingPackets = [];
  ImpactDetectorIsolate? _detectorIsolate;
  TapUdpCoordinator? _udpCoordinator;
  DesktopTapCoordinator? _desktopCoordinator;
  StreamSubscription<SensorSample>? _sensorSub;
  StreamSubscription<DetectedTapEvent>? _tapSub;
  StreamSubscription<ReceivedUdpTapPacket>? _udpSub;
  StreamSubscription<ReceivedTriggerSendRequest>? _triggerSendSub;
  bool _running = false;
  bool _executingTransfer = false;
  int _nonceCounter = 0;

  bool get _isDesktop => checkPlatformIsDesktop();

  List<String> _currentSelectedFilePaths() {
    if (widget.selectedFilePaths != null) {
      return widget.selectedFilePaths!;
    }
    return ref.read(selectedSendingFilesProvider).map((f) => f.path ?? f.name).toList();
  }

  List<String> _currentKnownPeerIps() {
    final nearbyIps = ref.read(nearbyDevicesProvider).devices.values.map((d) => d.ip).whereType<String>();
    final favIps = ref.read(favoritesProvider).map((f) => f.ip);
    final cachedIps = _peerDevicesByFingerprint.values.map((d) => d.ip).whereType<String>();
    return <String>{
      ...widget.knownPeerIps,
      ...nearbyIps,
      ...favIps,
      ...cachedIps,
    }.toList();
  }

  PeerTapAnnouncement _buildLocalAnnouncement({
    required int impactTimestampUs,
    required String nonce,
    required double peakLinearAccelMps2,
    required DevicePosture posture,
    required double dirX,
    required double dirY,
    required double dirZ,
    required bool hasSelectedFiles,
  }) {
    final localFp = ref.read(securityProvider).certificateHash;
    final serverState = ref.read(serverProvider);
    final settings = ref.read(settingsProvider);
    final deviceInfo = ref.read(deviceInfoProvider);
    return PeerTapAnnouncement(
      senderFingerprint: localFp,
      impactTimestampUs: impactTimestampUs,
      nonce: nonce,
      peakLinearAccelMps2: peakLinearAccelMps2,
      posture: posture,
      dirX: dirX,
      dirY: dirY,
      dirZ: dirZ,
      hasSelectedFiles: hasSelectedFiles,
      senderAlias: serverState?.alias ?? settings.alias,
      senderPort: serverState?.port ?? settings.port,
      senderHttps: serverState?.https ?? settings.https,
      senderDeviceModel: deviceInfo.deviceModel,
      senderVersion: defaultProtocolVersion,
      isDesktopTarget: _isDesktop,
    );
  }

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
      if (ref.read(tapTransferStateMachineProvider).phase == TapTransferPhase.idle) {
        stateMachine.arm(selectedFiles: _currentSelectedFilePaths());
      } else {
        stateMachine.updateSelectedFiles(_currentSelectedFilePaths());
      }

      // Start LAN UDP Coordinator on both Mobile and Desktop (`Spec 007` & `Spec 011`).
      final udp = TapUdpCoordinator(localFingerprint: localFp);
      try {
        try {
          await udp.start();
        } catch (_) {
          await Future<void>.delayed(const Duration(milliseconds: 80));
          await udp.start();
        }
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
        _triggerSendSub = udp.triggerSendStream.listen(_onTriggerSendReceived);
      } catch (_) {
        // Port may already be bound by another widget instance; continue gracefully.
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
          final currentFiles = _currentSelectedFilePaths();
          stateMachine.updateSelectedFiles(currentFiles);
          final nonce = 'live-tap-${DateTime.now().microsecondsSinceEpoch}-${++_nonceCounter}';
          final accepted = stateMachine.onLocalTapDetected(
            tapEvent,
            localNonce: nonce,
          );
          if (!accepted) {
            return;
          }

          // Trigger LocalSend's Rust multicast announcement in parallel so both devices discover each other.
          unawaited(ref.global.dispatchAsync(StartMulticastScan()));

          final announcement = _buildLocalAnnouncement(
            impactTimestampUs: tapEvent.impactTimestampUs,
            nonce: nonce,
            peakLinearAccelMps2: tapEvent.peakLinearAccelMps2,
            posture: tapEvent.posture,
            dirX: tapEvent.dirX,
            dirY: tapEvent.dirY,
            dirZ: tapEvent.dirZ,
            hasSelectedFiles: currentFiles.isNotEmpty,
          );
          final knownIps = _currentKnownPeerIps();
          _udpCoordinator?.broadcastTapAnnouncement(
            announcement,
            knownPeerIps: knownIps,
          );

          // Send a follow-up echo 120ms later in case the peer phone's isolate finished its 40ms post-impact window slightly after ours.
          Future<void>.delayed(const Duration(milliseconds: 120), () {
            if (mounted && _running) {
              _udpCoordinator?.broadcastTapAnnouncement(
                announcement,
                knownPeerIps: _currentKnownPeerIps(),
              );
            }
          });

          // Check if a peer's UDP announcement arrived within the last 600ms just before our local isolate finished.
          final nowLocalUs = DateTime.now().microsecondsSinceEpoch;
          _recentIncomingPackets.removeWhere((p) => (nowLocalUs - p.receivedAtLocalUs).abs() > 600000);
          if (_recentIncomingPackets.isNotEmpty) {
            final recent = _recentIncomingPackets.removeLast();
            stateMachine.onPeerMatched(
              peerFingerprint: recent.announcement.senderFingerprint,
              peerNonce: recent.announcement.nonce,
              peerHasFiles: recent.announcement.hasSelectedFiles,
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

  Device _registerPeerFromPacket(ReceivedUdpTapPacket packet) {
    final ann = packet.announcement;
    final peerIp = packet.senderAddress.address;
    final peerPort = ann.senderPort ?? defaultPort;
    final peerHttps = ann.senderHttps ?? true;
    final normalizedFp = ann.senderFingerprint.trim().toUpperCase();

    final device = Device(
      signalingId: null,
      ip: peerIp,
      version: ann.senderVersion ?? defaultProtocolVersion,
      port: peerPort,
      https: peerHttps,
      fingerprint: ann.senderFingerprint,
      alias: ann.senderAlias ?? (ann.isDesktopTarget ? 'Nearby PC' : 'Nearby Phone'),
      deviceModel: ann.senderDeviceModel,
      deviceType: ann.isDesktopTarget ? DeviceType.desktop : DeviceType.mobile,
      download: false,
      channels: [
        HttpChannel(
          host: peerIp,
          port: peerPort,
          https: peerHttps,
        ),
      ],
    );

    _peerDevicesByFingerprint[normalizedFp] = device;

    // Register into LocalSend's Rust discovery isolate and Flutter nearbyDevicesProvider so it is immediately usable by SendProvider.
    ref.redux(parentIsolateProvider).dispatch(IsolateDiscoveryAddDeviceAction(device: device));
    ref.redux(nearbyDevicesProvider).dispatch(RegisterDeviceAction(device));
    return device;
  }

  void _onUdpAnnouncementReceived(ReceivedUdpTapPacket packet) {
    if (!mounted) {
      return;
    }
    final peerDevice = _registerPeerFromPacket(packet);
    if (mounted) {
      setState(() {});
    }

    final settings = ref.read(tapToShareSettingsProvider);
    final favorites = ref.read(favoritesProvider);
    final stateMachine = ref.notifier(tapTransferStateMachineProvider);
    final currentFiles = _currentSelectedFilePaths();
    stateMachine.updateSelectedFiles(currentFiles);
    final ann = packet.announcement;

    // On Desktop, use DesktopTapCoordinator (`Spec 007`).
    if (_isDesktop && _desktopCoordinator != null) {
      final effectiveSettings = (settings.securityMode == TapToShareSecurityMode.favoritesOnly && favorites.isEmpty)
          ? settings.copyWith(securityMode: TapToShareSecurityMode.everyoneWithConfirmation)
          : settings;

      // If desktop was left in `done` or `cancelled` from a previous session, re-arm so the new mobile tap is accepted.
      final phase = ref.read(tapTransferStateMachineProvider).phase;
      if (phase == TapTransferPhase.idle || phase == TapTransferPhase.done || phase == TapTransferPhase.cancelled) {
        stateMachine.arm(selectedFiles: currentFiles);
      }

      final eval = _desktopCoordinator!.handleIncomingMobileTap(
        announcement: ann,
        settings: effectiveSettings,
        favorites: favorites,
        stateMachine: stateMachine,
        correctedPeerTimestampUs: packet.receivedAtLocalUs,
        nowLocalUs: packet.receivedAtLocalUs,
      );

      if (eval.accepted) {
        // Immediately reply to the mobile phone so the phone ALSO transitions from `tapDetected` to `matched`!
        final desktopReply = _buildLocalAnnouncement(
          impactTimestampUs: packet.receivedAtLocalUs,
          nonce: ref.read(tapTransferStateMachineProvider).localNonce ?? 'desktop-reply-${++_nonceCounter}',
          peakLinearAccelMps2: ann.peakLinearAccelMps2,
          posture: DevicePosture.faceUp,
          dirX: -ann.dirX,
          dirY: -ann.dirY,
          dirZ: -ann.dirZ,
          hasSelectedFiles: currentFiles.isNotEmpty,
        );
        _udpCoordinator?.broadcastTapAnnouncement(
          desktopReply,
          knownPeerIps: [
            if (peerDevice.ip != null) peerDevice.ip!,
          ],
        );
      }
      return;
    }

    // On Mobile: cache packet for 600ms in case our local isolate is still completing its 40ms post-impact window.
    _recentIncomingPackets.add(packet);
    if (_recentIncomingPackets.length > 8) {
      _recentIncomingPackets.removeAt(0);
    }

    // If we are already in `tapDetected`, match with the peer's announcement immediately.
    if (ref.read(tapTransferStateMachineProvider).phase == TapTransferPhase.tapDetected) {
      final matched = stateMachine.onPeerMatched(
        peerFingerprint: ann.senderFingerprint,
        peerNonce: ann.nonce,
        peerHasFiles: ann.hasSelectedFiles,
      );
      if (matched && !ann.isDesktopTarget && peerDevice.ip != null) {
        final currentState = ref.read(tapTransferStateMachineProvider);
        final localTap = currentState.localTap;
        if (localTap != null && currentState.localNonce != null) {
          final reply = _buildLocalAnnouncement(
            impactTimestampUs: localTap.impactTimestampUs,
            nonce: currentState.localNonce!,
            peakLinearAccelMps2: localTap.peakLinearAccelMps2,
            posture: localTap.posture,
            dirX: localTap.dirX,
            dirY: localTap.dirY,
            dirZ: localTap.dirZ,
            hasSelectedFiles: currentState.lockedFiles.isNotEmpty,
          );
          _udpCoordinator?.broadcastTapAnnouncement(
            reply,
            knownPeerIps: [peerDevice.ip!],
          );
        }
      }
    }
  }

  void _onTriggerSendReceived(ReceivedTriggerSendRequest request) {
    if (!mounted || _executingTransfer) {
      return;
    }
    final localFp = ref.read(securityProvider).certificateHash.trim().toUpperCase();
    if (request.targetFingerprint.isNotEmpty && request.targetFingerprint != localFp) {
      return;
    }
    final transferState = ref.read(tapTransferStateMachineProvider);
    final peerFp = transferState.peerFingerprint ?? request.senderFingerprint;
    final hasFiles = ref.read(selectedSendingFilesProvider).isNotEmpty;
    if (transferState.role == TapTransferRole.sender || hasFiles) {
      final peerDevice = _resolvePeerDevice(peerFp, fallbackIp: request.senderAddress.address);
      if (peerDevice != null) {
        unawaited(_executeRealSendToPeer(peerFp, peerDevice));
      }
    }
  }

  Device? _resolvePeerDevice(String? peerFingerprint, {String? fallbackIp}) {
    final normalizedFp = peerFingerprint?.trim().toUpperCase();
    final nearbyDevices = ref.read(nearbyDevicesProvider).devices.values;
    if (normalizedFp != null && normalizedFp.isNotEmpty) {
      final fromNearby = nearbyDevices.firstWhereOrNull(
        (d) => d.fingerprint.trim().toUpperCase() == normalizedFp,
      );
      if (fromNearby != null) {
        return fromNearby;
      }
      final fromCache = _peerDevicesByFingerprint[normalizedFp];
      if (fromCache != null) {
        return fromCache;
      }
      final fromFav = ref
          .read(favoritesProvider)
          .firstWhereOrNull(
            (f) => f.fingerprint.trim().toUpperCase() == normalizedFp,
          );
      if (fromFav != null) {
        final https = ref.read(settingsProvider).https;
        return Device(
          signalingId: null,
          ip: fromFav.ip,
          version: defaultProtocolVersion,
          port: fromFav.port,
          https: https,
          fingerprint: fromFav.fingerprint,
          alias: fromFav.alias,
          deviceModel: null,
          deviceType: DeviceType.mobile,
          download: false,
          channels: [
            HttpChannel(
              host: fromFav.ip,
              port: fromFav.port,
              https: https,
            ),
          ],
        );
      }
    }
    if (fallbackIp != null) {
      final https = ref.read(settingsProvider).https;
      final port = ref.read(settingsProvider).port;
      return Device(
        signalingId: null,
        ip: fallbackIp,
        version: defaultProtocolVersion,
        port: port,
        https: https,
        fingerprint: peerFingerprint ?? fallbackIp,
        alias: 'Nearby Device',
        deviceModel: null,
        deviceType: DeviceType.mobile,
        download: false,
        channels: [
          HttpChannel(
            host: fallbackIp,
            port: port,
            https: https,
          ),
        ],
      );
    }
    return nearbyDevices.firstOrNull ?? _peerDevicesByFingerprint.values.firstOrNull;
  }

  Future<void> _handleConfirmTransfer() async {
    if (_executingTransfer) {
      return;
    }
    final stateMachine = ref.notifier(tapTransferStateMachineProvider);
    final currentState = ref.read(tapTransferStateMachineProvider);
    final peerFp = currentState.peerFingerprint;
    final role = currentState.role;
    final sessionKey = currentState.sessionKey ?? '';

    if (peerFp == null) {
      await stateMachine.confirmTransfer();
      return;
    }

    final peerDevice = _resolvePeerDevice(peerFp);

    if (role == TapTransferRole.sender) {
      await stateMachine.confirmTransfer();
      if (peerDevice != null) {
        await _executeRealSendToPeer(peerFp, peerDevice);
      } else if (widget.onTransferConfirmed != null) {
        widget.onTransferConfirmed!.call();
      }
      return;
    }

    if (role == TapTransferRole.receiver) {
      // Pre-approve the sender fingerprint so ReceiveController.onPrepareUpload auto-accepts into ProgressPage!
      stateMachine.preApproveSenderForReceive(peerFp);
      await stateMachine.confirmTransfer();

      // If the sender already initiated `prepare-upload` and the session is waiting, accept it immediately!
      final activeSession = ref.read(serverProvider)?.session;
      if (activeSession != null && activeSession.status == SessionStatus.waiting) {
        final filesMap = {
          for (final f in activeSession.files.values) f.file.id: f.file.fileName,
        };
        // ignore: unawaited_futures
        Routerino.context.pushImmediately(
          () => ProgressPage(
            showAppBar: false,
            closeSessionOnClose: true,
            sessionId: activeSession.sessionId,
          ),
        );
        await ref.notifier(serverProvider).acceptFileRequest(filesMap);
        stateMachine.arm(selectedFiles: _currentSelectedFilePaths());
        return;
      }

      // Otherwise notify the sender over UDP to start `sendProvider.startSession` immediately!
      if (peerDevice?.ip != null) {
        _udpCoordinator?.sendTriggerSend(
          targetIp: peerDevice!.ip!,
          targetFingerprint: peerFp,
          sessionKey: sessionKey,
        );
      }
      stateMachine.arm(selectedFiles: _currentSelectedFilePaths());
    }
  }

  Future<void> _executeRealSendToPeer(String peerFp, Device targetDevice) async {
    if (_executingTransfer || !mounted) {
      return;
    }
    _executingTransfer = true;
    try {
      var files = ref.read(selectedSendingFilesProvider);
      if (files.isEmpty) {
        final options = FilePickerOption.getOptionsForPlatform();
        await AddFileDialog.open(
          context: context,
          options: options,
        );
        if (!mounted) {
          return;
        }
        files = ref.read(selectedSendingFilesProvider);
        if (files.isEmpty) {
          return;
        }
      }

      await ref
          .notifier(sendProvider)
          .startSession(
            target: targetDevice,
            files: files,
            background: false,
          );

      if (mounted) {
        ref
            .notifier(tapTransferStateMachineProvider)
            .arm(
              selectedFiles: _currentSelectedFilePaths(),
            );
      }
    } finally {
      _executingTransfer = false;
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
    await _triggerSendSub?.cancel();
    _triggerSendSub = null;
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
    final nextPaths = _currentSelectedFilePaths();
    if (!listEquals(oldWidget.selectedFilePaths, widget.selectedFilePaths)) {
      final immutableFiles = List<String>.unmodifiable(nextPaths);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          ref.notifier(tapTransferStateMachineProvider).updateSelectedFiles(immutableFiles);
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
    final currentFiles = _currentSelectedFilePaths();
    controller.arm(selectedFiles: currentFiles);

    final nowUs = DateTime.now().microsecondsSinceEpoch;
    final nonce = 'sim-local-$nowUs-${++_nonceCounter}';
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

    unawaited(ref.global.dispatchAsync(StartMulticastScan()));

    // Broadcast over UDP so any listening Desktop/Phone on the LAN receives the simulated tap!
    final announcement = _buildLocalAnnouncement(
      impactTimestampUs: nowUs,
      nonce: nonce,
      peakLinearAccelMps2: 16.4,
      posture: DevicePosture.tilted,
      dirX: 0.0,
      dirY: 1.0,
      dirZ: 0.0,
      hasSelectedFiles: currentFiles.isNotEmpty,
    );
    _udpCoordinator?.broadcastTapAnnouncement(
      announcement,
      knownPeerIps: _currentKnownPeerIps(),
    );

    final knownPeer = _resolvePeerDevice(widget.firstNearbyPeerFingerprint);
    if (knownPeer != null) {
      controller.onPeerMatched(
        peerFingerprint: knownPeer.fingerprint,
        peerNonce: 'sim-peer-${++_nonceCounter}',
        peerHasFiles: currentFiles.isEmpty,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(tapToShareSettingsProvider);
    final transferState = ref.watch(tapTransferStateMachineProvider);
    final selectedFiles = ref.watch(selectedSendingFilesProvider);
    final nearbyDevices = ref.watch(nearbyDevicesProvider.select((s) => s.devices));

    // Keep state machine's armedFiles in sync with LocalSend's selectedSendingFilesProvider.
    final currentPaths = widget.selectedFilePaths ?? selectedFiles.map((f) => f.path ?? f.name).toList();
    if (!listEquals(transferState.armedFiles, currentPaths)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          ref.notifier(tapTransferStateMachineProvider).updateSelectedFiles(currentPaths);
        }
      });
    }

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

    if (!settings.isEnabled) {
      return const SizedBox.shrink();
    }

    final matchedPeerDevice = _resolvePeerDevice(transferState.peerFingerprint) ?? nearbyDevices.values.firstOrNull;
    final peerDisplayName = matchedPeerDevice?.alias ?? widget.firstNearbyPeerAlias ?? (_isDesktop ? 'Nearby Mobile Phone' : 'Nearby Device');

    final colorScheme = Theme.of(context).colorScheme;
    final statusHeadline = _isDesktop
        ? 'Tap-to-Share Active (Desktop LAN Mode) — Bump your phone near this PC to share'
        : 'Tap-to-Share Active (${settings.sensitivityPreset.name.toUpperCase()}) — Bump phones or tap near PC to share';

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
          peerDisplayName: peerDisplayName,
          onConfirmPressed: _handleConfirmTransfer,
        ),
      ],
    );
  }
}
