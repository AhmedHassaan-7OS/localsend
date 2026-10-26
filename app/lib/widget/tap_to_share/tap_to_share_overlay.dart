import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:localsend_app/provider/tap_to_share/tap_transfer_state_machine.dart';
import 'package:localsend_app/util/tap_to_share/peer_tap_matcher.dart';
import 'package:refena_flutter/refena_flutter.dart';

/// Paints concentric contact ripples radiating from the physical impact edge (`Spec 006`).
class TapRipplePainter extends CustomPainter {
  final double progress;
  final double dirX;
  final double dirY;
  final Color color;
  final bool reduceMotion;

  const TapRipplePainter({
    required this.progress,
    required this.dirX,
    required this.dirY,
    required this.color,
    required this.reduceMotion,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final norm = math.sqrt((dirX * dirX) + (dirY * dirY));
    final nx = norm > 1e-6 ? dirX / norm : 0.0;
    final ny = norm > 1e-6 ? dirY / norm : 1.0;

    final center = Offset(
      size.width * (0.5 + (0.42 * nx)),
      size.height * (0.5 - (0.42 * ny)),
    );

    if (reduceMotion) {
      final staticPaint = Paint()
        ..color = color.withValues(alpha: 0.22)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3.0;
      canvas.drawCircle(center, 28.0, staticPaint);
      return;
    }

    final maxRadius = math.max(size.width, size.height) * 0.85;
    for (var ring = 0; ring < 3; ring++) {
      final ringPhase = (progress + (ring / 3.0)) % 1.0;
      final radius = 14.0 + (maxRadius * ringPhase);
      final alpha = ((1.0 - ringPhase) * 0.30).clamp(0.0, 1.0);
      final paint = Paint()
        ..color = color.withValues(alpha: alpha)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5;
      canvas.drawCircle(center, radius, paint);
    }
  }

  @override
  bool shouldRepaint(covariant TapRipplePainter oldDelegate) {
    return oldDelegate.progress != progress ||
        oldDelegate.dirX != dirX ||
        oldDelegate.dirY != dirY ||
        oldDelegate.color != color ||
        oldDelegate.reduceMotion != reduceMotion;
  }
}

/// Visual and haptic overlay card for Tap-to-Share (`Spec 006`).
///
/// Decoupled from detection and state-machine transitions (`R4.6`): disabling animations or
/// unmounting this widget never delays or alters [TapTransferStateMachineController].
class TapToShareOverlayCard extends StatefulWidget {
  final bool reduceMotion;
  final VoidCallback? onHapticFeedback;
  final String? peerDisplayName;

  const TapToShareOverlayCard({
    super.key,
    this.reduceMotion = false,
    this.onHapticFeedback,
    this.peerDisplayName,
  });

  @override
  State<TapToShareOverlayCard> createState() => _TapToShareOverlayCardState();
}

class _TapToShareOverlayCardState extends State<TapToShareOverlayCard> with SingleTickerProviderStateMixin, Refena {
  late final AnimationController _rippleController;
  String? _lastHapticSessionKey;

  @override
  void initState() {
    super.initState();
    _rippleController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    );
  }

  @override
  void dispose() {
    _rippleController.dispose();
    super.dispose();
  }

  void _syncEffects(TapTransferState state, {required bool effectiveReduceMotion}) {
    final shouldAnimateRipple = !effectiveReduceMotion && (state.phase == TapTransferPhase.tapDetected || state.phase == TapTransferPhase.matched);

    if (shouldAnimateRipple) {
      if (!_rippleController.isAnimating) {
        unawaited(_rippleController.repeat());
      }
    } else {
      if (_rippleController.isAnimating) {
        _rippleController.stop();
      }
    }

    if (state.phase == TapTransferPhase.matched && state.sessionKey != null && _lastHapticSessionKey != state.sessionKey) {
      _lastHapticSessionKey = state.sessionKey;
      final triggerHaptic = widget.onHapticFeedback ?? HapticFeedback.mediumImpact;
      triggerHaptic();
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(tapTransferStateMachineProvider);
    final controller = ref.notifier(tapTransferStateMachineProvider);
    final effectiveReduceMotion = widget.reduceMotion || MediaQuery.disableAnimationsOf(context);

    _syncEffects(state, effectiveReduceMotion: effectiveReduceMotion);

    if (state.phase == TapTransferPhase.idle || state.phase == TapTransferPhase.armed) {
      return const SizedBox.shrink();
    }

    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final dirX = state.localTap?.dirX ?? 0.0;
    final dirY = state.localTap?.dirY ?? 1.0;
    final shortPeerFp = state.peerFingerprint != null ? truncateFingerprint(state.peerFingerprint!) : '----';
    final peerLabel = widget.peerDisplayName != null ? '${widget.peerDisplayName} ($shortPeerFp)' : 'Peer $shortPeerFp';

    return Card(
      margin: const EdgeInsets.all(12),
      clipBehavior: Clip.antiAlias,
      child: AnimatedBuilder(
        animation: _rippleController,
        builder: (context, child) {
          return CustomPaint(
            painter: (state.phase == TapTransferPhase.tapDetected || state.phase == TapTransferPhase.matched)
                ? TapRipplePainter(
                    progress: _rippleController.value,
                    dirX: dirX,
                    dirY: dirY,
                    color: colorScheme.primary,
                    reduceMotion: effectiveReduceMotion,
                  )
                : null,
            child: child,
          );
        },
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Semantics(
                container: true,
                liveRegion: true,
                child: Text(
                  _headlineForPhase(state, peerLabel),
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: colorScheme.onSurface,
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                _subtitleForPhase(state),
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 12),
              if (state.phase == TapTransferPhase.matched && state.role == TapTransferRole.conflict)
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _ActionButton(
                      label: 'Send My Files (${state.lockedFiles.length})',
                      icon: Icons.upload_file,
                      isPrimary: true,
                      onPressed: () {
                        controller.resolveRoleConflict(TapTransferRole.sender);
                      },
                    ),
                    _ActionButton(
                      label: 'Receive Peer Files',
                      icon: Icons.download,
                      isPrimary: false,
                      onPressed: () {
                        controller.resolveRoleConflict(TapTransferRole.receiver);
                      },
                    ),
                    _ActionButton(
                      label: 'Cancel',
                      icon: Icons.close,
                      isPrimary: false,
                      onPressed: () {
                        unawaited(controller.cancel());
                      },
                    ),
                  ],
                )
              else if (state.phase == TapTransferPhase.matched || state.phase == TapTransferPhase.confirming)
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _ActionButton(
                      label: 'Confirm Transfer',
                      icon: Icons.check_circle_outline,
                      isPrimary: true,
                      onPressed: () {
                        unawaited(controller.confirmTransfer());
                      },
                    ),
                    _ActionButton(
                      label: 'Cancel',
                      icon: Icons.close,
                      isPrimary: false,
                      onPressed: () {
                        unawaited(controller.cancel());
                      },
                    ),
                  ],
                )
              else if (state.phase == TapTransferPhase.tapDetected || state.phase == TapTransferPhase.transferring)
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _ActionButton(
                      label: 'Cancel',
                      icon: Icons.close,
                      isPrimary: false,
                      onPressed: () {
                        unawaited(controller.cancel());
                      },
                    ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }

  String _headlineForPhase(TapTransferState state, String peerLabel) {
    switch (state.phase) {
      case TapTransferPhase.idle:
      case TapTransferPhase.armed:
        return 'Tap-to-Share Ready';
      case TapTransferPhase.tapDetected:
        return 'Tap Detected — Searching for Nearby Peer...';
      case TapTransferPhase.matched:
      case TapTransferPhase.confirming:
        return 'Matched with $peerLabel';
      case TapTransferPhase.transferring:
        return 'Transferring with $peerLabel...';
      case TapTransferPhase.done:
        return 'Tap-to-Share Complete';
      case TapTransferPhase.cancelled:
        return 'Tap-to-Share Cancelled';
    }
  }

  String _subtitleForPhase(TapTransferState state) {
    switch (state.phase) {
      case TapTransferPhase.tapDetected:
        return 'Verifying simultaneous tap on same network';
      case TapTransferPhase.matched:
      case TapTransferPhase.confirming:
        if (state.role == TapTransferRole.conflict) {
          return 'Both devices have selected files. Choose transfer direction:';
        }
        if (state.role == TapTransferRole.sender) {
          return 'Ready to send ${state.lockedFiles.length} locked file(s)';
        }
        return 'Ready to receive files from verified peer';
      case TapTransferPhase.transferring:
        return state.role == TapTransferRole.sender ? 'Sending ${state.lockedFiles.length} file(s)...' : 'Receiving file(s)...';
      case TapTransferPhase.done:
        return 'Files transferred successfully.';
      case TapTransferPhase.cancelled:
        return 'Reason: ${state.lastReason ?? "cancelled"}';
      case TapTransferPhase.idle:
      case TapTransferPhase.armed:
        return '';
    }
  }
}

class _ActionButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool isPrimary;
  final VoidCallback onPressed;

  const _ActionButton({
    required this.label,
    required this.icon,
    required this.isPrimary,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      label: label,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
        child: isPrimary
            ? FilledButton.icon(
                style: FilledButton.styleFrom(
                  minimumSize: const Size(48, 48),
                  backgroundColor: colorScheme.primary,
                  foregroundColor: colorScheme.onPrimary,
                ),
                onPressed: onPressed,
                icon: Icon(icon, size: 18),
                label: Text(label),
              )
            : OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size(48, 48),
                  foregroundColor: colorScheme.onSurface,
                ),
                onPressed: onPressed,
                icon: Icon(icon, size: 18),
                label: Text(label),
              ),
      ),
    );
  }
}
