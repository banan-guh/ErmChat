import 'package:flutter/material.dart';

import '../../models/ping_rule.dart';
import '../../services/ping_manager.dart';

class PingsScreen extends StatefulWidget {
  const PingsScreen({super.key});

  @override
  State<PingsScreen> createState() => _PingsScreenState();
}

class _PingsScreenState extends State<PingsScreen> {
  PingManager get _manager => PingManager.instance;

  static const builtinLabels = {
    'username': 'My username',
    'reply': 'Replies to me',
    'redemption': 'Channel point redemptions',
    'firstMsg': 'First messages',
    'elevated': 'Hype Chat messages',
  };

  static const builtinOrder = [
    'username',
    'reply',
    'redemption',
    'firstMsg',
    'elevated',
  ];

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

  PingTab _tab = PingTab.messages;

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: PingTab.values.length,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Pings'),
          bottom: TabBar(
            tabs: [for (final t in PingTab.values) Tab(text: t.label)],
            onTap: (i) => setState(() => _tab = PingTab.values[i]),
          ),
        ),
        floatingActionButton: FloatingActionButton(
          onPressed: () {
            final rule = switch (_tab) {
              PingTab.messages => const PingRule(
                id: '',
                kind: PingRuleKind.message,
                type: 'custom',
              ),
              PingTab.users => const PingRule(id: '', kind: PingRuleKind.user),
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

    var pattern = rule.pattern;
    var isRegex = rule.isRegex;
    var caseSensitive = rule.caseSensitive;
    var notify = rule.notify;
    int? color = rule.colorArgb;
    final controller = TextEditingController(text: pattern);

    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) => Padding(
          padding: EdgeInsets.only(
            left: 16,
            right: 16,
            top: 16,
            bottom: MediaQuery.viewInsetsOf(ctx).bottom + 16,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                isNew ? 'Add rule' : 'Edit rule',
                style: Theme.of(ctx).textTheme.titleMedium,
              ),
              if (editablePattern) ...[
                const SizedBox(height: 12),
                TextField(
                  controller: controller,
                  autofocus: isNew,
                  decoration: InputDecoration(
                    labelText: switch (rule.kind) {
                      PingRuleKind.user => 'Username',
                      PingRuleKind.badge => 'Badge set id (e.g. moderator)',
                      PingRuleKind.blacklist => 'Username or regex',
                      _ => 'Keyword',
                    },
                    hintText: canRegex ? 'Plain text or regex' : null,
                  ),
                  onChanged: (v) => pattern = v.trim(),
                ),
                if (canRegex)
                  SwitchListTile(
                    dense: true,
                    title: const Text('Regular expression'),
                    value: isRegex,
                    onChanged: (v) => setSheetState(() => isRegex = v),
                  ),
                SwitchListTile(
                  dense: true,
                  title: const Text('Case sensitive'),
                  value: caseSensitive,
                  onChanged: (v) => setSheetState(() => caseSensitive = v),
                ),
              ] else ...[
                const SizedBox(height: 8),
                Text(builtinLabels[rule.type] ?? rule.type),
              ],
              if (canNotify)
                SwitchListTile(
                  dense: true,
                  title: const Text('System notifications'),
                  subtitle: const Text(
                    'Push a notification when the app is in the background',
                  ),
                  value: notify,
                  onChanged: (v) => setSheetState(() => notify = v),
                ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  for (final c in colorChoices)
                    GestureDetector(
                      onTap: () => setSheetState(() => color = c),
                      child: Container(
                        width: 32,
                        height: 32,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: c == null ? null : Color(c),
                          border: Border.fromBorderSide(
                            BorderSide(
                              color: color == c
                                  ? Theme.of(ctx).colorScheme.primary
                                  : Theme.of(ctx).colorScheme.outline,
                              width: color == c ? 3 : 1,
                            ),
                          ),
                        ),
                        child: c == null
                            ? const Icon(Icons.block, size: 16)
                            : null,
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () {
                  if (isNew && editablePattern && pattern.isEmpty) {
                    Navigator.pop(ctx);
                    return;
                  }
                  Navigator.pop(ctx, true);
                },
                child: Text(isNew ? 'Add' : 'Save'),
              ),
            ],
          ),
        ),
      ),
    );

    controller.dispose();
    if (saved != true) return;

    final updated = rule.copyWith(
      pattern: editablePattern ? pattern : null,
      isRegex: canRegex ? isRegex : null,
      caseSensitive: editablePattern ? caseSensitive : null,
      notify: canNotify ? notify : null,
      colorArgb: color,
      clearColor: color == null,
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

enum PingTab {
  messages('Messages'),
  users('Users'),
  badges('Badges'),
  blacklist('Blacklist');

  final String label;
  const PingTab(this.label);
}
