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

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: PingTab.values.length,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Pings'),
          bottom: TabBar(
            tabs: [for (final t in PingTab.values) Tab(text: t.label)],
          ),
        ),
        // The FAB needs the selected tab; look it up from a context INSIDE
        // the DefaultTabController at press time so swipes count too (an
        // onTap-tracked field goes stale after a swipe without a tap).
        floatingActionButton: Builder(
          builder: (fabContext) => FloatingActionButton(
            onPressed: () {
              final tab = PingTab
                  .values[DefaultTabController.maybeOf(fabContext)?.index ?? 0];
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
              children: [
                _messagesList(),
                _ruleList(PingRuleKind.user, emptyHint: 'No user highlights'),
                _ruleList(PingRuleKind.badge, emptyHint: 'No badge highlights'),
                _ruleList(
                  PingRuleKind.blacklist,
                  emptyHint:
                      'Blacklisted users render normally but never ping. '
                      'Tap + to add one.',
                ),
              ],
            );
          },
        ),
      ),
    );
  }

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
        const _MentionFormatTile(),
        const Divider(height: 24),
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
    return ListTile(
      leading: Container(
        width: 20,
        height: 20,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: rule.colorArgb == null ? null : Color(rule.colorArgb!),
          border: Border.fromBorderSide(
            BorderSide(color: Theme.of(context).colorScheme.outline),
          ),
        ),
      ),
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
          IconButton(
            icon: const Icon(Icons.edit_outlined),
            tooltip: 'Edit',
            onPressed: () => _editRule(rule),
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
        canRegex: canRegex,
        canNotify: canNotify,
      ),
    );
    if (result == null) return;

    final updated = rule.copyWith(
      pattern: editablePattern ? result.pattern : null,
      isRegex: canRegex ? result.isRegex : null,
      caseSensitive: editablePattern ? result.caseSensitive : null,
      wordBoundary: editablePattern ? result.wordBoundary : null,
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
    required this.canNotify,
  });

  final PingRule rule;
  final bool isNew;
  final bool editablePattern;
  final bool canRegex;
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
            TextField(
              controller: _patternCtrl,
              autofocus: widget.isNew,
              decoration: InputDecoration(
                labelText: switch (widget.rule.kind) {
                  PingRuleKind.user => 'Username',
                  PingRuleKind.badge => 'Badge set id (e.g. moderator)',
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
    final pattern = _patternCtrl.text.trim();
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

class _MentionFormatTile extends StatefulWidget {
  const _MentionFormatTile();

  @override
  State<_MentionFormatTile> createState() => _MentionFormatTileState();
}

class _MentionFormatTileState extends State<_MentionFormatTile> {
  static const formats = <String, String>{
    '@name': '@name',
    '@name,': '@name,',
    'name': 'name',
    'name,': 'name,',
  };
  String _format = '@name';

  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((prefs) {
      if (mounted) {
        setState(() => _format = prefs.getString('mention_format') ?? '@name');
      }
    });
  }

  Future<void> _pick() async {
    final selected = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Mention format'),
        children: [
          RadioGroup<String>(
            groupValue: _format,
            onChanged: (v) {
              if (v != null) Navigator.pop(ctx, v);
            },
            child: Column(
              children: [
                for (final entry in formats.entries)
                  RadioListTile<String>(
                    value: entry.key,
                    title: Text(entry.value),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
    if (selected == null || selected == _format) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('mention_format', selected);
    if (mounted) setState(() => _format = selected);
  }

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: const Icon(Icons.text_format),
      title: const Text('Mention format'),
      subtitle: Text(
        'How tapping "Mention user" inserts the name: ${formats[_format]}',
      ),
      trailing: const Icon(Icons.chevron_right),
      onTap: _pick,
    );
  }
}
