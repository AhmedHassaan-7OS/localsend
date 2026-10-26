import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/model/tap_to_share/impact_event.dart';
import 'package:localsend_app/provider/tap_to_share/tap_transfer_state_machine.dart';
import 'package:refena_flutter/refena_flutter.dart';

class _RecordingExecutor implements TapTransferExecutor {
  int sendCount = 0;
  int receiveCount = 0;
  int abortCount = 0;
  List<String> lastSentFiles = const [];
  String? lastPeerFingerprint;
  String? lastAbortedSessionKey;
  Completer<bool>? pendingSendCompleter;

  @override
  Future<bool> startSend({
    required String sessionKey,
    required String peerFingerprint,
    required List<String> filePaths,
  }) {
    sendCount++;
    lastPeerFingerprint = peerFingerprint;
    lastSentFiles = List<String>.unmodifiable(filePaths);
    if (pendingSendCompleter != null) {
      return pendingSendCompleter!.future;
    }
    return Future<bool>.value(true);
  }

  @override
  Future<bool> prepareReceive({
    required String sessionKey,
    required String peerFingerprint,
  }) async {
    receiveCount++;
    lastPeerFingerprint = peerFingerprint;
    return true;
  }

  @override
  Future<void> abortTransfer(String sessionKey) async {
    abortCount++;
    lastAbortedSessionKey = sessionKey;
    if (pendingSendCompleter != null && !pendingSendCompleter!.isCompleted) {
      pendingSendCompleter!.complete(false);
    }
  }
}

DetectedTapEvent _tapAt(int timestampUs) {
  return DetectedTapEvent(
    impactTimestampUs: timestampUs,
    peakLinearAccelMps2: 16.5,
    peakJerkMps3: 1900.0,
    preImpactGyroRms: 0.2,
    duringImpactGyroPeak: 0.35,
    postImpactAccelRms: 0.12,
    postImpactGyroRms: 0.22,
    posture: DevicePosture.tilted,
    orientation: Quaternion.identity,
    dirX: 0.0,
    dirY: 1.0,
    dirZ: 0.0,
  );
}

void main() {
  group('Spec 004 — TapTransferStateMachineController', () {
    test('AC-1: completes full happy-path lifecycle (idle -> armed -> tapDetected -> matched -> confirming -> transferring -> done)', () async {
      final executor = _RecordingExecutor();
      final container = RefenaContainer();
      final provider = NotifierProvider<TapTransferStateMachineController, TapTransferState>(
        (ref) => TapTransferStateMachineController(executor: executor),
      );
      final notifier = container.notifier(provider);

      expect(container.read(provider).phase, TapTransferPhase.idle);

      notifier.arm(selectedFiles: const ['/photos/img1.jpg', '/photos/img2.jpg']);
      expect(container.read(provider).phase, TapTransferPhase.armed);

      expect(
        notifier.onLocalTapDetected(_tapAt(1000000), localNonce: 'local-nonce-1'),
        isTrue,
      );
      expect(container.read(provider).phase, TapTransferPhase.tapDetected);

      expect(
        notifier.onPeerMatched(
          peerFingerprint: 'PEER_FP_1234',
          peerNonce: 'peer-nonce-1',
          peerHasFiles: false,
        ),
        isTrue,
      );
      expect(container.read(provider).phase, TapTransferPhase.matched);
      expect(container.read(provider).role, TapTransferRole.sender);

      expect(notifier.requestConfirmation(), isTrue);
      expect(container.read(provider).phase, TapTransferPhase.confirming);

      final ok = await notifier.confirmTransfer();
      expect(ok, isTrue);
      expect(container.read(provider).phase, TapTransferPhase.done);
      expect(executor.sendCount, 1);
      expect(executor.lastSentFiles, const ['/photos/img1.jpg', '/photos/img2.jpg']);
      expect(
        notifier.phaseHistory,
        const [
          TapTransferPhase.idle,
          TapTransferPhase.armed,
          TapTransferPhase.tapDetected,
          TapTransferPhase.matched,
          TapTransferPhase.confirming,
          TapTransferPhase.transferring,
          TapTransferPhase.done,
        ],
      );
    });

    test('AC-2: flags TapTransferRole.conflict when both peers have files selected and requires explicit resolution', () async {
      final executor = _RecordingExecutor();
      final container = RefenaContainer();
      final provider = NotifierProvider<TapTransferStateMachineController, TapTransferState>(
        (ref) => TapTransferStateMachineController(executor: executor),
      );
      final notifier = container.notifier(provider);

      notifier.arm(selectedFiles: const ['/docs/report.pdf']);
      notifier.onLocalTapDetected(_tapAt(2000000), localNonce: 'local-n-conflict');
      notifier.onPeerMatched(
        peerFingerprint: 'PEER_FP_CONFLICT',
        peerNonce: 'peer-n-conflict',
        peerHasFiles: true,
      );

      expect(container.read(provider).phase, TapTransferPhase.matched);
      expect(container.read(provider).role, TapTransferRole.conflict);

      // Cannot confirm before conflict resolution.
      expect(notifier.requestConfirmation(), isFalse);
      expect(await notifier.confirmTransfer(), isFalse);
      expect(executor.sendCount, 0);

      // User resolves conflict by choosing receiver role.
      expect(notifier.resolveRoleConflict(TapTransferRole.receiver), isTrue);
      expect(container.read(provider).phase, TapTransferPhase.confirming);
      expect(container.read(provider).role, TapTransferRole.receiver);

      expect(await notifier.confirmTransfer(), isTrue);
      expect(executor.receiveCount, 1);
      expect(container.read(provider).phase, TapTransferPhase.done);
    });

    test('AC-3 & AC-4: ignores second tap during active states (race protection) and freezes lockedFiles snapshot at match', () async {
      final executor = _RecordingExecutor()..pendingSendCompleter = Completer<bool>();
      final container = RefenaContainer();
      final provider = NotifierProvider<TapTransferStateMachineController, TapTransferState>(
        (ref) => TapTransferStateMachineController(executor: executor),
      );
      final notifier = container.notifier(provider);

      notifier.arm(selectedFiles: const ['/a.txt', '/b.txt']);
      notifier.onLocalTapDetected(_tapAt(3000000), localNonce: 'n-local-3');
      notifier.onPeerMatched(
        peerFingerprint: 'PEER_FP_3',
        peerNonce: 'n-peer-3',
        peerHasFiles: false,
      );

      // AC-4: Mutating the UI file list after `matched` must NOT change `lockedFiles`.
      notifier.updateSelectedFiles(const ['/mutated_after_match.txt']);
      expect(container.read(provider).armedFiles, const ['/mutated_after_match.txt']);
      expect(container.read(provider).lockedFiles, const ['/a.txt', '/b.txt']);

      // AC-3: A new tap while in `matched` is ignored.
      expect(notifier.onLocalTapDetected(_tapAt(3100000), localNonce: 'n-local-ignored-1'), isFalse);

      notifier.requestConfirmation();
      // AC-3: A new tap while in `confirming` is ignored.
      expect(notifier.onLocalTapDetected(_tapAt(3200000), localNonce: 'n-local-ignored-2'), isFalse);

      final transferFuture = notifier.confirmTransfer();
      expect(container.read(provider).phase, TapTransferPhase.transferring);

      // AC-3: A new tap while in `transferring` is ignored.
      expect(notifier.onLocalTapDetected(_tapAt(3300000), localNonce: 'n-local-ignored-3'), isFalse);

      executor.pendingSendCompleter!.complete(true);
      expect(await transferFuture, isTrue);
      expect(executor.lastSentFiles, const ['/a.txt', '/b.txt']);
    });

    test('AC-5: deduplicates sessions so identical (localNonce, peerNonce) pairs never send files twice', () async {
      final executor = _RecordingExecutor();
      final container = RefenaContainer();
      final provider = NotifierProvider<TapTransferStateMachineController, TapTransferState>(
        (ref) => TapTransferStateMachineController(executor: executor),
      );
      final notifier = container.notifier(provider);

      notifier.arm(selectedFiles: const ['/once.zip']);
      notifier.onLocalTapDetected(_tapAt(4000000), localNonce: 'dup-local');
      expect(
        notifier.onPeerMatched(
          peerFingerprint: 'PEER_DUP',
          peerNonce: 'dup-peer',
          peerHasFiles: false,
        ),
        isTrue,
      );
      expect(await notifier.confirmTransfer(), isTrue);
      expect(executor.sendCount, 1);

      // Re-arm and try to trigger the same (dup-local, dup-peer) session again -> rejected.
      notifier.arm(selectedFiles: const ['/once.zip']);
      notifier.onLocalTapDetected(_tapAt(5000000), localNonce: 'dup-local');
      expect(
        notifier.onPeerMatched(
          peerFingerprint: 'PEER_DUP',
          peerNonce: 'dup-peer',
          peerHasFiles: false,
        ),
        isFalse,
      );
      expect(executor.sendCount, 1);
    });

    test('AC-6: enforces state timeouts without hanging and supports manual cancel() mid-transfer', () async {
      final executor = _RecordingExecutor()..pendingSendCompleter = Completer<bool>();
      final container = RefenaContainer();
      final provider = NotifierProvider<TapTransferStateMachineController, TapTransferState>(
        (ref) => TapTransferStateMachineController(
          executor: executor,
          matchTimeout: const Duration(milliseconds: 30),
          confirmTimeout: const Duration(milliseconds: 50),
        ),
      );
      final notifier = container.notifier(provider);

      // Subcase A: `tapDetected` times out if no peer matches within `matchTimeout`.
      notifier.arm(selectedFiles: const ['/file.bin']);
      notifier.onLocalTapDetected(_tapAt(6000000), localNonce: 'timeout-nonce');
      expect(container.read(provider).phase, TapTransferPhase.tapDetected);

      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(container.read(provider).phase, TapTransferPhase.cancelled);
      expect(container.read(provider).lastReason, 'timeout_tapDetected');

      // Subcase B: Manual `cancel()` during `transferring` aborts executor and transitions to `cancelled`.
      notifier.arm(selectedFiles: const ['/file.bin']);
      notifier.onLocalTapDetected(_tapAt(7000000), localNonce: 'cancel-local');
      notifier.onPeerMatched(
        peerFingerprint: 'PEER_CANCEL',
        peerNonce: 'cancel-peer',
        peerHasFiles: false,
      );
      final sendFuture = notifier.confirmTransfer();
      expect(container.read(provider).phase, TapTransferPhase.transferring);

      await notifier.cancel(reason: 'user_pressed_cancel');
      expect(container.read(provider).phase, TapTransferPhase.cancelled);
      expect(container.read(provider).lastReason, 'user_pressed_cancel');
      expect(executor.abortCount, 1);
      expect(await sendFuture, isFalse);
    });
  });
}
