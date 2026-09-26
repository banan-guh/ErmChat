// Shared fakes, pumps and harness widgets for the widget suites.
// See chat_test.dart, settings_test.dart and sheets_test.dart.

export 'dart:async';
export 'package:flutter/gestures.dart';
export 'package:flutter/material.dart';
export 'package:flutter/services.dart';
export 'package:flutter_riverpod/flutter_riverpod.dart' hide AsyncError;
export 'package:ermchat/color_utils.dart';
export 'package:flutter_test/flutter_test.dart';
export 'package:http/http.dart';
export 'package:http/testing.dart';
export 'package:shared_preferences/shared_preferences.dart';
export 'package:flutter_secure_storage/flutter_secure_storage.dart';
export 'package:ermchat/main.dart';
export 'package:ermchat/screens/settings/account_screen.dart';
export 'package:ermchat/screens/settings/channel_settings_screen.dart';
export 'package:ermchat/util/constants.dart';
export 'package:ermchat/screens/settings/chat_settings_screen.dart';
export 'package:ermchat/screens/settings/customization_screen.dart';
export 'package:ermchat/screens/settings/emotes_settings_screen.dart';
export 'package:ermchat/screens/settings/tools_settings_screen.dart';
export 'package:ermchat/screens/home_screen.dart';
export 'package:ermchat/sheets/user_sheet.dart';
export 'package:ermchat/services/analytics_service.dart';
export 'package:ermchat/models/emote_fetch_tier.dart';
export 'package:ermchat/services/twitch_api.dart';
export 'package:ermchat/eventsub/transport/connection.dart';
export 'package:ermchat/eventsub/transport/events.dart';
export 'package:ermchat/irc/decode/codec.dart';
export 'package:ermchat/irc/decode/events.dart';
export 'package:ermchat/irc/transport/events.dart';
export 'package:ermchat/irc/transport/read.dart';
export 'package:ermchat/irc/transport/write.dart';
export 'package:ermchat/services/recent_messages.dart';
export 'package:ermchat/services/twitch_auth.dart';
export 'package:ermchat/models/twitch_badge.dart';
export 'package:ermchat/models/twitch_message.dart';
export 'package:ermchat/composer/suggestion.dart';
export 'package:ermchat/widgets/app_snack.dart';
export 'package:ermchat/widgets/autocomplete_dropdown.dart';
export 'package:ermchat/widgets/chat_body.dart';
export 'package:ermchat/widgets/chat_message_tile.dart';
export 'package:ermchat/widgets/chat_notice_bar.dart';
export 'package:ermchat/chrome/stream_layout.dart';
export 'package:ermchat/widgets/tabbed_layout.dart';
export 'package:flutter_cache_manager/flutter_cache_manager.dart';
export 'package:ermchat/services/emote_cache_manager.dart';
export 'package:ermchat/services/emote_images.dart';
export '../helpers/fake_cache_repo.dart';
export 'package:ermchat/screens/settings/analytics_screen.dart';
export 'package:ermchat/emotes/emote.dart';
export 'package:ermchat/services/emote_manager.dart';
export 'package:ermchat/providers/app_providers.dart';
export 'package:ermchat/providers/emote_providers.dart';
export 'package:ermchat/widgets/emote_menu_panel.dart';
export 'package:url_launcher_platform_interface/link.dart';
export 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';
export 'package:ermchat/widgets/emote_sheet.dart';
export 'package:ermchat/widgets/message_input.dart';
export 'package:ermchat/widgets/chrome_menu_button.dart';
export 'package:ermchat/widgets/user_profile_sheet.dart';
export 'package:ermchat/widgets/image_embed_viewer.dart';
export 'package:cached_network_image/cached_network_image.dart';

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:ermchat/eventsub/transport/connection.dart';
import 'package:ermchat/eventsub/transport/events.dart';
import 'package:ermchat/irc/decode/events.dart';
import 'package:ermchat/irc/transport/events.dart';
import 'package:ermchat/irc/transport/read.dart';
import 'package:ermchat/irc/transport/write.dart';
import 'package:ermchat/services/recent_messages.dart';
import 'package:ermchat/models/twitch_message.dart';
import 'package:ermchat/widgets/app_snack.dart';
import 'package:ermchat/widgets/chat_body.dart';
import 'package:ermchat/widgets/chat_notice_bar.dart';
import 'package:ermchat/chrome/stream_layout.dart';
import 'package:ermchat/widgets/tabbed_layout.dart';
import 'package:url_launcher_platform_interface/link.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

class FakeEventSubService extends EventSubService {
  final _statusCtrl = StreamController<EventSubStatus>.broadcast(sync: true);

  @override
  Future<void> connect({String? url}) async {}

  @override
  Stream<EventSubStatus> get onStatus => _statusCtrl.stream;

  void triggerConnect() => _statusCtrl.add(EventSubStatus.connected);
  void triggerDisconnect() => _statusCtrl.add(EventSubStatus.disconnected);

  @override
  void dispose() {
    _statusCtrl.close();
    super.dispose();
  }
}

class FakeRecentMessagesService extends RecentMessagesService {
  @override
  Future<List<TwitchMessage>> fetchRecent(
    String channel, {
    int limit = 100,
  }) async {
    final now = DateTime.now();
    return [
      TwitchMessage(
        login: 'alice',
        text: 'hello world',
        channel: channel,
        messageId: 'root-1',
        timestamp: now.subtract(const Duration(minutes: 5)),
      ),
      TwitchMessage(
        login: 'bob',
        text: 'hi alice',
        channel: channel,
        messageId: 'reply-1',
        replyToParentId: 'root-1',
        replyToUser: 'alice',
        replyToText: 'hello world',
        timestamp: now.subtract(const Duration(minutes: 4)),
        isHistory: true,
      ),
      TwitchMessage(
        login: 'charlie',
        text: 'standalone post',
        channel: channel,
        messageId: 'standalone-1',
        timestamp: now.subtract(const Duration(minutes: 3)),
      ),
    ];
  }
}

class GappedRecentMessagesService extends RecentMessagesService {
  int calls = 0;

  @override
  Future<List<TwitchMessage>> fetchRecent(
    String channel, {
    int limit = 100,
  }) async {
    calls++;
    final now = DateTime.now();
    return [
      TwitchMessage(
        login: 'alice',
        text: 'early message',
        channel: channel,
        messageId: 'early-1',
        timestamp: now.subtract(const Duration(minutes: 5)),
      ),
      if (calls > 1)
        TwitchMessage(
          login: 'bob',
          text: 'missed during gap',
          channel: channel,
          messageId: 'gap-1',
          timestamp: now.subtract(const Duration(minutes: 1)),
        ),
    ];
  }
}

class FakeIrcService extends IrcService {
  final _statusCtrl = StreamController<IrcConnectionStatus>.broadcast(
    sync: true,
  );

  @override
  Future<void> connect({
    required String username,
    required String accessToken,
  }) async {}

  @override
  Stream<IrcConnectionStatus> get onStatus => _statusCtrl.stream;

  bool _fakeConnected = false;

  @override
  bool get isConnected => _fakeConnected;

  void triggerJoin(String channel) {
    handleLine(':tmi.twitch.tv ROOMSTATE #$channel');
  }

  void triggerConnect({String? joinChannel}) {
    _fakeConnected = true;
    _statusCtrl.add(IrcConnectionStatus.connected);
    if (joinChannel != null) triggerJoin(joinChannel);
  }

  void triggerDisconnect() {
    _fakeConnected = false;
    _statusCtrl.add(IrcConnectionStatus.disconnected);
  }

  @override
  void dispose() {
    _statusCtrl.close();
    super.dispose();
  }
}

class FakeIrcReadService extends IrcReadService {
  final _statusCtrl = StreamController<IrcConnectionStatus>.broadcast(
    sync: true,
  );

  @override
  Future<void> connect({
    required String username,
    required String accessToken,
  }) async {}

  @override
  Stream<IrcConnectionStatus> get onStatus => _statusCtrl.stream;

  bool _fakeConnected = false;

  @override
  bool get isConnected => _fakeConnected;

  void triggerJoin(String channel) {
    handleLine(':tmi.twitch.tv ROOMSTATE #$channel');
  }

  void triggerConnect({String? joinChannel}) {
    _fakeConnected = true;
    _statusCtrl.add(IrcConnectionStatus.connected);
    if (joinChannel != null) triggerJoin(joinChannel);
  }

  void triggerDisconnect() {
    _fakeConnected = false;
    _statusCtrl.add(IrcConnectionStatus.disconnected);
  }

  /// Delivers a chat message through the real socket decode path so the app
  /// sees it exactly like production traffic. System rows arrive as channel
  /// notices, like the real NOTICE path.
  void emitMessage(TwitchMessage msg) {
    if (msg.isSystem) {
      handleLine(':tmi.twitch.tv NOTICE #${msg.channel} :${msg.text}');
      return;
    }
    final login = msg.login.isEmpty ? 'user' : msg.login;
    final tags = <String>[
      'display-name=${_escapeTag(msg.displayName)}',
      if (msg.messageId != null) 'id=${_escapeTag(msg.messageId!)}',
      if (msg.userId != null) 'user-id=${_escapeTag(msg.userId!)}',
      if (msg.color != null) 'color=${_escapeTag(msg.color!)}',
      'tmi-sent-ts=${msg.timestamp.millisecondsSinceEpoch}',
      if (msg.badges != null && msg.badges!.isNotEmpty)
        'badges=${msg.badges!.map((b) => '${b.setId}/${b.versionId}').join(',')}',
      if (msg.emotePositions != null && msg.emotePositions!.isNotEmpty)
        'emotes=${_encodeEmotePositions(msg.emotePositions!)}',
      if (msg.replyToParentId != null)
        'reply-parent-msg-id=${_escapeTag(msg.replyToParentId!)}',
      if (msg.replyToUser != null)
        'reply-parent-display-name=${_escapeTag(msg.replyToUser!)}',
      if (msg.replyToText != null)
        'reply-parent-msg-body=${_escapeTag(msg.replyToText!)}',
    ];
    handleLine(
      '@${tags.join(';')} '
      ':$login!$login@$login.tmi.twitch.tv PRIVMSG #${msg.channel} :${msg.text}',
    );
  }

  void emitWhisper(TwitchMessage msg) {
    final login = msg.login.isEmpty ? 'user' : msg.login;
    final displayName = msg.displayName.isEmpty ? login : msg.displayName;
    final tags = <String>[
      'display-name=${_escapeTag(displayName)}',
      if (msg.messageId != null) 'id=${_escapeTag(msg.messageId!)}',
      if (msg.userId != null) 'user-id=${_escapeTag(msg.userId!)}',
      if (msg.color != null) 'color=${_escapeTag(msg.color!)}',
    ];
    handleLine(
      '@${tags.join(';')} '
      ':$login!$login@$login.tmi.twitch.tv WHISPER me :${msg.text}',
    );
  }

  void emitUserNotice(UserNoticeEvent event) {
    final tags = <String>[
      'msg-id=${_escapeTag(event.msgId)}',
      'login=${_escapeTag(event.login)}',
      'display-name=${_escapeTag(event.displayName)}',
      if (event.systemMsg != null) 'system-msg=${_escapeTag(event.systemMsg!)}',
      if (event.announcementColor != null)
        'msg-param-color=${_escapeTag(event.announcementColor!)}',
      if (event.userId != null) 'user-id=${_escapeTag(event.userId!)}',
      if (event.messageId != null) 'id=${_escapeTag(event.messageId!)}',
      if (event.color != null) 'color=${_escapeTag(event.color!)}',
      if (event.badges != null && event.badges!.isNotEmpty)
        'badges=${event.badges!.map((b) => '${b.setId}/${b.versionId}').join(',')}',
      if (event.emotePositions != null && event.emotePositions!.isNotEmpty)
        'emotes=${_encodeEmotePositions(event.emotePositions!)}',
    ];
    final trailing = event.text != null ? ' :${event.text}' : '';
    handleLine(
      '@${tags.join(';')} :tmi.twitch.tv USERNOTICE #${event.channel}$trailing',
    );
  }

  void emitBan(
    String user, {
    bool isTimeout = false,
    int? durationSeconds,
    String channel = '',
  }) {
    // An empty ban-duration reads back as a duration-less timeout, which raw
    // IRC cannot otherwise express.
    final tags = isTimeout
        ? '@ban-duration=${durationSeconds?.toString() ?? ''} '
        : '';
    handleLine('$tags:tmi.twitch.tv CLEARCHAT #$channel :$user');
  }

  void emitNotice(String channel, String message) {
    handleLine(':tmi.twitch.tv NOTICE #$channel :$message');
  }

  void emitDeleted(
    String messageId,
    String channel, {
    String user = 'unknown',
    String deletedMessageText = '',
  }) {
    handleLine(
      '@login=${_escapeTag(user)};target-msg-id=${_escapeTag(messageId)} '
      ':tmi.twitch.tv CLEARMSG #$channel :$deletedMessageText',
    );
  }

  @override
  void dispose() {
    _statusCtrl.close();
    super.dispose();
  }
}

/// Escapes a tag value the way Twitch IRCv3 requires (spaces, semicolons,
/// backslashes, CR/LF); the frame parser would otherwise end the tag block
/// at the first space.
String _escapeTag(String value) => value
    .replaceAll(r'\', r'\\')
    .replaceAll(' ', r'\s')
    .replaceAll(';', r'\:')
    .replaceAll('\r', r'\r')
    .replaceAll('\n', r'\n');

/// Encodes parsed emote positions back into an `emotes` tag value. Wire ends
/// are inclusive while [EmotePosition.endIndex] is exclusive.
String _encodeEmotePositions(List<EmotePosition> positions) {
  final byId = <String, List<EmotePosition>>{};
  for (final p in positions) {
    byId.putIfAbsent(p.emoteId, () => []).add(p);
  }
  return byId.entries
      .map(
        (e) =>
            '${e.key}:${e.value.map((p) => '${p.startIndex}-${p.endIndex - 1}').join(',')}',
      )
      .join('/');
}

class ConfigurableRecentMessagesService extends RecentMessagesService {
  final List<TwitchMessage> messages;
  ConfigurableRecentMessagesService(this.messages);

  @override
  Future<List<TwitchMessage>> fetchRecent(
    String channel, {
    int limit = 100,
  }) async => messages;
}

class ScriptedRecentMessagesService extends RecentMessagesService {
  final List<List<TwitchMessage>> responses;
  int callCount = 0;
  ScriptedRecentMessagesService(this.responses);

  @override
  Future<List<TwitchMessage>> fetchRecent(
    String channel, {
    int limit = 100,
  }) async {
    final idx = callCount < responses.length ? callCount : responses.length - 1;
    callCount++;
    return responses[idx];
  }
}

class CompleterRecentMessagesService extends RecentMessagesService {
  final Completer<List<TwitchMessage>> completer;
  CompleterRecentMessagesService(this.completer);

  @override
  Future<List<TwitchMessage>> fetchRecent(String channel, {int limit = 100}) =>
      completer.future;
}

class GatedRecentMessagesService extends RecentMessagesService {
  GatedRecentMessagesService(
    this.responses, {
    required this.gateOnCall,
    required this.gate,
  });

  final List<List<TwitchMessage>> responses;
  final int gateOnCall;
  final Completer<void> gate;
  int callCount = 0;

  @override
  Future<List<TwitchMessage>> fetchRecent(
    String channel, {
    int limit = 100,
  }) async {
    callCount++;
    final idx = (callCount - 1).clamp(0, responses.length - 1);
    if (callCount == gateOnCall) {
      await gate.future;
    }
    return responses[idx];
  }
}

class FakeUrlLauncher extends UrlLauncherPlatform {
  bool succeed = true;
  String? lastUrl;
  PreferredLaunchMode? lastMode;

  @override
  LinkDelegate? get linkDelegate => null;

  @override
  Future<bool> canLaunch(String url) async => true;

  @override
  Future<bool> launchUrl(String url, LaunchOptions options) async {
    lastUrl = url;
    lastMode = options.mode;
    return succeed;
  }

  @override
  Future<void> closeWebView() async {}
}

// Bar over a fake composer through the real ChatBody, so overlay order and
// the composer gap match production layout.
Widget noticeHarness(ChatNoticeController controller) {
  return MaterialApp(
    home: Scaffold(
      body: ChatBody(
        bodyBuilder:
            (
              context, {
              required hideChromeForKeyboard,
              required maxWidth,
              required maxHeight,
              required keyboardH,
              required composerH,
            }) => Container(key: const Key('notice-chat')),
        threadPanel: const SizedBox.shrink(),
        mentionsPanel: const SizedBox.shrink(),
        modViewPanel: const SizedBox.shrink(),
        emotePickerBuilder: (context, {required sheetBoxHeight}) =>
            const SizedBox.shrink(),
        autocomplete: const SizedBox.shrink(),
        emoteMaxFraction: 0.5,
        keyboardH: 0,
        composer: const SizedBox(key: Key('notice-composer'), height: 56),
        notice: ChatNoticeBar(controller: controller),
      ),
    ),
  );
}

Widget snackHarness() {
  return MaterialApp(
    scaffoldMessengerKey: rootScaffoldMessengerKey,
    navigatorObservers: [SnackPopObserver()],
    home: Scaffold(
      body: Builder(
        builder: (context) => Center(
          child: TextButton(
            onPressed: () => AppSnack.show(context, 'from button'),
            child: const Text('show snack'),
          ),
        ),
      ),
    ),
  );
}

const stackedVideoKey = Key('stub_video');
const stackedAudioKey = Key('stub_audio');

Widget stackedStubVideo() => const SizedBox(
  key: stackedVideoKey,
  child: ColoredBox(color: Colors.red),
);

Widget stackedStubAudio() => const SizedBox(key: stackedAudioKey, height: 56);

// Mimics the stacked portrait slot: tab strip, player dock, chat page.
Widget stackedPlayerHarness({
  required bool showVideo,
  required double keyboardH,
}) {
  return MaterialApp(
    home: Scaffold(
      resizeToAvoidBottomInset: true,
      body: ChatBody(
        bodyBuilder:
            (
              context, {
              required hideChromeForKeyboard,
              required maxWidth,
              required maxHeight,
              required keyboardH,
              required composerH,
            }) {
              return Column(
                children: [
                  Expanded(
                    child: TabbedLayout(
                      tabs: const ['xqc'],
                      selectedIndex: 0,
                      onSelectedIndexChanged: (_) {},
                      showTabBar: !hideChromeForKeyboard,
                      tabBarAnimationDuration: hideChromeForKeyboard
                          ? Duration.zero
                          : const Duration(milliseconds: 200),
                      belowTabBar: buildStackedPlayer(
                        show: showVideo,
                        video: stackedStubVideo(),
                        audioBar: stackedStubAudio(),
                      ),
                      pageBuilder: (_, _) =>
                          const ColoredBox(color: Colors.green),
                    ),
                  ),
                ],
              );
            },
        threadPanel: const SizedBox.shrink(),
        mentionsPanel: const SizedBox.shrink(),
        modViewPanel: const SizedBox.shrink(),
        emotePickerBuilder: (_, {required sheetBoxHeight}) =>
            const SizedBox.shrink(),
        autocomplete: const SizedBox.shrink(),
        emoteMaxFraction: 0.6,
        keyboardH: keyboardH,
        composer: const SizedBox(height: 56),
      ),
    ),
  );
}

Widget pipCollapseHarness({required bool isInPip}) {
  return MaterialApp(
    home: Scaffold(
      body: ChatBody(
        bodyBuilder:
            (
              context, {
              required hideChromeForKeyboard,
              required maxWidth,
              required maxHeight,
              required keyboardH,
              required composerH,
            }) => Container(key: const Key('pip-video')),
        threadPanel: const SizedBox(key: Key('pip-thread')),
        mentionsPanel: const SizedBox.shrink(),
        modViewPanel: const SizedBox.shrink(),
        emotePickerBuilder: (context, {required sheetBoxHeight}) =>
            const SizedBox.shrink(),
        autocomplete: const SizedBox.shrink(),
        emoteMaxFraction: 0.5,
        keyboardH: 0,
        isInPip: isInPip,
        composer: const SizedBox(key: Key('pip-composer'), height: 56),
      ),
    ),
  );
}
