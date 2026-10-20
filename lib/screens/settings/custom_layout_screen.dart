import 'package:flutter/material.dart';
import '../../l10n/l10n.dart';
import '../../util/prefs.dart';
import 'prefs_tiles.dart';
import 'settings_page.dart';
import 'settings_search.dart';
import '../../util/settings.dart';

/// Custom layout overrides. The master switch turns the override layer on;
/// each behavior switch then forces that behavior in both compact and full.
/// With the master off the switches grey out and the layout follows the
/// compact/full default.
class CustomLayoutScreen extends StatefulWidget {
  const CustomLayoutScreen({super.key});

  @override
  State<CustomLayoutScreen> createState() => _CustomLayoutScreenState();
}

class _CustomLayoutScreenState extends State<CustomLayoutScreen> {
  bool _enabled = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await Prefs.load();
    if (!mounted) return;
    setState(() => _enabled = prefs.customLayoutEnabled);
  }

  @override
  Widget build(BuildContext context) {
    return SettingsPage(
      title: Text(context.l10n.layoutCustom),
      body: ListView(
        children: [
          SettingAnchor(
            Setting.customLayout,
            child: PrefsSwitchTile(
              title: Setting.customLayout.titleOf(context.l10n),
              pref: Settings.customLayoutEnabled,
              onChanged: (v) => setState(() => _enabled = v),
            ),
          ),
          const Divider(),
          SettingAnchor(
            Setting.tighterComposer,
            child: PrefsSwitchTile(
              enabled: _enabled,
              title: Setting.tighterComposer.titleOf(context.l10n),
              subtitle: context.l10n.tighterComposerHint,
              pref: Settings.overrideTightComposer,
            ),
          ),
          SettingAnchor(
            Setting.horizontalSheetActions,
            child: PrefsSwitchTile(
              enabled: _enabled,
              title: Setting.horizontalSheetActions.titleOf(context.l10n),
              subtitle: context.l10n.horizontalSheetActionsHint,
              pref: Settings.overrideSheetActionRow,
            ),
          ),
          SettingAnchor(
            Setting.compactDensity,
            child: PrefsSwitchTile(
              enabled: _enabled,
              title: Setting.compactDensity.titleOf(context.l10n),
              subtitle: context.l10n.compactDensityHint,
              pref: Settings.overrideCompactDensity,
            ),
          ),
        ],
      ),
    );
  }
}
