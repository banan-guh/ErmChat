import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ermchat/services/chat_store.dart';
import 'package:ermchat/services/mod_actions.dart';
import 'package:ermchat/services/twitch_api.dart';
import 'package:ermchat/services/twitch_auth.dart';
import 'package:ermchat/widgets/mod_view.dart';

ChatStore _store() => ChatStore(
  channels: ['testchannel'],
  channelMessages: {},
  messageKeys: {},
  chatStatus: {},
  channelsWithUnread: {},
  channelsWithUnreadMentions: {},
  unreadMentionsPerChannel: {},
  historyLoaded: {},
  channelsEmotesResolved: {},
  channelUserIds: {},
  lastSentWireText: {},
);

Future<http.Response> _handler(http.Request request) async {
  final path = request.url.path;
  if (request.method == 'GET' && path.endsWith('moderation/moderators')) {
    return http.Response(
      '{"data":[{"user_login":"rosmod"}],"pagination":{}}',
      200,
    );
  }
  if (request.method == 'GET' && path.endsWith('channels/vips')) {
    return http.Response(
      '{"data":[{"user_login":"rosvip"}],"pagination":{}}',
      200,
    );
  }
  if (request.method == 'GET' && path.endsWith('moderation/shield_mode')) {
    return http.Response('{"data":[{"is_active":false}]}', 200);
  }
  if (request.method == 'GET' && path.endsWith('users')) {
    final login = request.url.queryParameters['login'] ?? 'x';
    return http.Response('{"data":[{"id":"u-$login","login":"$login"}]}', 200);
  }
  if (request.method == 'DELETE' && path.endsWith('moderation/bans')) {
    return http.Response('', 204);
  }
  if (request.method == 'GET' && path.endsWith('moderation/unban_requests')) {
    return http.Response('{"data":[],"pagination":{}}', 200);
  }
  if (request.method == 'GET' && path.endsWith('moderation/blocked_terms')) {
    return http.Response('{"data":[],"pagination":{}}', 200);
  }
  return http.Response('{"message":"unexpected $path"}', 404);
}

class _Harness extends StatelessWidget {
  const _Harness({
    required this.store,
    required this.actions,
    required this.auth,
    required this.tab,
    required this.onUser,
  });

  final ChatStore store;
  final ModActions actions;
  final TwitchAuth auth;
  final TabController tab;
  final ValueChanged<String> onUser;

  @override
  Widget build(BuildContext context) {
    return ModViewPanel(
      channel: 'testchannel',
      store: store,
      modActions: actions,
      auth: auth,
      tabController: tab,
      refresh: store.heldVersion,
      isModerationActive: (_) => true,
      isAutomodActive: (_) => true,
      getRoomModes: (_) => const {},
      onNotice: (_) {},
      onShowUser: onUser,
    );
  }
}

void main() {
  testWidgets('mod view tabs render queue, feed, users, and rosters', (
    tester,
  ) async {
    final t0 = DateTime(2026, 1, 1);
    final store = _store();
    store.addHeldMessage(
      const HeldMessage(
        messageId: 'h1',
        channel: 'testchannel',
        userLogin: 'helduser',
        text: 'bad text here',
        category: 'bullying',
      ),
    );
    store.addModActivity(
      ModActivityEntry(
        at: t0,
        channel: 'testchannel',
        action: 'ban',
        moderator: 'moduser',
        target: 'feeduser',
        reason: 'spam',
      ),
    );
    store.putBan(
      BanEntry(
        at: t0,
        channel: 'testchannel',
        login: 'banneduser',
        reason: 'hate',
        moderator: 'moduser',
      ),
    );
    store.addWarning(
      WarnEntry(
        at: t0,
        channel: 'testchannel',
        target: 'warneduser',
        moderator: 'moduser',
      ),
    );

    final auth = TwitchAuth();
    auth.accessToken = 'tok';
    final actions = ModActions(
      twitchApi: TwitchApi(client: MockClient(_handler)),
      getChannelUserIds: () => {'testchannel': 'broad1'},
      getCurrentUserId: () => 'mod1',
    );

    String? shownUser;
    final tab = TabController(length: 6, vsync: const TestVSync());
    addTearDown(tab.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: _Harness(
            store: store,
            actions: actions,
            auth: auth,
            tab: tab,
            onUser: (login) => shownUser = login,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Queue is the initial tab; tapping a row opens the user card.
    expect(find.text('helduser'), findsOneWidget);
    await tester.tap(find.text('helduser'));
    await tester.pump();
    expect(shownUser, 'helduser');

    // Activity tab shows the feed line.
    tab.animateTo(1);
    await tester.pumpAndSettle();
    expect(find.text('moduser banned feeduser: "spam".'), findsOneWidget);

    // Users tab shows bans, warnings, and the mod/vip rosters.
    tab.animateTo(2);
    await tester.pumpAndSettle();
    expect(find.text('banneduser'), findsOneWidget);
    expect(find.text('warneduser'), findsOneWidget);
    expect(find.text('rosmod'), findsOneWidget);
    expect(find.text('rosvip'), findsOneWidget);

    // Unban works end to end and drops the roster row.
    await tester.tap(find.byIcon(Icons.undo));
    await tester.pumpAndSettle();
    expect(find.text('banneduser'), findsNothing);

    // Requests tab loads the (empty) pending inbox.
    tab.animateTo(4);
    await tester.pumpAndSettle();
    expect(find.text('No pending requests.'), findsOneWidget);

    // Terms tab loads the (empty) public blocked list.
    tab.animateTo(5);
    await tester.pumpAndSettle();
    expect(find.text('No blocked terms yet.'), findsOneWidget);

    // Modes tab builds without crashing.
    tab.animateTo(3);
    await tester.pumpAndSettle();
  });
}
