import 'dart:async';

import 'package:flutter/material.dart';
import '../../l10n/l10n.dart';
import '../../models/emote_fetch_tier.dart';
import '../../emotes/emote.dart';
import '../../services/emote_cache_manager.dart';
import '../../services/emote_images.dart';
import '../../services/emote_manager.dart';
import '../../util/prefs.dart';
import '../../util/prefs_store.dart';
import '../../widgets/dialogs.dart';
import '../../widgets/emote_frame_rate.dart';
import 'settings_page.dart';
import 'setting_info.dart';
import 'settings_search.dart';
import '../../widgets/design_tokens.dart';

class EmotesSettingsScreen extends StatefulWidget {
  final ValueChanged<int>? onEmoteTierChanged;
  final ValueChanged<int>? onEmoteCacheMaxChanged;
  final ValueChanged<EmoteFetchAutoMode>? onEmoteAutoModeChanged;

  /// Nuke action (kills all in-memory emote state, then refetches
  /// everything). Null hides the section (tests, standalone previews).
  final VoidCallback? onNukeEmotes;

  /// Live connectivity (true = cellular data) so the tier slider reflects the
  /// effective tier while auto mode is picking. Null falls back to Wi-Fi.
  final ValueNotifier<bool>? mobileNotifier;

  /// Source of the disk-cache stats shown in the footer. Defaults to the
  /// manager's image owner.
  final EmoteImages? images;

  /// The live manager backing the per-provider visibility toggles. The
  /// section is hidden when null (tests, standalone previews).
  final EmoteManager? emoteManager;

  const EmotesSettingsScreen({
    super.key,
    this.onEmoteTierChanged,
    this.onEmoteCacheMaxChanged,
    this.onEmoteAutoModeChanged,
    this.onNukeEmotes,
    this.mobileNotifier,
    this.images,
    this.emoteManager,
  });

  @override
  State<EmotesSettingsScreen> createState() => _EmotesSettingsScreenState();
}

class _EmotesSettingsScreenState extends State<EmotesSettingsScreen> {
  final _providerEnabled = <EmoteType, bool>{};
  bool _allowUnlisted = true;
  bool _allowPersonal = true;
  bool _ffzEffects = true;
  bool _bttvModifiers = true;
  bool _sevenTvCosmetics = false;

  /// Enabled-provider snapshot from when the screen opened, so closing it
  /// can diff which providers were newly enabled.
  Set<EmoteType>? _enabledAtOpen;

  static const _providerLabels = {
    EmoteType.twitch: 'Twitch',
    EmoteType.bttv: 'BetterTTV',
    EmoteType.ffz: 'FrankerFaceZ',
    EmoteType.sevenTv: '7TV',
  };

  @override
  void initState() {
    super.initState();
    _loadPrefs();
    _loadProviders();
  }

  Future<void> _loadProviders() async {
    final manager = widget.emoteManager;
    if (manager == null) return;
    final enabled = await manager.enabledProviders();
    if (!mounted) return;
    _enabledAtOpen ??= enabled;
    setState(() {
      for (final type in EmoteType.values) {
        _providerEnabled[type] = enabled.contains(type);
      }
      _allowUnlisted = manager.allowUnlisted7tv;
      _allowPersonal = manager.allowPersonal7tv;
    });
  }

  @override
  void dispose() {
    // Leaving settings settles the provider changes: newly disabled ones drop
    // their emotes, newly enabled ones refetch. Off-on fiddling or no-change
    // visits do nothing.
    final manager = widget.emoteManager;
    final atOpen = _enabledAtOpen;
    if (manager != null && atOpen != null) {
      final newlyEnabled = {
        for (final entry in _providerEnabled.entries)
          if (entry.value && !atOpen.contains(entry.key)) entry.key,
      };
      final newlyDisabled = {
        for (final entry in _providerEnabled.entries)
          if (!entry.value && atOpen.contains(entry.key)) entry.key,
      };
      if (newlyDisabled.isNotEmpty) manager.dropProviders(newlyDisabled);
      if (newlyEnabled.isNotEmpty) {
        unawaited(manager.ensureStashed(newlyEnabled));
      }
    }
    super.dispose();
  }

  Future<void> _onProviderChanged(EmoteType type, bool enabled) async {
    setState(() => _providerEnabled[type] = enabled);
    await widget.emoteManager?.setProviderEnabled(type, enabled);
    // The 7TV socket follows the provider set through the prefs listener.
    PrefsStore.instance.notifyChanged();
  }

  Future<void> _onAllowUnlistedChanged(bool allowed) async {
    setState(() => _allowUnlisted = allowed);
    await widget.emoteManager?.setAllowUnlisted7tv(allowed);
  }

  Future<void> _onAllowPersonalChanged(bool allowed) async {
    setState(() => _allowPersonal = allowed);
    await widget.emoteManager?.setAllowPersonal7tv(allowed);
  }

  Future<void> _loadPrefs() async {
    final prefs = await Prefs.load();
    if (mounted) {
      setState(() {
        _ffzEffects = prefs.ffzEffects;
        _bttvModifiers = prefs.bttvModifiers;
        _sevenTvCosmetics = prefs.sevenTvCosmetics;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return SettingsPage(
      title: Text(context.l10n.pageEmotes),
      body: ListView(
        children: [
          EmoteQualitySection(
            mobileNotifier: widget.mobileNotifier,
            onTierChanged: widget.onEmoteTierChanged,
            onAutoModeChanged: widget.onEmoteAutoModeChanged,
          ),
          EmoteCacheSection(
            images: widget.images ?? widget.emoteManager?.images,
            onCacheMaxChanged: widget.onEmoteCacheMaxChanged,
            onNuke: widget.onNukeEmotes,
          ),
          const EmoteAnimationSection(),
          if (widget.emoteManager != null) ...[
            SettingAnchor(
              Setting.providers,
              child: SettingsNavTile(
                key: const Key('providers_tile'),
                icon: Icons.extension,
                title: Setting.providers.titleOf(context.l10n),
                subtitle: _providersSummary(),
                onTap: _showProviderSheet,
              ),
            ),
            SettingAnchor(
              Setting.unlistedEmotes,
              child: SwitchListTile(
                key: const Key('allow_unlisted_tile'),
                secondary: const Icon(Icons.visibility_off_outlined),
                title: Text(Setting.unlistedEmotes.titleOf(context.l10n)),
                value: _allowUnlisted,
                onChanged: _onAllowUnlistedChanged,
              ),
            ),
            SettingAnchor(
              Setting.personalEmotes,
              child: SwitchListTile(
                secondary: const Icon(Icons.person_outline),
                title: Text(Setting.personalEmotes.titleOf(context.l10n)),
                value: _allowPersonal,
                onChanged: _onAllowPersonalChanged,
              ),
            ),
          ],
          SizedBox(height: 16),
        ],
      ),
    );
  }

  static const _providers = [
    EmoteType.twitch,
    EmoteType.bttv,
    EmoteType.ffz,
    EmoteType.sevenTv,
  ];

  String _providersSummary() {
    final enabled = [
      for (final type in _providers)
        if (_providerEnabled[type] ?? true) _providerLabels[type]!,
    ];
    return enabled.isEmpty
        ? context.l10n.providersAllDisabled
        : context.l10n.providersEnabled(enabled.join(', '));
  }

  /// Bottom-sheet picker for emote providers: a switch per provider, with
  /// FFZ effects and BTTV modifiers as checkboxes under it while it is on.
  Future<void> _showProviderSheet() {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) {
        var enabled = Map.of(_providerEnabled);
        return SafeArea(
          child: StatefulBuilder(
            builder: (context, setSheetState) => ListView(
              shrinkWrap: true,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      context.l10n.providersTitle,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
                for (final type in _providers) ...[
                  if (type == EmoteType.sevenTv)
                    ..._sevenTvGroup(enabled, setSheetState)
                  else
                    SwitchListTile(
                      key: Key('provider_toggle_${type.name}'),
                      title: Text(_providerLabels[type] ?? type.name),
                      value: enabled[type] ?? true,
                      onChanged: (v) {
                        setSheetState(() => enabled[type] = v);
                        _onProviderChanged(type, v);
                      },
                    ),
                  if (type == EmoteType.ffz && (enabled[type] ?? true))
                    _subCheckbox(context.l10n.ffzEffects, _ffzEffects, (
                      v,
                    ) async {
                      setState(() => _ffzEffects = v);
                      setSheetState(() {});
                      final prefs = await Prefs.load();
                      await prefs.setFfzEffects(v);
                      PrefsStore.instance.notifyChanged();
                    }),
                  if (type == EmoteType.bttv && (enabled[type] ?? true))
                    _subCheckbox(context.l10n.bttvModifiers, _bttvModifiers, (
                      v,
                    ) async {
                      setState(() => _bttvModifiers = v);
                      setSheetState(() {});
                      final prefs = await Prefs.load();
                      await prefs.setBttvModifiers(v);
                      PrefsStore.instance.notifyChanged();
                    }),
                ],
                const SizedBox(height: 8),
              ],
            ),
          ),
        );
      },
    );
  }

  /// 7TV as one switch over its emotes and its cosmetics (paints and
  /// badges). The parent is on while either is.
  List<Widget> _sevenTvGroup(
    Map<EmoteType, bool> enabled,
    StateSetter setSheetState,
  ) {
    const type = EmoteType.sevenTv;
    final emotes = enabled[type] ?? true;
    void setEmotes(bool on) {
      setSheetState(() => enabled[type] = on);
      _onProviderChanged(type, on);
    }

    Future<void> setCosmetics(bool on) async {
      setState(() => _sevenTvCosmetics = on);
      setSheetState(() {});
      final prefs = await Prefs.load();
      await prefs.setSevenTvCosmetics(on);
      PrefsStore.instance.notifyChanged();
    }

    return [
      SwitchListTile(
        key: Key('provider_toggle_${type.name}'),
        title: Text(_providerLabels[type]!),
        value: emotes || _sevenTvCosmetics,
        onChanged: (v) {
          setEmotes(v);
          setCosmetics(v);
        },
      ),
      if (emotes || _sevenTvCosmetics) ...[
        _subCheckbox(context.l10n.sevenTvEmotes, emotes, setEmotes),
        _subCheckbox(
          context.l10n.sevenTvCosmetics,
          _sevenTvCosmetics,
          setCosmetics,
        ),
      ],
    ];
  }

  Widget _subCheckbox(String title, bool value, ValueChanged<bool> onChanged) =>
      CheckboxListTile(
        contentPadding: const EdgeInsets.only(left: 40, right: 34),
        dense: true,
        visualDensity: VisualDensity.compact,
        title: Text(title),
        value: value,
        onChanged: (v) => onChanged(v ?? value),
      );
}

/// The emote level slider and auto data saver picker. Shown on Emotes and
/// mirrored on Data.
class EmoteQualitySection extends StatefulWidget {
  const EmoteQualitySection({
    super.key,
    this.mobileNotifier,
    this.onTierChanged,
    this.onAutoModeChanged,
  });

  /// Live connectivity (true = cellular data) so the slider reflects the
  /// effective tier while auto mode is picking. Null falls back to Wi-Fi.
  final ValueNotifier<bool>? mobileNotifier;
  final ValueChanged<int>? onTierChanged;
  final ValueChanged<EmoteFetchAutoMode>? onAutoModeChanged;

  @override
  State<EmoteQualitySection> createState() => _EmoteQualitySectionState();
}

class _EmoteQualitySectionState extends State<EmoteQualitySection> {
  int _tier = EmoteFetchTier.high.index;
  EmoteFetchAutoMode _autoMode = defaultEmoteFetchAutoMode;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await Prefs.load();
    if (!mounted) return;
    setState(() {
      _tier = prefs.emoteFetchTier;
      final autoIndex = prefs.emoteFetchAuto;
      _autoMode = autoIndex >= 0 && autoIndex < EmoteFetchAutoMode.values.length
          ? EmoteFetchAutoMode.values[autoIndex]
          : defaultEmoteFetchAutoMode;
    });
  }

  /// Drag feedback only: moves the label/thumb without persisting or
  /// refetching (the tier change itself fires on release).
  void _onTierDragging(double value) {
    if (mounted) setState(() => _tier = value.toInt());
  }

  Future<void> _onTierChanged(double value) async {
    final v = value.toInt();
    final prefs = await Prefs.load();
    await prefs.setEmoteFetchTier(v);
    if (mounted) setState(() => _tier = v);
    widget.onTierChanged?.call(v);
  }

  Future<void> _onAutoModeChanged(EmoteFetchAutoMode mode) async {
    final prefs = await Prefs.load();
    await prefs.setEmoteFetchAuto(mode.index);
    if (mounted) setState(() => _autoMode = mode);
    widget.onAutoModeChanged?.call(mode);
  }

  @override
  Widget build(BuildContext context) {
    final mobile = widget.mobileNotifier;
    return mobile == null
        ? _build(context, isMobile: false)
        : ValueListenableBuilder<bool>(
            valueListenable: mobile,
            builder: (context, isMobile, _) =>
                _build(context, isMobile: isMobile),
          );
  }

  Widget _build(BuildContext context, {required bool isMobile}) {
    final tier = EmoteFetchTier.values[_tier];
    final autoOn = _autoMode != EmoteFetchAutoMode.off;
    final displayTier = autoOn
        ? effectiveEmoteFetchTier(
            manual: tier,
            auto: _autoMode,
            isMobile: isMobile,
          )
        : tier;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingAnchor(
          Setting.emoteFetching,
          child: SettingsSectionHeader(
            Setting.emoteFetching.titleOf(context.l10n),
            trailing: const SettingInfoButton(Setting.emoteFetching),
          ),
        ),
        TweenAnimationBuilder<double>(
          duration: Motion.slow,
          curve: Motion.move,
          tween: Tween<double>(end: displayTier.index.toDouble()),
          builder: (context, animatedValue, _) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  child: AnimatedSwitcher(
                    duration: Motion.normal,
                    child: Text(
                      _tierLabel(context.l10n, displayTier),
                      key: ValueKey('tier_label_${displayTier.label}'),
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                ),
                Slider(
                  key: const Key('emote_tier_slider'),
                  value: autoOn ? animatedValue : displayTier.index.toDouble(),
                  min: 0,
                  max: (EmoteFetchTier.values.length - 1).toDouble(),
                  divisions: EmoteFetchTier.values.length - 1,
                  label: _tierLabel(context.l10n, displayTier),
                  onChanged: autoOn ? null : _onTierDragging,
                  onChangeEnd: autoOn ? null : _onTierChanged,
                ),
              ],
            );
          },
        ),
        SizedBox(
          height: 48,
          width: double.infinity,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Align(
              alignment: Alignment.centerLeft,
              child: AnimatedSwitcher(
                duration: Motion.normal,
                child: autoOn
                    ? Text(
                        isMobile
                            ? context.l10n.autoTierCellular(
                                _tierLabel(context.l10n, displayTier),
                              )
                            : context.l10n.autoTierWifi(
                                _tierLabel(context.l10n, displayTier),
                              ),
                        key: ValueKey(
                          'auto_note_${isMobile}_${displayTier.label}',
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      )
                    : Text(
                        _tierHint(context.l10n, tier),
                        key: ValueKey('tier_subtitle_${tier.label}'),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
              ),
            ),
          ),
        ),
        SettingAnchor(
          Setting.autoDataSaver,
          child: SettingsSectionHeader(
            Setting.autoDataSaver.titleOf(context.l10n),
            trailing: const SettingInfoButton(Setting.autoDataSaver),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: SegmentedButton<EmoteFetchAutoMode>(
            key: const Key('emote_auto_mode'),
            segments: [
              for (final mode in EmoteFetchAutoMode.values)
                ButtonSegment(
                  value: mode,
                  // Narrow phones shrink the word instead of breaking it.
                  label: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      _autoModeLabel(context.l10n, mode),
                      maxLines: 1,
                      softWrap: false,
                    ),
                  ),
                ),
            ],
            selected: {_autoMode},
            showSelectedIcon: false,
            onSelectionChanged: (selection) =>
                _onAutoModeChanged(selection.first),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Text(
            _autoModeHint(context.l10n, _autoMode),
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ),
      ],
    );
  }

  static String _tierLabel(AppLocalizations l, EmoteFetchTier t) => switch (t) {
    EmoteFetchTier.nothing => l.tierNothing,
    EmoteFetchTier.low => l.tierLow,
    EmoteFetchTier.medium => l.tierMedium,
    EmoteFetchTier.high => l.tierHigh,
  };

  static String _tierHint(AppLocalizations l, EmoteFetchTier t) => switch (t) {
    EmoteFetchTier.nothing => l.tierNothingHint,
    EmoteFetchTier.low => l.tierLowHint,
    EmoteFetchTier.medium => l.tierMediumHint,
    EmoteFetchTier.high => l.tierHighHint,
  };

  static String _autoModeLabel(AppLocalizations l, EmoteFetchAutoMode m) =>
      switch (m) {
        EmoteFetchAutoMode.off => l.autoModeOff,
        EmoteFetchAutoMode.balanced => l.autoModeBalanced,
        EmoteFetchAutoMode.aggressive => l.autoModeAggressive,
      };

  static String _autoModeHint(AppLocalizations l, EmoteFetchAutoMode m) =>
      switch (m) {
        EmoteFetchAutoMode.off => l.autoModeOffHint,
        EmoteFetchAutoMode.balanced => l.autoModeBalancedHint,
        EmoteFetchAutoMode.aggressive => l.autoModeAggressiveHint,
      };
}

/// The emote disk cache cap, apply and clear buttons, and usage footer.
/// Shown on Emotes and mirrored on Data.
class EmoteCacheSection extends StatefulWidget {
  const EmoteCacheSection({
    super.key,
    this.images,
    this.onCacheMaxChanged,
    this.onNuke,
  });

  /// Source of the disk-cache stats shown in the footer.
  final EmoteImages? images;
  final ValueChanged<int>? onCacheMaxChanged;

  /// Kills all in-memory emote state, then refetches everything.
  final VoidCallback? onNuke;

  @override
  State<EmoteCacheSection> createState() => _EmoteCacheSectionState();
}

class _EmoteCacheSectionState extends State<EmoteCacheSection> {
  int _appliedCacheMb = defaultEmoteCacheMb;
  int _draftCacheMb = defaultEmoteCacheMb;
  EmoteCacheStats? _stats;

  @override
  void initState() {
    super.initState();
    _load();
    _loadStats();
  }

  Future<void> _load() async {
    final prefs = await Prefs.load();
    if (!mounted) return;
    setState(() {
      _appliedCacheMb = prefs.emoteCacheMb;
      _draftCacheMb = _appliedCacheMb;
    });
  }

  Future<void> _loadStats() async {
    final images = widget.images;
    if (images == null) return;
    final stats = await images.stats();
    if (mounted) setState(() => _stats = stats);
  }

  Future<void> _applyCacheMb() async {
    // The slider can move while this awaits; apply one value throughout.
    final target = _draftCacheMb;
    final prefs = await Prefs.load();
    await prefs.setEmoteCacheMb(target);
    widget.onCacheMaxChanged?.call(target);
    // Evict now so the footer reflects the new cap immediately, not just on
    // the next emote fetch.
    final images = widget.images;
    if (images != null) {
      images.cacheCapMb = target;
      await images.cache.enforceNow();
    }
    if (!mounted) return;
    setState(() => _appliedCacheMb = target);
    _loadStats();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingAnchor(
          Setting.emoteCache,
          child: SettingsSectionHeader(
            Setting.emoteCache.titleOf(context.l10n),
            trailing: const SettingInfoButton(Setting.emoteCache),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Text(
            '$_draftCacheMb MB (~${estimatedEmoteCount(capBytes: _draftCacheMb * bytesPerMb, fileCount: _stats?.fileCount ?? 0, totalBytes: _stats?.totalBytes ?? 0)} emotes)',
          ),
        ),
        Slider(
          key: const Key('emote_cache_slider'),
          value: _draftCacheMb.toDouble(),
          min: minEmoteCacheMb.toDouble(),
          max: maxEmoteCacheMb.toDouble(),
          divisions: 30,
          label: '$_draftCacheMb MB',
          onChanged: (value) => setState(() => _draftCacheMb = value.toInt()),
        ),
        if (_draftCacheMb == 0)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Text(
              context.l10n.emoteCacheZeroWarning,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.error,
              ),
            ),
          ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          // Stacks the buttons when a label won't fit beside the other,
          // instead of breaking it over two lines.
          child: OverflowBar(
            spacing: 12,
            overflowSpacing: 8,
            children: [
              FilledButton(
                key: const Key('emote_cache_apply'),
                onPressed: _draftCacheMb != _appliedCacheMb
                    ? _applyCacheMb
                    : null,
                child: Text(context.l10n.apply),
              ),
              FilledButton(
                key: const Key('emote_nuke'),
                onPressed: () async {
                  final confirm = await confirmDialog(
                    context,
                    title: context.l10n.clearEmoteCacheTitle,
                    message: context.l10n.clearEmoteCacheMessage,
                    confirmLabel: context.l10n.clearEmoteCacheConfirm,
                    cancelLabel: context.l10n.no,
                  );
                  if (confirm) widget.onNuke?.call();
                },
                child: Text(context.l10n.nukeEmotes),
              ),
            ],
          ),
        ),
        _buildCacheFooter(context),
      ],
    );
  }

  Widget _buildCacheFooter(BuildContext context) {
    final textStyle = Theme.of(context).textTheme.bodySmall?.copyWith(
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    );
    final stats = _stats;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        key: const Key('emote_cache_footer'),
        children: [
          Icon(
            Icons.storage,
            size: 16,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              stats == null
                  ? context.l10n.emoteCacheLoading
                  : context.l10n.emoteCacheStats(
                      stats.fileCount,
                      _formatBytes(stats.totalBytes),
                      _appliedCacheMb,
                    ),
              style: textStyle,
            ),
          ),
        ],
      ),
    );
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}

/// Emote animation and the idle frame-rate controls. Shown on Emotes and
/// mirrored on Battery.
class EmoteAnimationSection extends StatefulWidget {
  const EmoteAnimationSection({super.key});

  @override
  State<EmoteAnimationSection> createState() => _EmoteAnimationSectionState();
}

class _EmoteAnimationSectionState extends State<EmoteAnimationSection> {
  bool _animateGifs = true;
  bool _adaptiveFps = true;
  int _idleFps = kIdleEmoteFps;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await Prefs.load();
    if (!mounted) return;
    setState(() {
      _animateGifs = prefs.animateGifs;
      _adaptiveFps = prefs.adaptiveEmoteFps;
      _idleFps = prefs.idleEmoteFps;
    });
  }

  @override
  Widget build(BuildContext context) {
    final idleEnabled = _animateGifs && _adaptiveFps;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsSectionHeader(context.l10n.sectionAnimation),
        SettingAnchor(
          Setting.animateEmotes,
          child: SwitchListTile(
            secondary: const Icon(Icons.gif_box),
            title: TitleWithInfo(
              Setting.animateEmotes.titleOf(context.l10n),
              Setting.animateEmotes,
            ),
            value: _animateGifs,
            onChanged: (value) async {
              final prefs = await Prefs.load();
              await prefs.setAnimateGifs(value);
              PrefsStore.instance.notifyChanged();
              if (mounted) setState(() => _animateGifs = value);
            },
          ),
        ),
        SettingAnchor(
          Setting.adaptiveFps,
          child: SwitchListTile(
            secondary: const Icon(Icons.battery_saver_outlined),
            title: TitleWithInfo(
              Setting.adaptiveFps.titleOf(context.l10n),
              Setting.adaptiveFps,
            ),
            subtitle: Text(context.l10n.adaptiveFpsHint),
            value: _adaptiveFps,
            onChanged: _animateGifs
                ? (value) async {
                    final prefs = await Prefs.load();
                    await prefs.setAdaptiveEmoteFps(value);
                    PrefsStore.instance.notifyChanged();
                    if (mounted) setState(() => _adaptiveFps = value);
                  }
                : null,
          ),
        ),
        SettingAnchor(
          Setting.idleFps,
          // The value rides in the caption, so the slider keeps the full
          // width, matching the other slider rows.
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                child: TextWithTrailing(
                  '${Setting.idleFps.titleOf(context.l10n)}: '
                  '${_idleFpsLabel(context.l10n, _idleFps)}',
                  trailing: const SettingInfoButton(Setting.idleFps),
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: idleEnabled
                        ? null
                        : Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              Slider(
                key: const Key('idle_emote_fps_slider'),
                value: _idleFps.toDouble(),
                min: 0,
                max: kActiveEmoteFps.toDouble(),
                divisions: kActiveEmoteFps ~/ 5,
                label: _idleFpsLabel(context.l10n, _idleFps),
                onChanged: idleEnabled
                    ? (value) => setState(() => _idleFps = value.round())
                    : null,
                onChangeEnd: (value) async {
                  final prefs = await Prefs.load();
                  await prefs.setIdleEmoteFps(value.round());
                  PrefsStore.instance.notifyChanged();
                },
              ),
            ],
          ),
        ),
      ],
    );
  }

  static String _idleFpsLabel(AppLocalizations l, int fps) =>
      fps == 0 ? l.idleFpsFreeze : l.fpsValue(fps);
}
