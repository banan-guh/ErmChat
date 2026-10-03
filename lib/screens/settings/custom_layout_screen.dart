import 'package:flutter/material.dart';
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
      title: const Text('Custom'),
      body: ListView(
        children: [
          SettingAnchor(
            Setting.customLayout,
            child: PrefsSwitchTile(
              title: Setting.customLayout.title,
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
              title: Setting.mergeAppBar.title,
              subtitle: 'Join button becomes the last tab, actions pin right',
              read: (p) => p.overrideMergeAppBar,
              write: (p, v) => p.setOverrideMergeAppBar(v),
            ),
          ),
          SettingAnchor(
            Setting.foldPanelTitles,
            child: PrefsSwitchTile(
              enabled: _enabled,
              title: Setting.foldPanelTitles.title,
              subtitle: 'Drops the panel title row so the tabs name it',
              read: (p) => p.overrideFoldPanelHeaders,
              write: (p, v) => p.setOverrideFoldPanelHeaders(v),
            ),
          ),
          SettingAnchor(
            Setting.tighterComposer,
            child: PrefsSwitchTile(
              enabled: _enabled,
              title: Setting.tighterComposer.title,
              subtitle: 'Shorter input field with full-size buttons',
              read: (p) => p.overrideTightComposer,
              write: (p, v) => p.setOverrideTightComposer(v),
            ),
          ),
          SettingAnchor(
            Setting.horizontalSheetActions,
            child: PrefsSwitchTile(
              enabled: _enabled,
              title: Setting.horizontalSheetActions.title,
              subtitle: 'Icon-over-label rows in the emote and user sheets',
              read: (p) => p.overrideSheetActionRow,
              write: (p, v) => p.setOverrideSheetActionRow(v),
            ),
          ),
          SettingAnchor(
            Setting.compactDensity,
            child: PrefsSwitchTile(
              enabled: _enabled,
              title: Setting.compactDensity.title,
              subtitle: 'Smaller buttons, list tiles and menus',
              read: (p) => p.overrideCompactDensity,
              write: (p, v) => p.setOverrideCompactDensity(v),
            ),
          ),
          SettingAnchor(
            Setting.tighterChrome,
            child: PrefsSwitchTile(
              enabled: _enabled,
              title: Setting.tighterChrome.title,
              subtitle: 'Closer app bar action padding',
              read: (p) => p.overrideTightChromeMargins,
              write: (p, v) => p.setOverrideTightChromeMargins(v),
            ),
          ),
        ],
      ),
    );
  }
}
