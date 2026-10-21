import 'package:flutter/material.dart';
import '../../l10n/l10n.dart';
import '../../theme_colors.dart';
import '../../util/chrome_theme.dart';
import '../../util/layout_density.dart';
import '../../util/prefs.dart';
import '../../util/prefs_store.dart';
import '../../util/timestamp_formatter.dart';
import '../../widgets/dialogs.dart';
import '../../widgets/glass_chrome.dart';
import 'custom_layout_screen.dart';
import 'prefs_tiles.dart';
import 'settings_page.dart';
import 'setting_info.dart';
import 'settings_search.dart';
import '../../widgets/design_tokens.dart';
import '../../util/settings.dart';

class CustomizationScreen extends StatefulWidget {
  const CustomizationScreen({super.key, this.onEditLayout});

  /// Asks the home screen to enter layout edit mode.
  final VoidCallback? onEditLayout;

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

  int get _fontWeight => _prefs?.chatFontWeight ?? 400;

  Future<void> _pickFontWeight() async {
    final l = context.l10n;
    final selected = await showChoiceDialog<int>(
      context,
      title: Setting.chatFontWeight.titleOf(l),
      value: _fontWeight,
      options: [
        (400, l.fontWeightNormal, ''),
        (500, l.fontWeightMedium, ''),
        (600, l.fontWeightSemibold, ''),
        (700, l.fontWeightBold, ''),
      ],
    );
    if (selected == null || selected == _fontWeight) return;
    final prefs = _prefs ?? await Prefs.load();
    await prefs.setChatFontWeight(selected);
    PrefsStore.instance.notifyChanged();
    if (!mounted) return;
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return SettingsPage(
      title: Text(context.l10n.pageAppearance),
      body: ListView(
        children: [
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
          const TrueDarkTile(),
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
            Setting.editLayout,
            child: ListTile(
              title: Text(Setting.editLayout.titleOf(context.l10n)),
              trailing: const Icon(Icons.chevron_right),
              onTap: () {
                widget.onEditLayout?.call();
                Navigator.of(context).popUntil((r) => r.isFirst);
              },
            ),
          ),
          const LiquidGlassTile(),
          SettingAnchor(
            Setting.haptics,
            child: PrefsSwitchTile(
              secondary: const Icon(Icons.vibration),
              title: Setting.haptics.titleOf(context.l10n),
              pref: Settings.haptics,
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
            Setting.chatFontWeight,
            child: SettingsNavTile(
              icon: Icons.format_bold,
              title: Setting.chatFontWeight.titleOf(context.l10n),
              subtitle: switch (_fontWeight) {
                500 => context.l10n.fontWeightMedium,
                600 => context.l10n.fontWeightSemibold,
                700 => context.l10n.fontWeightBold,
                _ => context.l10n.fontWeightNormal,
              },
              onTap: _pickFontWeight,
            ),
          ),
          SettingAnchor(
            Setting.showTimestamps,
            child: PrefsSwitchTile(
              secondary: const Icon(Icons.schedule),
              title: Setting.showTimestamps.titleOf(context.l10n),
              pref: Settings.showTimestamps,
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
              pref: Settings.checkeredMessages,
            ),
          ),
          SettingAnchor(
            Setting.lineSeparator,
            child: PrefsSwitchTile(
              title: Setting.lineSeparator.titleOf(context.l10n),
              pref: Settings.lineSeparator,
            ),
          ),
          SettingsSectionHeader(context.l10n.sectionDisplay),
          const KeepScreenOnTile(),
          SettingsSectionHeader(context.l10n.sectionNavigation),
          SettingAnchor(
            Setting.fastChannelSwipe,
            child: PrefsSwitchTile(
              title: Setting.fastChannelSwipe.titleOf(context.l10n),
              pref: Settings.fastChannelSnap,
            ),
          ),
          SettingAnchor(
            Setting.reopenLastChannel,
            child: PrefsSwitchTile(
              title: Setting.reopenLastChannel.titleOf(context.l10n),
              pref: Settings.reopenLastChannel,
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
      borderRadius: BorderRadius.circular(Radii.large),
      child: AnimatedContainer(
        duration: Motion.fast,
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
                borderRadius: BorderRadius.circular(Radii.small),
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
                borderRadius: BorderRadius.circular(Radii.small),
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

/// A small island swatch: glass when [on], else a plain outline.
/// Pure black dark mode. Shown on Appearance and mirrored on Battery.
class TrueDarkTile extends StatelessWidget {
  const TrueDarkTile({super.key});

  @override
  Widget build(BuildContext context) => SettingAnchor(
    Setting.trueDark,
    child: PrefsSwitchTile(
      title: Setting.trueDark.titleOf(context.l10n),
      info: const SettingInfoButton(Setting.trueDark),
      enabled: Theme.of(context).brightness == Brightness.dark,
      pref: Settings.trueDark,
    ),
  );
}

/// Keeps the screen awake. Shown on Appearance and mirrored on Battery.
class KeepScreenOnTile extends StatelessWidget {
  const KeepScreenOnTile({super.key});

  @override
  Widget build(BuildContext context) => SettingAnchor(
    Setting.keepScreenOn,
    child: PrefsSwitchTile(
      title: Setting.keepScreenOn.titleOf(context.l10n),
      info: const SettingInfoButton(Setting.keepScreenOn),
      pref: Settings.keepScreenOn,
    ),
  );
}

/// Liquid glass with its live swatch. Island chrome only, so it follows
/// the chrome theme through [PrefsStore]. Shown on Appearance and mirrored
/// on Battery.
class LiquidGlassTile extends StatefulWidget {
  const LiquidGlassTile({super.key});

  @override
  State<LiquidGlassTile> createState() => _LiquidGlassTileState();
}

class _LiquidGlassTileState extends State<LiquidGlassTile> {
  Prefs? _prefs;

  @override
  void initState() {
    super.initState();
    _load();
    PrefsStore.instance.addListener(_load);
  }

  @override
  void dispose() {
    PrefsStore.instance.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    final prefs = await Prefs.load();
    if (mounted) setState(() => _prefs = prefs);
  }

  @override
  Widget build(BuildContext context) {
    final island = (_prefs?.chromeTheme ?? ChromeTheme.ermchat.spec).isIsland;
    return SettingAnchor(
      Setting.liquidGlass,
      child: PrefsSwitchTile(
        title: Setting.liquidGlass.titleOf(context.l10n),
        subtitle: island
            ? context.l10n.experimental
            : context.l10n.liquidGlassIslandOnly,
        enabled: island,
        // Draws real glass once it is on, so the GPU builds the glass
        // shaders here on the tap rather than while this page animates
        // away, which would crawl.
        info: const SettingInfoButton(Setting.liquidGlass),
        titleTrailing: _GlassSwatch(
          on: island && (_prefs?.liquidGlass ?? false),
        ),
        pref: Settings.liquidGlass,
      ),
    );
  }
}

class _GlassSwatch extends StatelessWidget {
  const _GlassSwatch({required this.on});

  final bool on;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 40,
    height: 28,
    child: on
        ? glassIsland(child: const SizedBox.expand())
        : DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(Radii.medium),
              border: Border.all(
                color: Theme.of(context).colorScheme.outlineVariant,
              ),
            ),
          ),
  );
}
