import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

/// Settings pages a search result can open.
enum SettingsPageId {
  channels('Channels'),
  appearance('Appearance'),
  customLayout('Appearance › Layout › Custom'),
  chat('Chat'),
  inlineEmbeds('Chat › Inline embeds'),
  highlights('Highlights'),
  emotes('Emotes'),
  tools('Tools'),
  tts('Tools › Text-to-speech'),
  uploader('Tools › Image uploader'),
  account('Account'),
  about('About');

  const SettingsPageId(this.label);
  final String label;
}

bool _android() => !kIsWeb && Platform.isAndroid;
bool _notIos() => !kIsWeb && !Platform.isIOS;

/// One searchable setting. Its tile reads [title] from here and wraps itself
/// in a [SettingAnchor], so the label, the search entry and the jump target
/// are one declaration (the Android Settings pattern).
class Setting {
  const Setting(
    this.id,
    this.title,
    this.page, {
    this.section,
    this.keywords = '',
    this.visible,
    this.anchored = true,
  });

  final String id;
  final String title;
  final SettingsPageId page;

  /// Section header on [page], for the result's location line.
  final String? section;

  /// Extra words people search by.
  final String keywords;

  /// Platform gate matching the tile's own; null is everywhere.
  final bool Function()? visible;

  /// False opens [page] itself with nothing to reveal.
  final bool anchored;

  String get path => section == null ? page.label : '${page.label} › $section';

  // ── Pages opened whole ──────────────────────────────────────────────
  static const channels = Setting(
    'channels',
    'Channels',
    SettingsPageId.channels,
    keywords: 'join leave reorder rename',
    anchored: false,
  );
  static const account = Setting(
    'account',
    'Account',
    SettingsPageId.account,
    keywords: 'login log out switch',
    anchored: false,
  );
  static const about = Setting(
    'about',
    'About',
    SettingsPageId.about,
    keywords: 'version licenses',
    anchored: false,
  );

  // ── Appearance ──────────────────────────────────────────────────────
  static const theme = Setting(
    'theme',
    'Theme',
    SettingsPageId.appearance,
    section: 'Theme',
    keywords: 'dark light mode',
  );
  static const accentColor = Setting(
    'accent_color',
    'Accent color',
    SettingsPageId.appearance,
    section: 'Theme',
    keywords: 'colour',
  );
  static const trueDark = Setting(
    'true_dark',
    'True dark mode',
    SettingsPageId.appearance,
    section: 'Theme',
    keywords: 'black amoled oled',
  );
  static const layout = Setting(
    'layout',
    'Layout',
    SettingsPageId.appearance,
    section: 'Layout',
    keywords: 'compact full density',
  );
  static const liquidGlass = Setting(
    'liquid_glass',
    'Liquid glass',
    SettingsPageId.appearance,
    section: 'Layout',
    keywords: 'blur',
  );
  static const chatFontSize = Setting(
    'chat_font_size',
    'Chat font size',
    SettingsPageId.appearance,
    section: 'Chat display',
    keywords: 'text',
  );
  static const showTimestamps = Setting(
    'show_timestamps',
    'Show timestamps',
    SettingsPageId.appearance,
    section: 'Chat display',
    keywords: 'time',
  );
  static const timestampFormat = Setting(
    'timestamp_format',
    'Timestamp format',
    SettingsPageId.appearance,
    section: 'Chat display',
    keywords: 'time',
  );
  static const checkered = Setting(
    'checkered',
    'Checkered messages',
    SettingsPageId.appearance,
    section: 'Chat display',
    keywords: 'alternate rows shading',
  );
  static const lineSeparator = Setting(
    'line_separator',
    'Separate messages with lines',
    SettingsPageId.appearance,
    section: 'Chat display',
    keywords: 'divider',
  );
  static const keepScreenOn = Setting(
    'keep_screen_on',
    'Keep screen on',
    SettingsPageId.appearance,
    section: 'Display',
    keywords: 'sleep dim',
  );
  static const fastChannelSwipe = Setting(
    'fast_channel_swipe',
    'Fast channel swipe',
    SettingsPageId.appearance,
    section: 'Navigation',
  );

  // ── Appearance › Layout › Custom ────────────────────────────────────
  static const customLayout = Setting(
    'custom_layout',
    'Enable custom layout',
    SettingsPageId.customLayout,
  );
  static const mergeAppBar = Setting(
    'merge_app_bar',
    'Merge app bar into tabs',
    SettingsPageId.customLayout,
  );
  static const foldPanelTitles = Setting(
    'fold_panel_titles',
    'Fold panel titles into tabs',
    SettingsPageId.customLayout,
  );
  static const tighterComposer = Setting(
    'tighter_composer',
    'Tighter composer',
    SettingsPageId.customLayout,
  );
  static const horizontalSheetActions = Setting(
    'horizontal_sheet_actions',
    'Horizontal sheet actions',
    SettingsPageId.customLayout,
  );
  static const compactDensity = Setting(
    'compact_density',
    'Compact density',
    SettingsPageId.customLayout,
  );
  static const tighterChrome = Setting(
    'tighter_chrome',
    'Tighter chrome margins',
    SettingsPageId.customLayout,
  );

  // ── Chat ────────────────────────────────────────────────────────────
  static const maxMessages = Setting(
    'max_messages',
    'Max messages per channel',
    SettingsPageId.chat,
    section: 'Messages',
    keywords: 'buffer limit',
  );
  static const sharedChat = Setting(
    'shared_chat',
    'Shared chat messages',
    SettingsPageId.chat,
    section: 'Messages',
    keywords: 'spotlight fade',
  );
  static const inlineEmbeds = Setting(
    'inline_embeds',
    'Inline embeds',
    SettingsPageId.chat,
    section: 'Messages',
    keywords: 'giphy images gif',
  );
  static const splitLinks = Setting(
    'split_links',
    'Split links',
    SettingsPageId.chat,
    section: 'Messages',
    keywords: 'whitelist domains',
  );
  static const recentMessagesLimit = Setting(
    'recent_messages_limit',
    'Recent messages to load',
    SettingsPageId.chat,
    section: 'History',
    keywords: 'history',
  );
  static const recentMessagesSource = Setting(
    'recent_messages_source',
    'Recent messages',
    SettingsPageId.chat,
    section: 'History',
    keywords: 'history provider robotty',
  );
  static const preferEmotes = Setting(
    'prefer_emotes',
    'Prefer emote suggestions (autocomplete)',
    SettingsPageId.chat,
    section: 'Typing',
    keywords: 'tab complete',
  );
  static const mentionFormat = Setting(
    'mention_format',
    'Mention format',
    SettingsPageId.chat,
    section: 'Typing',
    keywords: '@ name',
  );
  static const replyThreadRoot = Setting(
    'reply_thread_root',
    'Reply to thread first message',
    SettingsPageId.chat,
    section: 'Typing',
    keywords: 'root',
  );
  static const macros = Setting(
    'macros',
    'Command macros',
    SettingsPageId.chat,
    section: 'Typing',
    keywords: 'commands shortcuts',
  );
  static const doubleTapCopy = Setting(
    'double_tap_copy',
    'Double-tap name to copy',
    SettingsPageId.chat,
    section: 'Users',
  );
  static const namePaints = Setting(
    'name_paints',
    '7TV name paints',
    SettingsPageId.chat,
    section: 'Users',
    keywords: 'gradient colors',
  );
  static const stayConnected = Setting(
    'stay_connected',
    'Stay connected in background',
    SettingsPageId.chat,
    section: 'Connection',
    keywords: 'keep alive service',
    visible: _android,
  );
  static const chatProxy = Setting(
    'chat_proxy',
    'Chat proxy',
    SettingsPageId.chat,
    section: 'Connection',
    keywords: 'server',
  );

  // ── Chat › Inline embeds ────────────────────────────────────────────
  static const showGiphy = Setting(
    'show_giphy',
    'Show Giphy inline',
    SettingsPageId.inlineEmbeds,
    section: 'Giphy',
    keywords: 'gif',
  );
  static const giphyHeight = Setting(
    'giphy_height',
    'Giphy height',
    SettingsPageId.inlineEmbeds,
    section: 'Giphy',
  );
  static const showImages = Setting(
    'show_images',
    'Show images inline',
    SettingsPageId.inlineEmbeds,
    section: 'Images',
  );
  static const imageHeight = Setting(
    'image_height',
    'Image height',
    SettingsPageId.inlineEmbeds,
    section: 'Images',
  );

  // ── Highlights ──────────────────────────────────────────────────────
  static const notifications = Setting(
    'notifications',
    'Notifications',
    SettingsPageId.highlights,
    keywords: 'push alert mute pause snooze do not disturb dnd',
    visible: _notIos,
  );
  static const whisperPush = Setting(
    'whisper_push',
    'Whisper notifications',
    SettingsPageId.highlights,
    section: 'Mentions',
    keywords: 'notify push dm',
    visible: _notIos,
  );
  static const myUsername = Setting(
    'my_username',
    'My username',
    SettingsPageId.highlights,
    section: 'Mentions',
    keywords: 'ping',
  );
  static const repliesToMe = Setting(
    'replies_to_me',
    'Replies to me',
    SettingsPageId.highlights,
    section: 'Mentions',
  );
  static const threadsImIn = Setting(
    'threads_im_in',
    "Threads I'm in",
    SettingsPageId.highlights,
    section: 'Mentions',
  );
  static const highlightKeywords = Setting(
    'keywords',
    'Keywords',
    SettingsPageId.highlights,
    keywords: 'words ping alert',
  );
  static const highlightUsers = Setting(
    'highlight_users',
    'Users',
    SettingsPageId.highlights,
    keywords: 'highlight people',
  );
  static const firstMessages = Setting(
    'first_messages',
    'First messages',
    SettingsPageId.highlights,
    section: 'Events',
  );
  static const redemptions = Setting(
    'redemptions',
    'Channel point redemptions',
    SettingsPageId.highlights,
    section: 'Events',
    keywords: 'rewards',
  );
  static const hypeChat = Setting(
    'hype_chat',
    'Hype Chat',
    SettingsPageId.highlights,
    section: 'Events',
    keywords: 'paid',
  );
  static const badges = Setting(
    'badges',
    'Badges',
    SettingsPageId.highlights,
    section: 'Events',
    keywords: 'mod vip sub',
  );
  static const dontHighlight = Setting(
    'dont_highlight',
    "Don't highlight",
    SettingsPageId.highlights,
    keywords: 'blacklist',
  );
  static const ignores = Setting(
    'ignores',
    'Ignores',
    SettingsPageId.highlights,
    section: "Don't highlight",
    keywords: 'block mute hide',
  );
  static const highlightStrength = Setting(
    'highlight_strength',
    'Highlight strength',
    SettingsPageId.highlights,
    section: 'Appearance',
    keywords: 'opacity tint',
  );

  // ── Emotes ──────────────────────────────────────────────────────────
  static const emoteFetching = Setting(
    'emote_fetching',
    'Emote fetching',
    SettingsPageId.emotes,
    keywords: 'quality tier data',
  );
  static const autoDataSaver = Setting(
    'auto_data_saver',
    'Auto data saver mode',
    SettingsPageId.emotes,
    keywords: 'cellular wifi',
  );
  static const emoteCache = Setting(
    'emote_cache',
    'Emote image cache',
    SettingsPageId.emotes,
    keywords: 'storage nuke clear',
  );
  static const animateEmotes = Setting(
    'animate_emotes',
    'Animate emotes',
    SettingsPageId.emotes,
    section: 'Animation',
    keywords: 'gif',
  );
  static const emoteEffects = Setting(
    'emote_effects',
    'Emote effects',
    SettingsPageId.emotes,
    section: 'Animation',
    keywords: 'ffz modifier flip spin',
  );
  static const adaptiveFps = Setting(
    'adaptive_fps',
    'Adaptive frame rate',
    SettingsPageId.emotes,
    section: 'Animation',
    keywords: 'fps battery',
  );
  static const idleFps = Setting(
    'idle_fps',
    'Idle frame rate',
    SettingsPageId.emotes,
    section: 'Animation',
    keywords: 'fps battery',
  );
  static const providers = Setting(
    'providers',
    'Providers',
    SettingsPageId.emotes,
    keywords: 'bttv ffz 7tv',
  );
  static const unlistedEmotes = Setting(
    'unlisted_emotes',
    'Unlisted 7TV emotes',
    SettingsPageId.emotes,
  );

  // ── Tools ───────────────────────────────────────────────────────────
  static const tts = Setting(
    'tts',
    'Text-to-speech',
    SettingsPageId.tools,
    keywords: 'tts read aloud voice',
  );
  static const uploader = Setting(
    'uploader',
    'Image uploader',
    SettingsPageId.tools,
    keywords: 'upload',
  );
  static const analytics = Setting(
    'analytics',
    'Analytics',
    SettingsPageId.tools,
    keywords: 'stats',
  );
  static const pip = Setting(
    'pip',
    'Picture-in-picture',
    SettingsPageId.tools,
    section: 'Livestreams',
    keywords: 'pip stream',
    visible: _android,
  );

  // ── Tools › Text-to-speech ──────────────────────────────────────────
  static const enableTts = Setting(
    'enable_tts',
    'Enable TTS',
    SettingsPageId.tts,
  );
  static const ttsEngine = Setting(
    'tts_engine',
    'TTS engine',
    SettingsPageId.tts,
    keywords: 'voice',
  );
  static const ttsQueueMode = Setting(
    'tts_queue_mode',
    'Message queue mode',
    SettingsPageId.tts,
  );
  static const ttsFormat = Setting(
    'tts_format',
    'Message format',
    SettingsPageId.tts,
  );
  static const ttsForceEnglish = Setting(
    'tts_force_english',
    'Force language to English',
    SettingsPageId.tts,
  );
  static const ttsIgnoreUrls = Setting(
    'tts_ignore_urls',
    'Ignore URLs',
    SettingsPageId.tts,
  );
  static const ttsIgnoreEmotes = Setting(
    'tts_ignore_emotes',
    'Ignore emotes',
    SettingsPageId.tts,
  );
  static const ttsIgnoredUsers = Setting(
    'tts_ignored_users',
    'Ignored users',
    SettingsPageId.tts,
  );

  // ── Tools › Image uploader ──────────────────────────────────────────
  static const recentUploads = Setting(
    'recent_uploads',
    'Recent uploads',
    SettingsPageId.uploader,
  );

  /// Every searchable setting, in browsing order.
  static const all = [
    channels,
    theme,
    accentColor,
    trueDark,
    layout,
    liquidGlass,
    chatFontSize,
    showTimestamps,
    timestampFormat,
    checkered,
    lineSeparator,
    keepScreenOn,
    fastChannelSwipe,
    customLayout,
    mergeAppBar,
    foldPanelTitles,
    tighterComposer,
    horizontalSheetActions,
    compactDensity,
    tighterChrome,
    maxMessages,
    sharedChat,
    inlineEmbeds,
    splitLinks,
    recentMessagesLimit,
    recentMessagesSource,
    preferEmotes,
    mentionFormat,
    replyThreadRoot,
    macros,
    doubleTapCopy,
    namePaints,
    stayConnected,
    chatProxy,
    showGiphy,
    giphyHeight,
    showImages,
    imageHeight,
    notifications,
    whisperPush,
    myUsername,
    repliesToMe,
    threadsImIn,
    highlightKeywords,
    highlightUsers,
    firstMessages,
    redemptions,
    hypeChat,
    badges,
    dontHighlight,
    ignores,
    highlightStrength,
    emoteFetching,
    autoDataSaver,
    emoteCache,
    animateEmotes,
    emoteEffects,
    adaptiveFps,
    idleFps,
    providers,
    unlistedEmotes,
    tts,
    uploader,
    analytics,
    pip,
    enableTts,
    ttsEngine,
    ttsQueueMode,
    ttsFormat,
    ttsForceEnglish,
    ttsIgnoreUrls,
    ttsIgnoreEmotes,
    ttsIgnoredUsers,
    recentUploads,
    account,
    about,
  ];

  /// Settings that exist on this platform.
  static Iterable<Setting> get available =>
      all.where((s) => s.visible?.call() ?? true);
}

/// Wraps a page opened from search with the setting to reveal.
class SettingsTarget extends StatefulWidget {
  const SettingsTarget({super.key, required this.target, required this.child});

  final Setting target;
  final Widget child;

  @override
  State<SettingsTarget> createState() => _SettingsTargetState();
}

class _SettingsTargetState extends State<SettingsTarget> {
  // Mounted anchors, so a scroll position is known before the target builds.
  final _mounted = <String, BuildContext>{};
  bool _found = false;
  int _steps = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback(_seek);
  }

  /// True exactly once: for the target's anchor, the first time it mounts.
  bool _register(Setting setting, BuildContext anchor) {
    _mounted[setting.id] = anchor;
    if (_found || setting.id != widget.target.id) return false;
    _found = true;
    return true;
  }

  void _unregister(Setting setting, BuildContext anchor) {
    if (_mounted[setting.id] == anchor) _mounted.remove(setting.id);
  }

  // Lists only build rows near the viewport, so a far target has no anchor
  // yet: page down until it mounts or the list ends.
  void _seek(Duration _) {
    if (!mounted || _found || _mounted.isEmpty || ++_steps > 40) return;
    final position = Scrollable.maybeOf(_mounted.values.first)?.position;
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
  SettingAnchor(this.setting, {required this.child})
    : super(key: ValueKey('setting:${setting.id}'));

  final Setting setting;
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
    if (target == null || !target._register(widget.setting, context)) return;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      await Scrollable.ensureVisible(
        context,
        alignment: 0.3,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOutCubic,
      );
      if (mounted) unawaited(_pulse.forward(from: 0));
    });
  }

  @override
  void dispose() {
    _target?._unregister(widget.setting, context);
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

/// Settings search: a normal page with the field focused from the first
/// frame, so the keyboard opens during the slide-in. (Flutter's showSearch
/// fades for 300ms and only then focuses the field.)
///
/// Every typed word must match a setting's title, location or extra
/// keywords, so "dark" finds Theme and "ping" finds Highlights.
class SettingsSearchPage extends StatefulWidget {
  const SettingsSearchPage({super.key, required this.openPage});

  /// Builds a settings page; a result wraps it to reveal the setting.
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

  List<Setting> get _hits {
    final words = _query.text
        .toLowerCase()
        .split(' ')
        .where((w) => w.isNotEmpty)
        .toList();
    if (words.isEmpty) return const [];
    return Setting.available.where((s) {
      final haystack = '${s.title} ${s.path} ${s.keywords}'.toLowerCase();
      return words.every(haystack.contains);
    }).toList();
  }

  void _open(Setting hit) {
    final page = widget.openPage(hit.page);
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) =>
            hit.anchored ? SettingsTarget(target: hit, child: page) : page,
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
          decoration: const InputDecoration(
            hintText: 'Search settings',
            border: InputBorder.none,
          ),
        ),
        actions: [
          if (_query.text.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.clear),
              tooltip: 'Clear',
              onPressed: () => setState(_query.clear),
            ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: _query.text.trim().isEmpty
            ? const SizedBox.shrink()
            : hits.isEmpty
            ? const Padding(
                padding: EdgeInsets.all(24),
                child: Text('No matching settings'),
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
