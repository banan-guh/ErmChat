import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../theme_colors.dart';

class CustomizationScreen extends StatefulWidget {
  final ValueChanged<ThemeMode> onThemeChanged;
  final ValueChanged<bool>? onKeepScreenOnChanged;
  final ValueChanged<bool>? onTrueDarkChanged;
  final ValueChanged<String>? onAccentColorChanged;
  final ValueChanged<double>? onChatFontScaleChanged;
  final ValueChanged<bool>? onAnimateGifsChanged;
  final ValueChanged<bool>? onCheckeredMessagesChanged;
  final ValueChanged<bool>? onLineSeparatorChanged;

  const CustomizationScreen({
    super.key,
    required this.onThemeChanged,
    this.onKeepScreenOnChanged,
    this.onTrueDarkChanged,
    this.onAccentColorChanged,
    this.onChatFontScaleChanged,
    this.onAnimateGifsChanged,
    this.onCheckeredMessagesChanged,
    this.onLineSeparatorChanged,
  });

  @override
  State<CustomizationScreen> createState() => _CustomizationScreenState();
}

class _CustomizationScreenState extends State<CustomizationScreen> {
  bool _keepScreenOn = true;
  bool _trueDark = false;
  String _accentKey = kDefaultAccent;
  double _chatFontSize = 14.0;
  bool _animateGifs = true;
  bool _checkeredMessages = false;
  bool _lineSeparator = false;

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
        _accentKey = prefs.getString('accent_color') ?? kDefaultAccent;
        _chatFontSize = prefs.getDouble('chat_font_size') ?? 14.0;
        _animateGifs = prefs.getBool('animate_gifs') ?? true;
        _checkeredMessages = prefs.getBool('checkered_messages') ?? false;
        _lineSeparator = prefs.getBool('line_separator') ?? false;
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

  void _setCheckeredMessages(bool value) {
    setState(() => _checkeredMessages = value);
    SharedPreferences.getInstance().then((prefs) {
      prefs.setBool('checkered_messages', value);
    });
    widget.onCheckeredMessagesChanged?.call(value);
  }

  void _setLineSeparator(bool value) {
    setState(() => _lineSeparator = value);
    SharedPreferences.getInstance().then((prefs) {
      prefs.setBool('line_separator', value);
    });
    widget.onLineSeparatorChanged?.call(value);
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
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                child: Text(
                  'Chat font size: ${_chatFontSize.round()}',
                ),
              ),
              Slider(
                value: _chatFontSize,
                min: 8,
                max: 24,
                divisions: 16,
                label: '${_chatFontSize.round()}',
                onChanged: (value) {
                  setState(() => _chatFontSize = value);
                  widget.onChatFontScaleChanged?.call(value);
                },
                onChangeEnd: (value) {
                  SharedPreferences.getInstance().then(
                    (prefs) => prefs.setDouble('chat_font_size', value),
                  );
                },
              ),
            ],
          ),
          SwitchListTile(
            secondary: const Icon(Icons.gif_box),
            title: const Text('Animate gifs'),
            value: _animateGifs,
            onChanged: (value) async {
              final prefs = await SharedPreferences.getInstance();
              await prefs.setBool('animate_gifs', value);
              if (mounted) setState(() => _animateGifs = value);
              widget.onAnimateGifsChanged?.call(value);
            },
          ),
          SwitchListTile(
            title: const Text('Checkered messages'),
            subtitle: const Text(
              'Separate each line with a different background brightness',
            ),
            value: _checkeredMessages,
            onChanged: _setCheckeredMessages,
          ),
          SwitchListTile(
            title: const Text('Separate messages with lines'),
            value: _lineSeparator,
            onChanged: _setLineSeparator,
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
