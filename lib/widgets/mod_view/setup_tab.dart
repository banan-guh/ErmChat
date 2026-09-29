import 'package:flutter/material.dart';

import '../../services/twitch_api.dart';
import 'scope.dart';
import 'widgets.dart';

/// AutoMod levels: a Twitch preset or per-category levels.
class SetupTab extends ModTabWidget {
  const SetupTab({super.key, required super.mod});

  @override
  State<SetupTab> createState() => _SetupTabState();
}

class _SetupTabState extends State<SetupTab> with ModTabState<SetupTab> {
  static const _categories = [
    ('aggression', 'Aggression'),
    ('bullying', 'Bullying'),
    ('disability', 'Disability'),
    ('misogyny', 'Misogyny'),
    ('race_ethnicity_or_religion', 'Race, ethnicity, religion'),
    ('sex_based_terms', 'Sex-based terms'),
    ('sexuality_sex_or_gender', 'Sexuality, sex, gender'),
    ('swearing', 'Swearing'),
  ];
  static const _levelNames = [
    ('Off', 0),
    ('Low', 1),
    ('Medium', 2),
    ('High', 3),
    ('Max', 4),
  ];

  late final ModLoader<AutoModSettings> _settings;

  /// The settings the edits started from.
  AutoModSettings? _saved;
  Map<String, int> _levels = const {};

  /// Picked preset, or null for custom levels.
  int? _preset;

  /// Adopt the next load even with unsaved edits (after a save).
  bool _adoptNext = false;

  @override
  void initState() {
    super.initState();
    _settings = loader(
      (mod) => mod.actions.getAutoModSettings(mod.auth, mod.channel),
      failure: 'Could not load AutoMod settings.',
    )..addListener(_onLoaded);
    watch((mod) => mod.moderation?.modSettingsVersion, _settings.load);
  }

  @override
  void didChangeChannel() => _saved = null;

  /// Takes fresh settings unless the user is mid-edit.
  void _onLoaded() {
    final loaded = _settings.value;
    if (loaded == null || identical(loaded, _saved)) return;
    if (_saved != null && _dirty && !_adoptNext) return;
    _adoptNext = false;
    setState(() => _adopt(loaded));
  }

  void _adopt(AutoModSettings settings) {
    _saved = settings;
    _levels = Map.of(settings.levels);
    _preset = settings.overallLevel;
  }

  bool get _dirty {
    final saved = _saved;
    if (saved == null) return false;
    // A picked preset is a change until it matches the saved preset; Twitch
    // maps presets to its own category levels, so levels alone can't tell.
    if (_preset != null) return _preset != saved.overallLevel;
    // Custom: a dropdown moved away and back is not a change.
    if (saved.overallLevel != null) return true;
    if (_levels.length != saved.levels.length) return true;
    return _levels.entries.any((e) => saved.levels[e.key] != e.value);
  }

  void _pickPreset(int level) {
    final saved = _saved!;
    setState(() {
      // The saved preset shows Twitch's own category mix.
      if (level == saved.overallLevel) return _adopt(saved);
      _preset = level;
      _levels = {for (final key in _levels.keys) key: level};
    });
  }

  void _setLevel(String key, int level) => setState(() {
    _levels = {..._levels, key: level};
    _preset = null;
  });

  Future<void> _save() => busy('save', () async {
    // Helix takes a preset or per-category levels, never both.
    final preset = _preset;
    final ok = await mod.report(
      mod.actions.updateAutoModSettings(
        mod.auth,
        mod.channel,
        preset != null ? {'overall_level': preset} : _levels,
      ),
      done: 'AutoMod settings saved.',
    );
    if (!ok) return;
    _adoptNext = true;
    await _settings.load();
  });

  @override
  Widget build(BuildContext context) {
    return ModLoadView(
      loader: _settings,
      builder: (context, _) {
        final saving = isBusy('save');
        final dirty = _dirty && !saving;
        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          children: [
            const ModHint(
              'Presets set every category. Changing one switches to custom.',
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final (label, level) in _levelNames)
                  ChoiceChip(
                    label: Text(label),
                    selected: _preset == level,
                    onSelected: saving ? null : (_) => _pickPreset(level),
                  ),
              ],
            ),
            if (_preset == null)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text('Custom levels.'),
              ),
            const SizedBox(height: 8),
            for (final (key, label) in _categories)
              Card(
                margin: const EdgeInsets.symmetric(vertical: 6),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 4,
                  ),
                  child: Row(
                    children: [
                      Expanded(child: Text(label)),
                      DropdownButton<int>(
                        value: _levels[key] ?? 0,
                        items: [
                          for (final (name, level) in _levelNames)
                            DropdownMenuItem(value: level, child: Text(name)),
                        ],
                        onChanged: saving
                            ? null
                            : (level) {
                                if (level != null) _setLevel(key, level);
                              },
                      ),
                    ],
                  ),
                ),
              ),
            const SizedBox(height: 12),
            Row(
              spacing: 12,
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: dirty
                        ? () => setState(() => _adopt(_saved!))
                        : null,
                    child: const Text('Reset'),
                  ),
                ),
                Expanded(
                  flex: 2,
                  child: FilledButton(
                    onPressed: dirty ? _save : null,
                    child: saving
                        ? const ModSpinner(size: 18)
                        : const Text('Save changes'),
                  ),
                ),
              ],
            ),
          ],
        );
      },
    );
  }
}
