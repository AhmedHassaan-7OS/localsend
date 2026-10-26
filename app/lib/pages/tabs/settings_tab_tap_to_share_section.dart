import 'package:flutter/material.dart';
import 'package:localsend_app/provider/tap_to_share/tap_security_provider.dart';
import 'package:localsend_app/util/tap_to_share/tap_security_policy.dart';
import 'package:refena_flutter/refena_flutter.dart';

/// Accessible Settings card configuring Tap-to-Share security mode, favorite auto-accept, and sensitivity (`Spec 005`).
class TapToShareSettingsSection extends StatelessWidget {
  const TapToShareSettingsSection({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = context.watch(tapToShareSettingsProvider);
    final controller = context.notifier(tapToShareSettingsProvider);
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Semantics(
              header: true,
              child: Text(
                'Tap-to-Share Security',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: colorScheme.onSurface,
                ),
              ),
            ),
            const SizedBox(height: 8),
            MergeSemantics(
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 48),
                child: SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(
                    'Enable Tap-to-Share',
                    style: TextStyle(color: colorScheme.onSurface),
                  ),
                  subtitle: Text(
                    settings.isEnabled ? 'Active (${_modeLabel(settings.securityMode)})' : 'Disabled by default for privacy',
                    style: TextStyle(color: colorScheme.onSurfaceVariant),
                  ),
                  value: settings.isEnabled,
                  onChanged: controller.setEnabled,
                ),
              ),
            ),
            if (settings.isEnabled) ...[
              const Divider(),
              Text(
                'Allowed Peers',
                style: theme.textTheme.labelLarge?.copyWith(
                  color: colorScheme.onSurface,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _ModeOptionButton(
                    label: 'Favorites Only (Recommended)',
                    selected: settings.securityMode == TapToShareSecurityMode.favoritesOnly,
                    onTap: () => controller.setSecurityMode(TapToShareSecurityMode.favoritesOnly),
                  ),
                  _ModeOptionButton(
                    label: 'Everyone (Ask Every Time)',
                    selected: settings.securityMode == TapToShareSecurityMode.everyoneWithConfirmation,
                    onTap: () => controller.setSecurityMode(TapToShareSecurityMode.everyoneWithConfirmation),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              MergeSemantics(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 48),
                  child: SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      'Auto-Accept Verified Favorites',
                      style: TextStyle(color: colorScheme.onSurface),
                    ),
                    subtitle: Text(
                      'Verified via TLS certificate SHA-256 fingerprint (never device name)',
                      style: TextStyle(color: colorScheme.onSurfaceVariant),
                    ),
                    value: settings.autoAcceptFavorites,
                    onChanged: controller.setAutoAcceptFavorites,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Impact Sensitivity',
                style: theme.textTheme.labelLarge?.copyWith(
                  color: colorScheme.onSurface,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final preset in TapSensitivityPreset.values)
                    _ModeOptionButton(
                      label: 'Sensitivity: ${_presetLabel(preset)}',
                      selected: settings.sensitivityPreset == preset,
                      onTap: () => controller.setSensitivityPreset(preset),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _modeLabel(TapToShareSecurityMode mode) {
    switch (mode) {
      case TapToShareSecurityMode.disabled:
        return 'Disabled';
      case TapToShareSecurityMode.favoritesOnly:
        return 'Favorites Only';
      case TapToShareSecurityMode.everyoneWithConfirmation:
        return 'Everyone with Confirmation';
    }
  }

  String _presetLabel(TapSensitivityPreset preset) {
    switch (preset) {
      case TapSensitivityPreset.low:
        return 'Low';
      case TapSensitivityPreset.balanced:
        return 'Balanced';
      case TapSensitivityPreset.high:
        return 'High';
    }
  }
}

class _ModeOptionButton extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _ModeOptionButton({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
        child: OutlinedButton.icon(
          style: OutlinedButton.styleFrom(
            minimumSize: const Size(48, 48),
            backgroundColor: selected ? colorScheme.primaryContainer : null,
            foregroundColor: selected ? colorScheme.onPrimaryContainer : colorScheme.onSurface,
          ),
          onPressed: onTap,
          icon: Icon(
            selected ? Icons.check_circle : Icons.radio_button_unchecked,
            size: 18,
          ),
          label: Text(label),
        ),
      ),
    );
  }
}
