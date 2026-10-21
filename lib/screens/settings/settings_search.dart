import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
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
    this.mirrors = const {},
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

  /// Aggregate pages that show this setting's own tile too. Search opens
  /// [page], its home.
  final Set<SettingsPageId> mirrors;

  String get path => section == null ? page.label : '${page.label} › $section';

  /// [title] in the app language.
  String titleOf(AppLocalizations l) => switch (id) {
    'channels' => l.settingChannels,
    'account' => l.settingAccount,
    'about' => l.settingAbout,
    'language' => l.settingLanguage,
    'theme' => l.settingTheme,
    'accent_color' => l.settingAccentColor,
    'true_dark' => l.settingTrueDark,
    'layout' => l.settingLayout,
    'liquid_glass' => l.settingLiquidGlass,
    'haptics' => l.settingHaptics,
    'edit_layout' => l.settingEditLayout,
    'chat_font_size' => l.settingChatFontSize,
    'chat_font_weight' => l.settingChatFontWeight,
    'show_timestamps' => l.settingShowTimestamps,
    'timestamp_format' => l.settingTimestampFormat,
    'checkered' => l.settingCheckered,
    'line_separator' => l.settingLineSeparator,
    'keep_screen_on' => l.settingKeepScreenOn,
    'fast_channel_swipe' => l.settingFastChannelSwipe,
    'reopen_last_channel' => l.settingReopenLastChannel,
    'custom_layout' => l.settingCustomLayout,
    'tighter_composer' => l.settingTighterComposer,
    'horizontal_sheet_actions' => l.settingHorizontalSheetActions,
    'compact_density' => l.settingCompactDensity,
    'max_messages' => l.settingMaxMessages,
    'shared_chat' => l.settingSharedChat,
    'inline_embeds' => l.settingInlineEmbeds,
    'split_links' => l.settingSplitLinks,
    'recent_messages_limit' => l.settingRecentMessagesLimit,
    'recent_messages_source' => l.settingRecentMessagesSource,
    'archive_enabled' => l.settingArchiveEnabled,
    'archive_retention' => l.settingArchiveRetention,
    'archive_channel_cap' => l.settingArchiveChannelCap,
    'gap_fill' => l.settingGapFill,
    'prefer_emotes' => l.settingPreferEmotes,
    'mention_format' => l.settingMentionFormat,
    'reply_thread_root' => l.settingReplyThreadRoot,
    'send_swipe' => l.settingSendSwipe,
    'macros' => l.settingMacros,
    'double_tap_copy' => l.settingDoubleTapCopy,
    'stay_connected' => l.settingStayConnected,
    'chat_proxy' => l.settingChatProxy,
    'show_giphy' => l.settingShowGiphy,
    'giphy_height' => l.settingGiphyHeight,
    'show_images' => l.settingShowImages,
    'image_height' => l.settingImageHeight,
    'notifications' => l.settingNotifications,
    'whisper_push' => l.settingWhisperPush,
    'mention_foreground' => l.settingMentionForeground,
    'my_username' => l.settingMyUsername,
    'replies_to_me' => l.settingRepliesToMe,
    'threads_im_in' => l.settingThreadsImIn,
    'keywords' => l.settingHighlightKeywords,
    'highlight_users' => l.settingHighlightUsers,
    'first_messages' => l.settingFirstMessages,
    'redemptions' => l.settingRedemptions,
    'hype_chat' => l.settingHypeChat,
    'badges' => l.settingBadges,
    'dont_highlight' => l.settingDontHighlight,
    'ignores' => l.settingIgnores,
    'highlight_strength' => l.settingHighlightStrength,
    'emote_fetching' => l.settingEmoteFetching,
    'auto_data_saver' => l.settingAutoDataSaver,
    'emote_cache' => l.settingEmoteCache,
    'animate_emotes' => l.settingAnimateEmotes,
    'adaptive_fps' => l.settingAdaptiveFps,
    'idle_fps' => l.settingIdleFps,
    'providers' => l.settingProviders,
    'unlisted_emotes' => l.settingUnlistedEmotes,
    'personal_emotes' => l.settingPersonalEmotes,
    'tts' => l.settingTts,
    'uploader' => l.settingUploader,
    'analytics' => l.settingAnalytics,
    'data_usage' => l.settingDataUsage,
    'pip' => l.settingPip,
    'updates' => l.settingCheckForUpdates,
    'settings_backup' => l.settingSettingsBackup,
    'enable_tts' => l.settingEnableTts,
    'tts_engine' => l.settingTtsEngine,
    'tts_queue_mode' => l.settingTtsQueueMode,
    'tts_format' => l.settingTtsFormat,
    'tts_force_english' => l.settingTtsForceEnglish,
    'tts_ignore_urls' => l.settingTtsIgnoreUrls,
    'tts_ignore_emotes' => l.settingTtsIgnoreEmotes,
    'tts_ignored_users' => l.settingTtsIgnoredUsers,
    'recent_uploads' => l.settingRecentUploads,
    _ => title,
  };

  /// [path] in the app language.
  String pathOf(AppLocalizations l) {
    final pageLabel = page.labelOf(l);
    final s = section;
    return s == null ? pageLabel : '$pageLabel › ${_sectionOf(l, s)}';
  }

  static String _sectionOf(AppLocalizations l, String s) => switch (s) {
    'Animation' => l.sectionAnimation,
    'Appearance' => l.sectionAppearance,
    'Chat display' => l.sectionChatDisplay,
    'Connection' => l.sectionConnection,
    'Display' => l.sectionDisplay,
    'Events' => l.sectionEvents,
    'Giphy' => l.sectionGiphy,
    'History' => l.sectionHistory,
    'Images' => l.sectionImages,
    'Layout' => l.sectionLayout,
    'Livestreams' => l.sectionLivestreams,
    'Mentions' => l.sectionMentions,
    'Messages' => l.sectionMessages,
    'Navigation' => l.sectionNavigation,
    'Theme' => l.sectionTheme,
    'Typing' => l.sectionTyping,
    'Users' => l.sectionUsers,
    "Don't highlight" => l.settingDontHighlight,
    _ => s,
  };

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
  static const language = Setting(
    'language',
    'Language',
    SettingsPageId.language,
    keywords: 'translation locale',
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
    mirrors: {SettingsPageId.battery},
  );
  static const layout = Setting(
    'layout',
    'Layout',
    SettingsPageId.appearance,
    section: 'Layout',
    keywords: 'compact full density',
  );
  static const editLayout = Setting(
    'edit_layout',
    'Edit layout',
    SettingsPageId.appearance,
    keywords: 'buttons drag move rearrange chrome header row',
  );
  static const liquidGlass = Setting(
    'liquid_glass',
    'Liquid glass',
    SettingsPageId.appearance,
    section: 'Layout',
    keywords: 'blur',
    mirrors: {SettingsPageId.battery},
  );
  static const haptics = Setting(
    'haptics',
    'Haptics',
    SettingsPageId.appearance,
    section: 'Layout',
    keywords: 'vibration vibrate feedback buzz',
  );
  static const chatFontSize = Setting(
    'chat_font_size',
    'Chat font size',
    SettingsPageId.appearance,
    section: 'Chat display',
    keywords: 'text',
  );
  static const chatFontWeight = Setting(
    'chat_font_weight',
    'Chat font weight',
    SettingsPageId.appearance,
    section: 'Chat display',
    keywords: 'text bold thickness',
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
    mirrors: {SettingsPageId.battery},
  );
  static const fastChannelSwipe = Setting(
    'fast_channel_swipe',
    'Fast channel swipe',
    SettingsPageId.appearance,
    section: 'Navigation',
  );
  static const reopenLastChannel = Setting(
    'reopen_last_channel',
    'Start on last channel',
    SettingsPageId.appearance,
    section: 'Navigation',
    keywords: 'open reopen startup launch remember tab',
  );

  // ── Appearance › Layout › Custom ────────────────────────────────────
  static const customLayout = Setting(
    'custom_layout',
    'Enable custom layout',
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

  // ── Chat ────────────────────────────────────────────────────────────
  static const maxMessages = Setting(
    'max_messages',
    'Max messages per channel',
    SettingsPageId.history,
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
    SettingsPageId.history,
    keywords: 'history',
    mirrors: {SettingsPageId.data},
  );
  static const gapFill = Setting(
    'gap_fill',
    'Dynamic history fetch',
    SettingsPageId.history,
    keywords: 'history reconnect missed messages robotty',
    mirrors: {SettingsPageId.data},
  );
  static const archiveEnabled = Setting(
    'archive_enabled',
    'Chat archive',
    SettingsPageId.history,
    keywords: 'archive history storage disk save offline',
  );
  static const archiveRetention = Setting(
    'archive_retention',
    'Keep chat for',
    SettingsPageId.history,
    keywords: 'archive retention storage days delete',
  );
  static const archiveChannelCap = Setting(
    'archive_channel_cap',
    'Space per channel',
    SettingsPageId.history,
    keywords: 'archive storage size megabytes mb limit delete',
  );
  static const recentMessagesSource = Setting(
    'recent_messages_source',
    'Recent messages',
    SettingsPageId.history,
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
  static const sendSwipe = Setting(
    'send_swipe',
    'Hold to spam',
    SettingsPageId.chat,
    section: 'Typing',
    // Its speed sliders show only while it is on, so they search here.
    keywords: 'send menu repeat swipe gesture speed interval rate limit ms',
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
  static const stayConnected = Setting(
    'stay_connected',
    'Stay connected in background',
    SettingsPageId.chat,
    section: 'Connection',
    keywords: 'keep alive service',
    visible: _android,
    mirrors: {SettingsPageId.battery},
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
    mirrors: {SettingsPageId.data},
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
  static const mentionForeground = Setting(
    'mention_foreground',
    'Notify while app is open',
    SettingsPageId.highlights,
    section: 'Mentions',
    keywords: 'ping push foreground',
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
    mirrors: {SettingsPageId.data},
  );
  static const autoDataSaver = Setting(
    'auto_data_saver',
    'Auto data saver mode',
    SettingsPageId.emotes,
    keywords: 'cellular wifi',
    mirrors: {SettingsPageId.data},
  );
  static const emoteCache = Setting(
    'emote_cache',
    'Emote image cache',
    SettingsPageId.emotes,
    keywords: 'storage nuke clear',
    mirrors: {SettingsPageId.data},
  );
  static const animateEmotes = Setting(
    'animate_emotes',
    'Animate emotes',
    SettingsPageId.emotes,
    section: 'Animation',
    keywords: 'gif',
    mirrors: {SettingsPageId.battery},
  );
  static const adaptiveFps = Setting(
    'adaptive_fps',
    'Adaptive frame rate',
    SettingsPageId.emotes,
    section: 'Animation',
    keywords: 'fps battery',
    mirrors: {SettingsPageId.battery},
  );
  static const idleFps = Setting(
    'idle_fps',
    'Idle frame rate',
    SettingsPageId.emotes,
    section: 'Animation',
    keywords: 'fps battery',
    mirrors: {SettingsPageId.battery},
  );
  static const providers = Setting(
    'providers',
    'Providers',
    SettingsPageId.emotes,
    keywords: 'twitch bttv ffz 7tv effects modifiers paints badges cosmetics',
  );
  static const unlistedEmotes = Setting(
    'unlisted_emotes',
    'Unlisted 7TV emotes',
    SettingsPageId.emotes,
  );
  static const personalEmotes = Setting(
    'personal_emotes',
    'Personal 7TV emotes',
    SettingsPageId.emotes,
    keywords: 'seventv subscriber',
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
  static const dataUsage = Setting(
    'data_usage',
    'Data usage',
    SettingsPageId.data,
    keywords: 'bandwidth mobile data bytes',
  );
  static const updates = Setting(
    'updates',
    'Check for updates',
    SettingsPageId.tools,
    keywords: "what's new changelog version",
  );
  static const settingsBackup = Setting(
    'settings_backup',
    'Import/export settings',
    SettingsPageId.tools,
    keywords: 'backup restore copy paste clipboard file txt',
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
    editLayout,
    liquidGlass,
    chatFontSize,
    chatFontWeight,
    showTimestamps,
    timestampFormat,
    checkered,
    lineSeparator,
    keepScreenOn,
    fastChannelSwipe,
    reopenLastChannel,
    customLayout,
    tighterComposer,
    horizontalSheetActions,
    compactDensity,
    maxMessages,
    sharedChat,
    inlineEmbeds,
    splitLinks,
    recentMessagesLimit,
    recentMessagesSource,
    gapFill,
    archiveEnabled,
    archiveRetention,
    archiveChannelCap,
    preferEmotes,
    mentionFormat,
    replyThreadRoot,
    sendSwipe,
    macros,
    doubleTapCopy,
    stayConnected,
    chatProxy,
    showGiphy,
    giphyHeight,
    showImages,
    imageHeight,
    notifications,
    whisperPush,
    mentionForeground,
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
    adaptiveFps,
    idleFps,
    providers,
    unlistedEmotes,
    personalEmotes,
    tts,
    uploader,
    analytics,
    dataUsage,
    updates,
    settingsBackup,
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
    language,
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
  // Kept across frames with no mounted anchor, so paging can continue.
  ScrollPosition? _position;

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
        duration: Motion.normal,
        curve: Motion.enter,
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
    final l = context.l10n;
    // English stays searchable next to the translation.
    return Setting.available.where((s) {
      final haystack =
          '${s.titleOf(l)} ${s.pathOf(l)} ${s.title} ${s.path} ${s.keywords}'
              .toLowerCase();
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
                      title: Text(hit.titleOf(context.l10n)),
                      subtitle: Text(hit.pathOf(context.l10n)),
                      onTap: () => _open(hit),
                    ),
                ],
              ),
      ),
    );
  }
}
