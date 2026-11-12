import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../util/settings.dart';
import '../../widgets/design_tokens.dart';

/// Settings pages a search result can open.
enum SettingsPageId {
  channels('Channels'),
  appearance('Appearance'),
  customLayout('Appearance › Layout › Custom'),
  chat('Chat'),
  inlineEmbeds('Chat › Inline embeds'),
  highlights('Highlights'),
  emotes('Emotes'),
  data('Data'),
  history('History'),
  battery('Battery'),
  tools('Tools'),
  tts('Tools › Text-to-speech'),
  uploader('Tools › Image uploader'),
  account('Account'),
  about('About'),
  language('Language');

  const SettingsPageId(this.label);
  final String label;
}

extension SettingsPageIdL10n on SettingsPageId {
  /// [label] in the app language.
  String labelOf(AppLocalizations l) => switch (this) {
    SettingsPageId.channels => l.pageChannels,
    SettingsPageId.appearance => l.pageAppearance,
    SettingsPageId.customLayout => l.pageCustomLayout,
    SettingsPageId.chat => l.pageChat,
    SettingsPageId.inlineEmbeds => l.pageInlineEmbeds,
    SettingsPageId.highlights => l.pageHighlights,
    SettingsPageId.emotes => l.pageEmotes,
    SettingsPageId.data => l.pageData,
    SettingsPageId.history => l.pageHistory,
    SettingsPageId.battery => l.pageBattery,
    SettingsPageId.tools => l.pageTools,
    SettingsPageId.tts => l.pageTts,
    SettingsPageId.uploader => l.pageUploader,
    SettingsPageId.account => l.pageAccount,
    SettingsPageId.about => l.pageAbout,
    SettingsPageId.language => l.settingLanguage,
  };
}

/// Whether [gate]'s platform has the setting's tile.
bool gateOpen(SettingGate gate) => switch (gate) {
  SettingGate.none => true,
  SettingGate.android => !kIsWeb && Platform.isAndroid,
  SettingGate.notIos => !kIsWeb && !Platform.isIOS,
};

/// A row's title: the English word, which stays searchable in any language,
/// and how to say it in the app's. No accessor means English only, for rows
/// no user-facing page shows.
typedef _Title = (String, String Function(AppLocalizations)?);

/// Titles by row id.
final Map<String, _Title> _titles = {
  // ── Pages opened whole ──────────────────────────────────────────────
  'channels': ('Channels', (l) => l.settingChannels),
  'account': ('Account', (l) => l.settingAccount),
  'about': ('About', (l) => l.settingAbout),
  'language': ('Language', (l) => l.settingLanguage),

  // ── Appearance ──────────────────────────────────────────────────────
  'theme': ('Theme', (l) => l.settingTheme),
  'accent_color': ('Accent color', (l) => l.settingAccentColor),
  'true_dark': ('True dark mode', (l) => l.settingTrueDark),
  'layout': ('Layout', (l) => l.settingLayout),
  'edit_layout': ('Edit layout', (l) => l.settingEditLayout),
  'haptics': ('Haptics', (l) => l.settingHaptics),
  'chat_font_size': ('Chat font size', (l) => l.settingChatFontSize),
  'chat_font_weight': ('Chat font weight', (l) => l.settingChatFontWeight),
  'show_timestamps': ('Show timestamps', (l) => l.settingShowTimestamps),
  'timestamp_format': ('Timestamp format', (l) => l.settingTimestampFormat),
  'checkered': ('Checkered messages', (l) => l.settingCheckered),
  'line_separator': (
    'Separate messages with lines',
    (l) => l.settingLineSeparator,
  ),
  'compact_repeats': (
    'Compact repeated messages',
    (l) => l.settingCompactRepeats,
  ),
  'automod_in_chat': ('Inline AutoMod queue', (l) => l.settingAutomodInChat),
  'keep_screen_on': ('Keep screen on', (l) => l.settingKeepScreenOn),
  'fast_channel_swipe': (
    'Fast channel swipe',
    (l) => l.settingFastChannelSwipe,
  ),
  'reopen_last_channel': (
    'Start on last channel',
    (l) => l.settingReopenLastChannel,
  ),

  // ── Appearance › Layout › Custom ────────────────────────────────────
  'custom_layout': ('Enable custom layout', (l) => l.settingCustomLayout),
  'tighter_composer': ('Tighter composer', (l) => l.settingTighterComposer),
  'horizontal_sheet_actions': (
    'Horizontal sheet actions',
    (l) => l.settingHorizontalSheetActions,
  ),
  'compact_density': ('Compact density', (l) => l.settingCompactDensity),

  // ── Chat ────────────────────────────────────────────────────────────
  'max_messages': ('Max messages per channel', (l) => l.settingMaxMessages),
  'shared_chat': ('Shared chat messages', (l) => l.settingSharedChat),
  'emote_sort_order': ('Emote order', (l) => l.settingEmoteSortOrder),
  'inline_embeds': ('Inline embeds', (l) => l.settingInlineEmbeds),
  'split_links': ('Split links', (l) => l.settingSplitLinks),
  'recent_messages_limit': (
    'Recent messages to load',
    (l) => l.settingRecentMessagesLimit,
  ),
  'recent_messages_source': (
    'Recent messages',
    (l) => l.settingRecentMessagesSource,
  ),
  'gap_fill': ('Dynamic history fetch', (l) => l.settingGapFill),
  'archive_enabled': ('Chat archive', (l) => l.settingArchiveEnabled),
  'lazy_channels': (
    'Connect channels when opened',
    (l) => l.settingLazyChannels,
  ),
  'archive_retention': ('Keep chat for', (l) => l.settingArchiveRetention),
  'archive_channel_cap': (
    'Space per channel',
    (l) => l.settingArchiveChannelCap,
  ),
  'prefer_emotes': (
    'Prefer emote suggestions (autocomplete)',
    (l) => l.settingPreferEmotes,
  ),
  'mention_format': ('Mention format', (l) => l.settingMentionFormat),
  'reply_thread_root': (
    'Reply to thread first message',
    (l) => l.settingReplyThreadRoot,
  ),
  'send_swipe': ('Hold to spam', (l) => l.settingSendSwipe),
  'spam_interval': ('Spam speed', (l) => l.spamSpeed),
  'spam_interval_mod': ('Spam speed', (l) => l.spamSpeedMod),
  'macros': ('Command macros', (l) => l.settingMacros),
  'copy_username': ('Copy username', (l) => l.settingCopyUsername),
  'stay_connected': (
    'Stay connected in background',
    (l) => l.settingStayConnected,
  ),
  'chat_proxy': ('Chat proxy', (l) => l.settingChatProxy),

  // ── Chat › Inline embeds ────────────────────────────────────────────
  'show_giphy': ('Show Giphy inline', (l) => l.settingShowGiphy),
  'giphy_height': ('Giphy height', (l) => l.settingGiphyHeight),
  'show_images': ('Show images inline', (l) => l.settingShowImages),
  'image_height': ('Image height', (l) => l.settingImageHeight),
  'image_hosts': ('Image hosts', (l) => l.imageHosts),

  // ── Highlights ──────────────────────────────────────────────────────
  'notifications': ('Notifications', (l) => l.settingNotifications),
  'whisper_push': ('Whisper notifications', (l) => l.settingWhisperPush),
  'mention_foreground': (
    'Notify while app is open',
    (l) => l.settingMentionForeground,
  ),
  'my_username': ('My username', (l) => l.settingMyUsername),
  'replies_to_me': ('Replies to me', (l) => l.settingRepliesToMe),
  'threads_im_in': ("Threads I'm in", (l) => l.settingThreadsImIn),
  'keywords': ('Keywords', (l) => l.settingHighlightKeywords),
  'highlight_users': ('Users', (l) => l.settingHighlightUsers),
  'first_messages': ('First messages', (l) => l.settingFirstMessages),
  'redemptions': ('Channel point redemptions', (l) => l.settingRedemptions),
  'hype_chat': ('Hype Chat', (l) => l.settingHypeChat),
  'badges': ('Badges', (l) => l.settingBadges),
  'dont_highlight': ("Don't highlight", (l) => l.settingDontHighlight),
  'ignores': ('Ignores', (l) => l.settingIgnores),
  'highlight_strength': (
    'Highlight strength',
    (l) => l.settingHighlightStrength,
  ),

  // ── Emotes ──────────────────────────────────────────────────────────
  'emote_fetching': ('Emote fetching', (l) => l.settingEmoteFetching),
  'auto_data_saver': ('Auto data saver mode', (l) => l.settingAutoDataSaver),
  'emote_cache': ('Emote image cache', (l) => l.settingEmoteCache),
  'animate_emotes': ('Animate emotes', (l) => l.settingAnimateEmotes),
  'adaptive_fps': ('Adaptive frame rate', (l) => l.settingAdaptiveFps),
  'idle_fps': ('Idle frame rate', (l) => l.settingIdleFps),
  'providers': ('Providers', (l) => l.settingProviders),
  'unlisted_emotes': ('Unlisted 7TV emotes', (l) => l.settingUnlistedEmotes),
  'personal_emotes': ('Personal 7TV emotes', (l) => l.settingPersonalEmotes),
  'seven_tv_cosmetics': ('Paints and badges', (l) => l.sevenTvCosmetics),
  'ffz_effects': ('Effects', (l) => l.ffzEffects),
  'bttv_modifiers': ('Modifiers', (l) => l.bttvModifiers),

  // ── Tools ───────────────────────────────────────────────────────────
  'tts': ('Text-to-speech', (l) => l.settingTts),
  'uploader': ('Image uploader', (l) => l.settingUploader),
  'analytics': ('Analytics', (l) => l.settingAnalytics),
  'data_usage': ('Data usage', (l) => l.settingDataUsage),
  'updates': ('Check for updates', (l) => l.settingCheckForUpdates),
  'settings_backup': ('Import/export settings', (l) => l.settingSettingsBackup),
  'service_status': ('Service status', (l) => l.serviceStatus),
  'pip': ('Picture-in-picture', (l) => l.settingPip),
  'whats_new': ("Show what's new after updating", (l) => l.whatsNewToggle),

  // ── Tools › Text-to-speech ──────────────────────────────────────────
  'enable_tts': ('Enable TTS', (l) => l.settingEnableTts),
  'tts_engine': ('TTS engine', (l) => l.settingTtsEngine),
  'tts_queue_mode': ('Message queue mode', (l) => l.settingTtsQueueMode),
  'tts_format': ('Message format', (l) => l.settingTtsFormat),
  'tts_force_english': (
    'Force language to English',
    (l) => l.settingTtsForceEnglish,
  ),
  'tts_ignore_urls': ('Ignore URLs', (l) => l.settingTtsIgnoreUrls),
  'tts_ignore_emotes': ('Ignore emotes', (l) => l.settingTtsIgnoreEmotes),
  'tts_ignored_users': ('Ignored users', (l) => l.settingTtsIgnoredUsers),

  // ── Tools › Image uploader ──────────────────────────────────────────
  'recent_uploads': ('Recent uploads', (l) => l.settingRecentUploads),
};

/// Section headers by their English name.
final Map<String, String Function(AppLocalizations)> _sections = {
  'Animation': (l) => l.sectionAnimation,
  'Appearance': (l) => l.sectionAppearance,
  'Archive': (l) => l.sectionArchive,
  'Chat display': (l) => l.sectionChatDisplay,
  'Connection': (l) => l.sectionConnection,
  'Display': (l) => l.sectionDisplay,
  'Emotes': (l) => l.sectionEmotes,
  'Events': (l) => l.sectionEvents,
  'Giphy': (l) => l.sectionGiphy,
  'Images': (l) => l.sectionImages,
  'Layout': (l) => l.sectionLayout,
  'Livestreams': (l) => l.sectionLivestreams,
  'Mentions': (l) => l.sectionMentions,
  'Messages': (l) => l.sectionMessages,
  'Navigation': (l) => l.sectionNavigation,
  'Theme': (l) => l.sectionTheme,
  'Typing': (l) => l.sectionTyping,
  'Users': (l) => l.sectionUsers,
  "Don't highlight": (l) => l.settingDontHighlight,
};

/// Whether [id] has a title entry, so a row cannot ship nameless.
@visibleForTesting
bool hasTitleEntry(String id) => _titles.containsKey(id);

/// [id]'s English title.
String _enTitleOf(String id) => _titles[id]?.$1 ?? id;

/// [id]'s title in [l], or its English title when it has none.
String _titleOf(String id, AppLocalizations l) =>
    _titles[id]?.$2?.call(l) ?? _enTitleOf(id);

/// [page]'s English label, then [section].
String _enPathOf(String page, String? section) {
  final label = SettingsPageId.values.byName(page).label;
  return section == null ? label : '$label › $section';
}

/// [page]'s label in [l], then [section].
String _pathOf(String page, String? section, AppLocalizations l) {
  final label = SettingsPageId.values.byName(page).labelOf(l);
  return section == null
      ? label
      : '$label › ${_sections[section]?.call(l) ?? section}';
}

/// Search and label access for a stored setting.
extension SettingSearch on Setting<Object?> {
  /// [Setting.id]'s English title, still searchable in any language.
  String get enTitle => _enTitleOf(id);

  /// [Setting.id]'s title in the app language.
  String titleOf(AppLocalizations l) => _titleOf(id, l);

  /// Where it sits, in English.
  String get enPath => _enPathOf(page, section);

  /// Where it sits, in the app language.
  String pathOf(AppLocalizations l) => _pathOf(page, section, l);
}

/// A searchable row with no stored value: it opens a page, a sheet or a
/// section. Stored settings search through [Settings.all] instead.
class SettingsRow {
  const SettingsRow(
    this.id,
    this.page, {
    this.section,
    this.keywords = '',
    this.anchored = true,
  });

  final String id;
  final SettingsPageId page;

  /// Section header on [page], for the result's location line.
  final String? section;

  /// Extra words people search by.
  final String keywords;

  /// False opens [page] itself with nothing to reveal.
  final bool anchored;

  String get enTitle => _enTitleOf(id);

  String titleOf(AppLocalizations l) => _titleOf(id, l);

  String get enPath => _enPathOf(page.name, section);

  String pathOf(AppLocalizations l) => _pathOf(page.name, section, l);

  // ── Pages opened whole ──────────────────────────────────────────────
  static const channels = SettingsRow(
    'channels',
    SettingsPageId.channels,
    keywords: 'join leave reorder rename',
    anchored: false,
  );
  static const account = SettingsRow(
    'account',
    SettingsPageId.account,
    keywords: 'login log out switch',
    anchored: false,
  );
  static const about = SettingsRow(
    'about',
    SettingsPageId.about,
    keywords: 'version licenses',
    anchored: false,
  );
  static const language = SettingsRow(
    'language',
    SettingsPageId.language,
    keywords: 'translation locale',
    anchored: false,
  );

  // ── Rows that open a page or a sheet ────────────────────────────────
  static const editLayout = SettingsRow(
    'edit_layout',
    SettingsPageId.appearance,
    keywords: 'buttons drag move rearrange chrome header row',
  );
  static const inlineEmbeds = SettingsRow(
    'inline_embeds',
    SettingsPageId.chat,
    section: 'Messages',
    keywords: 'giphy images gif',
  );
  static const imageHosts = SettingsRow(
    'image_hosts',
    SettingsPageId.inlineEmbeds,
    section: 'Images',
    keywords: 'preview host domain whitelist',
  );
  static const macros = SettingsRow(
    'macros',
    SettingsPageId.chat,
    section: 'Typing',
    keywords: 'commands shortcuts',
  );
  static const dataUsage = SettingsRow(
    'data_usage',
    SettingsPageId.data,
    keywords: 'bandwidth mobile data bytes',
  );
  static const notifications = SettingsRow(
    'notifications',
    SettingsPageId.highlights,
    keywords: 'push alert mute pause snooze do not disturb dnd',
  );
  static const tts = SettingsRow(
    'tts',
    SettingsPageId.tools,
    keywords: 'tts read aloud voice',
  );
  static const uploader = SettingsRow(
    'uploader',
    SettingsPageId.tools,
    keywords: 'upload',
  );
  static const settingsBackup = SettingsRow(
    'settings_backup',
    SettingsPageId.tools,
    keywords: 'backup restore copy paste clipboard file txt',
  );
  static const serviceStatus = SettingsRow(
    'service_status',
    SettingsPageId.tools,
    keywords: 'status websocket ping uptime servers connection',
  );
  static const ttsEngine = SettingsRow(
    'tts_engine',
    SettingsPageId.tts,
    keywords: 'voice',
  );
  static const recentUploads = SettingsRow(
    'recent_uploads',
    SettingsPageId.uploader,
  );

  // ── Highlight rules, stored together in Settings.pingRules ──────────
  static const highlightKeywords = SettingsRow(
    'keywords',
    SettingsPageId.highlights,
    keywords: 'words ping alert',
  );
  static const highlightUsers = SettingsRow(
    'highlight_users',
    SettingsPageId.highlights,
    keywords: 'highlight people',
  );
  static const dontHighlight = SettingsRow(
    'dont_highlight',
    SettingsPageId.highlights,
    keywords: 'blacklist',
  );
  static const badges = SettingsRow(
    'badges',
    SettingsPageId.highlights,
    section: 'Events',
    keywords: 'mod vip sub',
  );
  static const myUsername = SettingsRow(
    'my_username',
    SettingsPageId.highlights,
    section: 'Mentions',
    keywords: 'ping',
  );
  static const repliesToMe = SettingsRow(
    'replies_to_me',
    SettingsPageId.highlights,
    section: 'Mentions',
  );
  static const threadsImIn = SettingsRow(
    'threads_im_in',
    SettingsPageId.highlights,
    section: 'Mentions',
  );
  static const firstMessages = SettingsRow(
    'first_messages',
    SettingsPageId.highlights,
    section: 'Events',
  );
  static const redemptions = SettingsRow(
    'redemptions',
    SettingsPageId.highlights,
    section: 'Events',
    keywords: 'rewards',
  );
  static const hypeChat = SettingsRow(
    'hype_chat',
    SettingsPageId.highlights,
    section: 'Events',
    keywords: 'paid',
  );

  /// Every row that stores nothing, in browsing order.
  static const all = <SettingsRow>[
    channels,
    editLayout,
    inlineEmbeds,
    imageHosts,
    macros,
    dataUsage,
    notifications,
    tts,
    uploader,
    settingsBackup,
    serviceStatus,
    ttsEngine,
    recentUploads,
    highlightKeywords,
    highlightUsers,
    dontHighlight,
    badges,
    myUsername,
    repliesToMe,
    threadsImIn,
    firstMessages,
    redemptions,
    hypeChat,
    account,
    about,
    language,
  ];
}

/// Wraps a page opened from search with the row to reveal.
class SettingsTarget extends StatefulWidget {
  const SettingsTarget({super.key, required this.id, required this.child});

  /// The anchor id search asked for.
  final String id;
  final Widget child;

  @override
  State<SettingsTarget> createState() => _SettingsTargetState();
}

class _SettingsTargetState extends State<SettingsTarget> {
  // Mounted anchors, so a scroll position is known before the target builds.
  final _mounted = <String, BuildContext>{};
  bool _found = false;
  int _steps = 0;
  // Kept across frames with no mounted anchor, so paging can continue.
  ScrollPosition? _position;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback(_seek);
  }

  /// True exactly once: for the target's anchor, the first time it mounts.
  bool _register(String id, BuildContext anchor) {
    _mounted[id] = anchor;
    if (_found || id != widget.id) return false;
    _found = true;
    return true;
  }

  void _unregister(String id, BuildContext anchor) {
    if (_mounted[id] == anchor) _mounted.remove(id);
  }

  // Lists only build rows near the viewport, so a far target has no anchor
  // yet: page down until it mounts or the list ends.
  void _seek(Duration _) {
    if (!mounted || _found || ++_steps > 40) return;
    if (_mounted.isNotEmpty) {
      _position = Scrollable.maybeOf(_mounted.values.first)?.position;
    }
    final position = _position;
    if (position == null || position.pixels >= position.maxScrollExtent) {
      return;
    }
    position.jumpTo(
      math.min(
        position.pixels + position.viewportDimension * 0.8,
        position.maxScrollExtent,
      ),
    );
    WidgetsBinding.instance.addPostFrameCallback(_seek);
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Marks a setting's row so search can scroll to it and pulse it.
class SettingAnchor extends StatefulWidget {
  /// Anchors a stored setting's row.
  SettingAnchor(Setting<Object?> setting, {Key? key, required this.child})
    : id = setting.id,
      super(key: key ?? ValueKey('setting:${setting.id}'));

  /// Anchors a row that stores nothing, such as a page or a sheet opener.
  SettingAnchor.row(SettingsRow row, {Key? key, required this.child})
    : id = row.id,
      super(key: key ?? ValueKey('setting:${row.id}'));

  /// The setting or row this marks.
  final String id;
  final Widget child;

  @override
  State<SettingAnchor> createState() => _SettingAnchorState();
}

class _SettingAnchorState extends State<SettingAnchor>
    with SingleTickerProviderStateMixin {
  _SettingsTargetState? _target;
  late final _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_target != null) return;
    final target = context.findAncestorStateOfType<_SettingsTargetState>();
    _target = target;
    if (target == null || !target._register(widget.id, context)) return;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      await Scrollable.ensureVisible(
        context,
        alignment: 0.3,
        duration: Motion.normal,
        curve: Motion.enter,
      );
      if (mounted) unawaited(_pulse.forward(from: 0));
    });
  }

  @override
  void dispose() {
    _target?._unregister(widget.id, context);
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.primary;
    return AnimatedBuilder(
      animation: _pulse,
      child: widget.child,
      builder: (context, child) {
        // Two soft pulses, then gone.
        final t = _pulse.value;
        final strength = t == 0 || t == 1
            ? 0.0
            : math.sin(t * 2 * math.pi).abs();
        return ColoredBox(
          color: color.withValues(alpha: 0.16 * strength),
          child: child,
        );
      },
    );
  }
}

/// One search result: its two lines and where a tap opens it.
typedef _Hit = ({
  String id,
  SettingsPageId page,
  bool anchored,
  String title,
  String path,
});

/// Settings search: a normal page with the field focused from the first
/// frame, so the keyboard opens during the slide-in. (Flutter's showSearch
/// fades for 300ms and only then focuses the field.)
///
/// Every typed word must match a row's title, location or extra keywords, so
/// "dark" finds Theme and "ping" finds Highlights. Rows come from
/// [Settings.all], the stored settings, plus [SettingsRow.all] for the ones
/// that only open a page or a sheet.
class SettingsSearchPage extends StatefulWidget {
  const SettingsSearchPage({super.key, required this.openPage});

  /// Builds a settings page; a result wraps it to reveal the row.
  final Widget Function(SettingsPageId page) openPage;

  @override
  State<SettingsSearchPage> createState() => _SettingsSearchPageState();
}

class _SettingsSearchPageState extends State<SettingsSearchPage> {
  final _query = TextEditingController();

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  List<_Hit> get _hits {
    final words = _query.text
        .toLowerCase()
        .split(' ')
        .where((w) => w.isNotEmpty)
        .toList();
    if (words.isEmpty) return const [];
    final l = context.l10n;
    final hits = <_Hit>[];
    void add(_Hit hit, String haystack) {
      if (words.every(haystack.toLowerCase().contains)) hits.add(hit);
    }

    for (final s in Settings.all) {
      if (!s.anchored || !gateOpen(s.gate)) continue;
      final title = s.titleOf(l);
      final path = s.pathOf(l);
      add((
        id: s.id,
        page: SettingsPageId.values.byName(s.page),
        anchored: true,
        title: title,
        path: path,
      ), '$title $path ${s.enTitle} ${s.enPath} ${s.keywords}');
    }
    for (final r in SettingsRow.all) {
      final title = r.titleOf(l);
      final path = r.pathOf(l);
      add((
        id: r.id,
        page: r.page,
        anchored: r.anchored,
        title: title,
        path: path,
      ), '$title $path ${r.enTitle} ${r.enPath} ${r.keywords}');
    }
    return hits;
  }

  void _open(_Hit hit) {
    final page = widget.openPage(hit.page);
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) =>
            hit.anchored ? SettingsTarget(id: hit.id, child: page) : page,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final hits = _hits;
    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _query,
          autofocus: true,
          textInputAction: TextInputAction.search,
          onChanged: (_) => setState(() {}),
          onSubmitted: (_) {
            if (hits.isNotEmpty) _open(hits.first);
          },
          decoration: InputDecoration(
            hintText: context.l10n.searchSettings,
            border: InputBorder.none,
          ),
        ),
        actions: [
          if (_query.text.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.clear),
              tooltip: context.l10n.clear,
              onPressed: () => setState(_query.clear),
            ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: _query.text.trim().isEmpty
            ? const SizedBox.shrink()
            : hits.isEmpty
            ? Padding(
                padding: const EdgeInsets.all(24),
                child: Text(context.l10n.noMatches),
              )
            : ListView(
                children: [
                  for (final hit in hits)
                    ListTile(
                      title: Text(hit.title),
                      subtitle: Text(hit.path),
                      onTap: () => _open(hit),
                    ),
                ],
              ),
      ),
    );
  }
}
