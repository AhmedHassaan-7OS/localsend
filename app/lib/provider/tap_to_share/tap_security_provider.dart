import 'package:localsend_app/util/tap_to_share/tap_security_policy.dart';
import 'package:refena_flutter/refena_flutter.dart';

final tapToShareSettingsProvider = NotifierProvider<TapToShareSettingsController, TapToShareSettings>((ref) {
  return TapToShareSettingsController();
});

/// Refena controller managing user-configurable Tap-to-Share security settings (`Spec 005`).
class TapToShareSettingsController extends Notifier<TapToShareSettings> {
  @override
  TapToShareSettings init() => const TapToShareSettings();

  /// Enables or disables Tap-to-Share (`R2.2`).
  /// Enabling from `disabled` always sets `favoritesOnly` by default (`R4.9`).
  void setEnabled(bool enabled) {
    state = state.withEnabled(enabled);
  }

  /// Updates the active security mode.
  void setSecurityMode(TapToShareSecurityMode mode) {
    state = state.copyWith(securityMode: mode);
  }

  /// Toggles auto-accept for verified Favorite devices (`false` by default).
  void setAutoAcceptFavorites(bool value) {
    state = state.copyWith(autoAcceptFavorites: value);
  }

  /// Updates the impact sensitivity preset.
  void setSensitivityPreset(TapSensitivityPreset preset) {
    state = state.copyWith(sensitivityPreset: preset);
  }
}
