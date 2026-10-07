import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../color_utils.dart' show highlightRowColor;
import '../../l10n/l10n.dart';
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

  /// Rebuilds when a timed pause runs out, so the rows un-pause on screen.
  Timer? _resumeTimer;

  @override
  void initState() {
    super.initState();
    _loadPrefs();
    PrefsStore.instance.addListener(_loadPrefs);
    _scheduleResumeRebuild();
  }

  @override
  void dispose() {
    _resumeTimer?.cancel();
    PrefsStore.instance.removeListener(_loadPrefs);
    super.dispose();
  }

  void _scheduleResumeRebuild() {
    _resumeTimer?.cancel();
    final until = ref.read(notificationPauseProvider);
    if (until == null) return;
    final left = until.difference(DateTime.now());
    if (left.isNegative) return;
    _resumeTimer = Timer(left, () {
      if (mounted) setState(() {});
    });
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
      final removed = rule.kind == PingRuleKind.message
          ? context.l10n.keywordRemoved
          : context.l10n.userRemoved;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(removed),
          action: SnackBarAction(
            label: context.l10n.undo,
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
    ref.watch(notificationPauseProvider);
    final muted = ref.read(notificationPauseProvider.notifier).paused;
    // Rules keep their notify setting; the bells show it's silenced.
    final paused = !pushOn || muted;
    return SettingsPage(
      title: Text(context.l10n.pageHighlights),
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
              if (_pushSupported) _notificationsTile(pushOn, muted),
              ..._mentionSection(rules, paused, pushOn),
              ..._listSection(rules, paused, PingRuleKind.message),
              ..._listSection(rules, paused, PingRuleKind.user),
              ..._eventSection(rules),
              ..._muteSection(rules),
              ..._appearanceSection(),
            ],
          );
        },
      ),
    );
  }

  /// Zero is "Nevermind": letting go there leaves notifications as they were.
  static const _muteSteps = [
    Duration.zero,
    Duration(minutes: 15),
    Duration(minutes: 30),
    Duration(hours: 1),
    Duration(hours: 2),
    Duration(hours: 4),
    Duration(hours: 8),
    Duration(hours: 12),
  ];
  static const _defaultMute = 3;

  /// Step under the finger while the moon is held, else null.
  int? _muteDrag;
  final _muteRow = GlobalKey();

  /// Inset of the mute slider's track from the row's edges.
  static const _muteInset = 16.0;

  static String _muteLabel(AppLocalizations l, Duration d) => d.inMinutes < 60
      ? l.durationMinutes(d.inMinutes)
      : l.durationHours(d.inHours);

  void _mute(Duration d) {
    ref.read(notificationPauseProvider.notifier).pauseFor(d);
    _scheduleResumeRebuild();
  }

  /// Puts the held mute slider's thumb under the finger.
  void _dragMute(double x) {
    final box = _muteRow.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final width = box.size.width - 2 * _muteInset;
    final along = box.globalToLocal(Offset(x, 0)).dx - _muteInset;
    final next = (along / width * (_muteSteps.length - 1)).round().clamp(
      0,
      _muteSteps.length - 1,
    );
    if (next == _muteDrag) return;
    HapticFeedback.selectionClick();
    setState(() => _muteDrag = next);
  }

  /// The held moon's slider, laid over the hidden row. It fades in as the
  /// mute gets longer.
  Widget _muteSlider(int drag) {
    final d = _muteSteps[drag];
    final last = _muteSteps.length - 1;
    return IgnorePointer(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: _muteInset),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              d == Duration.zero
                  ? context.l10n.muteNevermind
                  : context.l10n.muteFor(_muteLabel(context.l10n, d)),
              style: Theme.of(context).textTheme.bodyLarge,
            ),
            Opacity(
              opacity: 0.4 + 0.6 * drag / last,
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  padding: EdgeInsets.zero,
                  showValueIndicator: ShowValueIndicator.never,
                ),
                child: Slider(
                  value: drag.toDouble(),
                  max: last.toDouble(),
                  divisions: last,
                  onChanged: (_) {},
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Master switch for rule and whisper notifications, plus a moon that
  /// mutes them for a while: tap for an hour, hold and slide to choose.
  /// Neither changes the rules. The row keeps one height in every state.
  Widget _notificationsTile(bool pushOn, bool muted) {
    final pause = ref.read(notificationPauseProvider.notifier);
    final until = ref.read(notificationPauseProvider);
    final scheme = Theme.of(context).colorScheme;
    final showMute = pushOn && muted && until != null;
    final canMute = _keepAlive && pushOn;
    final drag = _muteDrag;
    final String status;
    if (!pushOn) {
      status = context.l10n.off;
    } else if (showMute) {
      final time = MaterialLocalizations.of(
        context,
      ).formatTimeOfDay(TimeOfDay.fromDateTime(until.toLocal()));
      status = context.l10n.mutedUntil(time);
    } else {
      status = context.l10n.on;
    }
    // The moon keeps its place in the tree while held, or the hold would end.
    final moon = GestureDetector(
      onLongPressStart: canMute
          ? (d) {
              HapticFeedback.mediumImpact();
              _dragMute(d.globalPosition.dx);
            }
          : null,
      onLongPressMoveUpdate: canMute
          ? (d) => _dragMute(d.globalPosition.dx)
          : null,
      onLongPressEnd: canMute
          ? (_) {
              final i = _muteDrag;
              setState(() => _muteDrag = null);
              if (i != null && i > 0) _mute(_muteSteps[i]);
            }
          : null,
      onLongPressCancel: () => setState(() => _muteDrag = null),
      child: Semantics(
        button: true,
        label: showMute ? context.l10n.unmute : context.l10n.muteForHour,
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: !canMute
              ? null
              : showMute
              ? pause.resume
              : () => _mute(_muteSteps[_defaultMute]),
          child: SizedBox.square(
            dimension: 48,
            child: Icon(
              showMute || drag != null ? Icons.bedtime : Icons.bedtime_outlined,
              color: !canMute
                  ? scheme.onSurface.withValues(alpha: 0.38)
                  : showMute || drag != null
                  ? scheme.primary
                  : scheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
    return SettingAnchor(
      Setting.notifications,
      child: _blockedTap(
        _keepAlive ? null : _keepAliveSnack,
        SizedBox(
          key: _muteRow,
          height: 72,
          // While the moon is held the row hides under the slider but stays
          // laid out, so nothing shifts and the hold keeps its gesture.
          child: Stack(
            children: [
              Opacity(
                opacity: drag == null ? 1 : 0,
                child: ListTile(
                  enabled: _keepAlive,
                  leading: const SizedBox(
                    width: 28,
                    child: Icon(Icons.notifications_outlined),
                  ),
                  title: Text(Setting.notifications.titleOf(context.l10n)),
                  subtitle: Text(status),
                  onTap: () => _setPush(!pushOn),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      moon,
                      Switch(
                        value: pushOn,
                        onChanged: _keepAlive ? _setPush : null,
                      ),
                    ],
                  ),
                ),
              ),
              if (drag != null) Positioned.fill(child: _muteSlider(drag)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _tile(PingRule r, bool paused) => _RuleTile(
    rule: r,
    paused: paused,
    levels: _pushSupported && _canNotify(r) ? 4 : 2,
    onLevel: (level) => _setLevel(r, level),
    onBlocked: _keepAlive ? null : _keepAliveSnack,
    onTap: () => _edit(r),
  );

  void _setLevel(PingRule rule, int level) {
    _manager.upsertRule(_withLevel(rule, level));
    _manager.save();
    if (level >= 2) _ensurePush();
  }

  /// Notifications only arrive while the background connection runs, so
  /// without it notifying controls are greyed and a tap says what to turn on.
  void _keepAliveSnack() => ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(context.l10n.notificationsNeedBackground),
        action: SnackBarAction(
          label: context.l10n.turnOn,
          onPressed: _enableKeepAlive,
        ),
      ),
    );

  void _masterOffSnack() => ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(context.l10n.notificationsOff),
        action: SnackBarAction(
          label: context.l10n.turnOn,
          onPressed: () => _setPush(true),
        ),
      ),
    );

  /// Wraps a greyed tile so a tap explains what to turn on; a null
  /// [onBlocked] leaves the tile as is.
  Widget _blockedTap(VoidCallback? onBlocked, Widget tile) {
    if (onBlocked == null) return tile;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onBlocked,
      child: tile,
    );
  }

  List<Widget> _mentionSection(
    List<PingRule> rules,
    bool paused,
    bool pushOn,
  ) => [
    SettingsSectionHeader(context.l10n.sectionMentions),
    for (final type in const ['username', 'reply', 'thread'])
      ...rules
          .where((r) => r.kind == PingRuleKind.message && r.type == type)
          .map((r) => _tile(r, paused)),
    if (_pushSupported)
      SettingAnchor(
        Setting.whisperPush,
        child: _blockedTap(
          !_keepAlive
              ? _keepAliveSnack
              : pushOn
              ? null
              : _masterOffSnack,
          PrefsSwitchTile(
            secondary: const Icon(Icons.mail_outline),
            title: Setting.whisperPush.titleOf(context.l10n),
            enabled: _keepAlive && pushOn,
            read: (p) => p.whisperNotifications,
            write: (p, v) => p.setWhisperNotifications(v),
            onChanged: widget.onWhisperNotifyChanged,
          ),
        ),
      ),
  ];

  List<Widget> _listSection(
    List<PingRule> rules,
    bool paused,
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
        _tile(r, paused),
      _AddTile(
        keywords ? context.l10n.addKeyword : context.l10n.addUser,
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
      SettingsSectionHeader(context.l10n.sectionEvents),
      for (final type in const ['firstMsg', 'redemption', 'elevated'])
        ...rules
            .where((r) => r.kind == PingRuleKind.message && r.type == type)
            .map((r) => _tile(r, false)),
      SettingAnchor(
        Setting.badges,
        child: ListTile(
          leading: const SizedBox(
            width: 28,
            child: Icon(Icons.shield_outlined),
          ),
          title: Text(Setting.badges.titleOf(context.l10n)),
          subtitle: Text(
            badgesOn.isEmpty ? context.l10n.none : badgesOn.join(', '),
          ),
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
      child: SettingsSectionHeader(Setting.dontHighlight.titleOf(context.l10n)),
    ),
    _Caption(context.l10n.dontHighlightCaption),
    for (final r in rules.where((r) => r.kind == PingRuleKind.blacklist))
      _tile(r, false),
    _AddTile(
      context.l10n.addUser,
      onTap: () => _edit(
        const PingRule(id: '', kind: PingRuleKind.blacklist),
        isNew: true,
      ),
    ),
    SettingAnchor(
      Setting.ignores,
      child: SettingsNavTile(
        icon: Icons.visibility_off_outlined,
        title: Setting.ignores.titleOf(context.l10n),
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
      SettingsSectionHeader(context.l10n.sectionAppearance),
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
              '${Setting.highlightStrength.titleOf(context.l10n)}: ${(v * 100).round()}%',
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
      title: Text(context.l10n.badgesTitle),
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

/// One rule: color swatch, name, and a level switch. Tapping opens the editor.
class _RuleTile extends ConsumerWidget {
  const _RuleTile({
    required this.rule,
    required this.onTap,
    this.levels = 2,
    this.paused = false,
    this.onLevel,
    this.onBlocked,
  });

  final PingRule rule;
  final VoidCallback onTap;

  /// Notifications are paused: the notify stop shows a crossed-out bell.
  final bool paused;

  /// 4 adds the notify stops; see [_LevelSwitch].
  final int levels;

  /// Null writes plain on/off straight to the manager.
  final ValueChanged<int>? onLevel;
  final VoidCallback? onBlocked;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final muted = rule.kind == PingRuleKind.blacklist;
    final subtitle = _ruleSubtitle(context.l10n, rule);
    // An off rule greys everything but its switch.
    final dim = rule.enabled ? 1.0 : 0.38;
    final tile = ListTile(
      leading: Opacity(
        opacity: dim,
        child: SizedBox(
          width: 28,
          child: muted
              ? Icon(Icons.block, color: scheme.onSurfaceVariant)
              : Center(
                  child: Container(
                    width: 22,
                    height: 22,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: rule.tint
                          ? _ruleTint(context, rule, rule.colorArgb, 1)
                          : null,
                      border: Border.all(color: scheme.outlineVariant),
                    ),
                  ),
                ),
        ),
      ),
      title: Opacity(opacity: dim, child: Text(_ruleTitle(context.l10n, rule))),
      subtitle: subtitle == null
          ? null
          : Opacity(opacity: dim, child: Text(subtitle)),
      trailing: _LevelSwitch(
        level: min(_levelOf(rule), levels - 1),
        levels: levels,
        paused: paused,
        color: muted
            ? scheme.primary
            : _ruleTint(context, rule, rule.colorArgb, 1),
        onBlocked: onBlocked,
        onChanged:
            onLevel ??
            (level) {
              final manager = ref.read(pingManagerProvider);
              manager.upsertRule(rule.copyWith(enabled: level > 0));
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
String? _builtinNote(AppLocalizations l, String? type) => switch (type) {
  'redemption' => l.redemptionNote,
  'elevated' => l.elevatedNote,
  _ => null,
};

String _badgeLabel(String id) => switch (id) {
  'vip' => 'VIP',
  '' => id,
  _ => id[0].toUpperCase() + id.substring(1),
};

String _ruleTitle(AppLocalizations l, PingRule rule) => switch (rule.kind) {
  PingRuleKind.message when rule.type != 'custom' =>
    _builtinSettings[rule.type]?.titleOf(l) ?? rule.type,
  PingRuleKind.badge => _badgeLabel(rule.pattern),
  PingRuleKind.user || PingRuleKind.blacklist => '@${rule.pattern}',
  _ => rule.pattern,
};

/// Only what differs from the defaults (whole word, @mentions).
String? _ruleSubtitle(AppLocalizations l, PingRule rule) {
  if (!_isListRule(rule)) return null;
  final parts = [
    if (rule.kind == PingRuleKind.message && !rule.wordBoundary)
      l.matchAnywhere,
    if (!rule.mention) l.highlightOnly,
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

/// Mention-tier builtins and list rules may notify.
bool _canNotify(PingRule rule) =>
    _isListRule(rule) ||
    rule.kind == PingRuleKind.message &&
        const {'username', 'reply', 'thread'}.contains(rule.type);

/// 0 off, 1 highlight, 2 highlight and notify, 3 notify without the tint.
int _levelOf(PingRule rule) => !rule.enabled
    ? 0
    : !(rule.notify && rule.mention)
    ? 1
    : rule.tint
    ? 2
    : 3;

/// Notifying needs the message in @mentions, so the notify levels add it.
PingRule _withLevel(PingRule rule, int level) => rule.copyWith(
  enabled: level > 0,
  notify: level >= 2,
  mention: level >= 2 || rule.mention,
  tint: level != 3,
);

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
    tint: r.tint,
    colorArgb: r.colorArgb,
    clearColor: r.colorArgb == null,
    enabled: r.enabled,
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
    tint: edited.tint,
    enabled: edited.enabled,
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
    this.tint = true,
    this.enabled = true,
    this.colorArgb,
    this.delete = false,
  });

  final String pattern;
  final bool wholeWord;
  final bool mention;
  final bool notify;
  final bool tint;
  final bool enabled;
  final int? colorArgb;
  final bool delete;
}

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

  /// Set on the row's switch, not here; kept so edits write it back as is.
  late final int _level = min(_levelOf(widget.rule), _levels - 1);
  late bool _mention = widget.rule.mention;
  late int? _color = widget.rule.colorArgb;

  PingRule get _rule => widget.rule;
  int get _levels => _pushSupported && _canNotify(_rule) ? 4 : 2;
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
      widget.isNew ? context.l10n.newKeyword : context.l10n.editKeyword,
    PingRuleKind.user || PingRuleKind.blacklist =>
      widget.isNew ? context.l10n.newUser : context.l10n.editUser,
    _ => _ruleTitle(context.l10n, _rule),
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
    final description = _builtinNote(context.l10n, _rule.type);
    final canSave = !_hasPattern || _pattern.isNotEmpty;
    final saveLabel = Text(widget.isNew ? context.l10n.add : context.l10n.save);
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
          const SizedBox(height: 8),
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
                labelText: _isKeyword
                    ? context.l10n.wordOrPhrase
                    : context.l10n.username,
                prefixText: _isUserList ? '@' : null,
                border: const OutlineInputBorder(),
              ),
            ),
          if (_isKeyword) ...[
            const SizedBox(height: 16),
            SegmentedButton<bool>(
              showSelectedIcon: false,
              segments: [
                ButtonSegment(value: true, label: Text(context.l10n.wholeWord)),
                ButtonSegment(
                  value: false,
                  label: Text(context.l10n.matchAnywhere),
                ),
              ],
              selected: {_wholeWord},
              onSelectionChanged: (s) => _set(() => _wholeWord = s.first),
            ),
            const SizedBox(height: 12),
            _matchExample(theme),
          ],
          if (_isListRule(_rule)) ...[
            const SizedBox(height: 16),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(context.l10n.addToMentions),
              subtitle: _level >= 2
                  ? Text(context.l10n.alwaysOnWhileNotifies)
                  : null,
              value: _level >= 2 || _mention,
              // Notifying always adds to @mentions.
              onChanged: _level >= 2 ? null : (v) => _set(() => _mention = v),
            ),
          ],
          if (_hasColor) ...[
            const SizedBox(height: 28),
            Row(
              children: [
                Text(context.l10n.color, style: theme.textTheme.titleSmall),
                const Spacer(),
                if (_color != null)
                  TextButton(
                    onPressed: () => _set(() => _color = null),
                    child: Text(context.l10n.useDefault),
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
                label: Text(context.l10n.delete),
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

  /// One fixed sample line run through the real matcher, so switching modes
  /// shows exactly which part of it lights up.
  Widget _matchExample(ThemeData theme) {
    const sample = 'pog poggers pogchamp';
    final re = PingManager.keywordRegExp('pog', wholeWord: _wholeWord);
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
    if (recent.isEmpty) {
      return Text(context.l10n.noRecentMessages, style: muted);
    }
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
    // Notify only leaves chat untinted, so its matches preview plain.
    final color = _hasColor && _level != 3
        ? _ruleTint(context, _rule, _color, widget.opacity)
        : theme.colorScheme.surfaceContainerHigh;
    final n = matches.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          context.l10n.recentMatches(n),
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
      mention: listRule ? _level >= 2 || _mention : _rule.mention,
      notify: _levels > 2 ? _level >= 2 : _rule.notify,
      tint: _levels > 2 ? _level != 3 : _rule.tint,
      enabled: _level > 0,
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

/// A switch with optional notify stops: off, highlight, highlight and
/// notify, and notify only. Once on, the track takes the rule's color; the
/// notify stops put a bell in the thumb, and notify only drops the color.
/// Tap a stop or drag to it; a bubble names the stop while it moves.
class _LevelSwitch extends StatefulWidget {
  const _LevelSwitch({
    required this.level,
    required this.levels,
    required this.color,
    required this.onChanged,
    this.paused = false,
    this.onBlocked,
  });

  final int level;

  /// 2 (off, on) or 4 (off, highlight, notify, notify only).
  final int levels;
  final Color color;
  final ValueChanged<int> onChanged;

  /// Notifications are paused, so the notify bell is crossed out.
  final bool paused;

  /// Set while notifying needs something else turned on first; picking the
  /// notify stop calls this instead.
  final VoidCallback? onBlocked;

  @override
  State<_LevelSwitch> createState() => _LevelSwitchState();
}

class _LevelSwitchState extends State<_LevelSwitch> {
  static const _height = 32.0;
  static const _pad = 4.0;
  static const _border = 2.0;
  static const _thumb = 24.0;
  static const _offThumb = 16.0;
  static const _duration = Duration(milliseconds: 160);

  final _bubble = OverlayPortalController();
  final _link = LayerLink();
  Timer? _hideBubble;

  int get _level => widget.level;
  int get _levels => widget.levels;
  double get _width => 52 + 32.0 * (_levels - 2);

  String get _name => _nameOf(_level);

  String _nameOf(int level) => switch (level) {
    0 => context.l10n.levelOff,
    1 => context.l10n.levelHighlight,
    _ when widget.paused => context.l10n.levelNotifyMuted,
    2 => context.l10n.levelNotify,
    _ => context.l10n.levelNotifyOnly,
  };

  @override
  void dispose() {
    _hideBubble?.cancel();
    super.dispose();
  }

  /// Shows the bubble on three-stop switches until [linger] after the last
  /// move; a null [linger] keeps it up (mid-drag).
  void _showBubble({Duration? linger = const Duration(milliseconds: 900)}) {
    if (_levels < 3) return;
    _hideBubble?.cancel();
    _bubble.show();
    if (linger != null) {
      _hideBubble = Timer(linger, () {
        if (mounted) _bubble.hide();
      });
    }
  }

  void _pick(int next, {bool dragging = false}) {
    next = next.clamp(0, _levels - 1);
    if (next == _level) return;
    if (next >= 2 && widget.onBlocked != null) {
      widget.onBlocked!();
      return;
    }
    HapticFeedback.selectionClick();
    widget.onChanged(next);
    _showBubble(linger: dragging ? null : const Duration(milliseconds: 900));
  }

  int _stopAt(double dx) =>
      (dx / _width * _levels).floor().clamp(0, _levels - 1);

  /// Thumb center as a fraction of the track, for anchoring the bubble.
  static const _inset = _pad + _border + (_thumb - 4) / 2;

  double _thumbAlign(int level) {
    const inset = _inset;
    final travel = _width - 2 * inset;
    final x = inset + (_levels == 1 ? 0 : level / (_levels - 1) * travel);
    return x / _width * 2 - 1;
  }

  Widget _bubbleBuilder(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Switches sit at the screen's right edge, so at the last stop the bubble
    // grows leftward from the switch's edge instead of centering.
    final last = _level == _levels - 1;
    final anchor = last ? Alignment.bottomRight : Alignment.bottomCenter;
    return CompositedTransformFollower(
      link: _link,
      targetAnchor: last
          ? Alignment.topRight
          : Alignment(_thumbAlign(_level), -1),
      followerAnchor: anchor,
      offset: const Offset(0, -2),
      child: Align(
        alignment: anchor,
        child: IgnorePointer(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: last
                ? CrossAxisAlignment.end
                : CrossAxisAlignment.center,
            children: [
              DecoratedBox(
                decoration: BoxDecoration(
                  color: scheme.inverseSurface,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  child: Text(
                    _name,
                    style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: scheme.onInverseSurface,
                    ),
                  ),
                ),
              ),
              Padding(
                // Keeps the point under the thumb when right-aligned.
                padding: EdgeInsets.only(right: last ? _inset - 5 : 0),
                child: CustomPaint(
                  size: const Size(10, 5),
                  painter: _TailPainter(scheme.inverseSurface),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Notify only shows no color: a neutral track with the bell.
    final plain = _level == 3;
    final color = plain ? scheme.surfaceContainerHighest : widget.color;
    final on = _level > 0;
    final onDark =
        ThemeData.estimateBrightnessForColor(color) == Brightness.dark;
    final thumbColor = !on
        ? scheme.outline
        : plain
        ? scheme.onSurfaceVariant
        : onDark
        ? Colors.white
        : Colors.black87;
    final thumbSize = on ? _thumb : _offThumb;
    final x = _levels == 1 ? 0.0 : _level / (_levels - 1) * 2 - 1;
    final three = _levels > 2;
    final top = _levels - 1;
    return Semantics(
      container: true,
      slider: three,
      toggled: three ? null : on,
      value: three ? _name : null,
      increasedValue: three && _level < top ? _nameOf(_level + 1) : null,
      decreasedValue: three && _level > 0 ? _nameOf(_level - 1) : null,
      onIncrease: three && _level < top ? () => _pick(_level + 1) : null,
      onDecrease: three && _level > 0 ? () => _pick(_level - 1) : null,
      onTap: three ? null : () => _pick(on ? 0 : 1),
      child: OverlayPortal(
        controller: _bubble,
        overlayChildBuilder: _bubbleBuilder,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          // Two stops toggle on any tap, like a plain switch.
          onTapUp: (d) =>
              _pick(three ? _stopAt(d.localPosition.dx) : (on ? 0 : 1)),
          onHorizontalDragStart: (_) => _showBubble(linger: null),
          onHorizontalDragUpdate: (d) =>
              _pick(_stopAt(d.localPosition.dx), dragging: true),
          onHorizontalDragEnd: (_) => _showBubble(),
          onHorizontalDragCancel: _showBubble,
          child: SizedBox(
            width: _width,
            height: 48,
            child: Center(
              child: CompositedTransformTarget(
                link: _link,
                child: AnimatedContainer(
                  duration: _duration,
                  width: _width,
                  height: _height,
                  padding: const EdgeInsets.all(_pad),
                  decoration: BoxDecoration(
                    color: on ? color : scheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(_height / 2),
                    border: Border.all(
                      color: on && !plain ? color : scheme.outline,
                      width: _border,
                    ),
                  ),
                  child: Stack(
                    children: [
                      // Dots mark the stops the thumb isn't on.
                      if (three)
                        for (var i = 0; i < _levels; i++)
                          if (i != _level)
                            Align(
                              alignment: Alignment(
                                i / (_levels - 1) * 2 - 1,
                                0,
                              ),
                              child: SizedBox(
                                width: _thumb - 4,
                                child: Center(
                                  child: Container(
                                    width: 4,
                                    height: 4,
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      color: thumbColor.withValues(alpha: 0.5),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                      AnimatedAlign(
                        duration: _duration,
                        curve: Curves.easeOutCubic,
                        alignment: Alignment(x, 0),
                        child: SizedBox(
                          width: _thumb - 4,
                          height: _thumb - 4,
                          child: OverflowBox(
                            maxWidth: _thumb,
                            maxHeight: _thumb,
                            child: AnimatedContainer(
                              duration: _duration,
                              width: thumbSize,
                              height: thumbSize,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: thumbColor,
                              ),
                              child: _level >= 2
                                  ? Icon(
                                      widget.paused
                                          ? Icons.notifications_off
                                          : Icons.notifications_active,
                                      size: 16,
                                      color: color,
                                    )
                                  : null,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The bubble's downward point.
class _TailPainter extends CustomPainter {
  const _TailPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..moveTo(0, 0)
      ..lineTo(size.width, 0)
      ..lineTo(size.width / 2, size.height)
      ..close();
    canvas.drawPath(path, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_TailPainter old) => old.color != color;
}
