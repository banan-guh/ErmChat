import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../theme_colors.dart';

class CustomizationScreen extends StatefulWidget {
  final ValueChanged<ThemeMode> onThemeChanged;
  final ValueChanged<bool>? onKeepScreenOnChanged;
  final ValueChanged<bool>? onTrueDarkChanged;
  final ValueChanged<String>? onAccentColorChanged;
  final ValueChanged<bool>? onTintedTabBarChanged;

  const CustomizationScreen({
    super.key,
    required this.onThemeChanged,
    this.onKeepScreenOnChanged,
    this.onTrueDarkChanged,
    this.onAccentColorChanged,
    this.onTintedTabBarChanged,
  });

  @override
  State<CustomizationScreen> createState() => _CustomizationScreenState();
}

class _CustomizationScreenState extends State<CustomizationScreen> {
  bool _keepScreenOn = true;
  bool _trueDark = false;
  bool _tintedTabBar = false;
  String _accentKey = kDefaultAccent;

  @override
  void initState() {
    super.initState();
    _loadPrefs();
  }

  Future<void> _loadPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() {
        _keepScreenOn = prefs.getBool('keep_screen_on') ?? true;
        _trueDark = prefs.getBool('true_dark') ?? false;
        _tintedTabBar = prefs.getBool('tinted_tab_bar') ?? false;
        _accentKey = prefs.getString('accent_color') ?? kDefaultAccent;
      });
    }
  }

  void _setKeepScreenOn(bool value) {
    setState(() => _keepScreenOn = value);
    SharedPreferences.getInstance().then((prefs) {
      prefs.setBool('keep_screen_on', value);
    });
    widget.onKeepScreenOnChanged?.call(value);
  }

  void _setTrueDark(bool value) {
    setState(() => _trueDark = value);
    SharedPreferences.getInstance().then((prefs) {
      prefs.setBool('true_dark', value);
    });
    widget.onTrueDarkChanged?.call(value);
  }

  void _setAccentColor(String key) {
    setState(() => _accentKey = key);
    SharedPreferences.getInstance().then((prefs) {
      prefs.setString('accent_color', key);
    });
    widget.onAccentColorChanged?.call(key);
  }

  void _setTintedTabBar(bool value) {
    setState(() => _tintedTabBar = value);
    SharedPreferences.getInstance().then((prefs) {
      prefs.setBool('tinted_tab_bar', value);
    });
    widget.onTintedTabBarChanged?.call(value);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      appBar: AppBar(title: const Text('Customization')),
      body: ListView(
        children: [
          SwitchListTile(
            title: const Text('Dark mode'),
            value: isDark,
            onChanged: (dark) {
              widget.onThemeChanged(dark ? ThemeMode.dark : ThemeMode.light);
            },
          ),
          SwitchListTile(
            title: const Text('True dark mode'),
            subtitle: const Text('Pure black chat background'),
            value: _trueDark,
            onChanged: isDark ? _setTrueDark : null,
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text(
              'Accent color',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                for (final entry in kAccentPresets.entries)
                  _AccentSwatch(
                    key: ValueKey('accent_${entry.key}'),
                    color: entry.value,
                    selected: entry.key == _accentKey,
                    onTap: () => _setAccentColor(entry.key),
                  ),
              ],
            ),
          ),
          SwitchListTile(
            title: const Text('Tinted tab bar'),
            subtitle: const Text('Color the tab bar with the accent'),
            value: _tintedTabBar,
            onChanged: _setTintedTabBar,
          ),
          SwitchListTile(
            title: const Text('Keep screen on'),
            value: _keepScreenOn,
            onChanged: _setKeepScreenOn,
          ),
        ],
      ),
    );
  }
}

class _AccentSwatch extends StatelessWidget {
  final Color color;
  final bool selected;
  final VoidCallback onTap;

  const _AccentSwatch({
    super.key,
    required this.color,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final onColor =
        ThemeData.estimateBrightnessForColor(color) == Brightness.dark
        ? Colors.white
        : Colors.black;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(24),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: selected
              ? Border.all(color: onColor, width: 3)
              : Border.all(color: Theme.of(context).dividerColor, width: 1),
        ),
        child: selected ? Icon(Icons.check, size: 20, color: onColor) : null,
      ),
    );
  }
}
