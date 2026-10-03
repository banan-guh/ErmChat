import 'dart:async';

import 'package:flutter/material.dart';
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
import 'settings_search.dart';

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
  int _tier = EmoteFetchTier.high.index;
  EmoteFetchAutoMode _autoMode = defaultEmoteFetchAutoMode;
  int _appliedCacheMb = defaultEmoteCacheMb;
  int _draftCacheMb = defaultEmoteCacheMb;
  EmoteCacheStats? _stats;
  final _providerEnabled = <EmoteType, bool>{};
  bool _allowUnlisted = true;
  bool _animateGifs = true;
  bool _adaptiveFps = true;
  int _idleFps = kIdleEmoteFps;

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
    _loadStats();
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
    });
  }

  @override
  void dispose() {
    // Providers newly enabled during this visit may have no retained stash
    // (persisted caches stripped them after an earlier disable); refetch
    // just those. Off-on fiddling or no-change visits do nothing.
    final manager = widget.emoteManager;
    final atOpen = _enabledAtOpen;
    if (manager != null && atOpen != null) {
      final newlyEnabled = {
        for (final entry in _providerEnabled.entries)
          if (entry.value && !atOpen.contains(entry.key)) entry.key,
      };
      if (newlyEnabled.isNotEmpty) {
        unawaited(manager.ensureStashed(newlyEnabled));
      }
    }
    super.dispose();
  }

  Future<void> _onProviderChanged(EmoteType type, bool enabled) async {
    setState(() => _providerEnabled[type] = enabled);
    await widget.emoteManager?.setProviderEnabled(type, enabled);
  }

  Future<void> _onAllowUnlistedChanged(bool allowed) async {
    setState(() => _allowUnlisted = allowed);
    await widget.emoteManager?.setAllowUnlisted7tv(allowed);
  }

  Future<void> _loadStats() async {
    final images = widget.images ?? widget.emoteManager?.images;
    if (images == null) return;
    final stats = await images.stats();
    if (mounted) setState(() => _stats = stats);
  }

  Future<void> _loadPrefs() async {
    final prefs = await Prefs.load();
    if (mounted) {
      setState(() {
        _tier = prefs.emoteFetchTier;
        final autoIndex = prefs.emoteFetchAuto;
        _autoMode =
            autoIndex >= 0 && autoIndex < EmoteFetchAutoMode.values.length
            ? EmoteFetchAutoMode.values[autoIndex]
            : defaultEmoteFetchAutoMode;
        _appliedCacheMb = prefs.emoteCacheMb;
        _draftCacheMb = _appliedCacheMb;
        _animateGifs = prefs.animateGifs;
        _adaptiveFps = prefs.adaptiveEmoteFps;
        _idleFps = prefs.idleEmoteFps;
      });
    }
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
    widget.onEmoteTierChanged?.call(v);
  }

  Future<void> _onAutoModeChanged(EmoteFetchAutoMode mode) async {
    final prefs = await Prefs.load();
    await prefs.setEmoteFetchAuto(mode.index);
    if (mounted) setState(() => _autoMode = mode);
    widget.onEmoteAutoModeChanged?.call(mode);
  }

  Future<void> _applyCacheMb() async {
    final prefs = await Prefs.load();
    await prefs.setEmoteCacheMb(_draftCacheMb);
    widget.onEmoteCacheMaxChanged?.call(_draftCacheMb);
    // Evict now so the footer reflects the new cap immediately, not just on
    // the next emote fetch.
    final images = widget.images ?? widget.emoteManager?.images;
    if (images != null) {
      images.cacheCapMb = _draftCacheMb;
      await images.cache.enforceNow();
    }
    if (!mounted) return;
    setState(() => _appliedCacheMb = _draftCacheMb);
    _loadStats();
  }

  @override
  Widget build(BuildContext context) {
    final tier = EmoteFetchTier.values[_tier];
    final autoOn = _autoMode != EmoteFetchAutoMode.off;
    return SettingsPage(
      title: const Text('Emotes'),
      body: widget.mobileNotifier == null
          ? _buildList(context, tier, autoOn, isMobile: false)
          : ValueListenableBuilder<bool>(
              valueListenable: widget.mobileNotifier!,
              builder: (context, isMobile, _) =>
                  _buildList(context, tier, autoOn, isMobile: isMobile),
            ),
    );
  }

  Widget _buildList(
    BuildContext context,
    EmoteFetchTier tier,
    bool autoOn, {
    required bool isMobile,
  }) {
    final displayTier = autoOn
        ? effectiveEmoteFetchTier(
            manual: tier,
            auto: _autoMode,
            isMobile: isMobile,
          )
        : tier;
    return ListView(
      children: [
        SettingAnchor(
          Setting.emoteFetching,
          child: SettingsSectionHeader(Setting.emoteFetching.title),
        ),
        TweenAnimationBuilder<double>(
          duration: const Duration(milliseconds: 350),
          curve: Curves.easeInOut,
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
                    duration: const Duration(milliseconds: 250),
                    child: Text(
                      displayTier.label,
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
                  label: displayTier.label,
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
                duration: const Duration(milliseconds: 250),
                child: autoOn
                    ? Text(
                        'Auto: ${displayTier.label} on '
                        '${isMobile ? 'cellular' : 'Wi-Fi'}',
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
                        tier.subtitle,
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
          child: SettingsSectionHeader(Setting.autoDataSaver.title),
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
                    child: Text(mode.label, maxLines: 1, softWrap: false),
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
            _autoMode.subtitle,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ),
        SettingAnchor(
          Setting.emoteCache,
          child: SettingsSectionHeader(Setting.emoteCache.title),
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
              '0 will not keep any emotes in the cache',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.error,
              ),
            ),
          ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              Expanded(
                child: FilledButton(
                  key: const Key('emote_cache_apply'),
                  onPressed: _draftCacheMb != _appliedCacheMb
                      ? _applyCacheMb
                      : null,
                  child: const Text('Apply'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  key: const Key('emote_nuke'),
                  onPressed: () async {
                    final confirm = await confirmDialog(
                      context,
                      title: 'Clear emote cache?',
                      message: 'This will wipe all cached emotes and refetch.',
                      confirmLabel: 'Erm the nuke',
                      cancelLabel: 'No',
                    );
                    if (confirm) widget.onNukeEmotes?.call();
                  },
                  child: const Text('Nuke emotes'),
                ),
              ),
            ],
          ),
        ),
        _buildCacheFooter(context),
        const SettingsSectionHeader('Animation'),
        SettingAnchor(
          Setting.animateEmotes,
          child: SwitchListTile(
            secondary: const Icon(Icons.gif_box),
            title: Text(Setting.animateEmotes.title),
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
            title: Text(Setting.adaptiveFps.title),
            subtitle: const Text('Frame rate after 30s idle'),
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
          child: ListTile(
            enabled: _animateGifs && _adaptiveFps,
            title: Text(Setting.idleFps.title),
            // Fixed width so the slider keeps its length as the label changes.
            trailing: SizedBox(
              width: 64,
              child: Text(_idleFpsLabel(_idleFps), textAlign: TextAlign.end),
            ),
            subtitle: Slider(
              key: const Key('idle_emote_fps_slider'),
              value: _idleFps.toDouble(),
              min: 0,
              max: kActiveEmoteFps.toDouble(),
              divisions: kActiveEmoteFps ~/ 5,
              label: _idleFpsLabel(_idleFps),
              onChanged: _animateGifs && _adaptiveFps
                  ? (value) => setState(() => _idleFps = value.round())
                  : null,
              onChangeEnd: (value) async {
                final prefs = await Prefs.load();
                await prefs.setIdleEmoteFps(value.round());
                PrefsStore.instance.notifyChanged();
              },
            ),
          ),
        ),
        if (widget.emoteManager != null) ...[
          SettingAnchor(
            Setting.providers,
            child: SettingsNavTile(
              key: const Key('providers_tile'),
              icon: Icons.extension,
              title: Setting.providers.title,
              subtitle: _providersSummary(),
              onTap: _showProviderSheet,
            ),
          ),
          SettingAnchor(
            Setting.unlistedEmotes,
            child: SwitchListTile(
              key: const Key('allow_unlisted_tile'),
              secondary: const Icon(Icons.visibility_off_outlined),
              title: Text(Setting.unlistedEmotes.title),
              value: _allowUnlisted,
              onChanged: _onAllowUnlistedChanged,
            ),
          ),
        ],
        SizedBox(height: 16),
      ],
    );
  }

  static const _thirdPartyProviders = [
    EmoteType.bttv,
    EmoteType.ffz,
    EmoteType.sevenTv,
  ];

  static String _idleFpsLabel(int fps) => fps == 0 ? 'Freeze' : '$fps fps';

  String _providersSummary() {
    final enabled = [
      for (final type in _thirdPartyProviders)
        if (_providerEnabled[type] ?? true) _providerLabels[type]!,
    ];
    return enabled.isEmpty ? 'All disabled' : '${enabled.join(', ')} enabled';
  }

  /// Bottom-sheet picker for third-party providers. Twitch is intentionally
  /// absent: its emotes are always fetched and rendered.
  Future<void> _showProviderSheet() {
    return showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) {
        var enabled = Map.of(_providerEnabled);
        return SafeArea(
          child: StatefulBuilder(
            builder: (context, setSheetState) => Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'Providers',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
                for (final type in _thirdPartyProviders)
                  CheckboxListTile(
                    key: Key('provider_toggle_${type.name}'),
                    title: Text(_providerLabels[type] ?? type.name),
                    value: enabled[type] ?? true,
                    onChanged: (v) {
                      setSheetState(() => enabled[type] = v ?? true);
                      _onProviderChanged(type, v ?? true);
                    },
                  ),
                const SizedBox(height: 8),
              ],
            ),
          ),
        );
      },
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
                  ? 'Emote cache...'
                  : '${stats.fileCount} emotes stored · '
                        '${_formatBytes(stats.totalBytes)} of '
                        '$_appliedCacheMb MB',
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
