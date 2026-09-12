import 'package:flutter/material.dart';
import '../../theme_colors.dart';
import '../../util/prefs.dart';
import 'settings_page.dart';

class CustomizationScreen extends StatefulWidget {
  final ValueChanged<ThemeMode> onThemeChanged;
  final ValueChanged<bool>? onKeepScreenOnChanged;
  final ValueChanged<bool>? onTrueDarkChanged;
  final ValueChanged<String>? onAccentColorChanged;
  final ValueChanged<double>? onChatFontScaleChanged;
  final ValueChanged<double>? onHighlightOpacityChanged;
  final ValueChanged<bool>? onCheckeredMessagesChanged;
  final ValueChanged<bool>? onLineSeparatorChanged;
  final ValueChanged<bool>? onFastSnapChanged;

  const CustomizationScreen({
    super.key,
    required this.onThemeChanged,
    this.onKeepScreenOnChanged,
    this.onTrueDarkChanged,
    this.onAccentColorChanged,
    this.onChatFontScaleChanged,
    this.onHighlightOpacityChanged,
    this.onCheckeredMessagesChanged,
    this.onLineSeparatorChanged,
    this.onFastSnapChanged,
  });

  @override
  State<CustomizationScreen> createState() => _CustomizationScreenState();
}

class _CustomizationScreenState extends State<CustomizationScreen> {
  ThemeMode _themeMode = ThemeMode.system;
  bool _keepScreenOn = true;
  bool _trueDark = false;
  String _accentKey = kDefaultAccent;
  double _chatFontSize = 14.0;
  double _highlightOpacity = 0.6;
  bool _checkeredMessages = false;
  bool _lineSeparator = false;
  bool _fastSnap = true;

  @override
  void initState() {
    super.initState();
    _loadPrefs();
  }

  Future<void> _loadPrefs() async {
    final prefs = await Prefs.load();
    if (mounted) {
      setState(() {
        _themeMode = prefs.themeMode;
        _keepScreenOn = prefs.keepScreenOn;
        _trueDark = prefs.trueDark;
        _accentKey = prefs.accentColor;
        _chatFontSize = prefs.chatFontSize;
        _highlightOpacity = prefs.highlightOpacity;
        _checkeredMessages = prefs.checkeredMessages;
        _lineSeparator = prefs.lineSeparator;
        _fastSnap = prefs.fastChannelSnap;
      });
    }
  }

  Future<void> _pickTheme(BuildContext context) async {
    final mode = await showModalBottomSheet<ThemeMode>(
      context: context,
      showDragHandle: false,
      useSafeArea: true,
      builder: (_) => SafeArea(
        top: false,
        bottom: true,
        child: _ThemePickerSheet(current: _themeMode),
      ),
    );
    if (mode == null || !mounted || mode == _themeMode) return;
    setState(() => _themeMode = mode);
    Prefs.load().then((prefs) => prefs.setThemeMode(mode));
    widget.onThemeChanged(mode);
  }

  void _setKeepScreenOn(bool value) {
    setState(() => _keepScreenOn = value);
    Prefs.load().then((prefs) => prefs.setKeepScreenOn(value));
    widget.onKeepScreenOnChanged?.call(value);
  }

  void _setTrueDark(bool value) {
    setState(() => _trueDark = value);
    Prefs.load().then((prefs) => prefs.setTrueDark(value));
    widget.onTrueDarkChanged?.call(value);
  }

  void _setAccentColor(String key) {
    setState(() => _accentKey = key);
    Prefs.load().then((prefs) => prefs.setAccentColor(key));
    widget.onAccentColorChanged?.call(key);
  }

  void _setCheckeredMessages(bool value) {
    setState(() => _checkeredMessages = value);
    Prefs.load().then((prefs) => prefs.setCheckeredMessages(value));
    widget.onCheckeredMessagesChanged?.call(value);
  }

  void _setLineSeparator(bool value) {
    setState(() => _lineSeparator = value);
    Prefs.load().then((prefs) => prefs.setLineSeparator(value));
    widget.onLineSeparatorChanged?.call(value);
  }

  void _setFastSnap(bool value) {
    setState(() => _fastSnap = value);
    Prefs.load().then((prefs) => prefs.setFastChannelSnap(value));
    widget.onFastSnapChanged?.call(value);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return SettingsPage(
      title: const Text('Customization'),
      body: ListView(
        children: [
          ListTile(
            title: const Text('Theme'),
            subtitle: Text(switch (_themeMode) {
              ThemeMode.system => 'System',
              ThemeMode.light => 'Light',
              ThemeMode.dark => 'Dark',
            }),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _pickTheme(context),
          ),
          SwitchListTile(
            title: const Text('True dark mode'),
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
                child: Text('Chat font size: ${_chatFontSize.round()}'),
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
                  Prefs.load().then((prefs) => prefs.setChatFontSize(value));
                },
              ),
            ],
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
                  'Highlight opacity: ${(_highlightOpacity * 100).round()}%',
                ),
              ),
              Slider(
                value: _highlightOpacity,
                min: 0,
                max: 1,
                divisions: 5,
                label: '${(_highlightOpacity * 100).round()}%',
                onChanged: (value) {
                  setState(() => _highlightOpacity = value);
                  widget.onHighlightOpacityChanged?.call(value);
                },
                onChangeEnd: (value) {
                  Prefs.load().then(
                    (prefs) => prefs.setHighlightOpacity(value),
                  );
                },
              ),
            ],
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
            title: const Text('Fast channel swipe'),
            subtitle: const Text('Snap to the next channel more quickly'),
            value: _fastSnap,
            onChanged: _setFastSnap,
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

class _ThemePickerSheet extends StatelessWidget {
  final ThemeMode current;

  const _ThemePickerSheet({required this.current});

  static const _options = <ThemeMode, (IconData, String)>{
    ThemeMode.system: (Icons.brightness_auto, 'System'),
    ThemeMode.light: (Icons.light_mode_outlined, 'Light'),
    ThemeMode.dark: (Icons.dark_mode_outlined, 'Dark'),
  };

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(
              width: 32,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.grey[400],
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 8),
          for (final entry in _options.entries)
            ListTile(
              leading: Icon(entry.value.$1),
              title: Text(entry.value.$2),
              trailing: entry.key == current
                  ? Icon(
                      Icons.check,
                      color: Theme.of(context).colorScheme.primary,
                    )
                  : null,
              onTap: () => Navigator.pop(context, entry.key),
            ),
        ],
      ),
    );
  }
}
