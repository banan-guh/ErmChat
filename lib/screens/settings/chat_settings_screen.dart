import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import '../../l10n/l10n.dart';
import '../../services/chat_sender.dart';
import '../../services/twitch_auth.dart';
import '../../util/settings.dart';
import 'link_whitelist_screen.dart';
import 'macros_screen.dart';
import 'inline_embeds_screen.dart';
import 'prefs_tiles.dart';
import 'proxy_settings_screen.dart';
import 'settings_page.dart';
import 'setting_info.dart';
import 'settings_search.dart';
import '../../widgets/dialogs.dart';

class ChatSettingsScreen extends StatefulWidget {
  final TwitchAuth? twitchAuth;

  /// Foreground-service side effect: starting/stopping the service cannot be
  /// re-applied from a prefs re-read, so it stays a callback.
  final ValueChanged<bool>? onBackgroundServiceChanged;

  const ChatSettingsScreen({
    super.key,
    this.twitchAuth,
    this.onBackgroundServiceChanged,
  });

  @override
  State<ChatSettingsScreen> createState() => _ChatSettingsScreenState();
}

class _ChatSettingsScreenState extends State<ChatSettingsScreen> {
  String get _sharedChatMode => Settings.sharedChatMode.value;

  bool get _showGifs => Settings.giphyInlineEnabled.value;

  bool get _showImages => Settings.imageEmbedEnabled.value;

  String get _sharedChatModeLabel => switch (_sharedChatMode) {
    'fade' => context.l10n.sharedChatFade,
    'hide' => context.l10n.sharedChatHide,
    _ => context.l10n.sharedChatSpotlight,
  };

  Future<void> _pickSharedChatMode() async {
    final l = context.l10n;
    final selected = await showChoiceDialog<String>(
      context,
      title: l.sharedChatTitle,
      value: _sharedChatMode,
      options: [
        ('spotlight', l.sharedChatSpotlight, l.sharedChatSpotlightHint),
        ('fade', l.sharedChatFade, l.sharedChatFadeHint),
        ('hide', l.sharedChatHide, l.sharedChatHideHint),
      ],
    );
    if (selected == null || !mounted || selected == _sharedChatMode) return;
    await Settings.sharedChatMode.set(selected);
  }

  String get _emoteSort => Settings.emoteSortOrder.value;

  String get _emoteSortLabel => switch (_emoteSort) {
    'newest' => context.l10n.emoteOrderNewest,
    'oldest' => context.l10n.emoteOrderOldest,
    _ => context.l10n.emoteOrderAlphabetical,
  };

  Future<void> _pickEmoteSort() async {
    final l = context.l10n;
    final selected = await showChoiceDialog<String>(
      context,
      title: Settings.emoteSortOrder.titleOf(l),
      value: _emoteSort,
      options: [
        ('name', l.emoteOrderAlphabetical, ''),
        ('newest', l.emoteOrderNewest, ''),
        ('oldest', l.emoteOrderOldest, ''),
      ],
    );
    if (selected == null || !mounted || selected == _emoteSort) return;
    await Settings.emoteSortOrder.set(selected);
  }

  String get _copyGestureLabel => switch (Settings.copyUsernameGesture.value) {
    NameCopyGesture.doubleTap => context.l10n.copyGestureDoubleTap,
    NameCopyGesture.longPress => context.l10n.copyGestureLongPress,
    NameCopyGesture.off => context.l10n.off,
  };

  Future<void> _pickCopyGesture() async {
    final l = context.l10n;
    final current = Settings.copyUsernameGesture.value;
    final selected = await showChoiceDialog<NameCopyGesture>(
      context,
      title: Settings.copyUsernameGesture.titleOf(l),
      value: current,
      options: [
        (NameCopyGesture.off, l.off, ''),
        (NameCopyGesture.doubleTap, l.copyGestureDoubleTap, l.delaysUserCard),
        (
          NameCopyGesture.longPress,
          l.copyGestureLongPress,
          l.copyGestureLongPressHint,
        ),
      ],
    );
    if (selected == null || !mounted || selected == current) return;
    await Settings.copyUsernameGesture.set(selected);
  }

  String get _inlineEmbedsSubtitle {
    return switch ((_showGifs, _showImages)) {
      (true, true) => context.l10n.embedsGiphyImages,
      (true, false) => context.l10n.embedsGiphy,
      (false, true) => context.l10n.embedsImages,
      _ => context.l10n.off,
    };
  }

  /// A nav row for [setting] that opens the page [page] builds.
  Widget _nav(
    Setting<Object?> setting,
    IconData icon,
    Widget Function() page, {
    String? subtitle,
  }) {
    return SettingAnchor(
      setting,
      child: _navTile(
        setting.titleOf(context.l10n),
        icon,
        page,
        subtitle: subtitle,
      ),
    );
  }

  /// The same row for a [row] that stores nothing.
  Widget _navRow(
    SettingsRow row,
    IconData icon,
    Widget Function() page, {
    String? subtitle,
  }) {
    return SettingAnchor.row(
      row,
      child: _navTile(
        row.titleOf(context.l10n),
        icon,
        page,
        subtitle: subtitle,
      ),
    );
  }

  /// The tile both nav rows share: leading icon, title and the push.
  SettingsNavTile _navTile(
    String title,
    IconData icon,
    Widget Function() page, {
    String? subtitle,
  }) {
    return SettingsNavTile(
      icon: icon,
      title: title,
      subtitle: subtitle,
      onTap: () =>
          Navigator.push(context, MaterialPageRoute(builder: (_) => page())),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SettingsPage(
      title: Text(context.l10n.pageChat),
      body: ListenableBuilder(
        listenable: Listenable.merge([
          Settings.sharedChatMode,
          Settings.emoteSortOrder,
          Settings.copyUsernameGesture,
          Settings.giphyInlineEnabled,
          Settings.imageEmbedEnabled,
          Settings.proxyEnabled,
        ]),
        builder: (context, _) => ListView(
          children: [
            SettingsSectionHeader(context.l10n.sectionMessages),
            SettingAnchor(
              Settings.sharedChatMode,
              child: SettingsNavTile(
                icon: Icons.merge_type,
                title: Settings.sharedChatMode.titleOf(context.l10n),
                subtitle: _sharedChatModeLabel,
                onTap: _pickSharedChatMode,
              ),
            ),
            _navRow(
              SettingsRow.inlineEmbeds,
              Icons.gif_box,
              () => const InlineEmbedsScreen(),
              subtitle: _inlineEmbedsSubtitle,
            ),
            _nav(
              Settings.linkWhitelistEnabled,
              Icons.link,
              () => const LinkWhitelistSettingsScreen(),
            ),
            SettingsSectionHeader(context.l10n.sectionEmotes),
            SettingAnchor(
              Settings.emoteSortOrder,
              child: SettingsNavTile(
                icon: Icons.sort,
                title: Settings.emoteSortOrder.titleOf(context.l10n),
                subtitle: _emoteSortLabel,
                onTap: _pickEmoteSort,
              ),
            ),
            SettingsSectionHeader(context.l10n.sectionTyping),
            SettingSwitch(
              Settings.preferEmotesFirst,
              secondary: const Icon(Icons.sentiment_very_satisfied),
            ),
            const _MentionFormatTile(),
            SettingSwitch(
              Settings.replyToThreadRoot,
              secondary: const Icon(Icons.reply),
            ),
            SettingSwitch(
              Settings.sendSwipeMenu,
              secondary: const Icon(Icons.repeat),
              subtitle: context.l10n.sendSwipeHint,
            ),
            ValueListenableBuilder(
              valueListenable: Settings.sendSwipeMenu,
              builder: (context, on, _) =>
                  on ? const _SpamSpeedTile() : const SizedBox.shrink(),
            ),
            if (widget.twitchAuth != null)
              _navRow(
                SettingsRow.macros,
                Icons.bolt,
                () => MacrosScreen(twitchAuth: widget.twitchAuth!),
              ),
            SettingsSectionHeader(context.l10n.sectionUsers),
            SettingAnchor(
              Settings.copyUsernameGesture,
              child: SettingsNavTile(
                icon: Icons.content_copy,
                title: Settings.copyUsernameGesture.titleOf(context.l10n),
                subtitle: _copyGestureLabel,
                onTap: _pickCopyGesture,
              ),
            ),
            SettingsSectionHeader(context.l10n.sectionConnection),
            StayConnectedTile(onChanged: widget.onBackgroundServiceChanged),
            _nav(
              Settings.proxyEnabled,
              Icons.cloud,
              () => const ProxySettingsScreen(),
              subtitle: Settings.proxyEnabled.value
                  ? context.l10n.on
                  : context.l10n.off,
            ),
          ],
        ),
      ),
    );
  }
}

/// Spam pace per role, plain and mod/VIP, shown only while the send menu is
/// on: one row with both values, and a tap opens their sliders. Auto stays
/// under Twitch's limits; a gap faster than the role's limit shows red with
/// "!".
class _SpamSpeedTile extends StatelessWidget {
  const _SpamSpeedTile();

  Future<void> _open(BuildContext context) async {
    await showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      showDragHandle: true,
      builder: (_) => const SafeArea(
        top: false,
        child: Padding(
          padding: EdgeInsets.only(bottom: 8),
          child: _SpamSpeedSliders(),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: const Icon(Icons.speed),
      title: Text(context.l10n.spamSpeed),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => _open(context),
    );
  }
}

class _SpamSpeedSliders extends StatelessWidget {
  const _SpamSpeedSliders();

  // 0 is Auto.
  static const _steps = [
    0,
    100,
    200,
    300,
    400,
    500,
    750,
    1000,
    1250,
    1500,
    2000,
    3000,
  ];

  static int _stepOf(int ms) {
    final i = _steps.indexOf(ms);
    return i < 0 ? 0 : i;
  }

  static bool _over(int ms, Duration limit) =>
      ms > 0 && ms < limit.inMilliseconds;

  static String _value(AppLocalizations l, int ms, Duration limit) {
    if (ms <= 0) return l.spamSpeedAuto;
    final text = l.spamSpeedMs(ms);
    return _over(ms, limit) ? '$text !' : text;
  }

  Widget _slider(
    BuildContext context, {
    required String role,
    required Duration limit,
    required int Function() read,
    required Future<void> Function(int ms) write,
  }) {
    final l = context.l10n;
    final error = Theme.of(context).colorScheme.error;
    return PrefsSliderTile(
      label: (v) => '$role: ${_value(l, _steps[v.round()], limit)}',
      sliderLabel: (v) => _value(l, _steps[v.round()], limit),
      min: 0,
      max: (_steps.length - 1).toDouble(),
      divisions: _steps.length - 1,
      defaultValue: 0,
      read: () => _stepOf(read()).toDouble(),
      write: (v) => write(_steps[v.round()]),
      tint: (v) => _over(_steps[v.round()], limit) ? error : null,
    );
  }

  @override
  Widget build(BuildContext context) {
    final plain = _slider(
      context,
      role: context.l10n.spamSpeedPlain,
      limit: ChatSender.plainRepeatGap,
      read: () => Settings.spamIntervalMs.value,
      write: (ms) => Settings.spamIntervalMs.set(ms),
    );
    final mod = _slider(
      context,
      role: context.l10n.spamSpeedMod,
      limit: ChatSender.privilegedRepeatGap,
      read: () => Settings.spamIntervalModMs.value,
      write: (ms) => Settings.spamIntervalModMs.set(ms),
    );
    // Landscape has little height to spare, so the two share a row instead
    // of stacking into half the screen.
    if (MediaQuery.orientationOf(context) == Orientation.landscape) {
      return Row(
        children: [
          Expanded(child: plain),
          Expanded(child: mod),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [plain, mod],
    );
  }
}

class _MentionFormatTile extends StatelessWidget {
  const _MentionFormatTile();

  static const formats = <String, String>{
    '@name': '@name',
    '@name,': '@name,',
    'name': 'name',
    'name,': 'name,',
  };

  Future<void> _pick(BuildContext context) async {
    final current = Settings.mentionFormat.value;
    final selected = await showChoiceDialog<String>(
      context,
      title: context.l10n.mentionFormatTitle,
      value: current,
      options: [
        for (final entry in formats.entries) (entry.key, entry.value, ''),
      ],
    );
    if (selected == null || selected == current) return;
    await Settings.mentionFormat.set(selected);
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<String>(
      valueListenable: Settings.mentionFormat,
      builder: (context, format, _) => SettingAnchor(
        Settings.mentionFormat,
        child: SettingsNavTile(
          icon: Icons.text_format,
          title: Settings.mentionFormat.titleOf(context.l10n),
          subtitle: formats[format],
          onTap: () => _pick(context),
        ),
      ),
    );
  }
}

/// Background connection through the Android foreground service. Shown on
/// Chat and mirrored on Battery. Renders nothing off Android.
class StayConnectedTile extends StatelessWidget {
  const StayConnectedTile({super.key, this.onChanged});

  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    if (kIsWeb || !Platform.isAndroid) return const SizedBox.shrink();
    return SettingSwitch(
      Settings.backgroundService,
      secondary: const Icon(Icons.wifi_tethering),
      subtitle: context.l10n.persistentNotification,
      info: SettingInfoButton(Settings.backgroundService),
      onChanged: onChanged,
    );
  }
}
