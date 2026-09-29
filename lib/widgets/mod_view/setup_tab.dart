import 'dart:async';

import 'package:flutter/material.dart';
import '../../chat/chat.dart';
import '../../services/mod_actions.dart';
import '../../services/twitch_api.dart';
import '../../services/twitch_auth.dart';
import 'common.dart';

class SetupTab extends StatefulWidget {
  const SetupTab({
    super.key,
    required this.channel,
    required this.chat,
    required this.modActions,
    required this.auth,
    required this.onNotice,
  });

  final String channel;
  final Chat chat;
  final ModActions modActions;
  final TwitchAuth auth;
  final ValueChanged<String> onNotice;

  @override
  State<SetupTab> createState() => _SetupTabState();
}

class _SetupTabState extends State<SetupTab> {
  static const _cats = [
    ('aggression', 'Aggression'),
    ('bullying', 'Bullying'),
    ('disability', 'Disability'),
    ('misogyny', 'Misogyny'),
    ('race_ethnicity_or_religion', 'Race, ethnicity, religion'),
    ('sex_based_terms', 'Sex-based terms'),
    ('sexuality_sex_or_gender', 'Sexuality, sex, gender'),
    ('swearing', 'Swearing'),
  ];
  static const _presets = [
    ('Off', 0),
    ('Low', 1),
    ('Medium', 2),
    ('High', 3),
    ('Max', 4),
  ];

  AutoModSettings? _settings;
  Map<String, int>? _levels;
  int? _overall;
  String? _error;
  int _loadGen = 0;
  bool _saving = false;
  ValueNotifier<int>? _settingsVersion;

  @override
  void initState() {
    super.initState();
    _subscribeSettings();
    _load();
  }

  void _subscribeSettings() {
    _settingsVersion = widget.chat
        .channelFor(widget.channel)
        ?.moderation
        .modSettingsVersion;
    _settingsVersion?.addListener(_onSettingsChanged);
  }

  void _unsubscribeSettings() {
    _settingsVersion?.removeListener(_onSettingsChanged);
    _settingsVersion = null;
  }

  @override
  void didUpdateWidget(covariant SetupTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.channel != widget.channel) {
      _unsubscribeSettings();
      _subscribeSettings();
      _load(force: true);
    }
  }

  @override
  void dispose() {
    _unsubscribeSettings();
    super.dispose();
  }

  void _onSettingsChanged() => _load();

  Future<void> _load({bool force = false}) async {
    final gen = ++_loadGen;
    final background = _settings != null;
    final actions = widget.modActions;
    final (settings, error) = await actions.twitchApi
        .isolateErrors<(AutoModSettings?, String?)>(() async {
          const fallback = 'Could not load AutoMod settings.';
          try {
            final settings = await actions.getAutoModSettings(
              widget.auth,
              widget.channel,
            );
            if (settings != null) return (settings, null);
            return (
              null,
              actions.twitchApi.lastErrorStatus != null
                  ? actions.failureReason()
                  : fallback,
            );
          } catch (_) {
            return (null, fallback);
          }
        });
    if (!mounted || gen != _loadGen) return;
    if (error != null && background) {
      widget.onNotice(error);
      return;
    }
    if (!force && background && _dirty && settings != null) return;
    setState(() {
      _error = error;
      if (settings != null) {
        _settings = settings;
        _levels = Map.of(settings.levels);
        _overall = settings.overallLevel;
      }
    });
  }

  bool get _dirty {
    final saved = _settings;
    final levels = _levels;
    if (saved == null || levels == null) return false;
    // A picked preset is a change until it matches the saved preset; Twitch
    // maps presets to its own category levels, so levels alone can't tell.
    if (_overall != null) return _overall != saved.overallLevel;
    // Custom: a dropdown moved away and back is not a change.
    if (saved.overallLevel != null) return true;
    if (levels.length != saved.levels.length) return true;
    for (final entry in levels.entries) {
      if (saved.levels[entry.key] != entry.value) return true;
    }
    return false;
  }

  void _reset() {
    final saved = _settings;
    if (saved == null) return;
    setState(() {
      _levels = Map.of(saved.levels);
      _overall = saved.overallLevel;
    });
  }

  Future<void> _save() async {
    final levels = _levels;
    if (levels == null || _saving || !_dirty) return;
    setState(() => _saving = true);
    try {
      // Helix takes a preset or per-category levels, never both.
      final overall = _overall;
      final result = await widget.modActions.updateAutoModSettings(
        widget.auth,
        widget.channel,
        overall != null ? {'overall_level': overall} : levels,
      );
      if (!mounted) return;
      if (result.ok) {
        widget.onNotice('AutoMod settings saved.');
        await _load(force: true);
      } else {
        widget.onNotice(modErrorText(result));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null && _settings == null) {
      return ModError(message: _error!, onRetry: _load);
    }
    final levels = _levels;
    if (levels == null) {
      return const Center(child: CircularProgressIndicator());
    }
    final theme = Theme.of(context);
    final displayOverall = _overall;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        Text(
          'Presets set every category. Changing one switches to custom.',
          style: TextStyle(
            fontSize: 12,
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final (label, value) in _presets)
              ChoiceChip(
                label: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 4,
                    vertical: 4,
                  ),
                  child: Text(label),
                ),
                selected: displayOverall == value,
                onSelected: _saving
                    ? null
                    : (_) {
                        final saved = _settings!;
                        // The saved preset shows Twitch's own category mix.
                        if (value == saved.overallLevel) return _reset();
                        setState(() {
                          _overall = value;
                          for (final key in levels.keys) {
                            levels[key] = value;
                          }
                        });
                      },
              ),
          ],
        ),
        if (displayOverall == null)
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text('Custom levels.'),
          ),
        const SizedBox(height: 8),
        for (final (key, label) in _cats)
          Card(
            margin: const EdgeInsets.symmetric(vertical: 6),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
              child: Row(
                children: [
                  Expanded(child: Text(label)),
                  DropdownButton<int>(
                    value: levels[key] ?? 0,
                    items: [
                      for (final (itemLabel, value) in _presets)
                        DropdownMenuItem(value: value, child: Text(itemLabel)),
                    ],
                    onChanged: _saving
                        ? null
                        : (v) {
                            if (v == null) return;
                            setState(() {
                              levels[key] = v;
                              _overall = null;
                            });
                          },
                  ),
                ],
              ),
            ),
          ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: _dirty && !_saving ? _reset : null,
                child: const Text('Reset'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              flex: 2,
              child: FilledButton(
                onPressed: _dirty && !_saving ? _save : null,
                child: _saving
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Save changes'),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
