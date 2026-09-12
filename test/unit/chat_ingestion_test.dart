import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ermchat/models/twitch_message.dart';
import 'package:ermchat/chat/chat.dart';
import 'package:ermchat/client/session.dart';
import 'package:ermchat/services/chat_ingestion.dart';
import 'package:ermchat/services/chat_sender.dart';
import 'package:ermchat/services/emote_manager.dart';
import 'package:ermchat/services/moderation_hub.dart';
import 'package:ermchat/services/twitch_auth.dart';
import 'package:ermchat/services/twitch_badge_service.dart';
import 'package:ermchat/irc/decode/decoder.dart';
import 'package:ermchat/irc/transport/read.dart';
import 'package:ermchat/irc/transport/write.dart';
import 'package:ermchat/services/user_store.dart';

void main() {
  ChatIngestion makeIngestion(EmoteManager emoteManager) {
    final irc = IrcService();
    final ircRead = IrcReadService();
    final session = Session();
    final auth = TwitchAuth();
    final chat = Chat();
    final sender = ChatSender(
      irc: irc,
      session: session,
      twitchAuth: auth,
      onCommand: (_, _, _) {},
      getReplyToMsg: () => null,
      setReplyToMsg: (_) {},
      onSystemMessage: (_, _) {},
      slowModeSeconds: (_) => 0,
      selfBadges: (_) => const {},
    );
    final moderation = ModerationHub(
      chat: chat,
      session: session,
      isModerationActive: (_) => false,
      onSystemMessage: (_, _) {},
      onSelfTimeoutArmed: (_, _) {},
      onSelfTimeoutCleared: (_) {},
    );
    return ChatIngestion(
      irc: irc,
      ircRead: ircRead,
      readDecoder: IrcChatDecoder(ircRead.onIrcMessage),
      writeDecoder: IrcChatDecoder(irc.onIrcMessage),
      chat: chat,
      session: session,
      userStore: UserStore(),
      emoteManager: emoteManager,
      badgeService: TwitchBadgeService(),
      twitchAuth: auth,
      sender: sender,
      moderation: moderation,
      mentionsChannel: '@mentions',
      getMaxMessagesPerChannel: () => 500,
      getSelectedChannel: () => null,
      isModerationActive: (_) => false,
      isJoinFailureNotified: (_) => false,
      onSystemMessage: (_, _, {accent, messageId}) {},
    );
  }

  test('ingesting messages fires no per-sender 7TV lookups', () async {
    SharedPreferences.setMockInitialValues({});
    var sevenTvHttp = 0;
    final manager = EmoteManager(
      fetchStagger: Duration.zero,
      sevenTvOwnedSetIdsFetcher: (_) async {
        sevenTvHttp++;
        return [];
      },
      sevenTvEmoteSetFetcher: (_, _) async {
        sevenTvHttp++;
        return [];
      },
    );
    final ingestion = makeIngestion(manager);

    // Live message with unknown words: previously triggered a listing fetch.
    ingestion.precacheMessageEmotes(
      TwitchMessage(
        login: 'someone',
        text: 'SomeUnknownWord hello',
        userId: 'sender-1',
      ),
      'ch',
    );
    // History message: same expectation.
    ingestion.precacheMessageEmotes(
      TwitchMessage(
        login: 'someone',
        text: 'SomeUnknownWord hello',
        userId: 'sender-1',
        isHistory: true,
      ),
      'ch',
    );
    await Future.delayed(const Duration(milliseconds: 100));

    expect(sevenTvHttp, 0);
  });
}
