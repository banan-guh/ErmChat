import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show ThemeMode;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/emote_fetch_tier.dart';
import '../theme_colors.dart';
import 'constants.dart';
import 'layout_density.dart';
import 'timestamp_formatter.dart';

/// One persisted setting: its key, its default, and its own change signal.
///
/// [value] reads the store, so it is always current. Listeners hear only this
/// setting, after [set] or after a bulk write announced through
/// [Settings.refresh].
class Pref<T> extends ChangeNotifier implements ValueListenable<T> {
  Pref(this.key, this.fallback, {this.exported = true});

  final String key;
  final T fallback;

  /// Whether a settings export carries it.
  final bool exported;

  static SharedPreferences? _store;

  /// The value listeners last heard, to tell a bulk write that changed this
  /// setting from one that did not.
  Object? _heard;

  @override
  T get value => decode(_store?.get(key));

  /// The typed value for what the store holds; anything unusable reads as
  /// [fallback].
  @protected
  T decode(Object? raw) => raw is T ? raw : fallback;

  /// What the store keeps for [value].
  @protected
  Object? encode(T value) => value;

  /// The storable form of an imported [raw], or null when it has the wrong
  /// type.
  Object? importable(Object? raw) => raw is T ? raw : null;

  Future<void> set(T value) async {
    assert(Settings.all.contains(this), '$key is missing from Settings.all');
    final store = _store ?? await Settings.bind();
    final raw = encode(value);
    switch (raw) {
      case null:
        await store.remove(key);
      case final bool v:
        await store.setBool(key, v);
      case final int v:
        await store.setInt(key, v);
      case final double v:
        await store.setDouble(key, v);
      case final String v:
        await store.setString(key, v);
      case final List<String> v:
        await store.setStringList(key, v);
    }
    _announce();
  }

  void _announce() {
    final now = value;
    if (_same(now, _heard)) return;
    _heard = now;
    notifyListeners();
  }

  static bool _same(Object? a, Object? b) =>
      a is List && b is List ? listEquals(a, b) : a == b;
}

class IntPref extends Pref<int> {
  IntPref(super.key, super.fallback, {this.min, this.max, super.exported});

  final int? min;
  final int? max;

  @override
  int decode(Object? raw) {
    if (raw is! int) return fallback;
    return raw.clamp(min ?? raw, max ?? raw);
  }
}

class DoublePref extends Pref<double> {
  DoublePref(super.key, super.fallback, {this.min, this.max, super.exported});

  final double? min;
  final double? max;

  @override
  double decode(Object? raw) {
    if (raw is! num) return fallback;
    final v = raw.toDouble();
    return v.clamp(min ?? v, max ?? v);
  }

  @override
  Object? importable(Object? raw) => raw is num ? raw.toDouble() : null;
}

/// An enum stored by name; an unknown name reads as the fallback.
class EnumPref<E extends Enum> extends Pref<E> {
  EnumPref(super.key, super.fallback, this.values, {super.exported});

  final List<E> values;

  @override
  E decode(Object? raw) =>
      values.firstWhere((e) => e.name == raw, orElse: () => fallback);

  @override
  Object? encode(E value) => value.name;

  @override
  Object? importable(Object? raw) => raw is String ? raw : null;
}

/// A string list. [L] is nullable where "never set" differs from empty.
class ListPref<L extends List<String>?> extends Pref<L> {
  ListPref(super.key, super.fallback, {super.exported});

  @override
  L decode(Object? raw) =>
      raw is List ? raw.cast<String>().toList() as L : fallback;

  @override
  Object? importable(Object? raw) =>
      raw is List && raw.every((e) => e is String) ? raw.cast<String>() : null;
}

/// Every user setting, one line each. Keys and defaults live here and
/// nowhere else; `Prefs` keeps device state, caches and per-account data.
abstract final class Settings {
  /// Points every setting at the plugin's store. A new store instance (tests
  /// swapping mock values) resets what listeners heard without notifying.
  static Future<SharedPreferences> bind() async {
    final store = await SharedPreferences.getInstance();
    if (identical(store, Pref._store)) return store;
    Pref._store = store;
    for (final p in all) {
      p._heard = p.value;
    }
    return store;
  }

  /// Notifies the settings whose value changed since listeners last heard.
  /// Runs after writes that bypass [Pref.set] (imports, raw store writes).
  static void refresh() {
    for (final p in all) {
      p._announce();
    }
  }

  // ── App / theme ─────────────────────────────────────────────────────
  static final themeMode = EnumPref(
    'themeMode',
    ThemeMode.system,
    ThemeMode.values,
  );

  /// App language tag (`es`, `pt_BR`); null follows the system.
  static final locale = Pref<String?>('locale', null);
  static final keepScreenOn = Pref('keep_screen_on', true);
  static final trueDark = Pref('true_dark', false);
  static final accentColor = Pref('accent_color', kDefaultAccent);

  // ── Chat behavior ───────────────────────────────────────────────────
  static final maxMessagesPerChannel = IntPref(
    'max_messages_per_channel',
    kMaxMessagesPerChannelDefault,
  );
  static final recentMessagesLimit = IntPref(
    'recent_messages_limit',
    kRecentMessagesLimitDefault,
  );

  /// Days of chat the archive keeps, at most 30.
  static final archiveRetentionDays = IntPref(
    'archive_retention_days',
    30,
    min: 1,
    max: 30,
  );

  /// Megabytes of chat the archive keeps per channel, 0 for no cap.
  static final archiveChannelCapMb = IntPref('archive_channel_cap_mb', 0);

  /// Nonzero sizes the history fetch to the gap since the last message seen.
  static final historyGapFill = IntPref('history_gap_fill', 1);

  /// Messages the first history fetch loads: the default page under gap
  /// fill, which tops up the gap itself, else the manual count.
  static int get historyFetchLimit => historyGapFill.value != 0
      ? kRecentMessagesLimitDefault
      : recentMessagesLimit.value;
  static final replyToThreadRoot = Pref('reply_to_thread_root', false);
  static final backgroundService = Pref('background_service', false);
  static final whisperNotifications = Pref('whisper_notifications', false);
  static final mentionNotifyForeground = Pref(
    'mention_notify_foreground',
    false,
  );
  static final preferEmotesFirst = Pref('prefer_emotes_first', false);

  /// Haptic feedback on holds, drags and crossed thresholds.
  static final haptics = Pref('haptics', true);

  /// Swiping up from send opens the send menu (spam).
  static final sendSwipeMenu = Pref('send_swipe_menu', false);

  /// Gap between spam sends in ms for a plain account; 0 paces
  /// automatically under Twitch's limits.
  static final spamIntervalMs = IntPref('spam_interval_ms', 0);

  /// [spamIntervalMs] where you are broadcaster, mod or VIP.
  static final spamIntervalModMs = IntPref('spam_interval_mod_ms', 0);
  static final doubleTapNameCopy = Pref('double_tap_name_copy', false);
  static final showTimestamps = Pref(kShowTimestampsPrefKey, true);
  static final timestampFormat = Pref(
    kTimestampFormatPrefKey,
    kDefaultTimestampFormat,
  );
  static final sharedChatMode = Pref('shared_chat_mode', 'spotlight');

  /// 7TV name paints and badges.
  static final sevenTvCosmetics = Pref('seventv_name_paints', false);
  static final showInput = Pref('show_input', true);
  static final mentionFormat = Pref('mention_format', '@name');
  static final analyticsEnabled = Pref('analytics_enabled', false);
  static final whatsNewEnabled = Pref('whats_new_enabled', true);
  static final updateCheckEnabled = Pref('update_check_enabled', true);

  // ── Emote playback ──────────────────────────────────────────────────
  static final animateGifs = Pref('animate_gifs', true);
  static final ffzEffects = Pref('ffz_effects', true);
  static final bttvModifiers = Pref('bttv_modifiers', true);
  static final adaptiveEmoteFps = Pref('adaptive_emote_fps', true);

  /// Emote frame rate while idle under adaptive, 0 to 60; 0 freezes.
  static final idleEmoteFps = IntPref('idle_emote_fps', 30);

  // ── Customization ───────────────────────────────────────────────────
  static final chatFontSize = DoublePref('chat_font_size', 14);

  /// Chat body weight as a CSS value: 400, 500, 600 or 700.
  static final chatFontWeight = IntPref('chat_font_weight', 400);
  static final highlightOpacity = DoublePref('highlight_opacity', 0.6);
  static final checkeredMessages = Pref('checkered_messages', false);
  static final lineSeparator = Pref('line_separator', false);
  static final fastChannelSnap = Pref('fast_channel_snap', true);
  static final layoutDensity = EnumPref(
    'layout_density',
    LayoutDensity.auto,
    LayoutDensity.values,
  );
  static final customLayoutEnabled = Pref('custom_layout_enabled', false);
  static final overrideTightComposer = Pref('override_tight_composer', true);
  static final overrideSheetActionRow = Pref(
    'override_sheet_action_row',
    false,
  );
  static final overrideCompactDensity = Pref('override_compact_density', true);

  /// The selected chrome theme key; `Prefs.chromeThemeKey` validates it.
  static final chromeTheme = Pref<String?>('chrome_theme', null);

  /// Encoded custom chrome themes, in the order they were made.
  static final customChromeThemes = ListPref<List<String>>(
    'chrome_themes_custom',
    const [],
  );
  static final liquidGlass = Pref('liquid_glass', false);

  // ── Inline embeds ───────────────────────────────────────────────────
  static final giphyInlineEnabled = Pref(
    kGiphyInlineEnabledPrefKey,
    kGiphyInlineEnabledDefault,
  );
  static final giphyInlineHeight = DoublePref(
    kGiphyInlineHeightPrefKey,
    kGiphyInlineHeightDefault,
    min: kGiphyInlineHeightMin,
    max: kGiphyInlineHeightMax,
  );
  static final imageEmbedEnabled = Pref(
    kImageEmbedEnabledPrefKey,
    kImageEmbedEnabledDefault,
  );
  static final imageEmbedHeight = DoublePref(
    kImageEmbedHeightPrefKey,
    kImageEmbedHeightDefault,
    min: kImageEmbedHeightMin,
    max: kImageEmbedHeightMax,
  );

  // ── Emotes ──────────────────────────────────────────────────────────
  static final emoteFetchTier = IntPref(
    'emote_fetch_tier',
    EmoteFetchTier.high.index,
    min: 0,
    max: EmoteFetchTier.values.length - 1,
  );
  static final emoteFetchAuto = IntPref(
    'emote_fetch_auto',
    defaultEmoteFetchAutoMode.index,
  );
  static final emoteCacheMb = IntPref('emote_cache_mb', defaultEmoteCacheMb);

  /// Null until the user first changes providers.
  static final emoteProvidersDisabled = ListPref<List<String>?>(
    'emote_providers_disabled',
    null,
  );
  static final emoteAllowUnlisted7tv = Pref('emote_7tv_allow_unlisted', true);
  static final emoteAllowPersonal7tv = Pref('emote_7tv_allow_personal', true);

  // ── TTS ─────────────────────────────────────────────────────────────
  static final ttsEnabled = Pref('tts_enabled', false);
  static final ttsQueueMode = Pref('tts_queue_mode', 'queue');
  static final ttsFormatMode = Pref('tts_format_mode', 'userAndMessage');
  static final ttsIgnoreUrls = Pref('tts_ignore_urls', true);
  static final ttsIgnoreEmotes = Pref('tts_ignore_emotes', true);
  static final ttsForceEnglish = Pref('tts_force_english', false);
  static final ttsUserIgnoreList = ListPref<List<String>>(
    'tts_user_ignore_list',
    const [],
  );

  // ── Stream, history backend, local stores ───────────────────────────
  static final streamPipEnabled = Pref('stream_pip_enabled', false);
  static final recentMessagesMode = Pref('recent_messages_mode', 'auto');
  static final localIgnores = Pref('local_ignores_v1', '');
  static final keywordReplacements = Pref('keyword_replacements_v1', '');
  static final pingRules = Pref<String?>('ping_rules_v1', null);
  static final analyticsFilterStopwords = Pref(
    'analytics_filter_stopwords',
    false,
  );

  /// Null until first saved, so the defaults seed once.
  static final linkWhitelist = ListPref<List<String>?>(
    kLinkWhitelistPrefKey,
    null,
  );
  static final linkWhitelistEnabled = Pref('link_whitelist_enabled', false);

  // ── Chat proxy (ermchat-server) ─────────────────────────────────────
  // Never exported: the proxy receives the OAuth token, so an imported file
  // must never point it somewhere else.
  static final proxyEnabled = Pref('proxy_enabled', false, exported: false);
  static final proxyUrl = Pref('proxy_url', '', exported: false);

  static final List<Pref<Object?>> all = [
    themeMode,
    locale,
    keepScreenOn,
    trueDark,
    accentColor,
    maxMessagesPerChannel,
    recentMessagesLimit,
    archiveRetentionDays,
    archiveChannelCapMb,
    historyGapFill,
    replyToThreadRoot,
    backgroundService,
    whisperNotifications,
    mentionNotifyForeground,
    preferEmotesFirst,
    haptics,
    sendSwipeMenu,
    spamIntervalMs,
    spamIntervalModMs,
    doubleTapNameCopy,
    showTimestamps,
    timestampFormat,
    sharedChatMode,
    sevenTvCosmetics,
    showInput,
    mentionFormat,
    analyticsEnabled,
    whatsNewEnabled,
    updateCheckEnabled,
    animateGifs,
    ffzEffects,
    bttvModifiers,
    adaptiveEmoteFps,
    idleEmoteFps,
    chatFontSize,
    chatFontWeight,
    highlightOpacity,
    checkeredMessages,
    lineSeparator,
    fastChannelSnap,
    layoutDensity,
    customLayoutEnabled,
    overrideTightComposer,
    overrideSheetActionRow,
    overrideCompactDensity,
    chromeTheme,
    customChromeThemes,
    liquidGlass,
    giphyInlineEnabled,
    giphyInlineHeight,
    imageEmbedEnabled,
    imageEmbedHeight,
    emoteFetchTier,
    emoteFetchAuto,
    emoteCacheMb,
    emoteProvidersDisabled,
    emoteAllowUnlisted7tv,
    emoteAllowPersonal7tv,
    ttsEnabled,
    ttsQueueMode,
    ttsFormatMode,
    ttsIgnoreUrls,
    ttsIgnoreEmotes,
    ttsForceEnglish,
    ttsUserIgnoreList,
    streamPipEnabled,
    recentMessagesMode,
    localIgnores,
    keywordReplacements,
    pingRules,
    analyticsFilterStopwords,
    linkWhitelist,
    linkWhitelistEnabled,
    proxyEnabled,
    proxyUrl,
  ];
}
