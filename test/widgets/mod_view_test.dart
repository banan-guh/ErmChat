import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ermchat/chat/chat.dart';
import 'package:ermchat/chat/channel/moderation.dart';
import 'package:ermchat/panels/mod_panel.dart';
import 'package:ermchat/services/mod_actions.dart';
import 'package:ermchat/services/twitch_api.dart';
import 'package:ermchat/services/twitch_auth.dart';
import 'package:ermchat/widgets/mod_view.dart';
import 'package:ermchat/widgets/tab_drag_focus.dart';

Chat _chat() {
  final chat = Chat();
  chat.ensure('testchannel');
  return chat;
}

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
    required this.chat,
    required this.actions,
    required this.auth,
    required this.tab,
    required this.onUser,
    this.broadcaster = false,
    this.onNotice,
  });

  final Chat chat;
  final ModActions actions;
  final TwitchAuth auth;
  final TabController tab;
  final ValueChanged<String> onUser;
  final bool broadcaster;
  final ValueChanged<String>? onNotice;

  @override
  Widget build(BuildContext context) {
    return ModViewPanel(
      channel: 'testchannel',
      chat: chat,
      modActions: actions,
      auth: auth,
      tabController: tab,
      refresh: chat.channelFor('testchannel')!.moderation.heldVersion,
      termsVersion: ValueNotifier(0),
      dragFocus: TabDragFocus(tab: () => tab, onFocusChanged: (_) {}),
      isModerationActive: (_) => true,
      isAutomodActive: (_) => true,
      getRoomModes: (_) => const {},
      onNotice: onNotice ?? (_) {},
      onShowUser: onUser,
      isBroadcaster: broadcaster,
    );
  }
}

/// Pumps the Mod View on [tabIndex] over [handler]; returns the notices.
Future<List<String>> _pumpOn(
  WidgetTester tester,
  int tabIndex, {
  Chat? chat,
  Future<http.Response> Function(http.Request) handler = _handler,
}) async {
  final auth = TwitchAuth();
  auth.accessToken = 'tok';
  final actions = ModActions(
    twitchApi: TwitchApi(client: MockClient(handler)),
    getChannelUserIds: () => {'testchannel': 'broad1'},
    getCurrentUserId: () => 'mod1',
  );
  recordedRequests.clear();
  tester.view.physicalSize = const Size(800, 1600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  final tab = TabController(
    length: ModPanels.tabCount,
    vsync: const TestVSync(),
    initialIndex: tabIndex,
  );
  addTearDown(tab.dispose);
  final notices = <String>[];
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: _Harness(
          chat: chat ?? _chat(),
          actions: actions,
          auth: auth,
          tab: tab,
          onUser: (_) {},
          onNotice: notices.add,
        ),
      ),
    ),
  );
  return notices;
}

void main() {
  testWidgets('mod view tabs render queue, feed, users, and rosters', (
    tester,
  ) async {
    final t0 = DateTime(2026, 1, 1);
    final chat = _chat();
    final mod = chat.channelFor('testchannel')!.moderation;
    mod.addHeld(
      const HeldMessage(
        messageId: 'h1',
        channel: 'testchannel',
        userLogin: 'helduser',
        text: 'bad text here',
        category: 'bullying',
      ),
    );
    mod.addFeed(
      ModActivityEntry(
        at: t0,
        channel: 'testchannel',
        action: 'ban',
        moderator: 'moduser',
        target: 'feeduser',
        reason: 'spam',
      ),
    );
    mod.putBan(
      BanEntry(
        at: t0,
        channel: 'testchannel',
        login: 'banneduser',
        reason: 'hate',
        moderator: 'moduser',
      ),
    );
    mod.addWarning(
      WarnEntry(
        at: t0,
        channel: 'testchannel',
        target: 'warneduser',
        moderator: 'moduser',
      ),
    );
    mod.noteSuspicious(
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
    final notices = <String>[];
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
            chat: chat,
            actions: actions,
            auth: auth,
            tab: tab,
            onUser: (login) => shownUser = login,
            onNotice: notices.add,
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

    // Users tab shows bans, warnings, and flags to mods; the mod/vip
    // rosters are broadcaster-only Helix and stay hidden (no error).
    tab.animateTo(4);
    await tester.pumpAndSettle();
    expect(find.text('banneduser'), findsOneWidget);
    expect(find.text('warneduser'), findsOneWidget);
    expect(find.text('flaggeduser'), findsOneWidget);
    expect(find.text('rosmod'), findsNothing);
    expect(find.text('rosvip'), findsNothing);
    expect(
      recordedRequests.where(
        (r) =>
            r.url.path.endsWith('moderation/moderators') ||
            r.url.path.endsWith('channels/vips'),
      ),
      isEmpty,
    );

    // Unban works end to end and drops the roster row.
    await tester.tap(find.widgetWithText(OutlinedButton, 'Unban').first);
    await tester.pumpAndSettle();
    expect(find.text('banneduser'), findsNothing);

    // Clearing a flag drops the flagged row.
    await tester.tap(find.widgetWithText(OutlinedButton, 'Clear').first);
    await tester.pumpAndSettle();
    expect(find.text('flaggeduser'), findsNothing);

    // Requests tab loads the (empty) pending inbox.
    tab.animateTo(5);
    await tester.pumpAndSettle();
    expect(find.text('No pending requests.'), findsOneWidget);

    // Terms tab loads the (empty) public blocked list.
    tab.animateTo(6);
    await tester.pumpAndSettle();
    expect(find.text('No blocked terms yet.'), findsOneWidget);

    // Setup tab loads levels; saving a preset puts overall_level.
    tab.animateTo(7);
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
    tab.animateTo(2);
    await tester.pumpAndSettle();

    // Channel tab shows stream tools to moderators; rosters stay
    // broadcaster-only.
    tab.animateTo(3);
    await tester.pumpAndSettle();
    expect(find.text('Start raid'), findsOneWidget);
    expect(find.textContaining('Only the broadcaster'), findsNothing);

    // Broadcaster-only tiles stay visible but greyed for mods: tapping
    // explains instead of calling Helix.
    await tester.tap(find.text('Start raid'));
    await tester.pump();
    expect(notices.last, 'Only broadcasters can use this.');
    expect(find.text('Raid a channel?'), findsNothing);
    await tester.tap(find.text('Commercial'));
    await tester.pump();
    expect(notices.last, 'Only broadcasters can use this.');
    expect(find.text('Commercial length'), findsNothing);
    expect(
      recordedRequests.where((r) => r.url.path.endsWith('/raids')),
      isEmpty,
    );

    // As the broadcaster the rosters and stream tools render.
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: _Harness(
            chat: chat,
            actions: actions,
            auth: auth,
            tab: tab,
            onUser: (login) => shownUser = login,
            onNotice: notices.add,
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

    // As the broadcaster the commercial tile opens its dialog and posts.
    await tester.tap(find.text('Commercial'));
    await tester.pumpAndSettle();
    expect(find.text('Commercial length'), findsOneWidget);
    await tester.tap(find.text('30s'));
    await tester.pumpAndSettle();
    expect(
      recordedRequests.where(
        (r) => r.method == 'POST' && r.url.path.endsWith('channels/commercial'),
      ),
      isNotEmpty,
    );

    // The rosters live on the Channel tab only.
    tab.animateTo(4);
    await tester.pumpAndSettle();
    expect(find.text('warneduser'), findsOneWidget);
    expect(find.text('rosmod'), findsNothing);
    expect(find.text('rosvip'), findsNothing);

    // Back to the Channel tab for the points section.
    tab.animateTo(3);
    await tester.pumpAndSettle();

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
    final chat = _chat();
    final mod = chat.channelFor('testchannel')!.moderation;
    mod.addHeld(
      const HeldMessage(
        messageId: 'h-allow',
        channel: 'testchannel',
        userLogin: 'allowuser',
        text: 'flagged one',
        category: 'bullying',
      ),
    );
    mod.addHeld(
      const HeldMessage(
        messageId: 'h-other',
        channel: 'testchannel',
        userLogin: 'otheruser',
        text: 'flagged two',
        category: 'spam',
      ),
    );
    mod.addHeld(
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
            chat: chat,
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
    await tester.tap(find.widgetWithText(FilledButton, 'Allow').at(2));
    await tester.pumpAndSettle();
    expect(find.text('allowuser'), findsNothing);
    final allow = recordedRequests.lastWhere(
      (r) => r.url.path.endsWith('moderation/automod/message'),
    );
    expect(jsonDecode(allow.body)['action'], 'ALLOW');
    expect(find.text('otheruser'), findsOneWidget);
    expect(find.text('thirduser'), findsOneWidget);
  });

  testWidgets('a slow load cannot overwrite a newer request list', (
    tester,
  ) async {
    final pending = Completer<http.Response>();
    Future<http.Response> handler(http.Request request) {
      if (request.url.path.endsWith('moderation/unban_requests')) {
        if (request.url.queryParameters['status'] == 'pending') {
          return pending.future;
        }
        return Future.value(
          http.Response(
            '{"data":[{"id":"r2","user_login":"approveduser","text":"sorry",'
            '"status":"approved","created_at":"2026-01-01T00:00:00Z"}]}',
            200,
          ),
        );
      }
      return _handler(request);
    }

    await _pumpOn(tester, 5, handler: handler);
    await tester.pump();
    await tester.tap(find.text('Approved'));
    await tester.pumpAndSettle();
    expect(find.text('approveduser'), findsOneWidget);

    pending.complete(
      http.Response(
        '{"data":[{"id":"r1","user_login":"pendinguser","text":"pls",'
        '"status":"pending","created_at":"2026-01-01T00:00:00Z"}]}',
        200,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('pendinguser'), findsNothing);
    expect(find.text('approveduser'), findsOneWidget);
  });

  test('concurrent Helix calls each see their own failure', () async {
    final slowOk = Completer<http.Response>();
    final api = TwitchApi(
      client: MockClient((request) {
        if (request.url.path.endsWith('moderation/moderators')) {
          return Future.value(http.Response('{"message":"nope"}', 403));
        }
        return slowOk.future;
      }),
    );
    final actions = ModActions(
      twitchApi: api,
      getChannelUserIds: () => {'testchannel': 'broad1'},
      getCurrentUserId: () => 'mod1',
    );
    final auth = TwitchAuth()..accessToken = 'tok';

    final vips = api.isolateErrors(() async {
      await actions.getVips(auth, 'testchannel');
      return api.lastErrorStatus;
    });
    final mods = api.isolateErrors(() async {
      await actions.getModerators(auth, 'testchannel');
      return api.lastErrorStatus;
    });
    expect(await mods, 403);
    slowOk.complete(http.Response('{"data":[],"pagination":{}}', 200));
    expect(await vips, isNull);
  });

  testWidgets('users tab hides lapsed timeouts', (tester) async {
    final chat = _chat();
    final mod = chat.channelFor('testchannel')!.moderation;
    final now = DateTime.now();
    mod.putBan(
      BanEntry(
        at: now.subtract(const Duration(minutes: 20)),
        channel: 'testchannel',
        login: 'lapseduser',
        moderator: 'moduser',
        expiresAt: now.subtract(const Duration(minutes: 10)),
      ),
    );
    mod.putBan(
      BanEntry(
        at: now,
        channel: 'testchannel',
        login: 'timeduser',
        moderator: 'moduser',
        expiresAt: now.add(const Duration(minutes: 10)),
      ),
    );
    await _pumpOn(tester, 4, chat: chat);
    await tester.pumpAndSettle();
    expect(find.text('timeduser'), findsOneWidget);
    expect(find.text('lapseduser'), findsNothing);
    expect(find.text('RECENT BANS (1)'), findsOneWidget);
  });

  testWidgets('modes tab sends chat settings and offers slow presets', (
    tester,
  ) async {
    await _pumpOn(tester, 2);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Emote-only'));
    await tester.pumpAndSettle();
    final emote = recordedRequests.lastWhere(
      (r) => r.url.path.endsWith('chat/settings'),
    );
    expect(jsonDecode(emote.body)['emote_mode'], isTrue);

    await tester.tap(find.text('Slow mode'));
    await tester.pumpAndSettle();
    for (final label in ['3 seconds', '5 seconds', '10 seconds', 'Custom...']) {
      expect(find.text(label), findsOneWidget);
    }
    await tester.tap(find.text('5 seconds'));
    await tester.pumpAndSettle();
    final patch = recordedRequests.lastWhere(
      (r) => r.url.path.endsWith('chat/settings'),
    );
    expect(jsonDecode(patch.body)['slow_mode_wait_time'], 5);
  });

  testWidgets('automod setup shows the preset Twitch reports', (tester) async {
    Future<http.Response> handler(http.Request request) async {
      if (request.method == 'GET' &&
          request.url.path.endsWith('moderation/automod/settings')) {
        // Twitch's level 1 preset uses mixed category levels.
        return http.Response(
          '{"data":[{"broadcaster_id":"broad1","moderator_id":"mod1",'
          '"overall_level":1,"disability":0,"aggression":1,'
          '"sexuality_sex_or_gender":0,"misogyny":0,"bullying":1,'
          '"swearing":0,"race_ethnicity_or_religion":1,'
          '"sex_based_terms":0}]}',
          200,
        );
      }
      return _handler(request);
    }

    await _pumpOn(tester, 7, handler: handler);
    await tester.pumpAndSettle();
    bool selected(String label) => tester
        .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, label))
        .selected;
    expect(selected('Low'), isTrue);
    expect(find.text('Custom levels.'), findsNothing);
  });

  testWidgets('a channel switch reloads and rebinds the tab', (tester) async {
    final chat = _chat()..ensure('otherchannel');
    Future<http.Response> handler(http.Request request) async {
      recordedRequests.add(request);
      if (request.url.path.endsWith('moderation/blocked_terms')) {
        final term = request.url.queryParameters['broadcaster_id'] == 'broad2'
            ? 'otherterm'
            : 'firstterm';
        return http.Response(
          '{"data":[{"id":"$term","text":"$term",'
          '"created_at":"2026-01-01T00:00:00Z"}],"pagination":{}}',
          200,
        );
      }
      return _handler(request);
    }

    final auth = TwitchAuth()..accessToken = 'tok';
    final actions = ModActions(
      twitchApi: TwitchApi(client: MockClient(handler)),
      getChannelUserIds: () => {
        'testchannel': 'broad1',
        'otherchannel': 'broad2',
      },
      getCurrentUserId: () => 'mod1',
    );
    final tab = TabController(
      length: ModPanels.tabCount,
      vsync: const TestVSync(),
      initialIndex: 6,
    );
    addTearDown(tab.dispose);
    final channel = ValueNotifier('testchannel');
    recordedRequests.clear();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ValueListenableBuilder<String>(
            valueListenable: channel,
            builder: (_, name, _) => ModViewPanel(
              channel: name,
              chat: chat,
              modActions: actions,
              auth: auth,
              tabController: tab,
              refresh: ValueNotifier(0),
              termsVersion: ValueNotifier(0),
              dragFocus: TabDragFocus(tab: () => tab, onFocusChanged: (_) {}),
              isModerationActive: (_) => true,
              isAutomodActive: (_) => true,
              getRoomModes: (_) => const {},
              onNotice: (_) {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('firstterm'), findsOneWidget);

    channel.value = 'otherchannel';
    await tester.pumpAndSettle();
    expect(find.text('otherterm'), findsOneWidget);
    expect(find.text('firstterm'), findsNothing);

    int termLoads() => recordedRequests
        .where((r) => r.url.path.endsWith('moderation/blocked_terms'))
        .length;
    final before = termLoads();
    chat.channelFor('testchannel')!.moderation.touchTerms();
    await tester.pumpAndSettle();
    expect(termLoads(), before, reason: 'old channel is unbound');
    chat.channelFor('otherchannel')!.moderation.touchTerms();
    await tester.pumpAndSettle();
    expect(termLoads(), before + 1);
  });
}
