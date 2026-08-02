import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class CustomizationScreen extends StatefulWidget {
  final ValueChanged<ThemeMode> onThemeChanged;
  final ValueChanged<bool>? onKeepScreenOnChanged;

  const CustomizationScreen({
    super.key,
    required this.onThemeChanged,
    this.onKeepScreenOnChanged,
  });

  @override
  State<CustomizationScreen> createState() => _CustomizationScreenState();
}

class _CustomizationScreenState extends State<CustomizationScreen> {
  bool _keepScreenOn = true;

  @override
  void initState() {
    super.initState();
    _loadPrefs();
  }

  Future<void> _loadPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() => _keepScreenOn = prefs.getBool('keep_screen_on') ?? true);
    }
  }

  void _setKeepScreenOn(bool value) {
    setState(() => _keepScreenOn = value);
    SharedPreferences.getInstance().then((prefs) {
      prefs.setBool('keep_screen_on', value);
    });
    widget.onKeepScreenOnChanged?.call(value);
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
            title: const Text('Keep screen on'),
            value: _keepScreenOn,
            onChanged: _setKeepScreenOn,
          ),
        ],
      ),
    );
  }
}
