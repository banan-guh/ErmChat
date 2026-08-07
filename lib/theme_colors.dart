import 'package:flutter/material.dart';

/// Accent presets that seed the app color scheme. Kept in their own file so
/// both `main.dart` (theme building) and the customization screen can share
/// the list without an import cycle.
const Map<String, Color> kAccentPresets = {
  'blue': Colors.blue,
  'red': Colors.red,
  'green': Colors.green,
  'deepPurple': Colors.deepPurple,
  'indigo': Colors.indigo,
  'cyan': Colors.cyan,
  'teal': Colors.teal,
  'orange': Colors.orange,
  'pink': Colors.pink,
  'brown': Colors.brown,
};

/// The default accent key shown when a stored value is missing.
const String kDefaultAccent = 'blue';
