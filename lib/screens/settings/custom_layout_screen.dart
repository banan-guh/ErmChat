import 'package:flutter/material.dart';
import '../../l10n/l10n.dart';
import '../../util/prefs.dart';
import 'prefs_tiles.dart';
import 'settings_page.dart';
import 'settings_search.dart';

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
              read: (p) => p.customLayoutEnabled,
              write: (p, v) => p.setCustomLayoutEnabled(v),
              onChanged: (v) => setState(() => _enabled = v),
            ),
          ),
          const Divider(),
          SettingAnchor(
            Setting.mergeAppBar,
            child: PrefsSwitchTile(
              enabled: _enabled,
              title: Setting.mergeAppBar.titleOf(context.l10n),
              subtitle: context.l10n.mergeAppBarHint,
              read: (p) => p.overrideMergeAppBar,
              write: (p, v) => p.setOverrideMergeAppBar(v),
            ),
          ),
          SettingAnchor(
            Setting.foldPanelTitles,
            child: PrefsSwitchTile(
              enabled: _enabled,
              title: Setting.foldPanelTitles.titleOf(context.l10n),
              subtitle: context.l10n.foldPanelTitlesHint,
              read: (p) => p.overrideFoldPanelHeaders,
              write: (p, v) => p.setOverrideFoldPanelHeaders(v),
            ),
          ),
          SettingAnchor(
            Setting.tighterComposer,
            child: PrefsSwitchTile(
              enabled: _enabled,
              title: Setting.tighterComposer.titleOf(context.l10n),
              subtitle: context.l10n.tighterComposerHint,
              read: (p) => p.overrideTightComposer,
              write: (p, v) => p.setOverrideTightComposer(v),
            ),
          ),
          SettingAnchor(
            Setting.horizontalSheetActions,
            child: PrefsSwitchTile(
              enabled: _enabled,
              title: Setting.horizontalSheetActions.titleOf(context.l10n),
              subtitle: context.l10n.horizontalSheetActionsHint,
              read: (p) => p.overrideSheetActionRow,
              write: (p, v) => p.setOverrideSheetActionRow(v),
            ),
          ),
          SettingAnchor(
            Setting.compactDensity,
            child: PrefsSwitchTile(
              enabled: _enabled,
              title: Setting.compactDensity.titleOf(context.l10n),
              subtitle: context.l10n.compactDensityHint,
              read: (p) => p.overrideCompactDensity,
              write: (p, v) => p.setOverrideCompactDensity(v),
            ),
          ),
          SettingAnchor(
            Setting.tighterChrome,
            child: PrefsSwitchTile(
              enabled: _enabled,
              title: Setting.tighterChrome.titleOf(context.l10n),
              subtitle: context.l10n.tighterChromeHint,
              read: (p) => p.overrideTightChromeMargins,
              write: (p, v) => p.setOverrideTightChromeMargins(v),
            ),
          ),
        ],
      ),
    );
  }
}
