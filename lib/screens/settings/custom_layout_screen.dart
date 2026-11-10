import 'package:flutter/material.dart';
import '../../l10n/l10n.dart';
import 'prefs_tiles.dart';
import 'settings_page.dart';
import '../../util/settings.dart';

/// Custom layout overrides. The master switch turns the override layer on;
/// each behavior switch then forces that behavior in both compact and full.
/// With the master off the switches grey out and the layout follows the
/// compact/full default.
class CustomLayoutScreen extends StatelessWidget {
  const CustomLayoutScreen({super.key});

  /// The override switches under the master, each with its hint.
  static List<(Setting<bool>, String)> _overrides(AppLocalizations l) => [
    (Settings.overrideTightComposer, l.tighterComposerHint),
    (Settings.overrideSheetActionRow, l.horizontalSheetActionsHint),
    (Settings.overrideCompactDensity, l.compactDensityHint),
  ];

  @override
  Widget build(BuildContext context) {
    return SettingsPage(
      title: Text(context.l10n.layoutCustom),
      body: ValueListenableBuilder<bool>(
        valueListenable: Settings.customLayoutEnabled,
        builder: (context, enabled, _) => ListView(
          children: [
            SettingSwitch(Settings.customLayoutEnabled),
            const Divider(),
            for (final (setting, hint) in _overrides(context.l10n))
              SettingSwitch(setting, enabled: enabled, subtitle: hint),
          ],
        ),
      ),
    );
  }
}
