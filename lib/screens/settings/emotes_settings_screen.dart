import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../models/emote_fetch_tier.dart';
import '../../services/emote_cache_manager.dart';

class EmotesSettingsScreen extends StatefulWidget {
  final ValueChanged<int>? onEmoteTierChanged;
  final ValueChanged<int>? onEmoteCacheMaxChanged;
  final ValueChanged<EmoteFetchAutoMode>? onEmoteAutoModeChanged;

  /// Live connectivity (true = cellular data) so the tier slider reflects the
  /// effective tier while auto mode is picking. Null falls back to Wi-Fi.
  final ValueNotifier<bool>? mobileNotifier;

  /// Source of the disk-cache stats shown in the footer. Defaults to the
  /// shared [EmoteCacheManager] singleton.
  final EmoteCacheManager? cacheManager;

  const EmotesSettingsScreen({
    super.key,
    this.onEmoteTierChanged,
    this.onEmoteCacheMaxChanged,
    this.onEmoteAutoModeChanged,
    this.mobileNotifier,
    this.cacheManager,
  });

  @override
  State<EmotesSettingsScreen> createState() => _EmotesSettingsScreenState();
}

class _EmotesSettingsScreenState extends State<EmotesSettingsScreen> {
  int _tier = EmoteFetchTier.high.index;
  EmoteFetchAutoMode _autoMode = defaultEmoteFetchAutoMode;
  int _appliedCacheMax = defaultEmoteCacheMax;
  int _draftCacheMax = defaultEmoteCacheMax;
  EmoteCacheStats? _stats;

  @override
  void initState() {
    super.initState();
    _loadPrefs();
    _loadStats();
  }

  Future<void> _loadStats() async {
    final stats = await (widget.cacheManager ?? EmoteCacheManager()).stats();
    if (mounted) setState(() => _stats = stats);
  }

  Future<void> _loadPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() {
        _tier =
            prefs.getInt(emoteFetchTierPrefsKey) ?? EmoteFetchTier.high.index;
        final autoIndex =
            prefs.getInt(emoteFetchAutoPrefsKey) ??
            defaultEmoteFetchAutoMode.index;
        _autoMode = EmoteFetchAutoMode.values[autoIndex];
        _appliedCacheMax =
            prefs.getInt(emoteCacheMaxPrefsKey) ?? defaultEmoteCacheMax;
        _draftCacheMax = _appliedCacheMax;
      });
    }
  }

  Future<void> _onTierChanged(double value) async {
    final v = value.toInt();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(emoteFetchTierPrefsKey, v);
    if (mounted) setState(() => _tier = v);
    widget.onEmoteTierChanged?.call(v);
  }

  Future<void> _onAutoModeChanged(EmoteFetchAutoMode mode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(emoteFetchAutoPrefsKey, mode.index);
    if (mounted) setState(() => _autoMode = mode);
    widget.onEmoteAutoModeChanged?.call(mode);
  }

  Future<void> _applyCacheMax() async {
    final cache = widget.cacheManager ?? EmoteCacheManager();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(emoteCacheMaxPrefsKey, _draftCacheMax);
    widget.onEmoteCacheMaxChanged?.call(_draftCacheMax);
    // Evict now so the footer reflects the new cap immediately, not just on
    // the next emote fetch.
    cache.maxObjects = _draftCacheMax;
    await cache.enforceNow();
    if (!mounted) return;
    setState(() => _appliedCacheMax = _draftCacheMax);
    _loadStats();
  }

  @override
  Widget build(BuildContext context) {
    final tier = EmoteFetchTier.values[_tier];
    final autoOn = _autoMode != EmoteFetchAutoMode.off;
    return Scaffold(
      appBar: AppBar(title: const Text('Emotes')),
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
        _sectionHeader('Emote fetching'),
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
                  onChanged: autoOn ? null : _onTierChanged,
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
                        'Auto picks by connection '
                        '(${isMobile ? 'cellular' : 'Wi-Fi'}). '
                        'Currently: ${displayTier.label}. '
                        'Disable auto to choose manually.',
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
        _sectionHeader('Auto data saver mode'),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: SegmentedButton<EmoteFetchAutoMode>(
            key: const Key('emote_auto_mode'),
            segments: [
              for (final mode in EmoteFetchAutoMode.values)
                ButtonSegment(value: mode, label: Text(mode.label)),
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
        _sectionHeader('Emote image cache'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Text('$_draftCacheMax emotes kept in cache'),
        ),
        Slider(
          key: const Key('emote_cache_slider'),
          value: _draftCacheMax.toDouble(),
          min: minEmoteCacheMax.toDouble(),
          max: maxEmoteCacheMax.toDouble(),
          divisions: 30,
          label: '$_draftCacheMax',
          onChanged: (value) => setState(() => _draftCacheMax = value.toInt()),
        ),
        if (_draftCacheMax == 0)
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
          child: FilledButton(
            key: const Key('emote_cache_apply'),
            onPressed: _draftCacheMax != _appliedCacheMax
                ? _applyCacheMax
                : null,
            child: const Text('Apply'),
          ),
        ),
        SizedBox(height: 16),
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
                  ? 'Emote cache...'
                  : '${stats.fileCount} emotes stored · '
                        '${_formatBytes(stats.totalBytes)}',
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

  Widget _sectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(
        title,
        style: Theme.of(
          context,
        ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
      ),
    );
  }
}
