import 'dart:io' show Platform;
import 'dart:math';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../color_utils.dart' show highlightRowColor;
import '../../models/highlight_state.dart';
import '../../models/ping_rule.dart';
import '../../models/twitch_message.dart';
import '../../providers/app_providers.dart';
import '../../providers/ui_state_providers.dart';
import '../../services/ping_manager.dart';
import '../../util/prefs.dart';
import '../../util/prefs_store.dart';
import 'ignores_screen.dart';
import 'prefs_tiles.dart';
import 'settings_page.dart';
import 'settings_search.dart';

/// Mention push rides the Android foreground-service path; iOS has none.
final _pushSupported = !kIsWeb && !Platform.isIOS;

/// Highlights: what tints a message, what lands in @mentions, what notifies.
class PingsScreen extends ConsumerStatefulWidget {
  const PingsScreen({
    super.key,
    this.onMentionPushChanged,
    this.onWhisperNotifyChanged,
    this.onBackgroundServiceChanged,
  });

  /// Service and permission side effects owned by the home screen.
  final ValueChanged<bool>? onMentionPushChanged;
  final ValueChanged<bool>? onWhisperNotifyChanged;
  final ValueChanged<bool>? onBackgroundServiceChanged;

  @override
  ConsumerState<PingsScreen> createState() => _PingsScreenState();
}

class _PingsScreenState extends ConsumerState<PingsScreen> {
  // Assume keep-alive is on until prefs load so the warning never flashes.
  bool _keepAlive = true;
  double _opacity = 0.6;

  /// Preview lines: each word is an emote (true) or "erm" (false). Rolled
  /// once so slider drags don't reshuffle them.
  final _previewLines = List.generate(3, (_) => _rollErmLine(Random()));

  PingManager get _manager => ref.read(pingManagerProvider);

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
    if (!mounted) return;
    setState(() {
      _keepAlive = prefs.backgroundService;
      _opacity = prefs.highlightOpacity;
    });
  }

  void _setPush(bool value) {
    final apply =
        widget.onMentionPushChanged ??
        ref.read(mentionPushProvider.notifier).set;
    apply(value);
  }

  Future<void> _enableKeepAlive() async {
    final prefs = await Prefs.load();
    await prefs.setBackgroundService(true);
    PrefsStore.instance.notifyChanged();
    widget.onBackgroundServiceChanged?.call(true);
  }

  /// Saving a notifying rule while push is off turns push on too: the user
  /// just asked to be notified, so a second switch elsewhere would be a trap.
  void _ensurePush() {
    if (!ref.read(mentionPushProvider)) _setPush(true);
  }

  Future<void> _edit(PingRule rule, {bool isNew = false}) async {
    final saved = await _editRule(
      context,
      _manager,
      rule,
      isNew: isNew,
      recent: _recentMessages(),
      opacity: _opacity,
    );
    if (!mounted || saved == null) return;
    if (saved.deleted) {
      final noun = rule.kind == PingRuleKind.message ? 'Keyword' : 'User';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('$noun removed'),
          action: SnackBarAction(
            label: 'Undo',
            onPressed: () {
              _manager.upsertRule(rule);
              _manager.save();
            },
          ),
        ),
      );
    } else if (saved.rule.notify && saved.rule.mention) {
      _ensurePush();
    }
  }

  /// Snapshot of buffered chat, newest first, for the editor's live preview.
  List<TwitchMessage> _recentMessages() {
    final chat = ref.read(chatProvider);
    final out = <TwitchMessage>[
      for (final name in chat.names)
        ...?chat.channelFor(name)?.messages.items.where((m) => !m.isSystem),
    ];
    out.sort((a, b) => b.timestamp.compareTo(a.timestamp));
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final manager = ref.watch(pingManagerProvider);
    final pushOn = ref.watch(mentionPushProvider);
    return SettingsPage(
      title: const Text('Highlights'),
      body: ListenableBuilder(
        listenable: manager,
        builder: (context, _) {
          if (!manager.loaded) {
            return const Center(child: CircularProgressIndicator());
          }
          final rules = manager.rules;
          return ListView(
            padding: const EdgeInsets.only(bottom: 32),
            children: [
              if (_pushSupported) ..._notificationSection(pushOn),
              ..._mentionSection(rules, pushOn),
              ..._listSection(rules, pushOn, PingRuleKind.message),
              ..._listSection(rules, pushOn, PingRuleKind.user),
              ..._eventSection(rules),
              ..._muteSection(rules),
              ..._appearanceSection(),
            ],
          );
        },
      ),
    );
  }

  Widget _tile(PingRule r, bool pushOn) => _RuleTile(
    rule: r,
    pushOn: _pushSupported && _canNotify(r) ? pushOn : null,
    onTap: () => _edit(r),
  );

  List<Widget> _notificationSection(bool pushOn) => [
    const SettingsSectionHeader('Notifications'),
    SettingAnchor(
      Setting.mentionPush,
      child: _needsKeepAlive(
        SwitchListTile(
          secondary: const Icon(Icons.alternate_email),
          title: Text(Setting.mentionPush.title),
          value: pushOn,
          onChanged: _keepAlive ? _setPush : null,
        ),
      ),
    ),
    SettingAnchor(
      Setting.whisperPush,
      child: _needsKeepAlive(
        PrefsSwitchTile(
          secondary: const Icon(Icons.mail_outline),
          title: Setting.whisperPush.title,
          enabled: _keepAlive,
          read: (p) => p.whisperNotifications,
          write: (p, v) => p.setWhisperNotifications(v),
          onChanged: widget.onWhisperNotifyChanged,
        ),
      ),
    ),
  ];

  /// Notifications only arrive while the background connection runs, so
  /// without it the toggles are greyed and a tap says what to turn on.
  Widget _needsKeepAlive(Widget tile) {
    if (_keepAlive) return tile;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: const Text(
              'Notifications need Stay connected in background',
            ),
            action: SnackBarAction(
              label: 'Turn on',
              onPressed: _enableKeepAlive,
            ),
          ),
        ),
      child: tile,
    );
  }

  List<Widget> _mentionSection(List<PingRule> rules, bool pushOn) => [
    const SettingsSectionHeader('Mentions'),
    for (final type in const ['username', 'reply', 'thread'])
      ...rules
          .where((r) => r.kind == PingRuleKind.message && r.type == type)
          .map((r) => _tile(r, pushOn)),
  ];

  List<Widget> _listSection(
    List<PingRule> rules,
    bool pushOn,
    PingRuleKind kind,
  ) {
    final keywords = kind == PingRuleKind.message;
    return [
      SettingAnchor(
        keywords ? Setting.highlightKeywords : Setting.highlightUsers,
        child: SettingsSectionHeader(
          (keywords ? Setting.highlightKeywords : Setting.highlightUsers).title,
        ),
      ),
      for (final r in rules.where(
        (r) => r.kind == kind && (!keywords || r.type == 'custom'),
      ))
        _tile(r, pushOn),
      _AddTile(
        keywords ? 'Add keyword' : 'Add user',
        onTap: () => _edit(
          PingRule(id: '', kind: kind, wordBoundary: keywords),
          isNew: true,
        ),
      ),
    ];
  }

  List<Widget> _eventSection(List<PingRule> rules) {
    final badgesOn = rules
        .where((r) => r.kind == PingRuleKind.badge && r.enabled)
        .map((r) => _badgeLabel(r.pattern))
        .toList();
    return [
      const SettingsSectionHeader('Events'),
      for (final type in const ['firstMsg', 'redemption', 'elevated'])
        ...rules
            .where((r) => r.kind == PingRuleKind.message && r.type == type)
            .map((r) => _RuleTile(rule: r, onTap: () => _edit(r))),
      SettingAnchor(
        Setting.badges,
        child: ListTile(
          leading: const SizedBox(
            width: 28,
            child: Icon(Icons.shield_outlined),
          ),
          title: Text(Setting.badges.title),
          subtitle: Text(badgesOn.isEmpty ? 'None' : badgesOn.join(', ')),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) =>
                  _BadgesPage(opacity: _opacity, recent: _recentMessages()),
            ),
          ),
        ),
      ),
    ];
  }

  List<Widget> _muteSection(List<PingRule> rules) => [
    SettingAnchor(
      Setting.dontHighlight,
      child: SettingsSectionHeader(Setting.dontHighlight.title),
    ),
    const _Caption('Shown, but never highlighted or notified.'),
    for (final r in rules.where((r) => r.kind == PingRuleKind.blacklist))
      _RuleTile(rule: r, onTap: () => _edit(r)),
    _AddTile(
      'Add user',
      onTap: () => _edit(
        const PingRule(id: '', kind: PingRuleKind.blacklist),
        isNew: true,
      ),
    ),
    SettingAnchor(
      Setting.ignores,
      child: SettingsNavTile(
        icon: Icons.visibility_off_outlined,
        title: Setting.ignores.title,
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const IgnoresScreen()),
        ),
      ),
    ),
  ];

  List<Widget> _appearanceSection() {
    final surface = Theme.of(context).scaffoldBackgroundColor;
    final tinted = highlightRowColor(
      const HighlightState(types: {HighlightType.username}),
      surface,
      opacity: _opacity,
    );
    return [
      const SettingsSectionHeader('Appearance'),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
        child: DecoratedBox(
          decoration: BoxDecoration(
            border: Border.all(
              color: Theme.of(context).colorScheme.outlineVariant,
            ),
            borderRadius: BorderRadius.circular(12),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Column(
              children: [
                for (final (i, words) in _previewLines.indexed)
                  _ChatLine(
                    'viewer${i + 1}',
                    _ermSpans(words),
                    color: i == 1 ? tinted : surface,
                  ),
              ],
            ),
          ),
        ),
      ),
      SettingAnchor(
        Setting.highlightStrength,
        child: PrefsSliderTile(
          label: (v) =>
              '${Setting.highlightStrength.title}: ${(v * 100).round()}%',
          min: 0,
          max: 1,
          divisions: 5,
          defaultValue: 0.6,
          read: (p) => p.highlightOpacity,
          write: (p, v) => p.setHighlightOpacity(v),
          onChanged: (v) => setState(() => _opacity = v),
        ),
      ),
    ];
  }
}

/// Two to six words, each an Erm emote one time in three, at least one emote.
List<bool> _rollErmLine(Random rng) {
  final words = List.generate(2 + rng.nextInt(5), (_) => rng.nextInt(3) == 0);
  if (!words.contains(true)) words[rng.nextInt(words.length)] = true;
  return words;
}

List<InlineSpan> _ermSpans(List<bool> words) => [
  for (final (i, emote) in words.indexed) ...[
    if (i > 0) const TextSpan(text: ' '),
    emote
        ? WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: Image.asset(
              'assets/erm_emote.png',
              width: 24,
              height: 24,
              filterQuality: FilterQuality.medium,
            ),
          )
        : const TextSpan(text: 'erm'),
  ],
];

/// Badge presets live on their own page: eight rows would bury the rest.
class _BadgesPage extends ConsumerWidget {
  const _BadgesPage({required this.opacity, required this.recent});

  final double opacity;
  final List<TwitchMessage> recent;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final manager = ref.watch(pingManagerProvider);
    return SettingsPage(
      title: const Text('Badges'),
      body: ListenableBuilder(
        listenable: manager,
        builder: (context, _) => ListView(
          padding: const EdgeInsets.symmetric(vertical: 8),
          children: [
            for (final r in manager.rules.where(
              (r) => r.kind == PingRuleKind.badge,
            ))
              _RuleTile(
                rule: r,
                onTap: () => _editRule(
                  context,
                  manager,
                  r,
                  recent: recent,
                  opacity: opacity,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _Caption extends StatelessWidget {
  const _Caption(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
      child: Text(
        text,
        style: theme.textTheme.bodyMedium?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

class _AddTile extends StatelessWidget {
  const _AddTile(this.label, {required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.primary;
    return ListTile(
      leading: SizedBox(width: 28, child: Icon(Icons.add, color: color)),
      title: Text(label, style: TextStyle(color: color)),
      onTap: onTap,
    );
  }
}

/// One rule: tint swatch, name (with a bell when it notifies), on/off. The
/// switch is the only control; notifying is set in the rule's editor.
class _RuleTile extends ConsumerWidget {
  const _RuleTile({required this.rule, required this.onTap, this.pushOn});

  final PingRule rule;
  final VoidCallback onTap;

  /// Null hides the bell (tint-only rules, or no push on this platform);
  /// false dims it because notifications are switched off.
  final bool? pushOn;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final muted = rule.kind == PingRuleKind.blacklist;
    final subtitle = _ruleSubtitle(rule);
    final pushOn = this.pushOn;
    final tile = ListTile(
      leading: SizedBox(
        width: 28,
        child: muted
            ? Icon(Icons.block, color: scheme.onSurfaceVariant)
            : Center(
                child: Container(
                  width: 22,
                  height: 22,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _ruleTint(context, rule, rule.colorArgb, 1),
                    border: Border.all(color: scheme.outlineVariant),
                  ),
                ),
              ),
      ),
      title: Row(
        children: [
          Flexible(child: Text(_ruleTitle(rule))),
          if (pushOn != null && rule.notify) ...[
            const SizedBox(width: 6),
            Icon(
              Icons.notifications_active,
              size: 16,
              semanticLabel: 'Notifies',
              color: pushOn ? scheme.primary : scheme.onSurfaceVariant,
            ),
          ],
        ],
      ),
      subtitle: subtitle == null ? null : Text(subtitle),
      trailing: Switch(
        value: rule.enabled,
        onChanged: (v) {
          final manager = ref.read(pingManagerProvider);
          manager.upsertRule(rule.copyWith(enabled: v));
          manager.save();
        },
      ),
      onTap: onTap,
    );
    // Builtin rows are searchable settings; user-made rules are not.
    final setting = rule.kind == PingRuleKind.message
        ? _builtinSettings[rule.type]
        : null;
    return setting == null ? tile : SettingAnchor(setting, child: tile);
  }
}

/// A chat-shaped line used by the tint preview and the editor's matches.
class _ChatLine extends StatelessWidget {
  const _ChatLine(this.name, this.body, {required this.color});

  final String name;
  final List<InlineSpan> body;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: color,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Text.rich(
        TextSpan(
          children: [
            TextSpan(
              text: '$name: ',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            ...body,
          ],
        ),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}

/// [text] with each of [marks] styled, e.g. the keyword a rule caught.
List<InlineSpan> _markedSpans(
  String text,
  Iterable<Match> marks, {
  TextStyle style = const TextStyle(fontWeight: FontWeight.bold),
}) {
  final spans = <InlineSpan>[];
  var at = 0;
  for (final m in marks) {
    if (m.start < at || m.end == m.start) continue;
    spans
      ..add(TextSpan(text: text.substring(at, m.start)))
      ..add(TextSpan(text: m[0], style: style));
    at = m.end;
  }
  spans.add(TextSpan(text: text.substring(at)));
  return spans;
}

/// Builtin message rules as searchable settings; their names come from here.
const _builtinSettings = {
  'username': Setting.myUsername,
  'reply': Setting.repliesToMe,
  'thread': Setting.threadsImIn,
  'firstMsg': Setting.firstMessages,
  'redemption': Setting.redemptions,
  'elevated': Setting.hypeChat,
};

/// Editor notes for the builtins whose names undersell what they catch.
const _builtinNotes = {
  'redemption': 'Includes highlighted messages.',
  'elevated': 'Paid messages pinned to chat.',
};

String _badgeLabel(String id) => switch (id) {
  'vip' => 'VIP',
  '' => id,
  _ => id[0].toUpperCase() + id.substring(1),
};

String _ruleTitle(PingRule rule) => switch (rule.kind) {
  PingRuleKind.message when rule.type != 'custom' =>
    _builtinSettings[rule.type]?.title ?? rule.type,
  PingRuleKind.badge => _badgeLabel(rule.pattern),
  PingRuleKind.user || PingRuleKind.blacklist => '@${rule.pattern}',
  _ => rule.pattern,
};

/// Only what differs from the defaults (whole word, @mentions).
String? _ruleSubtitle(PingRule rule) {
  if (!_isListRule(rule)) return null;
  final parts = [
    if (rule.kind == PingRuleKind.message && !rule.wordBoundary) 'Anywhere',
    if (!rule.mention) 'Highlight only',
  ];
  return parts.isEmpty ? null : parts.join(' · ');
}

HighlightType _typeOf(PingRule rule) => switch (rule.kind) {
  PingRuleKind.user => HighlightType.user,
  PingRuleKind.badge => HighlightType.badge,
  _ => switch (rule.type) {
    'username' => HighlightType.username,
    'reply' || 'thread' => HighlightType.reply,
    'redemption' => HighlightType.redemption,
    'firstMsg' => HighlightType.firstMsg,
    'elevated' => HighlightType.elevated,
    _ => HighlightType.custom,
  },
};

/// The row color chat would paint for [rule] with [colorArgb].
Color _ruleTint(
  BuildContext context,
  PingRule rule,
  int? colorArgb,
  double opacity,
) => highlightRowColor(
  HighlightState(
    types: {_typeOf(rule)},
    customColor: colorArgb == null ? null : Color(colorArgb),
  ),
  Theme.of(context).scaffoldBackgroundColor,
  opacity: opacity,
);

bool _isListRule(PingRule rule) =>
    rule.kind == PingRuleKind.user ||
    (rule.kind == PingRuleKind.message && rule.type == 'custom');

/// Mention-tier rules may notify; list rules only while not tint-only.
bool _canNotify(PingRule rule) => _isListRule(rule)
    ? rule.mention
    : rule.kind == PingRuleKind.message &&
          const {'username', 'reply', 'thread'}.contains(rule.type);

typedef _Saved = ({PingRule rule, bool deleted});

/// Opens the rule editor and applies the result. Returns what was saved, or
/// null when the editor was closed.
Future<_Saved?> _editRule(
  BuildContext context,
  PingManager manager,
  PingRule rule, {
  bool isNew = false,
  required List<TwitchMessage> recent,
  required double opacity,
}) async {
  // Typing gets a full page so the keyboard never covers the form; the rest
  // fit a sheet.
  final typed = _isListRule(rule) || rule.kind == PingRuleKind.blacklist;
  PingRule apply(_EditResult r) => rule.copyWith(
    pattern: r.pattern,
    wordBoundary: r.wholeWord,
    mention: r.mention,
    notify: r.notify,
    colorArgb: r.colorArgb,
    clearColor: r.colorArgb == null,
  );
  // Existing rules save on every change; this tracks the last one written.
  PingRule? live;
  Widget editor(_) => _RuleEditor(
    rule: rule,
    isNew: isNew,
    recent: recent,
    opacity: opacity,
    sheet: !typed,
    onLiveChange: isNew
        ? null
        : (r) {
            live = apply(r);
            manager.upsertRule(live!);
            manager.save();
          },
  );
  final result = typed
      ? await Navigator.push<_EditResult>(
          context,
          // A new rule is a draft (close discards it); an edit is already
          // saved, so it gets a plain back arrow.
          MaterialPageRoute(fullscreenDialog: isNew, builder: editor),
        )
      : await showModalBottomSheet<_EditResult>(
          context: context,
          isScrollControlled: true,
          useSafeArea: true,
          showDragHandle: true,
          builder: editor,
        );
  if (result != null && result.delete) {
    manager.removeRule(rule.id);
    manager.save();
    return (rule: rule, deleted: true);
  }
  if (!isNew) {
    final saved = live;
    return saved == null ? null : (rule: saved, deleted: false);
  }
  if (result == null) return null;
  final edited = apply(result);
  final saved = PingRule(
    id: DateTime.now().microsecondsSinceEpoch.toString(),
    kind: edited.kind,
    type: edited.type,
    pattern: edited.pattern,
    wordBoundary: edited.wordBoundary,
    mention: edited.mention,
    notify: edited.notify,
    colorArgb: edited.colorArgb,
  );
  manager.upsertRule(saved);
  manager.save();
  return (rule: saved, deleted: false);
}

class _EditResult {
  const _EditResult({
    this.pattern = '',
    this.wholeWord = false,
    this.mention = true,
    this.notify = false,
    this.colorArgb,
    this.delete = false,
  });

  final String pattern;
  final bool wholeWord;
  final bool mention;
  final bool notify;
  final int? colorArgb;
  final bool delete;
}

/// How far a keyword or user rule reaches.
enum _Effect { tint, mention, notify }

/// Rule editor, as a page or a sheet. Owns its TextEditingController and
/// disposes it in [dispose], which only runs after the route has fully exited.
class _RuleEditor extends StatefulWidget {
  const _RuleEditor({
    required this.rule,
    required this.isNew,
    required this.recent,
    required this.opacity,
    required this.sheet,
    this.onLiveChange,
  });

  final PingRule rule;
  final bool isNew;
  final List<TwitchMessage> recent;
  final double opacity;

  /// Bottom-sheet chrome instead of a full page.
  final bool sheet;

  /// Set when editing an existing rule: every change persists at once, so
  /// there is no Save. New rules still need Add to be created.
  final ValueChanged<_EditResult>? onLiveChange;

  @override
  State<_RuleEditor> createState() => _RuleEditorState();
}

class _RuleEditorState extends State<_RuleEditor> {
  static const _colorChoices = <int>[
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
  late bool _wholeWord = widget.rule.wordBoundary;
  late bool _notify = widget.rule.notify;
  late _Effect _effect = !widget.rule.mention
      ? _Effect.tint
      : widget.rule.notify && _pushSupported
      ? _Effect.notify
      : _Effect.mention;
  late int? _color = widget.rule.colorArgb;

  PingRule get _rule => widget.rule;
  bool get _isKeyword =>
      _rule.kind == PingRuleKind.message && _rule.type == 'custom';
  bool get _isUserList =>
      _rule.kind == PingRuleKind.user || _rule.kind == PingRuleKind.blacklist;
  bool get _hasPattern => _isKeyword || _isUserList;
  bool get _hasColor => _rule.kind != PingRuleKind.blacklist;
  bool get _canDelete => !widget.isNew && _hasPattern;

  /// Usernames drop a typed `@` and compare lowercase, like IRC logins.
  String get _pattern {
    final raw = _patternCtrl.text.trim();
    if (!_isUserList) return raw;
    return (raw.startsWith('@') ? raw.substring(1) : raw).toLowerCase();
  }

  String get _title => switch (_rule.kind) {
    PingRuleKind.message when _isKeyword =>
      widget.isNew ? 'New keyword' : 'Edit keyword',
    PingRuleKind.user ||
    PingRuleKind.blacklist => widget.isNew ? 'New user' : 'Edit user',
    _ => _ruleTitle(_rule),
  };

  @override
  void dispose() {
    _patternCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodyMedium?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final description = _builtinNotes[_rule.type];
    final canSave = !_hasPattern || _pattern.isNotEmpty;
    final saveLabel = Text(widget.isNew ? 'Add' : 'Save');
    final sheet = widget.sheet;
    final body = SafeArea(
      top: false,
      child: ListView(
        shrinkWrap: sheet,
        padding: EdgeInsets.fromLTRB(24, sheet ? 0 : 16, 24, sheet ? 24 : 32),
        children: [
          if (sheet) ...[
            Text(_title, style: theme.textTheme.titleLarge),
            const SizedBox(height: 4),
          ],
          if (description != null) Text(description, style: muted),
          if (_hasPattern)
            TextField(
              controller: _patternCtrl,
              autofocus: widget.isNew,
              autocorrect: !_isUserList,
              textInputAction: TextInputAction.done,
              onChanged: (_) => _set(() {}),
              onSubmitted: (_) =>
                  widget.isNew && canSave ? _save() : Navigator.pop(context),
              decoration: InputDecoration(
                labelText: _isKeyword ? 'Word or phrase' : 'Username',
                prefixText: _isUserList ? '@' : null,
                border: const OutlineInputBorder(),
              ),
            ),
          if (_isKeyword) ...[
            const SizedBox(height: 16),
            SegmentedButton<bool>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: true, label: Text('Whole word')),
                ButtonSegment(value: false, label: Text('Anywhere')),
              ],
              selected: {_wholeWord},
              onSelectionChanged: (s) => _set(() => _wholeWord = s.first),
            ),
            const SizedBox(height: 12),
            _matchExample(theme),
          ],
          if (_isListRule(_rule)) ...[
            const SizedBox(height: 20),
            RadioGroup<_Effect>(
              groupValue: _effect,
              onChanged: (v) => _set(() => _effect = v ?? _effect),
              child: Column(
                children: [
                  const RadioListTile(
                    contentPadding: EdgeInsets.zero,
                    value: _Effect.tint,
                    title: Text('Highlight only'),
                  ),
                  const RadioListTile(
                    contentPadding: EdgeInsets.zero,
                    value: _Effect.mention,
                    title: Text('Add to @mentions'),
                  ),
                  if (_pushSupported)
                    const RadioListTile(
                      contentPadding: EdgeInsets.zero,
                      value: _Effect.notify,
                      title: Text('Add to @mentions and notify'),
                    ),
                ],
              ),
            ),
          ] else if (_pushSupported && _canNotify(_rule)) ...[
            const SizedBox(height: 16),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              secondary: const Icon(Icons.notifications_outlined),
              title: const Text('Send a notification'),
              value: _notify,
              onChanged: (v) => _set(() => _notify = v),
            ),
          ],
          if (_hasColor) ...[
            const SizedBox(height: 28),
            Row(
              children: [
                Text('Color', style: theme.textTheme.titleSmall),
                const Spacer(),
                if (_color != null)
                  TextButton(
                    onPressed: () => _set(() => _color = null),
                    child: const Text('Use default'),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [for (final c in _colorChoices) _swatch(c)],
            ),
          ],
          if (_hasPreview) ...[
            const SizedBox(height: 32),
            _preview(theme, muted),
          ],
          if (_canDelete) ...[
            const SizedBox(height: 40),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: theme.colorScheme.error,
                  side: BorderSide(color: theme.colorScheme.error),
                ),
                icon: const Icon(Icons.delete_outline),
                label: const Text('Delete'),
                onPressed: () =>
                    Navigator.pop(context, const _EditResult(delete: true)),
              ),
            ),
          ],
          if (widget.sheet && widget.isNew) ...[
            const SizedBox(height: 28),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton(onPressed: _save, child: saveLabel),
            ),
          ],
        ],
      ),
    );
    if (sheet) return body;
    return Scaffold(
      appBar: AppBar(
        title: Text(_title),
        actions: [
          if (widget.isNew)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: TextButton(
                onPressed: canSave ? _save : null,
                child: saveLabel,
              ),
            ),
        ],
      ),
      body: body,
    );
  }

  Widget _swatch(int c) {
    final selected = _color == c;
    // Material clips the ripple to the swatch circle.
    return Semantics(
      selected: selected,
      button: true,
      child: Material(
        color: Color(c),
        shape: CircleBorder(
          side: selected
              ? BorderSide(
                  color: Theme.of(context).colorScheme.onSurface,
                  width: 3,
                )
              : BorderSide.none,
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => _set(() => _color = c),
          child: SizedBox(
            width: 36,
            height: 36,
            child: selected
                ? const Icon(Icons.check, size: 18, color: Colors.black87)
                : null,
          ),
        ),
      ),
    );
  }

  /// One sample line run through the real matcher, so switching modes shows
  /// exactly which part of it lights up.
  Widget _matchExample(ThemeData theme) {
    final t = _pattern.isEmpty ? 'pog' : _pattern;
    final sample = '$t ${t}gers ${t}champ';
    final re = PingManager.keywordRegExp(t, wholeWord: _wholeWord);
    final scheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text.rich(
        TextSpan(
          children: _markedSpans(
            sample,
            re.allMatches(sample),
            style: TextStyle(
              fontWeight: FontWeight.bold,
              color: scheme.onPrimaryContainer,
              backgroundColor: scheme.primaryContainer,
            ),
          ),
        ),
      ),
    );
  }

  /// Builtins depend on who is signed in, so only list rules preview.
  bool get _hasPreview => _hasPattern || _rule.kind == PingRuleKind.badge;

  Widget _preview(ThemeData theme, TextStyle? muted) {
    final recent = widget.recent;
    final pattern = _rule.kind == PingRuleKind.badge ? _rule.pattern : _pattern;
    if (pattern.isEmpty) return const SizedBox.shrink();
    if (recent.isEmpty) return Text('No recent messages', style: muted);
    final keyword = _isKeyword
        ? PingManager.keywordRegExp(pattern, wholeWord: _wholeWord)
        : null;
    bool hits(TwitchMessage m) => switch (_rule.kind) {
      PingRuleKind.badge =>
        m.badges?.any((b) => b.setId.toLowerCase() == pattern) ?? false,
      PingRuleKind.user ||
      PingRuleKind.blacklist => m.login.toLowerCase() == pattern,
      _ => keyword!.hasMatch(m.text),
    };
    final matches = recent.where(hits).toList();
    final color = _hasColor
        ? _ruleTint(context, _rule, _color, widget.opacity)
        : theme.colorScheme.surfaceContainerHigh;
    final n = matches.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          n == 0
              ? 'No recent matches'
              : '$n recent ${n == 1 ? 'match' : 'matches'}',
          style: n == 0 ? muted : theme.textTheme.titleSmall,
        ),
        if (n > 0) ...[
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Column(
              children: [
                for (final m in matches.take(3))
                  _ChatLine(
                    m.displayName,
                    keyword == null
                        ? [TextSpan(text: m.text)]
                        : _markedSpans(m.text, keyword.allMatches(m.text)),
                    color: color,
                  ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  _EditResult _result() {
    final listRule = _isListRule(_rule);
    return _EditResult(
      pattern: _hasPattern ? _pattern : _rule.pattern,
      wholeWord: _wholeWord,
      mention: listRule ? _effect != _Effect.tint : _rule.mention,
      notify: listRule ? _effect == _Effect.notify : _notify,
      colorArgb: _color,
    );
  }

  /// Applies an edit and, for an existing rule, persists it right away. An
  /// emptied pattern waits until it has text again.
  void _set(VoidCallback change) {
    setState(change);
    final live = widget.onLiveChange;
    if (live != null && (!_hasPattern || _pattern.isNotEmpty)) live(_result());
  }

  void _save() => Navigator.pop(context, _result());
}
