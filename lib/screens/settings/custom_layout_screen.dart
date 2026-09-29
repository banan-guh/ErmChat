import 'package:flutter/material.dart';
import '../../util/prefs.dart';
import 'prefs_tiles.dart';
import 'settings_page.dart';

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
          PrefsSwitchTile(
            title: 'Enable custom layout',
            read: (p) => p.customLayoutEnabled,
            write: (p, v) => p.setCustomLayoutEnabled(v),
            onChanged: (v) => setState(() => _enabled = v),
          ),
          const Divider(),
          PrefsSwitchTile(
            enabled: _enabled,
            title: 'Merge app bar into tabs',
            subtitle: 'Join button becomes the last tab, actions pin right',
            read: (p) => p.overrideMergeAppBar,
            write: (p, v) => p.setOverrideMergeAppBar(v),
          ),
          PrefsSwitchTile(
            enabled: _enabled,
            title: 'Fold panel titles into tabs',
            subtitle: 'Drops the panel title row so the tabs name it',
            read: (p) => p.overrideFoldPanelHeaders,
            write: (p, v) => p.setOverrideFoldPanelHeaders(v),
          ),
          PrefsSwitchTile(
            enabled: _enabled,
            title: 'Tighter composer',
            subtitle: 'Shorter input field with full-size buttons',
            read: (p) => p.overrideTightComposer,
            write: (p, v) => p.setOverrideTightComposer(v),
          ),
          PrefsSwitchTile(
            enabled: _enabled,
            title: 'Horizontal sheet actions',
            subtitle: 'Icon-over-label rows in the emote and user sheets',
            read: (p) => p.overrideSheetActionRow,
            write: (p, v) => p.setOverrideSheetActionRow(v),
          ),
          PrefsSwitchTile(
            enabled: _enabled,
            title: 'Compact density',
            subtitle: 'Smaller buttons, list tiles and menus',
            read: (p) => p.overrideCompactDensity,
            write: (p, v) => p.setOverrideCompactDensity(v),
          ),
          PrefsSwitchTile(
            enabled: _enabled,
            title: 'Tighter chrome margins',
            subtitle: 'Closer app bar action padding',
            read: (p) => p.overrideTightChromeMargins,
            write: (p, v) => p.setOverrideTightChromeMargins(v),
          ),
        ],
      ),
    );
  }
}
