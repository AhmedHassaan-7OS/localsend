import 'dart:async';

import 'package:localsend_app/model/tap_to_share/impact_event.dart';
import 'package:refena_flutter/refena_flutter.dart';

/// Phases of the Tap-to-Share transfer lifecycle (`Spec 004`).
enum TapTransferPhase {
  idle,
  armed,
  tapDetected,
  matched,
  confirming,
  transferring,
  done,
  cancelled,
}

/// Negotiated transfer direction between the two matched peers.
enum TapTransferRole {
  none,
  sender,
  receiver,
  conflict,
}

/// Abstract executor that bridges the Tap-to-Share state machine to LocalSend's existing HTTP send/receive pipeline.
abstract class TapTransferExecutor {
  /// Initiates sending the locked [filePaths] to [peerFingerprint].
  /// Returns `true` when the transfer completes successfully.
  Future<bool> startSend({
    required String sessionKey,
    required String peerFingerprint,
    required List<String> filePaths,
  });

  /// Prepares and awaits receiving files from [peerFingerprint].
  /// Returns `true` when the incoming transfer completes successfully.
  Future<bool> prepareReceive({
    required String sessionKey,
    required String peerFingerprint,
  });

  /// Aborts an in-flight transfer identified by [sessionKey].
  Future<void> abortTransfer(String sessionKey);
}

/// Default no-op executor used when no transfer pipeline is wired yet.
class NoOpTapTransferExecutor implements TapTransferExecutor {
  const NoOpTapTransferExecutor();

  @override
  Future<bool> startSend({
    required String sessionKey,
    required String peerFingerprint,
    required List<String> filePaths,
  }) async {
    return true;
  }

  @override
  Future<bool> prepareReceive({
    required String sessionKey,
    required String peerFingerprint,
  }) async {
    return true;
  }

  @override
  Future<void> abortTransfer(String sessionKey) async {}
}

/// Immutable state snapshot of the Tap-to-Share state machine.
class TapTransferState {
  final TapTransferPhase phase;
  final TapTransferRole role;

  /// Live list of selected file paths while idle/armed.
  final List<String> armedFiles;

  /// Immutable snapshot of selected files locked at the exact moment of `matched` (`FR-3` / `AC-4`).
  final List<String> lockedFiles;

  final DetectedTapEvent? localTap;
  final String? localNonce;
  final String? peerFingerprint;
  final String? peerNonce;
  final bool peerHasFiles;
  final String? sessionKey;
  final String? lastReason;

  const TapTransferState({
    this.phase = TapTransferPhase.idle,
    this.role = TapTransferRole.none,
    this.armedFiles = const [],
    this.lockedFiles = const [],
    this.localTap,
    this.localNonce,
    this.peerFingerprint,
    this.peerNonce,
    this.peerHasFiles = false,
    this.sessionKey,
    this.lastReason,
  });

  bool get isBusy => phase == TapTransferPhase.matched || phase == TapTransferPhase.confirming || phase == TapTransferPhase.transferring;

  TapTransferState copyWith({
    TapTransferPhase? phase,
    TapTransferRole? role,
    List<String>? armedFiles,
    List<String>? lockedFiles,
    DetectedTapEvent? localTap,
    bool clearLocalTap = false,
    String? localNonce,
    bool clearLocalNonce = false,
    String? peerFingerprint,
    bool clearPeer = false,
    String? peerNonce,
    bool? peerHasFiles,
    String? sessionKey,
    bool clearSessionKey = false,
    String? lastReason,
    bool clearLastReason = false,
  }) {
    return TapTransferState(
      phase: phase ?? this.phase,
      role: role ?? this.role,
      armedFiles: armedFiles ?? this.armedFiles,
      lockedFiles: lockedFiles ?? this.lockedFiles,
      localTap: clearLocalTap ? null : (localTap ?? this.localTap),
      localNonce: clearLocalNonce ? null : (localNonce ?? this.localNonce),
      peerFingerprint: clearPeer ? null : (peerFingerprint ?? this.peerFingerprint),
      peerNonce: clearPeer ? null : (peerNonce ?? this.peerNonce),
      peerHasFiles: clearPeer ? false : (peerHasFiles ?? this.peerHasFiles),
      sessionKey: clearSessionKey ? null : (sessionKey ?? this.sessionKey),
      lastReason: clearLastReason ? null : (lastReason ?? this.lastReason),
    );
  }
}

/// Builds a canonical order-independent session key from [nonceA] and [nonceB].
String buildCanonicalSessionKey(String nonceA, String nonceB) {
  final a = nonceA.trim();
  final b = nonceB.trim();
  return a.compareTo(b) <= 0 ? '$a|$b' : '$b|$a';
}

final tapTransferStateMachineProvider = NotifierProvider<TapTransferStateMachineController, TapTransferState>((ref) {
  return TapTransferStateMachineController();
});

/// State machine coordinating role negotiation, file-list snapshot locking, race protection, timeouts, and cancellation.
class TapTransferStateMachineController extends Notifier<TapTransferState> {
  final TapTransferExecutor _executor;
  final Duration matchTimeout;
  final Duration confirmTimeout;
  final Duration transferTimeout;
  final List<TapTransferPhase> phaseHistory = [];

  final Set<String> _processedSessionKeys = {};
  final Map<String, int> _preApprovedSenderExpiryUs = {};
  Timer? _phaseTimer;
  int _activeOperationToken = 0;

  TapTransferStateMachineController({
    TapTransferExecutor executor = const NoOpTapTransferExecutor(),
    this.matchTimeout = const Duration(milliseconds: 1500),
    this.confirmTimeout = const Duration(seconds: 30),
    this.transferTimeout = const Duration(seconds: 60),
  }) : _executor = executor;

  /// Pre-approves an incoming transfer from [senderFingerprint] after the user confirms a Tap-to-Share match as receiver.
  void preApproveSenderForReceive(
    String senderFingerprint, {
    Duration ttl = const Duration(seconds: 45),
  }) {
    final normalized = senderFingerprint.trim().toUpperCase();
    if (normalized.isEmpty) {
      return;
    }
    _preApprovedSenderExpiryUs[normalized] = DateTime.now().microsecondsSinceEpoch + ttl.inMicroseconds;
  }

  /// Consumes a pre-approved sender authorization if still within its TTL window.
  bool consumePreApprovedSender(String senderFingerprint) {
    final normalized = senderFingerprint.trim().toUpperCase();
    final expiryUs = _preApprovedSenderExpiryUs.remove(normalized);
    if (expiryUs == null) {
      return false;
    }
    return DateTime.now().microsecondsSinceEpoch <= expiryUs;
  }

  @override
  TapTransferState init() {
    phaseHistory.add(TapTransferPhase.idle);
    return const TapTransferState();
  }

  void _transitionTo(TapTransferState nextState) {
    if (phaseHistory.isEmpty || phaseHistory.last != nextState.phase) {
      phaseHistory.add(nextState.phase);
    }
    state = nextState;
  }

  /// Arms the state machine to listen for taps, optionally setting the initial [selectedFiles].
  void arm({List<String>? selectedFiles}) {
    _cancelTimer();
    _activeOperationToken++;
    final nextArmedFiles = selectedFiles != null ? List<String>.unmodifiable(selectedFiles) : state.armedFiles;
    _transitionTo(
      TapTransferState(
        phase: TapTransferPhase.armed,
        armedFiles: nextArmedFiles,
      ),
    );
  }

  /// Disarms the state machine back to `idle`.
  void disarm() {
    _cancelTimer();
    _activeOperationToken++;
    _transitionTo(
      TapTransferState(
        phase: TapTransferPhase.idle,
        armedFiles: state.armedFiles,
      ),
    );
  }

  /// Updates the user's currently selected files in the UI.
  /// Does NOT mutate [TapTransferState.lockedFiles] if a session is already `matched`, `confirming`, or `transferring` (`AC-4`).
  void updateSelectedFiles(List<String> files) {
    final immutableFiles = List<String>.unmodifiable(files);
    state = state.copyWith(armedFiles: immutableFiles);
  }

  /// Handles a local physical tap event (`armed → tapDetected`).
  /// Returns `false` if ignored due to race-condition protection (`AC-3`) or when `idle`.
  bool onLocalTapDetected(
    DetectedTapEvent tap, {
    required String localNonce,
  }) {
    if (state.isBusy) {
      // AC-3: Ignore new taps while matched, confirming, or transferring.
      return false;
    }
    if (state.phase != TapTransferPhase.armed && state.phase != TapTransferPhase.done && state.phase != TapTransferPhase.cancelled) {
      return false;
    }

    _cancelTimer();
    _activeOperationToken++;
    _transitionTo(
      TapTransferState(
        phase: TapTransferPhase.tapDetected,
        armedFiles: state.armedFiles,
        localTap: tap,
        localNonce: localNonce.trim(),
      ),
    );

    _startTimer(
      matchTimeout,
      onTimeout: () {
        if (state.phase == TapTransferPhase.tapDetected) {
          _transitionTo(
            TapTransferState(
              phase: TapTransferPhase.cancelled,
              armedFiles: state.armedFiles,
              lastReason: 'timeout_tapDetected',
            ),
          );
        }
      },
    );
    return true;
  }

  /// Transitions from `tapDetected` to `matched` once `PeerTapMatcher` finds a valid peer.
  /// Locks `lockedFiles` (`AC-4`), determines role (`AC-2`), and guards against duplicate session keys (`AC-5`).
  bool onPeerMatched({
    required String peerFingerprint,
    required String peerNonce,
    required bool peerHasFiles,
  }) {
    if (state.phase != TapTransferPhase.tapDetected || state.localNonce == null) {
      return false;
    }

    final sessionKey = buildCanonicalSessionKey(state.localNonce!, peerNonce);
    if (_processedSessionKeys.contains(sessionKey)) {
      // AC-5: Never process the same session key twice.
      return false;
    }

    _cancelTimer();
    final snapshotFiles = List<String>.unmodifiable(List<String>.from(state.armedFiles));
    final localHasFiles = snapshotFiles.isNotEmpty;

    final TapTransferRole role;
    if (localHasFiles && !peerHasFiles) {
      role = TapTransferRole.sender;
    } else if (!localHasFiles && peerHasFiles) {
      role = TapTransferRole.receiver;
    } else {
      // Either both peers have files selected, or neither peer has pre-selected files yet;
      // let the user choose whether to Send (picking files if needed) or Receive.
      role = TapTransferRole.conflict;
    }

    _processedSessionKeys.add(sessionKey);

    _transitionTo(
      state.copyWith(
        phase: TapTransferPhase.matched,
        role: role,
        lockedFiles: snapshotFiles,
        peerFingerprint: peerFingerprint.trim().toUpperCase(),
        peerNonce: peerNonce.trim(),
        peerHasFiles: peerHasFiles,
        sessionKey: sessionKey,
        clearLastReason: true,
      ),
    );

    _startConfirmTimer();
    return true;
  }

  /// Advances from `matched` to `confirming` once role is unambiguous (`sender` or `receiver`).
  bool requestConfirmation() {
    if (state.phase != TapTransferPhase.matched) {
      return false;
    }
    if (state.role == TapTransferRole.conflict || state.role == TapTransferRole.none) {
      return false;
    }
    _transitionTo(state.copyWith(phase: TapTransferPhase.confirming));
    return true;
  }

  /// Resolves a `TapTransferRole.conflict` when both peers had files selected (`AC-2`).
  bool resolveRoleConflict(TapTransferRole chosenRole) {
    if (state.phase != TapTransferPhase.matched || state.role != TapTransferRole.conflict) {
      return false;
    }
    if (chosenRole != TapTransferRole.sender && chosenRole != TapTransferRole.receiver) {
      return false;
    }
    final nextLockedFiles = chosenRole == TapTransferRole.receiver ? const <String>[] : state.lockedFiles;
    _transitionTo(
      state.copyWith(
        phase: TapTransferPhase.confirming,
        role: chosenRole,
        lockedFiles: nextLockedFiles,
      ),
    );
    return true;
  }

  /// Confirms the matched transfer and executes the send/receive pipeline (`confirming → transferring → done`).
  Future<bool> confirmTransfer() async {
    if (state.phase == TapTransferPhase.matched) {
      if (!requestConfirmation()) {
        return false;
      }
    }
    if (state.phase != TapTransferPhase.confirming) {
      return false;
    }
    if (state.role != TapTransferRole.sender && state.role != TapTransferRole.receiver) {
      return false;
    }

    final sessionKey = state.sessionKey;
    final peerFp = state.peerFingerprint;
    if (sessionKey == null || peerFp == null) {
      return false;
    }

    _cancelTimer();
    final opToken = ++_activeOperationToken;
    _transitionTo(state.copyWith(phase: TapTransferPhase.transferring));

    _startTimer(
      transferTimeout,
      onTimeout: () {
        if (state.phase == TapTransferPhase.transferring && _activeOperationToken == opToken) {
          unawaited(_abortAndCancel(sessionKey: sessionKey, reason: 'timeout_transferring'));
        }
      },
    );

    try {
      final bool ok;
      if (state.role == TapTransferRole.sender) {
        ok = await _executor.startSend(
          sessionKey: sessionKey,
          peerFingerprint: peerFp,
          filePaths: state.lockedFiles,
        );
      } else {
        ok = await _executor.prepareReceive(
          sessionKey: sessionKey,
          peerFingerprint: peerFp,
        );
      }

      if (_activeOperationToken != opToken || state.phase != TapTransferPhase.transferring) {
        return false;
      }

      _cancelTimer();
      if (ok) {
        _transitionTo(state.copyWith(phase: TapTransferPhase.done));
        return true;
      } else {
        _transitionTo(
          state.copyWith(
            phase: TapTransferPhase.cancelled,
            lastReason: 'transfer_failed',
          ),
        );
        return false;
      }
    } catch (_) {
      if (_activeOperationToken == opToken && state.phase == TapTransferPhase.transferring) {
        _cancelTimer();
        _transitionTo(
          state.copyWith(
            phase: TapTransferPhase.cancelled,
            lastReason: 'transfer_exception',
          ),
        );
      }
      return false;
    }
  }

  /// Cancels any active tap detection, match confirmation, or ongoing transfer immediately (`AC-6`).
  Future<void> cancel({String reason = 'user_cancelled'}) async {
    _cancelTimer();
    _activeOperationToken++;
    final activeSessionKey = state.sessionKey;
    final wasTransferring = state.phase == TapTransferPhase.transferring;

    _transitionTo(
      TapTransferState(
        phase: TapTransferPhase.cancelled,
        armedFiles: state.armedFiles,
        lastReason: reason,
      ),
    );

    if (wasTransferring && activeSessionKey != null) {
      await _executor.abortTransfer(activeSessionKey);
    }
  }

  Future<void> _abortAndCancel({
    required String sessionKey,
    required String reason,
  }) async {
    _activeOperationToken++;
    _transitionTo(
      TapTransferState(
        phase: TapTransferPhase.cancelled,
        armedFiles: state.armedFiles,
        lastReason: reason,
      ),
    );
    await _executor.abortTransfer(sessionKey);
  }

  void _startConfirmTimer() {
    _startTimer(
      confirmTimeout,
      onTimeout: () {
        if (state.phase == TapTransferPhase.matched || state.phase == TapTransferPhase.confirming) {
          _activeOperationToken++;
          _transitionTo(
            TapTransferState(
              phase: TapTransferPhase.cancelled,
              armedFiles: state.armedFiles,
              lastReason: 'timeout_${state.phase.name}',
            ),
          );
        }
      },
    );
  }

  void _startTimer(Duration duration, {required void Function() onTimeout}) {
    _cancelTimer();
    _phaseTimer = Timer(duration, onTimeout);
  }

  void _cancelTimer() {
    _phaseTimer?.cancel();
    _phaseTimer = null;
  }

  @override
  void dispose() {
    _cancelTimer();
    super.dispose();
  }
}
