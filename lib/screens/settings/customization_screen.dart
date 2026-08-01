import 'package:flutter/material.dart';

class CustomizationScreen extends StatelessWidget {
  final ValueChanged<ThemeMode> onThemeChanged;
  final bool keepScreenOn;
  final ValueChanged<bool>? onKeepScreenOnChanged;

  const CustomizationScreen({
    super.key,
    required this.onThemeChanged,
    this.keepScreenOn = true,
    this.onKeepScreenOnChanged,
  });

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
              onThemeChanged(dark ? ThemeMode.dark : ThemeMode.light);
            },
          ),
          SwitchListTile(
            title: const Text('Keep screen on'),
            value: keepScreenOn,
            onChanged: onKeepScreenOnChanged,
          ),
        ],
      ),
    );
  }
}
