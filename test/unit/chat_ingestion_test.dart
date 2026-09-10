import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ermchat/models/twitch_message.dart';
import 'package:ermchat/chat/chat.dart';
import 'package:ermchat/services/chat_ingestion.dart';
import 'package:ermchat/services/emote_manager.dart';
import 'package:ermchat/services/twitch_auth.dart';
import 'package:ermchat/services/twitch_badge_service.dart';
import 'package:ermchat/services/twitch_irc.dart';
import 'package:ermchat/services/user_store.dart';

void main() {
  ChatIngestion makeIngestion(EmoteManager emoteManager) {
    return ChatIngestion(
      irc: IrcService(),
      ircRead: IrcReadService(),
      chat: Chat(),
      userStore: UserStore(),
      emoteManager: emoteManager,
      badgeService: TwitchBadgeService(),
      twitchAuth: TwitchAuth(),
      lastSentWireText: {},
      mentionsChannel: '@mentions',
      getMaxMessagesPerChannel: () => 500,
      getSelectedChannel: () => null,
      isModerationActive: (_) => false,
      onSelfTimeoutArmed: (_, _) {},
      onSelfTimeoutCleared: (_) {},
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
