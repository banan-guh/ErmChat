import 'package:flutter/material.dart';
import '../../l10n/l10n.dart';
import 'prefs_tiles.dart';
import 'settings_page.dart';
import 'settings_search.dart';
import '../../util/settings.dart';

/// Custom layout overrides. The master switch turns the override layer on;
/// each behavior switch then forces that behavior in both compact and full.
/// With the master off the switches grey out and the layout follows the
/// compact/full default.
class CustomLayoutScreen extends StatelessWidget {
  const CustomLayoutScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return SettingsPage(
      title: Text(context.l10n.layoutCustom),
      body: ValueListenableBuilder<bool>(
        valueListenable: Settings.customLayoutEnabled,
        builder: (context, enabled, _) => ListView(
          children: [
            SettingAnchor(
              Setting.customLayout,
              child: PrefsSwitchTile(
                title: Setting.customLayout.titleOf(context.l10n),
                pref: Settings.customLayoutEnabled,
              ),
            ),
            const Divider(),
            SettingAnchor(
              Setting.tighterComposer,
              child: PrefsSwitchTile(
                enabled: enabled,
                title: Setting.tighterComposer.titleOf(context.l10n),
                subtitle: context.l10n.tighterComposerHint,
                pref: Settings.overrideTightComposer,
              ),
            ),
            SettingAnchor(
              Setting.horizontalSheetActions,
              child: PrefsSwitchTile(
                enabled: enabled,
                title: Setting.horizontalSheetActions.titleOf(context.l10n),
                subtitle: context.l10n.horizontalSheetActionsHint,
                pref: Settings.overrideSheetActionRow,
              ),
            ),
            SettingAnchor(
              Setting.compactDensity,
              child: PrefsSwitchTile(
                enabled: enabled,
                title: Setting.compactDensity.titleOf(context.l10n),
                subtitle: context.l10n.compactDensityHint,
                pref: Settings.overrideCompactDensity,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
