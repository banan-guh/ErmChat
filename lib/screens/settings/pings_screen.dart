import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../models/ping_rule.dart';
import '../../services/ping_manager.dart';

class PingsScreen extends StatefulWidget {
  const PingsScreen({super.key});

  @override
  State<PingsScreen> createState() => _PingsScreenState();
}

class _PingsScreenState extends State<PingsScreen> {
  PingManager get _manager => PingManager.instance;
  bool _simpleMode = true;

  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((prefs) {
      if (mounted) {
        setState(() => _simpleMode = prefs.getBool('ping_simple_mode') ?? true);
      }
    });
  }

  List<PingTab> get _visibleTabs =>
      _simpleMode ? [PingTab.messages, PingTab.users] : PingTab.values.toList();

  void _toggleMode() async {
    final next = !_simpleMode;
    setState(() => _simpleMode = next);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('ping_simple_mode', next);
  }

  @override
  Widget build(BuildContext context) {
    final visibleTabs = _visibleTabs;
    return DefaultTabController(
      length: visibleTabs.length,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Pings'),
          actions: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(_simpleMode ? 'Simple' : 'Advanced'),
                  const SizedBox(width: 8),
                  Switch(value: !_simpleMode, onChanged: (_) => _toggleMode()),
                ],
              ),
            ),
          ],
          bottom: TabBar(
            labelColor: Theme.of(context).colorScheme.primary,
            unselectedLabelColor: Theme.of(
              context,
            ).colorScheme.onSurface.withValues(alpha: 0.55),
            indicatorColor: Theme.of(context).colorScheme.primary,
            labelStyle: const TextStyle(fontSize: 13),
            labelPadding: const EdgeInsets.symmetric(horizontal: 8),
            tabs: [for (final t in visibleTabs) Tab(text: t.label)],
          ),
        ),
        // The FAB needs the selected tab; look it up from a context INSIDE
        // the DefaultTabController at press time so swipes count too (an
        // onTap-tracked field goes stale after a swipe without a tap).
        floatingActionButton: Builder(
          builder: (fabContext) => FloatingActionButton(
            onPressed: () {
              final idx = DefaultTabController.maybeOf(fabContext)?.index ?? 0;
              final tab = _visibleTabs[idx.clamp(0, _visibleTabs.length - 1)];
              final rule = switch (tab) {
                PingTab.messages => const PingRule(
                  id: '',
                  kind: PingRuleKind.message,
                  type: 'custom',
                ),
                PingTab.users => const PingRule(
                  id: '',
                  kind: PingRuleKind.user,
                ),
                PingTab.badges => const PingRule(
                  id: '',
                  kind: PingRuleKind.badge,
                ),
                PingTab.blacklist => const PingRule(
                  id: '',
                  kind: PingRuleKind.blacklist,
                ),
              };
              _editRule(rule, isNew: true);
            },
            child: const Icon(Icons.add),
          ),
        ),
        body: ListenableBuilder(
          listenable: _manager,
          builder: (context, _) {
            if (!_manager.loaded) {
              return const Center(child: CircularProgressIndicator());
            }
            return TabBarView(
              children: [for (final t in visibleTabs) _bodyFor(t)],
            );
          },
        ),
      ),
    );
  }

  Widget _bodyFor(PingTab tab) => switch (tab) {
    PingTab.messages => _messagesList(),
    PingTab.users => _ruleList(
      PingRuleKind.user,
      emptyHint: 'No user highlights',
    ),
    PingTab.badges => _ruleList(
      PingRuleKind.badge,
      emptyHint: 'No badge highlights',
    ),
    PingTab.blacklist => _ruleList(
      PingRuleKind.blacklist,
      emptyHint:
          'Blacklisted users render normally but never ping. '
          'Tap + to add one.',
    ),
  };

  Widget _messagesList() {
    final rules = _manager.rules;
    final builtins = [
      for (final type in builtinOrder)
        rules.firstWhere(
          (r) => r.kind == PingRuleKind.message && r.type == type,
          orElse: () => const PingRule(id: '', kind: PingRuleKind.message),
        ),
    ].where((r) => r.id.isNotEmpty);
    final customs = rules
        .where((r) => r.kind == PingRuleKind.message && r.type == 'custom')
        .toList();

    return ListView(
      children: [
        for (final rule in builtins)
          _tile(
            rule,
            title: builtinLabels[rule.type] ?? rule.type,
            subtitle: rule.type == 'username' || rule.type == 'reply'
                ? null
                : 'Highlight tint only, no notification by default',
          ),
        const Divider(height: 24),
        if (customs.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text(
              'Custom keywords highlight any message containing them. '
              'Tap + to add one.',
              style: TextStyle(color: Colors.grey),
            ),
          )
        else
          for (final rule in customs) _tile(rule, title: rule.pattern),
      ],
    );
  }

  Widget _ruleList(PingRuleKind kind, {required String emptyHint}) {
    final rules = _manager.rules.where((r) => r.kind == kind).toList();
    if (rules.isEmpty) {
      return Center(child: Text(emptyHint, textAlign: TextAlign.center));
    }
    return ListView(
      children: [
        for (final rule in rules)
          _tile(
            rule,
            title: rule.pattern.isEmpty ? '(no pattern)' : rule.pattern,
          ),
      ],
    );
  }

  Widget _tile(PingRule rule, {required String title, String? subtitle}) {
    final subtitles = <String>[
      ?subtitle,
      if (rule.isRegex) 'regex',
      if (rule.caseSensitive) 'case sensitive',
      if (rule.wordBoundary) 'whole word',
      if (rule.notify) 'notifies',
    ];
    final isPreset =
        rule.id.startsWith('builtin_') || rule.id.startsWith('preset_badge_');
    final tile = ListTile(
      title: Text(title),
      subtitle: subtitles.isEmpty
          ? null
          : Text(subtitles.join(', '), style: const TextStyle(fontSize: 12)),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Switch(
            value: rule.enabled,
            onChanged: (v) => _update(rule.copyWith(enabled: v)),
          ),
          if (!isPreset)
            IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: 'Delete',
              onPressed: () {
                _manager.removeRule(rule.id);
                _manager.save();
              },
            ),
        ],
      ),
      onTap: () => _editRule(rule),
    );
    // Square accent bar flush to the left edge. Always 4px wide (transparent
    // when no color) so the tile's content padding never shifts between
    // colored and uncolored rows.
    return Container(
      decoration: BoxDecoration(
        border: Border(
          left: BorderSide(
            color: rule.colorArgb == null
                ? Colors.transparent
                : Color(rule.colorArgb!),
            width: 4,
          ),
        ),
      ),
      child: tile,
    );
  }

  void _update(PingRule updated) {
    _manager.upsertRule(updated);
    _manager.save();
  }

  Future<void> _editRule(PingRule rule, {bool isNew = false}) async {
    final editablePattern =
        rule.type == 'custom' || rule.kind != PingRuleKind.message;
    final canRegex =
        (rule.type == 'custom' && rule.kind == PingRuleKind.message) ||
        rule.kind == PingRuleKind.blacklist;
    final effectiveCanRegex = canRegex && !_simpleMode;
    final canNotify =
        rule.type == 'username' ||
        rule.type == 'reply' ||
        rule.type == 'custom' ||
        rule.kind == PingRuleKind.user;

    final result = await showModalBottomSheet<_PingRuleSheetResult>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => _PingRuleSheet(
        rule: rule,
        isNew: isNew,
        editablePattern: editablePattern,
        canRegex: effectiveCanRegex,
        simple: _simpleMode,
        canNotify: canNotify,
      ),
    );
    if (result == null) return;

    final updated = rule.copyWith(
      pattern: editablePattern ? result.pattern : null,
      isRegex: effectiveCanRegex ? result.isRegex : null,
      caseSensitive: (!_simpleMode && editablePattern)
          ? result.caseSensitive
          : null,
      wordBoundary: effectiveCanRegex ? result.wordBoundary : null,
      notify: canNotify ? result.notify : null,
      colorArgb: result.colorArgb,
      clearColor: result.colorArgb == null,
    );
    if (isNew) {
      _update(
        PingRule(
          id: DateTime.now().microsecondsSinceEpoch.toString(),
          kind: updated.kind,
          type: updated.type,
          pattern: updated.pattern,
          isRegex: updated.isRegex,
          caseSensitive: updated.caseSensitive,
          wordBoundary: updated.wordBoundary,
          enabled: true,
          notify: updated.notify,
          colorArgb: updated.colorArgb,
        ),
      );
    } else {
      _update(updated);
    }
  }
}

/// Builtin message-rule labels, in fixed UI order.
const builtinLabels = {
  'username': 'My username',
  'reply': 'Replies to me',
  'redemption': 'Channel point redemptions',
  'firstMsg': 'First messages',
  'elevated': 'Hype Chat messages',
};

const builtinOrder = [
  'username',
  'reply',
  'redemption',
  'firstMsg',
  'elevated',
];

class _PingRuleSheetResult {
  const _PingRuleSheetResult({
    required this.pattern,
    required this.isRegex,
    required this.caseSensitive,
    required this.wordBoundary,
    required this.notify,
    required this.colorArgb,
  });

  final String pattern;
  final bool isRegex;
  final bool caseSensitive;
  final bool wordBoundary;
  final bool notify;
  final int? colorArgb;
}

/// Rule editor bottom sheet. Owns its TextEditingController and disposes it in
/// [dispose], which only runs after the sheet route has fully exited;
/// disposing right after showModalBottomSheet resolves would race the exit
/// transition (and the collapsing keyboard's inset animation) rebuilding the
/// field against a dead controller.
class _PingRuleSheet extends StatefulWidget {
  const _PingRuleSheet({
    required this.rule,
    required this.isNew,
    required this.editablePattern,
    required this.canRegex,
    required this.simple,
    required this.canNotify,
  });

  final PingRule rule;
  final bool isNew;
  final bool editablePattern;
  final bool canRegex;
  final bool simple;
  final bool canNotify;

  @override
  State<_PingRuleSheet> createState() => _PingRuleSheetState();
}

class _PingRuleSheetState extends State<_PingRuleSheet> {
  static const colorChoices = <int?>[
    null,
    0xFFE57373,
    0xFFF06292,
    0xFFBA68C8,
    0xFF9575CD,
    0xFF7986CB,
    0xFF64B5F6,
    0xFF4DB6AC,
    0xFF81C784,
    0xFFFFD54F,
    0xFFFF8A65,
    0xFF90A4AE,
  ];

  late final _patternCtrl = TextEditingController(text: widget.rule.pattern);
  late bool _isRegex = widget.rule.isRegex;
  late bool _caseSensitive = widget.rule.caseSensitive;
  // Only custom keyword rules match free text, so whole word applies there.
  late bool _wholeWord = widget.rule.wordBoundary;
  late bool _notify = widget.rule.notify;
  late int? _color = widget.rule.colorArgb;
  late String _badgeId = widget.rule.pattern.isNotEmpty
      ? widget.rule.pattern
      : _badgeOptions.first;

  static const _badgeOptions = <String>[
    'broadcaster',
    'moderator',
    'vip',
    'subscriber',
    'staff',
    'partner',
    'founder',
    'turbo',
  ];

  @override
  void dispose() {
    _patternCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 16,
        bottom: MediaQuery.viewInsetsOf(context).bottom + 16,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            widget.isNew ? 'Add rule' : 'Edit rule',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          if (widget.editablePattern) ...[
            const SizedBox(height: 12),
            if (widget.rule.kind == PingRuleKind.badge)
              DropdownButtonFormField<String>(
                initialValue: _badgeId,
                decoration: const InputDecoration(
                  labelText: 'Badge',
                  helperText: "Highlights messages carrying this badge",
                ),
                items: [
                  if (!_badgeOptions.contains(_badgeId))
                    DropdownMenuItem(value: _badgeId, child: Text(_badgeId)),
                  for (final id in _badgeOptions)
                    DropdownMenuItem(value: id, child: Text(id)),
                ],
                onChanged: (v) => setState(() => _badgeId = v ?? _badgeId),
              )
            else
              TextField(
                controller: _patternCtrl,
                autofocus: widget.isNew,
                decoration: InputDecoration(
                  labelText: switch (widget.rule.kind) {
                    PingRuleKind.user => 'Username',
                    PingRuleKind.blacklist => 'Username or regex',
                    _ => 'Keyword',
                  },
                  hintText: widget.canRegex ? 'Plain text or regex' : null,
                ),
              ),
            if (widget.canRegex)
              SwitchListTile(
                dense: true,
                title: const Text('Regular expression'),
                value: _isRegex,
                onChanged: (v) => setState(() => _isRegex = v),
              ),
            if (!widget.simple)
              SwitchListTile(
                dense: true,
                title: const Text('Case sensitive'),
                value: _caseSensitive,
                onChanged: (v) => setState(() => _caseSensitive = v),
              ),
            if (widget.canRegex && widget.editablePattern)
              SwitchListTile(
                dense: true,
                title: const Text('Whole word'),
                subtitle: const Text('Plain text patterns only'),
                value: _wholeWord,
                onChanged: (v) => setState(() => _wholeWord = v),
              ),
          ] else ...[
            const SizedBox(height: 8),
            Text(builtinLabels[widget.rule.type] ?? widget.rule.type),
          ],
          if (widget.canNotify)
            SwitchListTile(
              dense: true,
              title: const Text('System notifications'),
              subtitle: const Text(
                'Push a notification when the app is in the background',
              ),
              value: _notify,
              onChanged: (v) => setState(() => _notify = v),
            ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              for (final c in colorChoices)
                GestureDetector(
                  onTap: () => setState(() => _color = c),
                  child: Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: c == null ? null : Color(c),
                      border: Border.fromBorderSide(
                        BorderSide(
                          color: _color == c
                              ? Theme.of(context).colorScheme.primary
                              : Theme.of(context).colorScheme.outline,
                          width: _color == c ? 3 : 1,
                        ),
                      ),
                    ),
                    child: c == null ? const Icon(Icons.block, size: 16) : null,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _save,
            child: Text(widget.isNew ? 'Add' : 'Save'),
          ),
        ],
      ),
    );
  }

  void _save() {
    final pattern = widget.rule.kind == PingRuleKind.badge
        ? _badgeId
        : _patternCtrl.text.trim();
    if (widget.isNew && widget.editablePattern && pattern.isEmpty) {
      Navigator.pop(context);
      return;
    }
    Navigator.pop(
      context,
      _PingRuleSheetResult(
        pattern: pattern,
        isRegex: _isRegex,
        caseSensitive: _caseSensitive,
        wordBoundary: _wholeWord,
        notify: _notify,
        colorArgb: _color,
      ),
    );
  }
}

enum PingTab {
  messages('Messages'),
  users('Users'),
  badges('Badges'),
  blacklist('Blacklist');

  final String label;
  const PingTab(this.label);
}
