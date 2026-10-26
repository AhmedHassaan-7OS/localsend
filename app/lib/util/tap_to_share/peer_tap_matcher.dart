import 'dart:collection';
import 'dart:math' as math;

import 'package:localsend_app/model/tap_to_share/impact_event.dart';

/// Truncates a SHA-256 certificate fingerprint to its first 8 hex characters for privacy-safe logging.
String truncateFingerprint(String fingerprint) {
  final normalized = fingerprint.trim().toUpperCase();
  if (normalized.length <= 8) {
    return normalized;
  }
  return normalized.substring(0, 8);
}

/// NTP-style 4-timestamp ping/pong sample in microseconds.
class ClockSyncSample {
  /// Local monotonic/wall timestamp when ping request was sent ($t_1$).
  final int t1LocalSendUs;

  /// Peer timestamp when ping request was received ($t_2$).
  final int t2PeerRecvUs;

  /// Peer timestamp when pong response was sent ($t_3$).
  final int t3PeerSendUs;

  /// Local timestamp when pong response was received ($t_4$).
  final int t4LocalRecvUs;

  const ClockSyncSample({
    required this.t1LocalSendUs,
    required this.t2PeerRecvUs,
    required this.t3PeerSendUs,
    required this.t4LocalRecvUs,
  });

  /// Round-trip network delay in microseconds: $(t_4 - t_1) - (t_3 - t_2)$.
  int get rttUs => math.max(0, (t4LocalRecvUs - t1LocalSendUs) - (t3PeerSendUs - t2PeerRecvUs));

  /// Estimated clock offset $\theta$ in microseconds such that $t_{\text{peer}} \approx t_{\text{local}} + \theta$.
  int get clockOffsetUs => (((t2PeerRecvUs - t1LocalSendUs) + (t3PeerSendUs - t4LocalRecvUs)) / 2).round();
}

/// Aggregated clock offset and network delay estimate for a specific peer.
class PeerClockEstimate {
  final String peerFingerprint;
  final int clockOffsetUs;
  final int minRttUs;
  final int latestRttUs;
  final int jitterUs;
  final int sampleCount;

  const PeerClockEstimate({
    required this.peerFingerprint,
    required this.clockOffsetUs,
    required this.minRttUs,
    required this.latestRttUs,
    required this.jitterUs,
    required this.sampleCount,
  });
}

/// Estimates per-peer clock offset ($\theta$), RTT, and jitter using a rolling window of NTP-style samples.
class PeerClockEstimator {
  final int maxSamplesPerPeer;
  final Map<String, ListQueue<ClockSyncSample>> _samplesByPeer = {};
  final Map<String, PeerClockEstimate> _estimatesByPeer = {};

  PeerClockEstimator({this.maxSamplesPerPeer = 8});

  /// Records a new 4-timestamp ping/pong sample and updates the peer's clock estimate.
  PeerClockEstimate recordSample(String peerFingerprint, ClockSyncSample sample) {
    final key = peerFingerprint.trim().toUpperCase();
    final queue = _samplesByPeer.putIfAbsent(key, ListQueue<ClockSyncSample>.new);
    queue.addLast(sample);
    while (queue.length > maxSamplesPerPeer) {
      queue.removeFirst();
    }

    // Standard NTP clock filter: pick the sample with the minimum RTT because it suffered the least queuing asymmetry.
    ClockSyncSample bestSample = queue.first;
    var rttSum = 0;
    for (final s in queue) {
      rttSum += s.rttUs;
      if (s.rttUs < bestSample.rttUs) {
        bestSample = s;
      }
    }

    final meanRtt = rttSum / queue.length;
    var madSum = 0.0;
    for (final s in queue) {
      madSum += (s.rttUs - meanRtt).abs();
    }
    final jitterUs = (madSum / queue.length).round();

    final estimate = PeerClockEstimate(
      peerFingerprint: key,
      clockOffsetUs: bestSample.clockOffsetUs,
      minRttUs: bestSample.rttUs,
      latestRttUs: sample.rttUs,
      jitterUs: jitterUs,
      sampleCount: queue.length,
    );
    _estimatesByPeer[key] = estimate;
    return estimate;
  }

  /// Returns the latest clock estimate for [peerFingerprint], or `null` if no ping/pong samples exist.
  PeerClockEstimate? estimateFor(String peerFingerprint) {
    return _estimatesByPeer[peerFingerprint.trim().toUpperCase()];
  }

  /// Converts a timestamp reported by [peerFingerprint] into the local clock frame ($t_{\text{peer}} - \theta$).
  int toLocalTimestampUs(String peerFingerprint, int peerTimestampUs) {
    final estimate = estimateFor(peerFingerprint);
    if (estimate == null) {
      return peerTimestampUs;
    }
    return peerTimestampUs - estimate.clockOffsetUs;
  }

  void clear() {
    _samplesByPeer.clear();
    _estimatesByPeer.clear();
  }
}

/// Announcement broadcast or exchanged when a peer detects a local tap candidate.
class PeerTapAnnouncement {
  final String senderFingerprint;
  final int impactTimestampUs;
  final String nonce;
  final double peakLinearAccelMps2;
  final DevicePosture posture;
  final double dirX;
  final double dirY;
  final double dirZ;
  final bool hasSelectedFiles;
  final String? senderAlias;
  final int senderPort;
  final bool senderHttps;
  final String? senderDeviceModel;
  final String senderVersion;
  final bool isDesktopTarget;

  const PeerTapAnnouncement({
    required this.senderFingerprint,
    required this.impactTimestampUs,
    required this.nonce,
    required this.peakLinearAccelMps2,
    required this.posture,
    required this.dirX,
    required this.dirY,
    required this.dirZ,
    required this.hasSelectedFiles,
    this.senderAlias,
    this.senderPort = 53317,
    this.senderHttps = true,
    this.senderDeviceModel,
    this.senderVersion = '2.1',
    this.isDesktopTarget = false,
  });

  Map<String, dynamic> toJson() => {
    'senderFingerprint': senderFingerprint.trim().toUpperCase(),
    'impactTimestampUs': impactTimestampUs,
    'nonce': nonce,
    'peakLinearAccelMps2': peakLinearAccelMps2,
    'posture': posture.name,
    'dirX': dirX,
    'dirY': dirY,
    'dirZ': dirZ,
    'hasSelectedFiles': hasSelectedFiles,
    if (senderAlias != null) 'senderAlias': senderAlias,
    'senderPort': senderPort,
    'senderHttps': senderHttps,
    if (senderDeviceModel != null) 'senderDeviceModel': senderDeviceModel,
    'senderVersion': senderVersion,
    'isDesktopTarget': isDesktopTarget,
  };

  factory PeerTapAnnouncement.fromJson(Map<String, dynamic> json) {
    final postureName = json['posture'] as String? ?? DevicePosture.unknown.name;
    final posture = DevicePosture.values.firstWhere(
      (p) => p.name == postureName,
      orElse: () => DevicePosture.unknown,
    );
    return PeerTapAnnouncement(
      senderFingerprint: (json['senderFingerprint'] as String).trim().toUpperCase(),
      impactTimestampUs: (json['impactTimestampUs'] as num).toInt(),
      nonce: json['nonce'] as String,
      peakLinearAccelMps2: (json['peakLinearAccelMps2'] as num).toDouble(),
      posture: posture,
      dirX: (json['dirX'] as num?)?.toDouble() ?? 0.0,
      dirY: (json['dirY'] as num?)?.toDouble() ?? 0.0,
      dirZ: (json['dirZ'] as num?)?.toDouble() ?? 0.0,
      hasSelectedFiles: json['hasSelectedFiles'] as bool? ?? false,
      senderAlias: json['senderAlias'] as String?,
      senderPort: (json['senderPort'] as num?)?.toInt() ?? 53317,
      senderHttps: json['senderHttps'] as bool? ?? true,
      senderDeviceModel: json['senderDeviceModel'] as String?,
      senderVersion: json['senderVersion'] as String? ?? '2.1',
      isDesktopTarget: json['isDesktopTarget'] as bool? ?? false,
    );
  }
}

/// Scored peer candidate within the effective matching window.
class PeerMatchCandidate {
  final PeerTapAnnouncement announcement;
  final int correctedPeerTimestampUs;
  final int timestampDeltaUs;
  final int effectiveWindowUs;
  final int estimatedRttUs;
  final double score;

  const PeerMatchCandidate({
    required this.announcement,
    required this.correctedPeerTimestampUs,
    required this.timestampDeltaUs,
    required this.effectiveWindowUs,
    required this.estimatedRttUs,
    required this.score,
  });
}

enum PeerMatchStatus {
  matched,
  ambiguous,
  noMatch,
}

/// Outcome of correlating a local tap with received peer announcements.
class PeerMatchResult {
  final PeerMatchStatus status;
  final DetectedTapEvent? localTap;
  final String? localNonce;
  final PeerMatchCandidate? matchedCandidate;
  final List<PeerMatchCandidate> candidates;
  final String? rejectionReason;

  const PeerMatchResult({
    required this.status,
    this.localTap,
    this.localNonce,
    this.matchedCandidate,
    this.candidates = const [],
    this.rejectionReason,
  });

  factory PeerMatchResult.noMatch({
    DetectedTapEvent? localTap,
    String? localNonce,
    required String reason,
  }) {
    return PeerMatchResult(
      status: PeerMatchStatus.noMatch,
      localTap: localTap,
      localNonce: localNonce,
      rejectionReason: reason,
    );
  }
}

class _PendingAnnouncement {
  final PeerTapAnnouncement announcement;
  final int receivedAtLocalUs;

  const _PendingAnnouncement({
    required this.announcement,
    required this.receivedAtLocalUs,
  });
}

/// Coordinates local impact events with remote peer announcements using latency-adjusted windows and replay defense.
class PeerTapMatcher {
  final String localFingerprint;
  final PeerClockEstimator clockEstimator;

  /// Base matching window in microseconds (`120 ms` default, refined via field telemetry).
  final int baseMatchingWindowUs;

  /// Upper cap on latency-adjusted matching window (`450 ms` default).
  final int maxMatchingWindowUs;

  /// Minimum plausible peak linear acceleration (`m/s^2`).
  final double minPeakLinearAccelMps2;

  /// Maximum plausible peak linear acceleration (`m/s^2`).
  final double maxPeakLinearAccelMps2;

  /// Minimum score lead required when 2+ peers match simultaneously before declaring an unambiguous winner.
  final double ambiguityScoreMargin;

  /// Time-to-live for replay-cache nonces in microseconds (`30 s` default).
  final int nonceTtlUs;

  DetectedTapEvent? _activeLocalTap;
  String? _activeLocalNonce;
  bool _activeLocalHasFiles = false;

  final List<_PendingAnnouncement> _pendingAnnouncements = [];
  final Map<String, int> _seenNonceExpiryByKey = {};

  PeerTapMatcher({
    required String localFingerprint,
    PeerClockEstimator? clockEstimator,
    this.baseMatchingWindowUs = 120000,
    this.maxMatchingWindowUs = 450000,
    this.minPeakLinearAccelMps2 = 3.5,
    this.maxPeakLinearAccelMps2 = 85.0,
    this.ambiguityScoreMargin = 0.15,
    this.nonceTtlUs = 30000000,
  }) : localFingerprint = localFingerprint.trim().toUpperCase(),
       clockEstimator = clockEstimator ?? PeerClockEstimator();

  bool get hasActiveLocalTap => _activeLocalTap != null;
  bool get activeLocalHasFiles => _activeLocalHasFiles;

  /// Computes the latency-adjusted matching window for [peerFingerprint].
  int effectiveWindowUsForPeer(String peerFingerprint) {
    final estimate = clockEstimator.estimateFor(peerFingerprint);
    if (estimate == null) {
      return baseMatchingWindowUs;
    }
    final dynamicWindow = baseMatchingWindowUs + (estimate.latestRttUs ~/ 2) + estimate.jitterUs;
    return math.min(maxMatchingWindowUs, dynamicWindow);
  }

  /// Registers a local physical tap event detected by `ImpactDetector`.
  void recordLocalTap(
    DetectedTapEvent tap, {
    required String localNonce,
    required bool hasSelectedFiles,
  }) {
    _activeLocalTap = tap;
    _activeLocalNonce = localNonce;
    _activeLocalHasFiles = hasSelectedFiles;
  }

  /// Clears the active local tap candidate.
  void clearLocalTap() {
    _activeLocalTap = null;
    _activeLocalNonce = null;
    _activeLocalHasFiles = false;
  }

  /// Processes an incoming `PeerTapAnnouncement`.
  /// Returns `true` if accepted into the candidate pool, or `false` if rejected (self-echo, replay, or out-of-bounds).
  bool receivePeerAnnouncement(
    PeerTapAnnouncement announcement, {
    required int receivedAtLocalUs,
  }) {
    _pruneExpiredState(receivedAtLocalUs);

    final senderFp = announcement.senderFingerprint.trim().toUpperCase();
    if (senderFp.isEmpty || senderFp == localFingerprint) {
      return false;
    }

    final trimmedNonce = announcement.nonce.trim();
    if (trimmedNonce.isEmpty) {
      return false;
    }

    final replayKey = '$senderFp:$trimmedNonce';
    if (_seenNonceExpiryByKey.containsKey(replayKey)) {
      return false;
    }

    if (announcement.peakLinearAccelMps2 < minPeakLinearAccelMps2 || announcement.peakLinearAccelMps2 > maxPeakLinearAccelMps2) {
      return false;
    }

    _seenNonceExpiryByKey[replayKey] = receivedAtLocalUs + nonceTtlUs;
    _pendingAnnouncements.add(
      _PendingAnnouncement(
        announcement: PeerTapAnnouncement(
          senderFingerprint: senderFp,
          impactTimestampUs: announcement.impactTimestampUs,
          nonce: trimmedNonce,
          peakLinearAccelMps2: announcement.peakLinearAccelMps2,
          posture: announcement.posture,
          dirX: announcement.dirX,
          dirY: announcement.dirY,
          dirZ: announcement.dirZ,
          hasSelectedFiles: announcement.hasSelectedFiles,
        ),
        receivedAtLocalUs: receivedAtLocalUs,
      ),
    );
    return true;
  }

  /// Evaluates whether the active local tap matches any pending peer announcement.
  PeerMatchResult evaluate({required int nowLocalUs}) {
    _pruneExpiredState(nowLocalUs);

    final localTap = _activeLocalTap;
    final localNonce = _activeLocalNonce;
    if (localTap == null || localNonce == null) {
      return PeerMatchResult.noMatch(reason: 'no_local_tap');
    }

    if ((nowLocalUs - localTap.impactTimestampUs).abs() > maxMatchingWindowUs) {
      clearLocalTap();
      return PeerMatchResult.noMatch(
        localTap: localTap,
        localNonce: localNonce,
        reason: 'local_tap_expired',
      );
    }

    // Best candidate per unique peer fingerprint.
    final bestByPeer = <String, PeerMatchCandidate>{};

    for (final pending in _pendingAnnouncements) {
      final ann = pending.announcement;
      final peerFp = ann.senderFingerprint;
      final effectiveWindowUs = effectiveWindowUsForPeer(peerFp);
      final correctedPeerTsUs = clockEstimator.toLocalTimestampUs(peerFp, ann.impactTimestampUs);
      final deltaUs = (localTap.impactTimestampUs - correctedPeerTsUs).abs();

      if (deltaUs > effectiveWindowUs) {
        continue;
      }

      final timeScore = (1.0 - (deltaUs / effectiveWindowUs)).clamp(0.0, 1.0);
      final minPeak = math.min(localTap.peakLinearAccelMps2, ann.peakLinearAccelMps2);
      final maxPeak = math.max(localTap.peakLinearAccelMps2, ann.peakLinearAccelMps2);
      final impulseScore = maxPeak > 0 ? (minPeak / maxPeak).clamp(0.0, 1.0) : 0.0;
      final totalScore = (0.70 * timeScore) + (0.30 * impulseScore);

      final estimate = clockEstimator.estimateFor(peerFp);
      final candidate = PeerMatchCandidate(
        announcement: ann,
        correctedPeerTimestampUs: correctedPeerTsUs,
        timestampDeltaUs: deltaUs,
        effectiveWindowUs: effectiveWindowUs,
        estimatedRttUs: estimate?.latestRttUs ?? 0,
        score: totalScore,
      );

      final existing = bestByPeer[peerFp];
      if (existing == null || candidate.score > existing.score) {
        bestByPeer[peerFp] = candidate;
      }
    }

    if (bestByPeer.isEmpty) {
      return PeerMatchResult.noMatch(
        localTap: localTap,
        localNonce: localNonce,
        reason: 'no_peer_within_window',
      );
    }

    final sortedCandidates = bestByPeer.values.toList()..sort((a, b) => b.score.compareTo(a.score));

    if (sortedCandidates.length >= 2) {
      final scoreLead = sortedCandidates[0].score - sortedCandidates[1].score;
      if (scoreLead < ambiguityScoreMargin) {
        return PeerMatchResult(
          status: PeerMatchStatus.ambiguous,
          localTap: localTap,
          localNonce: localNonce,
          candidates: List.unmodifiable(sortedCandidates),
          rejectionReason: 'ambiguous_multiple_peers',
        );
      }
    }

    final winner = sortedCandidates.first;
    _consumeMatchedPair(winner.announcement.senderFingerprint, winner.announcement.nonce);

    return PeerMatchResult(
      status: PeerMatchStatus.matched,
      localTap: localTap,
      localNonce: localNonce,
      matchedCandidate: winner,
      candidates: List.unmodifiable(sortedCandidates),
    );
  }

  void _consumeMatchedPair(String peerFingerprint, String peerNonce) {
    clearLocalTap();
    _pendingAnnouncements.removeWhere(
      (p) => p.announcement.senderFingerprint == peerFingerprint && p.announcement.nonce == peerNonce,
    );
  }

  void _pruneExpiredState(int nowLocalUs) {
    _seenNonceExpiryByKey.removeWhere((_, expiryUs) => nowLocalUs >= expiryUs);
    _pendingAnnouncements.removeWhere(
      (p) => (nowLocalUs - p.receivedAtLocalUs).abs() > maxMatchingWindowUs * 2,
    );
  }
}
