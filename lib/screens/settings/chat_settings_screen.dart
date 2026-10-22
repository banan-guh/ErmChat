import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import '../../l10n/l10n.dart';
import '../../services/chat_sender.dart';
import '../../services/twitch_auth.dart';
import '../../util/prefs.dart';
import 'link_whitelist_screen.dart';
import 'macros_screen.dart';
import 'inline_embeds_screen.dart';
import 'prefs_tiles.dart';
import 'proxy_settings_screen.dart';
import 'settings_page.dart';
import 'setting_info.dart';
import 'settings_search.dart';
import '../../widgets/dialogs.dart';
import '../../util/settings.dart';

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

  String get _inlineEmbedsSubtitle {
    return switch ((_showGifs, _showImages)) {
      (true, true) => context.l10n.embedsGiphyImages,
      (true, false) => context.l10n.embedsGiphy,
      (false, true) => context.l10n.embedsImages,
      _ => context.l10n.off,
    };
  }

  @override
  Widget build(BuildContext context) {
    return SettingsPage(
      title: Text(context.l10n.pageChat),
      body: ListenableBuilder(
        listenable: Listenable.merge([
          Settings.sharedChatMode,
          Settings.giphyInlineEnabled,
          Settings.imageEmbedEnabled,
          Settings.proxyEnabled,
        ]),
        builder: (context, _) => ListView(
          children: [
            SettingsSectionHeader(context.l10n.sectionMessages),
            SettingAnchor(
              Setting.sharedChat,
              child: SettingsNavTile(
                icon: Icons.merge_type,
                title: Setting.sharedChat.titleOf(context.l10n),
                subtitle: _sharedChatModeLabel,
                onTap: _pickSharedChatMode,
              ),
            ),
            SettingAnchor(
              Setting.inlineEmbeds,
              child: SettingsNavTile(
                icon: Icons.gif_box,
                title: Setting.inlineEmbeds.titleOf(context.l10n),
                subtitle: _inlineEmbedsSubtitle,
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const InlineEmbedsScreen(),
                    ),
                  );
                },
              ),
            ),
            SettingAnchor(
              Setting.splitLinks,
              child: SettingsNavTile(
                icon: Icons.link,
                title: Setting.splitLinks.titleOf(context.l10n),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => const LinkWhitelistSettingsScreen(),
                  ),
                ),
              ),
            ),
            SettingsSectionHeader(context.l10n.sectionTyping),
            SettingAnchor(
              Setting.preferEmotes,
              child: PrefsSwitchTile(
                secondary: const Icon(Icons.sentiment_very_satisfied),
                title: Setting.preferEmotes.titleOf(context.l10n),
                pref: Settings.preferEmotesFirst,
              ),
            ),
            const _MentionFormatTile(),
            SettingAnchor(
              Setting.replyThreadRoot,
              child: PrefsSwitchTile(
                secondary: const Icon(Icons.reply),
                title: Setting.replyThreadRoot.titleOf(context.l10n),
                pref: Settings.replyToThreadRoot,
              ),
            ),
            SettingAnchor(
              Setting.sendSwipe,
              child: PrefsSwitchTile(
                secondary: const Icon(Icons.repeat),
                title: Setting.sendSwipe.titleOf(context.l10n),
                subtitle: context.l10n.sendSwipeHint,
                pref: Settings.sendSwipeMenu,
              ),
            ),
            ValueListenableBuilder(
              valueListenable: Settings.sendSwipeMenu,
              builder: (context, on, _) =>
                  on ? const _SpamSpeedTile() : const SizedBox.shrink(),
            ),
            if (widget.twitchAuth != null)
              SettingAnchor(
                Setting.macros,
                child: SettingsNavTile(
                  icon: Icons.bolt,
                  title: Setting.macros.titleOf(context.l10n),
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) =>
                            MacrosScreen(twitchAuth: widget.twitchAuth!),
                      ),
                    );
                  },
                ),
              ),
            SettingsSectionHeader(context.l10n.sectionUsers),
            SettingAnchor(
              Setting.doubleTapCopy,
              child: PrefsSwitchTile(
                secondary: const Icon(Icons.content_copy),
                title: Setting.doubleTapCopy.titleOf(context.l10n),
                subtitle: context.l10n.delaysUserCard,
                pref: Settings.doubleTapNameCopy,
              ),
            ),
            SettingsSectionHeader(context.l10n.sectionConnection),
            StayConnectedTile(onChanged: widget.onBackgroundServiceChanged),
            SettingAnchor(
              Setting.chatProxy,
              child: SettingsNavTile(
                icon: Icons.cloud,
                title: Setting.chatProxy.titleOf(context.l10n),
                subtitle: Settings.proxyEnabled.value
                    ? context.l10n.on
                    : context.l10n.off,
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => const ProxySettingsScreen(),
                  ),
                ),
              ),
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
      builder: (_) => const SafeArea(
        top: false,
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: 8),
          child: _SpamSpeedSliders(),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([
        Settings.spamIntervalMs,
        Settings.spamIntervalModMs,
      ]),
      builder: (context, _) {
        final l = context.l10n;
        final plain = Settings.spamIntervalMs.value;
        final mod = Settings.spamIntervalModMs.value;
        final over =
            _SpamSpeedSliders._over(plain, ChatSender.plainRepeatGap) ||
            _SpamSpeedSliders._over(mod, ChatSender.privilegedRepeatGap);
        return ListTile(
          leading: const Icon(Icons.speed),
          title: Text(l.spamSpeed),
          subtitle: Text(
            '${l.spamSpeedPlainShort}: '
            '${_SpamSpeedSliders._value(l, plain, ChatSender.plainRepeatGap)} · '
            '${l.spamSpeedModShort}: '
            '${_SpamSpeedSliders._value(l, mod, ChatSender.privilegedRepeatGap)}',
            style: over
                ? TextStyle(color: Theme.of(context).colorScheme.error)
                : null,
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _open(context),
        );
      },
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
    required int Function(Prefs p) read,
    required Future<void> Function(Prefs p, int ms) write,
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
      read: (p) => _stepOf(read(p)).toDouble(),
      write: (p, v) => write(p, _steps[v.round()]),
      tint: (v) => _over(_steps[v.round()], limit) ? error : null,
    );
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      _slider(
        context,
        role: context.l10n.spamSpeedPlain,
        limit: ChatSender.plainRepeatGap,
        read: (p) => p.spamIntervalMs,
        write: (p, ms) => p.setSpamIntervalMs(ms),
      ),
      _slider(
        context,
        role: context.l10n.spamSpeedMod,
        limit: ChatSender.privilegedRepeatGap,
        read: (p) => p.spamIntervalModMs,
        write: (p, ms) => p.setSpamIntervalModMs(ms),
      ),
    ],
  );
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
        Setting.mentionFormat,
        child: SettingsNavTile(
          icon: Icons.text_format,
          title: Setting.mentionFormat.titleOf(context.l10n),
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
    return SettingAnchor(
      Setting.stayConnected,
      child: PrefsSwitchTile(
        secondary: const Icon(Icons.wifi_tethering),
        title: Setting.stayConnected.titleOf(context.l10n),
        subtitle: context.l10n.persistentNotification,
        info: const SettingInfoButton(Setting.stayConnected),
        pref: Settings.backgroundService,
        onChanged: onChanged,
      ),
    );
  }
}
