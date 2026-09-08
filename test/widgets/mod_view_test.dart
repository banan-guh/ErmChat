import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ermchat/services/chat_store.dart';
import 'package:ermchat/panels/mod_panel.dart';
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
  recordedRequests.add(request);
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
  if (request.method == 'GET' && path.endsWith('moderation/automod/settings')) {
    return http.Response(
      '{"data":[{"broadcaster_id":"broad1","moderator_id":"mod1","overall_level":2,"disability":2,"aggression":2,"sexuality_sex_or_gender":2,"misogyny":2,"bullying":2,"swearing":2,"race_ethnicity_or_religion":2,"sex_based_terms":2}]}',
      200,
    );
  }
  if (request.method == 'PUT' && path.endsWith('moderation/automod/settings')) {
    return http.Response(
      '{"data":[{"broadcaster_id":"broad1","moderator_id":"mod1","overall_level":4,"disability":4,"aggression":4,"sexuality_sex_or_gender":4,"misogyny":4,"bullying":4,"swearing":4,"race_ethnicity_or_religion":4,"sex_based_terms":4}]}',
      200,
    );
  }
  if (request.method == 'DELETE' &&
      path.endsWith('moderation/suspicious_users')) {
    return http.Response('{"data":[]}', 200);
  }
  if (request.method == 'GET' && path.endsWith('moderation/banned')) {
    return http.Response(
      '{"data":[{"user_id":"u1","user_login":"bannedlogin","user_name":"BannedLogin","expires_at":"","reason":"spam","moderator_id":"mod1","moderator_login":"rosmod","moderator_name":"Rosmod"}],"pagination":{}}',
      200,
    );
  }
  if (request.method == 'GET' &&
      (path.endsWith('/polls') || path.endsWith('/predictions'))) {
    return http.Response('{"data":[],"pagination":{}}', 200);
  }
  if (request.method == 'GET' &&
      path.endsWith('channel_points/custom_rewards')) {
    final paused = pausedRewards.contains('reward1');
    return http.Response(
      '{"data":[{"id":"reward1","title":"Hydrate","cost":500,"is_enabled":true,"is_paused":$paused}],"pagination":{}}',
      200,
    );
  }
  if (request.method == 'PATCH' &&
      path.endsWith('channel_points/custom_rewards')) {
    try {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      if (body['is_paused'] == true) {
        pausedRewards.add(request.url.queryParameters['id'] ?? 'reward1');
      } else {
        pausedRewards.remove(request.url.queryParameters['id']);
      }
    } catch (_) {
      pausedRewards.add('reward1');
    }
    return http.Response(
      '{"data":[{"id":"reward1","title":"Hydrate","cost":500,"is_enabled":true,"is_paused":true}]}',
      200,
    );
  }
  if (request.method == 'GET' && path.endsWith('custom_rewards/redemptions')) {
    if (fulfilledRedemptions.contains('red1')) {
      return http.Response('{"data":[],"pagination":{}}', 200);
    }
    return http.Response(
      '{"data":[{"id":"red1","user_login":"fan","user_input":"do a flip","status":"UNFULFILLED","redeemed_at":"2026-01-02T03:04:05Z","reward":{"id":"reward1","title":"Hydrate","cost":500}}],"pagination":{}}',
      200,
    );
  }
  if (request.method == 'PATCH' &&
      path.endsWith('custom_rewards/redemptions')) {
    final id = request.url.queryParameters['id'];
    if (id != null) fulfilledRedemptions.add(id);
    return http.Response('{"data":[]}', 200);
  }
  if (request.method == 'POST' && path.endsWith('moderation/automod/message')) {
    return http.Response('', 204);
  }
  if (request.method == 'PATCH' && path.endsWith('chat/settings')) {
    return http.Response('{"data":[]}', 200);
  }
  if (request.method == 'PUT' && path.endsWith('moderation/shield_mode')) {
    return http.Response('{"data":[]}', 200);
  }
  return http.Response('{"message":"unexpected $path"}', 404);
}

final recordedRequests = <http.Request>[];

/// Redemption ids the mock treats as fulfilled (drops from the queue).
final fulfilledRedemptions = <String>{};

/// Reward ids the mock treats as paused.
final pausedRewards = <String>{};

class _Harness extends StatelessWidget {
  const _Harness({
    required this.store,
    required this.actions,
    required this.auth,
    required this.tab,
    required this.onUser,
    this.broadcaster = false,
  });

  final ChatStore store;
  final ModActions actions;
  final TwitchAuth auth;
  final TabController tab;
  final ValueChanged<String> onUser;
  final bool broadcaster;

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
      isBroadcaster: broadcaster,
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
    store.noteSuspicious(
      SuspiciousInfo(
        at: t0,
        channel: 'testchannel',
        login: 'flaggeduser',
        status: 'restricted',
        types: const ['manually_added'],
        banEvasion: 'possible',
        sharedBanChannelIds: const ['111'],
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
    recordedRequests.clear();
    fulfilledRedemptions.clear();
    pausedRewards.clear();
    // The Channel tab is taller than the default 600px viewport; a tall
    // surface keeps every sliver built so no scrolling is needed.
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    final tab = TabController(
      length: ModPanels.tabCount,
      vsync: const TestVSync(),
    );
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

    // Users tab shows bans, warnings, flags, and the mod/vip rosters.
    tab.animateTo(2);
    await tester.pumpAndSettle();
    expect(find.text('banneduser'), findsOneWidget);
    expect(find.text('warneduser'), findsOneWidget);
    expect(find.text('flaggeduser'), findsOneWidget);
    expect(find.text('rosmod'), findsOneWidget);
    expect(find.text('rosvip'), findsOneWidget);

    // Unban works end to end and drops the roster row.
    await tester.tap(find.byIcon(Icons.undo));
    await tester.pumpAndSettle();
    expect(find.text('banneduser'), findsNothing);

    // Clearing a flag drops the flagged row.
    await tester.tap(find.byIcon(Icons.visibility_off_outlined));
    await tester.pumpAndSettle();
    expect(find.text('flaggeduser'), findsNothing);

    // Requests tab loads the (empty) pending inbox.
    tab.animateTo(4);
    await tester.pumpAndSettle();
    expect(find.text('No pending requests.'), findsOneWidget);

    // Terms tab loads the (empty) public blocked list.
    tab.animateTo(5);
    await tester.pumpAndSettle();
    expect(find.text('No blocked terms yet.'), findsOneWidget);

    // Setup tab loads levels; saving a preset puts overall_level.
    tab.animateTo(6);
    await tester.pumpAndSettle();
    expect(find.text('Swearing'), findsOneWidget);
    await tester.tap(find.text('Max'));
    await tester.pump();
    await tester.tap(find.text('Save changes'));
    await tester.pumpAndSettle();
    final put = recordedRequests.lastWhere(
      (r) => r.method == 'PUT' && r.url.path.endsWith('automod/settings'),
    );
    expect(jsonDecode(put.body), {'overall_level': 4});

    // Modes tab builds without crashing.
    tab.animateTo(3);
    await tester.pumpAndSettle();

    // Channel tab shows stream tools to moderators; rosters stay
    // broadcaster-only.
    tab.animateTo(7);
    await tester.pumpAndSettle();
    expect(find.text('Start raid...'), findsOneWidget);
    expect(find.textContaining('Only the broadcaster'), findsNothing);

    // As the broadcaster the rosters and stream tools render.
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: _Harness(
            store: store,
            actions: actions,
            auth: auth,
            tab: tab,
            onUser: (login) => shownUser = login,
            broadcaster: true,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('Only the broadcaster'), findsNothing);
    expect(find.text('bannedlogin'), findsOneWidget);
    expect(find.text('rosmod'), findsOneWidget);
    expect(find.text('No active poll.'), findsOneWidget);
    expect(find.text('Start poll'), findsOneWidget);
    expect(
      find.text('No open prediction. Create one with /prediction.'),
      findsOneWidget,
    );

    // Points section loads rewards; selecting one loads its queue.
    expect(find.text('Hydrate'), findsOneWidget);
    await tester.tap(find.text('Hydrate'));
    await tester.pumpAndSettle();
    expect(find.text('fan'), findsOneWidget);

    // Fulfill drops the redemption row.
    await tester.tap(find.byIcon(Icons.check));
    await tester.pumpAndSettle();
    await tester.pumpAndSettle();
    expect(find.text('fan'), findsNothing);

    // Pause toggles the reward status.
    await tester.tap(find.byIcon(Icons.pause));
    await tester.pumpAndSettle();
    await tester.pumpAndSettle();
    expect(find.textContaining('Paused'), findsOneWidget);
  });

  testWidgets('queue allow drops the row and filters reset', (tester) async {
    final store = _store();
    store.addHeldMessage(
      const HeldMessage(
        messageId: 'h-allow',
        channel: 'testchannel',
        userLogin: 'allowuser',
        text: 'flagged one',
        category: 'bullying',
      ),
    );
    store.addHeldMessage(
      const HeldMessage(
        messageId: 'h-other',
        channel: 'testchannel',
        userLogin: 'otheruser',
        text: 'flagged two',
        category: 'spam',
      ),
    );
    store.addHeldMessage(
      const HeldMessage(
        messageId: 'h-third',
        channel: 'testchannel',
        userLogin: 'thirduser',
        text: 'flagged three',
        category: 'bullying',
      ),
    );
    final auth = TwitchAuth();
    auth.accessToken = 'tok';
    final actions = ModActions(
      twitchApi: TwitchApi(client: MockClient(_handler)),
      getChannelUserIds: () => {'testchannel': 'broad1'},
      getCurrentUserId: () => 'mod1',
    );
    recordedRequests.clear();
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    final tab = TabController(
      length: ModPanels.tabCount,
      vsync: const TestVSync(),
    );
    addTearDown(tab.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: _Harness(
            store: store,
            actions: actions,
            auth: auth,
            tab: tab,
            onUser: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('allowuser'), findsOneWidget);
    expect(find.text('otheruser'), findsOneWidget);
    await tester.tap(find.widgetWithText(ChoiceChip, 'spam'));
    await tester.pump();
    expect(find.text('otheruser'), findsOneWidget);
    expect(find.text('allowuser'), findsNothing);
    await tester.tap(find.widgetWithText(ChoiceChip, 'spam'));
    await tester.pump();
    expect(find.text('allowuser'), findsOneWidget);
    await tester.tap(find.byTooltip('Allow').at(2));
    await tester.pumpAndSettle();
    expect(find.text('allowuser'), findsNothing);
    final allow = recordedRequests.lastWhere(
      (r) => r.url.path.endsWith('moderation/automod/message'),
    );
    expect(jsonDecode(allow.body)['action'], 'ALLOW');
    expect(find.text('otheruser'), findsOneWidget);
    expect(find.text('thirduser'), findsOneWidget);
  });

  testWidgets('modes emote toggle sends chat settings', (tester) async {
    final store = _store();
    final auth = TwitchAuth();
    auth.accessToken = 'tok';
    final actions = ModActions(
      twitchApi: TwitchApi(client: MockClient(_handler)),
      getChannelUserIds: () => {'testchannel': 'broad1'},
      getCurrentUserId: () => 'mod1',
    );
    recordedRequests.clear();
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    final tab = TabController(
      length: ModPanels.tabCount,
      vsync: const TestVSync(),
    );
    addTearDown(tab.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: _Harness(
            store: store,
            actions: actions,
            auth: auth,
            tab: tab,
            onUser: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    tab.animateTo(3);
    await tester.pumpAndSettle();
    final tile = find.widgetWithText(SwitchListTile, 'Emote-only');
    expect(tile, findsOneWidget);
    await tester.tap(tile);
    await tester.pumpAndSettle();
    final patch = recordedRequests.lastWhere(
      (r) => r.url.path.endsWith('chat/settings'),
    );
    expect(jsonDecode(patch.body)['emote_mode'], isTrue);
  });
}
