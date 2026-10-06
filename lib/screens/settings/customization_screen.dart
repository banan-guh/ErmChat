import 'package:flutter/material.dart';
import '../../l10n/l10n.dart';
import '../../theme_colors.dart';
import '../../util/layout_density.dart';
import '../../util/prefs.dart';
import '../../util/prefs_store.dart';
import '../../util/timestamp_formatter.dart';
import '../../widgets/dialogs.dart';
import 'custom_layout_screen.dart';
import 'prefs_tiles.dart';
import 'settings_page.dart';
import 'settings_search.dart';

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

  /// Saved language tag; empty follows the system.
  String get _locale => _prefs?.locale ?? '';

  Future<void> _pickLanguage(BuildContext context) async {
    final tag = await showModalBottomSheet<String>(
      context: context,
      useSafeArea: true,
      builder: (sheetContext) => SafeArea(
        top: false,
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final tag in ['', ..._localeTags])
              ListTile(
                title: Text(
                  tag.isEmpty
                      ? sheetContext.l10n.languageSystem
                      : _languageName(tag),
                ),
                trailing: tag == _locale
                    ? Icon(
                        Icons.check,
                        color: Theme.of(sheetContext).colorScheme.primary,
                      )
                    : null,
                onTap: () => Navigator.pop(sheetContext, tag),
              ),
          ],
        ),
      ),
    );
    if (tag == null || !mounted || tag == _locale) return;
    final prefs = _prefs ?? await Prefs.load();
    await prefs.setLocale(tag.isEmpty ? null : tag);
    PrefsStore.instance.notifyChanged();
    if (mounted) setState(() {});
  }

  /// Every shipped translation, as `pt_BR` style tags.
  static final _localeTags = [
    for (final l in AppLocalizations.supportedLocales)
      [l.languageCode, ?l.countryCode].join('_'),
  ];

  /// Each language in its own words, so a reader finds theirs.
  static String _languageName(String tag) => switch (tag) {
    'en' => 'English',
    'es' => 'Español',
    'de' => 'Deutsch',
    'fr' => 'Français',
    'pt' || 'pt_BR' => 'Português',
    'ja' => '日本語',
    _ => tag,
  };

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
          customEnabled: _customLayoutEnabled,
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

  String get _timestampFormat =>
      _prefs?.timestampFormat ?? kDefaultTimestampFormat;

  Future<void> _pickTimestampFormat() async {
    final now = DateTime.now();
    final selected = await showChoiceDialog<String>(
      context,
      title: context.l10n.timestampFormatTitle,
      value: _timestampFormat,
      height: 420,
      options: [
        for (final fmt in kTimestampFormats)
          (fmt, fmt, context.l10n.timestampExample(formatTimestamp(now, fmt))),
      ],
    );
    if (selected == null || selected == _timestampFormat) return;
    final prefs = _prefs ?? await Prefs.load();
    await prefs.setTimestampFormat(selected);
    PrefsStore.instance.notifyChanged();
    if (!mounted) return;
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return SettingsPage(
      title: Text(context.l10n.pageAppearance),
      body: ListView(
        children: [
          SettingAnchor(
            Setting.language,
            child: ListTile(
              // Findable by anyone stuck in a language they cannot read.
              leading: const Icon(Icons.translate),
              title: Text(context.l10n.settingLanguage),
              subtitle: Text(
                _locale.isEmpty
                    ? context.l10n.languageSystem
                    : _languageName(_locale),
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _pickLanguage(context),
            ),
          ),
          SettingsSectionHeader(context.l10n.sectionTheme),
          SettingAnchor(
            Setting.theme,
            child: ListTile(
              title: Text(Setting.theme.titleOf(context.l10n)),
              subtitle: Text(switch (_themeMode) {
                ThemeMode.system => context.l10n.themeSystem,
                ThemeMode.light => context.l10n.themeLight,
                ThemeMode.dark => context.l10n.themeDark,
              }),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _pickTheme(context),
            ),
          ),
          SettingAnchor(
            Setting.accentColor,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                  child: Text(
                    Setting.accentColor.titleOf(context.l10n),
                    style: const TextStyle(fontWeight: FontWeight.w600),
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
              ],
            ),
          ),
          SettingAnchor(
            Setting.trueDark,
            child: PrefsSwitchTile(
              title: Setting.trueDark.titleOf(context.l10n),
              defaultValue: false,
              enabled: isDark,
              read: (p) => p.trueDark,
              write: (p, v) => p.setTrueDark(v),
            ),
          ),
          SettingsSectionHeader(context.l10n.sectionLayout),
          SettingAnchor(
            Setting.layout,
            child: ListTile(
              title: Text(Setting.layout.titleOf(context.l10n)),
              subtitle: Text(
                _customLayoutEnabled
                    ? context.l10n.layoutCustom
                    : switch (_layoutDensity) {
                        LayoutDensity.auto =>
                          isCompactLayout(context)
                              ? context.l10n.layoutAutoCompact
                              : context.l10n.layoutAutoFull,
                        LayoutDensity.compact => context.l10n.layoutCompact,
                        LayoutDensity.full => context.l10n.layoutFull,
                      },
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _pickLayoutDensity(context),
            ),
          ),
          SettingAnchor(
            Setting.liquidGlass,
            child: PrefsSwitchTile(
              title: Setting.liquidGlass.titleOf(context.l10n),
              subtitle: context.l10n.experimental,
              read: (p) => p.liquidGlass,
              write: (p, v) => p.setLiquidGlass(v),
            ),
          ),
          SettingsSectionHeader(context.l10n.sectionChatDisplay),
          SettingAnchor(
            Setting.chatFontSize,
            child: PrefsSliderTile(
              label: (v) =>
                  '${Setting.chatFontSize.titleOf(context.l10n)}: ${v.round()}',
              min: 8,
              max: 24,
              divisions: 16,
              defaultValue: 14,
              read: (p) => p.chatFontSize,
              write: (p, v) => p.setChatFontSize(v),
            ),
          ),
          SettingAnchor(
            Setting.showTimestamps,
            child: PrefsSwitchTile(
              secondary: const Icon(Icons.schedule),
              title: Setting.showTimestamps.titleOf(context.l10n),
              defaultValue: true,
              read: (p) => p.showTimestamps,
              write: (p, v) => p.setShowTimestamps(v),
            ),
          ),
          SettingAnchor(
            Setting.timestampFormat,
            child: SettingsNavTile(
              icon: Icons.access_time,
              title: Setting.timestampFormat.titleOf(context.l10n),
              subtitle: _timestampFormat,
              onTap: _pickTimestampFormat,
            ),
          ),
          SettingAnchor(
            Setting.checkered,
            child: PrefsSwitchTile(
              title: Setting.checkered.titleOf(context.l10n),
              subtitle: context.l10n.checkeredHint,
              defaultValue: false,
              read: (p) => p.checkeredMessages,
              write: (p, v) => p.setCheckeredMessages(v),
            ),
          ),
          SettingAnchor(
            Setting.lineSeparator,
            child: PrefsSwitchTile(
              title: Setting.lineSeparator.titleOf(context.l10n),
              defaultValue: false,
              read: (p) => p.lineSeparator,
              write: (p, v) => p.setLineSeparator(v),
            ),
          ),
          SettingsSectionHeader(context.l10n.sectionDisplay),
          SettingAnchor(
            Setting.keepScreenOn,
            child: PrefsSwitchTile(
              title: Setting.keepScreenOn.titleOf(context.l10n),
              defaultValue: true,
              read: (p) => p.keepScreenOn,
              write: (p, v) => p.setKeepScreenOn(v),
            ),
          ),
          SettingsSectionHeader(context.l10n.sectionNavigation),
          SettingAnchor(
            Setting.fastChannelSwipe,
            child: PrefsSwitchTile(
              title: Setting.fastChannelSwipe.titleOf(context.l10n),
              defaultValue: true,
              read: (p) => p.fastChannelSnap,
              write: (p, v) => p.setFastChannelSnap(v),
            ),
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

  static Map<ThemeMode, (IconData, String)> _options(AppLocalizations l) => {
    ThemeMode.system: (Icons.brightness_auto, l.themeSystem),
    ThemeMode.light: (Icons.light_mode_outlined, l.themeLight),
    ThemeMode.dark: (Icons.dark_mode_outlined, l.themeDark),
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
          for (final entry in _options(context.l10n).entries)
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

/// Layout picker sheet. Mirrors the theme picker, plus a Custom row that
/// opens the custom layout screen. While custom is on the density rows grey
/// out, and Custom stays open so it can be turned off.
class _LayoutPickerSheet extends StatelessWidget {
  final LayoutDensity current;
  final bool customEnabled;
  final VoidCallback onCustom;

  const _LayoutPickerSheet({
    required this.current,
    required this.customEnabled,
    required this.onCustom,
  });

  static Map<LayoutDensity, (IconData, String, String)> _options(
    AppLocalizations l,
  ) => {
    LayoutDensity.auto: (Icons.brightness_auto, l.layoutAuto, l.layoutAutoHint),
    LayoutDensity.compact: (
      Icons.smartphone,
      l.layoutCompact,
      l.layoutCompactHint,
    ),
    LayoutDensity.full: (Icons.tablet, l.layoutFull, l.layoutFullHint),
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
          for (final entry in _options(context.l10n).entries)
            ListTile(
              enabled: !customEnabled,
              leading: Icon(entry.value.$1),
              title: Text(entry.value.$2),
              subtitle: Text(entry.value.$3),
              trailing: !customEnabled && entry.key == current
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
            title: Text(context.l10n.layoutCustom),
            trailing: customEnabled
                ? Icon(
                    Icons.check,
                    color: Theme.of(context).colorScheme.primary,
                  )
                : const Icon(Icons.chevron_right),
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
