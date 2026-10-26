import 'dart:collection';

import 'package:localsend_app/model/persistence/favorite_device.dart';
import 'package:localsend_app/model/tap_to_share/impact_event.dart';
import 'package:localsend_app/util/tap_to_share/peer_tap_matcher.dart';

/// User-selectable security modes for Tap-to-Share (`Spec 005`).
enum TapToShareSecurityMode {
  /// Feature is completely off (`R2.2` default).
  disabled,

  /// Only peers whose TLS certificate SHA-256 `fingerprint` is in Favorites can match (`R4.9` default when enabled).
  favoritesOnly,

  /// Any nearby peer can match if both devices experience a physical tap, always requiring manual confirmation.
  everyoneWithConfirmation,
}

/// User-selectable impact sensitivity preset.
enum TapSensitivityPreset {
  low,
  balanced,
  high
  ;

  ImpactDetectorConfig toDetectorConfig() {
    switch (this) {
      case TapSensitivityPreset.low:
        return const ImpactDetectorConfig(
          minPeakLinearAccelMps2: 8.5,
          minJerkMps3: 400.0,
          maxPreImpactGyroRmsRadPerSec: 4.5,
          maxPreImpactGyroPeakRadPerSec: 9.0,
          maxPreImpactAccelRmsMps2: 6.5,
          maxDuringImpactGyroPeakRadPerSec: 10.0,
          maxPostImpactGyroRmsRadPerSec: 4.0,
          maxPostImpactAccelRmsMps2: 6.0,
        );
      case TapSensitivityPreset.balanced:
        return const ImpactDetectorConfig(
          minPeakLinearAccelMps2: 5.5,
          minJerkMps3: 220.0,
          maxPreImpactGyroRmsRadPerSec: 6.5,
          maxPreImpactGyroPeakRadPerSec: 12.0,
          maxPreImpactAccelRmsMps2: 9.5,
          maxDuringImpactGyroPeakRadPerSec: 15.0,
          maxPostImpactGyroRmsRadPerSec: 6.0,
          maxPostImpactAccelRmsMps2: 9.0,
        );
      case TapSensitivityPreset.high:
        return const ImpactDetectorConfig(
          minPeakLinearAccelMps2: 3.8,
          minJerkMps3: 140.0,
          maxPreImpactGyroRmsRadPerSec: 8.5,
          maxPreImpactGyroPeakRadPerSec: 16.0,
          maxPreImpactAccelRmsMps2: 12.0,
          maxDuringImpactGyroPeakRadPerSec: 20.0,
          maxPostImpactGyroRmsRadPerSec: 8.0,
          maxPostImpactAccelRmsMps2: 11.0,
        );
    }
  }
}

/// Immutable settings model for Tap-to-Share (`Spec 005`).
class TapToShareSettings {
  final TapToShareSecurityMode securityMode;

  /// Optional auto-accept for verified Favorite devices only (`false` by default).
  /// Non-favorite devices always require manual confirmation regardless of this setting.
  final bool autoAcceptFavorites;

  final TapSensitivityPreset sensitivityPreset;

  const TapToShareSettings({
    this.securityMode = TapToShareSecurityMode.disabled,
    this.autoAcceptFavorites = false,
    this.sensitivityPreset = TapSensitivityPreset.balanced,
  });

  bool get isEnabled => securityMode != TapToShareSecurityMode.disabled;

  /// Toggles the feature on or off. Enabling from `disabled` always defaults to `favoritesOnly` (`R4.9`).
  TapToShareSettings withEnabled(bool enabled) {
    if (!enabled) {
      return copyWith(securityMode: TapToShareSecurityMode.disabled);
    }
    if (securityMode == TapToShareSecurityMode.disabled) {
      return copyWith(securityMode: TapToShareSecurityMode.favoritesOnly);
    }
    return this;
  }

  TapToShareSettings copyWith({
    TapToShareSecurityMode? securityMode,
    bool? autoAcceptFavorites,
    TapSensitivityPreset? sensitivityPreset,
  }) {
    return TapToShareSettings(
      securityMode: securityMode ?? this.securityMode,
      autoAcceptFavorites: autoAcceptFavorites ?? this.autoAcceptFavorites,
      sensitivityPreset: sensitivityPreset ?? this.sensitivityPreset,
    );
  }
}

/// Reason codes produced by [TapSecurityPolicyGuard].
enum TapSecurityDecisionReason {
  allowed,
  featureDisabled,
  selfAnnouncement,
  invalidNonce,
  replayedNonce,
  expiredTimestamp,
  rateLimited,
  untrustedPeer,
}

/// Result of evaluating a peer tap announcement against the active security policy.
class TapSecurityDecision {
  final bool allowed;
  final TapSecurityDecisionReason reason;
  final bool isFavoritePeer;
  final bool requiresManualConfirmation;
  final String sanitizedLogMessage;

  const TapSecurityDecision({
    required this.allowed,
    required this.reason,
    required this.isFavoritePeer,
    required this.requiresManualConfirmation,
    required this.sanitizedLogMessage,
  });
}

/// Enforces certificate fingerprint verification, nonce replay defense, timestamp freshness, and per-peer rate limiting.
class TapSecurityPolicyGuard {
  final String localFingerprint;
  final int maxAnnouncementAgeUs;
  final int nonceTtlUs;
  final int rateLimitWindowUs;
  final int maxAttemptsPerWindow;

  final Map<String, int> _seenNonceExpiryByKey = {};
  final Map<String, ListQueue<int>> _attemptTimestampsByPeer = {};

  TapSecurityPolicyGuard({
    required String localFingerprint,
    this.maxAnnouncementAgeUs = 3000000, // 3 seconds
    this.nonceTtlUs = 30000000, // 30 seconds
    this.rateLimitWindowUs = 10000000, // 10 seconds
    this.maxAttemptsPerWindow = 3,
  }) : localFingerprint = localFingerprint.trim().toUpperCase();

  /// Evaluates [announcement] against [settings] and the user's [favorites] list.
  ///
  /// Identity is verified strictly via TLS certificate `fingerprint` (`FavoriteDevice.fingerprint`),
  /// never via [claimedAlias] (`AC-2`, `R4.9`, `R7.8`).
  TapSecurityDecision evaluateAnnouncement({
    required PeerTapAnnouncement announcement,
    required TapToShareSettings settings,
    required List<FavoriteDevice> favorites,
    required int correctedPeerTimestampUs,
    required int nowLocalUs,
    String? claimedAlias,
  }) {
    _pruneExpiredState(nowLocalUs);

    final senderFp = announcement.senderFingerprint.trim().toUpperCase();
    final shortFp = truncateFingerprint(senderFp);

    if (settings.securityMode == TapToShareSecurityMode.disabled) {
      return TapSecurityDecision(
        allowed: false,
        reason: TapSecurityDecisionReason.featureDisabled,
        isFavoritePeer: false,
        requiresManualConfirmation: true,
        sanitizedLogMessage: 'Tap-to-Share rejected packet from $shortFp: feature disabled.',
      );
    }

    if (senderFp.isEmpty || senderFp == localFingerprint) {
      return TapSecurityDecision(
        allowed: false,
        reason: TapSecurityDecisionReason.selfAnnouncement,
        isFavoritePeer: false,
        requiresManualConfirmation: true,
        sanitizedLogMessage: 'Tap-to-Share rejected self/empty fingerprint ($shortFp).',
      );
    }

    // Sliding-window per-peer rate limiter (`AC-4`).
    final attempts = _attemptTimestampsByPeer.putIfAbsent(senderFp, ListQueue<int>.new);
    while (attempts.isNotEmpty && (nowLocalUs - attempts.first) > rateLimitWindowUs) {
      attempts.removeFirst();
    }
    if (attempts.length >= maxAttemptsPerWindow) {
      return TapSecurityDecision(
        allowed: false,
        reason: TapSecurityDecisionReason.rateLimited,
        isFavoritePeer: false,
        requiresManualConfirmation: true,
        sanitizedLogMessage: 'Tap-to-Share rate-limited peer $shortFp (>= $maxAttemptsPerWindow attempts).',
      );
    }
    attempts.addLast(nowLocalUs);

    // Nonce presence and replay validation (`AC-3`).
    final trimmedNonce = announcement.nonce.trim();
    if (trimmedNonce.isEmpty) {
      return TapSecurityDecision(
        allowed: false,
        reason: TapSecurityDecisionReason.invalidNonce,
        isFavoritePeer: false,
        requiresManualConfirmation: true,
        sanitizedLogMessage: 'Tap-to-Share rejected packet from $shortFp: empty nonce.',
      );
    }

    final nonceKey = '$senderFp:$trimmedNonce';
    if (_seenNonceExpiryByKey.containsKey(nonceKey)) {
      return TapSecurityDecision(
        allowed: false,
        reason: TapSecurityDecisionReason.replayedNonce,
        isFavoritePeer: false,
        requiresManualConfirmation: true,
        sanitizedLogMessage: 'Tap-to-Share rejected replayed nonce from $shortFp.',
      );
    }

    // Timestamp freshness check (`AC-3`).
    final ageUs = (nowLocalUs - correctedPeerTimestampUs).abs();
    if (ageUs > maxAnnouncementAgeUs) {
      return TapSecurityDecision(
        allowed: false,
        reason: TapSecurityDecisionReason.expiredTimestamp,
        isFavoritePeer: false,
        requiresManualConfirmation: true,
        sanitizedLogMessage: 'Tap-to-Share rejected stale packet from $shortFp (ageUs=$ageUs).',
      );
    }

    // Strict TLS certificate fingerprint check against Favorites (`AC-2`).
    // Note: `claimedAlias` is intentionally ignored for trust decisions.
    final isFavorite = favorites.any(
      (fav) => fav.fingerprint.trim().toUpperCase() == senderFp,
    );

    if (settings.securityMode == TapToShareSecurityMode.favoritesOnly && !isFavorite) {
      return TapSecurityDecision(
        allowed: false,
        reason: TapSecurityDecisionReason.untrustedPeer,
        isFavoritePeer: false,
        requiresManualConfirmation: true,
        sanitizedLogMessage: 'Tap-to-Share rejected non-favorite peer $shortFp in favoritesOnly mode.',
      );
    }

    _seenNonceExpiryByKey[nonceKey] = nowLocalUs + nonceTtlUs;

    final requiresConfirmation = !isFavorite || !settings.autoAcceptFavorites;
    return TapSecurityDecision(
      allowed: true,
      reason: TapSecurityDecisionReason.allowed,
      isFavoritePeer: isFavorite,
      requiresManualConfirmation: requiresConfirmation,
      sanitizedLogMessage: 'Tap-to-Share accepted packet from $shortFp (fav=$isFavorite, confirm=$requiresConfirmation).',
    );
  }

  void _pruneExpiredState(int nowLocalUs) {
    _seenNonceExpiryByKey.removeWhere((_, expiryUs) => nowLocalUs >= expiryUs);
    _attemptTimestampsByPeer.removeWhere((_, queue) {
      while (queue.isNotEmpty && (nowLocalUs - queue.first) > rateLimitWindowUs) {
        queue.removeFirst();
      }
      return queue.isEmpty;
    });
  }
}
