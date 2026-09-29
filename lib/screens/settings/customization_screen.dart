import 'package:flutter/material.dart';
import '../../theme_colors.dart';
import '../../util/layout_density.dart';
import '../../util/prefs.dart';
import '../../util/prefs_store.dart';
import 'custom_layout_screen.dart';
import 'prefs_tiles.dart';
import 'settings_page.dart';

class CustomizationScreen extends StatefulWidget {
  const CustomizationScreen({super.key});

  @override
  State<CustomizationScreen> createState() => _CustomizationScreenState();
}

class _CustomizationScreenState extends State<CustomizationScreen> {
  Prefs? _prefs;

  @override
  void initState() {
    super.initState();
    _loadPrefs();
    PrefsStore.instance.addListener(_loadPrefs);
  }

  @override
  void dispose() {
    PrefsStore.instance.removeListener(_loadPrefs);
    super.dispose();
  }

  Future<void> _loadPrefs() async {
    final prefs = await Prefs.load();
    if (mounted) setState(() => _prefs = prefs);
  }

  ThemeMode get _themeMode => _prefs?.themeMode ?? ThemeMode.system;

  String get _accentKey => _prefs?.accentColor ?? kDefaultAccent;

  bool get _customLayoutEnabled => _prefs?.customLayoutEnabled ?? false;

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
    final prefs = _prefs ?? await Prefs.load();
    await prefs.setThemeMode(mode);
    PrefsStore.instance.notifyChanged();
    if (!mounted) return;
    setState(() {});
  }

  LayoutDensity get _layoutDensity =>
      _prefs?.layoutDensity ?? LayoutDensity.auto;

  Future<void> _pickLayoutDensity(BuildContext context) async {
    final picked = await showModalBottomSheet<LayoutDensity>(
      context: context,
      showDragHandle: false,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => SafeArea(
        top: false,
        bottom: true,
        child: _LayoutPickerSheet(
          current: _layoutDensity,
          onCustom: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const CustomLayoutScreen()),
          ),
        ),
      ),
    );
    if (picked == null || !mounted || picked == _layoutDensity) return;
    final prefs = _prefs ?? await Prefs.load();
    await prefs.setLayoutDensity(picked);
    PrefsStore.instance.notifyChanged();
    if (!mounted) return;
    setState(() {});
  }

  Future<void> _setAccentColor(String key) async {
    if (key == _accentKey) return;
    final prefs = _prefs ?? await Prefs.load();
    await prefs.setAccentColor(key);
    PrefsStore.instance.notifyChanged();
    if (!mounted) return;
    setState(() {});
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
          ListTile(
            enabled: !_customLayoutEnabled,
            title: const Text('Layout'),
            subtitle: Text(
              _customLayoutEnabled
                  ? 'Overridden by custom layout'
                  : switch (_layoutDensity) {
                      LayoutDensity.auto =>
                        'Auto (${isCompactLayout(context) ? 'compact' : 'full'})',
                      LayoutDensity.compact => 'Compact',
                      LayoutDensity.full => 'Full',
                    },
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: _customLayoutEnabled
                ? null
                : () => _pickLayoutDensity(context),
          ),
          PrefsSwitchTile(
            title: 'True dark mode',
            defaultValue: false,
            enabled: isDark,
            read: (p) => p.trueDark,
            write: (p, v) => p.setTrueDark(v),
          ),
          PrefsSwitchTile(
            title: 'Liquid glass (experimental)',
            subtitle: 'Floating glass header and composer with chat underneath',
            read: (p) => p.liquidGlass,
            write: (p, v) => p.setLiquidGlass(v),
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
          PrefsSliderTile(
            label: (v) => 'Chat font size: ${v.round()}',
            min: 8,
            max: 24,
            divisions: 16,
            defaultValue: 14,
            read: (p) => p.chatFontSize,
            write: (p, v) => p.setChatFontSize(v),
          ),
          PrefsSliderTile(
            label: (v) => 'Highlight opacity: ${(v * 100).round()}%',
            min: 0,
            max: 1,
            divisions: 5,
            defaultValue: 0.6,
            read: (p) => p.highlightOpacity,
            write: (p, v) => p.setHighlightOpacity(v),
          ),
          PrefsSwitchTile(
            title: 'Checkered messages',
            subtitle:
                'Separate each line with a different background brightness',
            defaultValue: false,
            read: (p) => p.checkeredMessages,
            write: (p, v) => p.setCheckeredMessages(v),
          ),
          PrefsSwitchTile(
            title: 'Separate messages with lines',
            defaultValue: false,
            read: (p) => p.lineSeparator,
            write: (p, v) => p.setLineSeparator(v),
          ),
          PrefsSwitchTile(
            title: 'Fast channel swipe',
            subtitle: 'Snap to the next channel more quickly',
            defaultValue: true,
            read: (p) => p.fastChannelSnap,
            write: (p, v) => p.setFastChannelSnap(v),
          ),
          PrefsSwitchTile(
            title: 'Keep screen on',
            defaultValue: true,
            read: (p) => p.keepScreenOn,
            write: (p, v) => p.setKeepScreenOn(v),
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

/// Layout picker sheet. Mirrors the theme picker, plus an Other row that
/// opens the custom layout screen.
class _LayoutPickerSheet extends StatelessWidget {
  final LayoutDensity current;
  final VoidCallback onCustom;

  const _LayoutPickerSheet({required this.current, required this.onCustom});

  static const _options = <LayoutDensity, (IconData, String, String)>{
    LayoutDensity.auto: (
      Icons.brightness_auto,
      'Auto',
      'Compact on small phones',
    ),
    LayoutDensity.compact: (
      Icons.smartphone,
      'Compact',
      'Merged top row, tighter spacing',
    ),
    LayoutDensity.full: (Icons.tablet, 'Full', 'Separate top bar and tabs'),
  };

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
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
              subtitle: Text(entry.value.$3),
              trailing: entry.key == current
                  ? Icon(
                      Icons.check,
                      color: Theme.of(context).colorScheme.primary,
                    )
                  : null,
              onTap: () => Navigator.pop(context, entry.key),
            ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.tune),
            title: const Text('Custom'),
            subtitle: const Text('Override layout behaviors'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              Navigator.pop(context);
              onCustom();
            },
          ),
        ],
      ),
    );
  }
}
