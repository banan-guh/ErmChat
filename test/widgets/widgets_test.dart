import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:ermchat/main.dart';
import 'package:ermchat/theme_colors.dart';
import 'package:ermchat/screens/settings/account_screen.dart';
import 'package:ermchat/screens/settings/channel_settings_screen.dart';
import 'package:ermchat/screens/settings/chat_settings_screen.dart';
import 'package:ermchat/screens/settings/customization_screen.dart';
import 'package:ermchat/screens/settings/emotes_settings_screen.dart';
import 'package:ermchat/screens/settings/tools_settings_screen.dart';
import 'package:ermchat/screens/settings/recent_uploads_screen.dart';
import 'package:ermchat/services/media_uploader.dart';
import 'package:ermchat/services/analytics_service.dart';
import 'package:ermchat/models/emote_fetch_tier.dart';
import 'package:ermchat/services/twitch_api.dart';
import 'package:ermchat/services/twitch_eventsub.dart';
import 'package:ermchat/services/twitch_irc.dart';
import 'package:ermchat/services/recent_messages.dart';
import 'package:ermchat/services/twitch_auth.dart';
import 'package:ermchat/models/twitch_message.dart';
import 'package:ermchat/services/suggestion.dart';
import 'package:ermchat/widgets/autocomplete_dropdown.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:ermchat/services/emote_cache_manager.dart';
import '../helpers/fake_cache_repo.dart';
import 'package:ermchat/screens/settings/analytics_screen.dart';
import 'package:ermchat/widgets/chat_widget_cutout.dart';
import 'package:ermchat/models/generic_emote.dart';
import 'package:ermchat/services/emote_manager.dart';
import 'package:ermchat/widgets/emote_menu_panel.dart';
import 'package:url_launcher_platform_interface/link.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';
import 'package:ermchat/widgets/emote_image.dart';
import 'package:ermchat/widgets/emote_sheet.dart';
import 'package:ermchat/widgets/user_profile_sheet.dart';

class _FakeEventSubService extends EventSubService {
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

class _FakeRecentMessagesService extends RecentMessagesService {
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

class _GappedRecentMessagesService extends RecentMessagesService {
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

class _FakeIrcService extends IrcService {
  final _banCtrl = StreamController<IrcBanEvent>.broadcast(sync: true);
  final _noticeCtrl = StreamController<IrcNoticeEvent>.broadcast(sync: true);
  final _deleteCtrl = StreamController<IrcMessageDeletedEvent>.broadcast(
    sync: true,
  );
  final _statusCtrl = StreamController<IrcConnectionStatus>.broadcast(
    sync: true,
  );

  @override
  Future<void> connect({
    required String username,
    required String accessToken,
  }) async {}

  @override
  Stream<IrcBanEvent> get onBan => _banCtrl.stream;

  @override
  Stream<IrcNoticeEvent> get onNotice => _noticeCtrl.stream;

  @override
  Stream<IrcMessageDeletedEvent> get onMessageDeleted => _deleteCtrl.stream;

  @override
  Stream<IrcConnectionStatus> get onStatus => _statusCtrl.stream;

  bool _fakeConnected = false;

  @override
  bool get isConnected => _fakeConnected;

  void triggerConnect() {
    _fakeConnected = true;
    _statusCtrl.add(IrcConnectionStatus.connected);
  }

  void triggerDisconnect() {
    _fakeConnected = false;
    _statusCtrl.add(IrcConnectionStatus.disconnected);
  }

  void emitMessage(TwitchMessage msg) => emitChatMessage(msg);

  void emitBan(
    String user, {
    bool isTimeout = false,
    int? durationSeconds,
    String channel = '',
  }) {
    _banCtrl.add(
      IrcBanEvent(
        user: user,
        isTimeout: isTimeout,
        duration: durationSeconds,
        channel: channel,
      ),
    );
  }

  void emitNotice(String channel, String message) {
    _noticeCtrl.add(IrcNoticeEvent(channel: channel, message: message));
  }

  void emitDeleted(
    String messageId,
    String channel, {
    String user = 'unknown',
    String deletedMessageText = '',
  }) {
    _deleteCtrl.add(
      IrcMessageDeletedEvent(
        channel: channel,
        messageId: messageId,
        user: user,
        deletedMessageText: deletedMessageText,
      ),
    );
  }

  @override
  void dispose() {
    _banCtrl.close();
    _noticeCtrl.close();
    _deleteCtrl.close();
    _statusCtrl.close();
    super.dispose();
  }
}

class _ConfigurableRecentMessagesService extends RecentMessagesService {
  final List<TwitchMessage> messages;
  _ConfigurableRecentMessagesService(this.messages);

  @override
  Future<List<TwitchMessage>> fetchRecent(
    String channel, {
    int limit = 100,
  }) async => messages;
}

class _ScriptedRecentMessagesService extends RecentMessagesService {
  final List<List<TwitchMessage>> responses;
  int callCount = 0;
  _ScriptedRecentMessagesService(this.responses);

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

class _CompleterRecentMessagesService extends RecentMessagesService {
  final Completer<List<TwitchMessage>> completer;
  _CompleterRecentMessagesService(this.completer);

  @override
  Future<List<TwitchMessage>> fetchRecent(String channel, {int limit = 100}) =>
      completer.future;
}

class _GatedRecentMessagesService extends RecentMessagesService {
  _GatedRecentMessagesService(
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

PollEvent _poll() => PollEvent(
  channel: 'c',
  kind: 'begin',
  title: 'A or B?',
  choices: [
    PollChoice(title: 'A', votes: 10),
    PollChoice(title: 'B', votes: 5),
  ],
  status: 'ACTIVE',
);

HypeTrainEvent _hypeTrain() => HypeTrainEvent(
  channel: 'c',
  kind: 'begin',
  level: 1,
  progress: 10,
  total: 50,
  expiresAt: DateTime.now().add(const Duration(minutes: 5)),
  topContributions: [
    HypeTrainContribution(userName: 'bitsuser', type: 'BITS', total: 100),
  ],
);

class _FakeUrlLauncher extends UrlLauncherPlatform {
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

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });

  testWidgets('Home screen shows credentials message when not configured', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      TwitchChatApp(
        eventSubService: _FakeEventSubService(),
        ircService: _FakeIrcService(),
        recentMessagesService: _FakeRecentMessagesService(),
      ),
    );
    await tester.pump();

    expect(find.byIcon(Icons.add), findsOneWidget);
    expect(find.byIcon(Icons.more_vert), findsOneWidget);
    expect(find.byIcon(Icons.settings), findsNothing);
    expect(
      find.text('Configure Twitch credentials in Settings first'),
      findsOneWidget,
    );
    // Let the anonymous-mode socket attempts resolve so no timer pends.
    await tester.pumpAndSettle();
  });

  testWidgets(
    'Adding channel without credentials is view-only: sending blocked, '
    'incoming messages still render',
    (WidgetTester tester) async {
      final fakeEventSub = _FakeEventSubService();
      final fakeIrc = _FakeIrcService();
      final fakeRecent = _FakeRecentMessagesService();

      await tester.pumpWidget(
        TwitchChatApp(
          eventSubService: fakeEventSub,
          ircService: fakeIrc,
          recentMessagesService: fakeRecent,
        ),
      );
      await tester.pump();

      await tester.tap(find.byIcon(Icons.add));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField).last, 'xqc');
      await tester.tap(find.text('Join'));
      await tester.pump();

      expect(find.text('Connect an account to chat'), findsOneWidget);

      // Trying to send does nothing (input is disabled without credentials).
      await tester.enterText(
        find.byKey(const Key('message_input')),
        'hello chat',
      );
      await tester.tap(find.byIcon(Icons.send), warnIfMissed: false);
      await tester.pump();
      expect(find.textContaining('hello chat'), findsNothing);

      // EventSub messages still appear in view-only mode.
      fakeIrc.emitMessage(
        TwitchMessage(
          login: 'xqc',
          text: 'hello chat',
          channel: 'xqc',
          messageId: 'm1',
        ),
      );
      await tester.pump();

      expect(find.textContaining('hello chat'), findsOneWidget);
    },
  );

  testWidgets('Settings screen opens and shows dark mode toggle', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const TwitchChatApp());
    await tester.pump();

    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();

    expect(find.text('Settings'), findsOneWidget);
    expect(find.text('Dark mode'), findsNothing);
    expect(find.text('Customization'), findsOneWidget);

    await tester.tap(find.text('Account'));
    await tester.pumpAndSettle();

    expect(find.text('Login'), findsOneWidget);
  });

  testWidgets('Settings shows channel list when channels are joined', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const TwitchChatApp());
    await tester.pump();

    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'xqc');
    await tester.tap(find.text('Join'));
    await tester.pump();

    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();

    expect(find.text('Channels'), findsOneWidget);

    await tester.tap(find.text('Channels'));
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.remove_circle_outline), findsOneWidget);
  });

  testWidgets('Notification bell opens mentions modal', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const TwitchChatApp());
    await tester.pump();

    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'xqc');
    await tester.tap(find.text('Join'));
    await tester.pump();

    // Mentions panel is always mounted but closed with null data.
    expect(find.text('No mentions or whispers'), findsNothing);

    await tester.tap(find.byIcon(Icons.notifications_active));
    await tester.pumpAndSettle();

    expect(find.text('Mentions / Whispers'), findsOneWidget); // title
    expect(find.text('Mentions'), findsOneWidget); // tab
    expect(find.text('Whispers'), findsOneWidget); // tab
    expect(find.text('No mentions or whispers'), findsOneWidget);
  });

  testWidgets(
    'Mention in focused channel does not turn notification bell red',
    (WidgetTester tester) async {
      final eventSub = _FakeEventSubService();
      final irc = _FakeIrcService();
      final recent = _ConfigurableRecentMessagesService(const []);
      await tester.pumpWidget(
        TwitchChatApp(
          eventSubService: eventSub,
          ircService: irc,
          recentMessagesService: recent,
          initialCurrentUserLogin: 'me',
        ),
      );
      await tester.pump();

      await tester.tap(find.byIcon(Icons.add));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, 'a');
      await tester.tap(find.text('Join'));
      await tester.pump();

      // 'a' is the selected channel; emit a mention there.
      irc.emitMessage(
        TwitchMessage(
          login: 'bob',
          text: 'hey @me how are you',
          channel: 'a',
          messageId: 'm1',
        ),
      );
      await tester.pump();

      final bell = tester.widget<Icon>(find.byIcon(Icons.notifications_active));
      expect(bell.color, isNull);
      expect(find.byKey(const Key('unread_mention_dot')), findsNothing);
    },
  );

  testWidgets(
    'Unfocused-channel mention turns bell red and shows a red dot on the tab',
    (WidgetTester tester) async {
      final eventSub = _FakeEventSubService();
      final irc = _FakeIrcService();
      final recent = _ConfigurableRecentMessagesService(const []);
      await tester.pumpWidget(
        TwitchChatApp(
          eventSubService: eventSub,
          ircService: irc,
          recentMessagesService: recent,
          initialCurrentUserLogin: 'me',
        ),
      );
      await tester.pump();

      // Join 'b' first, then 'a' so 'a' is selected and 'b' is unfocused.
      for (final name in ['b', 'a']) {
        await tester.tap(find.byIcon(Icons.add));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField).last, name);
        await tester.tap(find.text('Join'));
        await tester.pump();
      }

      irc.emitMessage(
        TwitchMessage(
          login: 'carol',
          text: 'hello @me',
          channel: 'b',
          messageId: 'm2',
        ),
      );
      await tester.pump();

      final bell = tester.widget<Icon>(find.byIcon(Icons.notifications_active));
      expect(bell.color, isNotNull);
      expect(find.byKey(const Key('unread_mention_dot')), findsOneWidget);
    },
  );

  testWidgets(
    'Switching to a channel with unread mention clears its dot and name color',
    (WidgetTester tester) async {
      final eventSub = _FakeEventSubService();
      final irc = _FakeIrcService();
      final recent = _ConfigurableRecentMessagesService(const []);
      await tester.pumpWidget(
        TwitchChatApp(
          eventSubService: eventSub,
          ircService: irc,
          recentMessagesService: recent,
          initialCurrentUserLogin: 'me',
        ),
      );
      await tester.pump();

      for (final name in ['b', 'a']) {
        await tester.tap(find.byIcon(Icons.add));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField).last, name);
        await tester.tap(find.text('Join'));
        await tester.pump();
      }

      irc.emitMessage(
        TwitchMessage(
          login: 'carol',
          text: 'hello @me',
          channel: 'b',
          messageId: 'm3',
        ),
      );
      await tester.pump();
      expect(find.byKey(const Key('unread_mention_dot')), findsOneWidget);

      // Select 'b' (clears its unread state), then switch back to 'a' so 'b'
      // is unselected again. A previously-viewed channel must revert to grey.
      Future<void> tapNamed(String name) async {
        final barText = find.text(name).first;
        await tester.ensureVisible(barText);
        await tester.pump();
        await tester.tap(barText);
        await tester.pumpAndSettle();
        await tester.pump();
      }

      await tapNamed('b');
      expect(find.byKey(const Key('unread_mention_dot')), findsNothing);
      await tapNamed('a');

      final text = tester.widget<Text>(find.text('b'));
      expect(text.style?.color, isNull);
      expect(find.byKey(const Key('unread_mention_dot')), findsNothing);
    },
  );

  testWidgets(
    'Opening mentions panel clears the bell color and per-channel dot',
    (WidgetTester tester) async {
      final eventSub = _FakeEventSubService();
      final irc = _FakeIrcService();
      final recent = _ConfigurableRecentMessagesService(const []);
      await tester.pumpWidget(
        TwitchChatApp(
          eventSubService: eventSub,
          ircService: irc,
          recentMessagesService: recent,
          initialCurrentUserLogin: 'me',
        ),
      );
      await tester.pump();

      for (final name in ['b', 'a']) {
        await tester.tap(find.byIcon(Icons.add));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField).last, name);
        await tester.tap(find.text('Join'));
        await tester.pump();
      }

      irc.emitMessage(
        TwitchMessage(
          login: 'carol',
          text: 'hello @me',
          channel: 'b',
          messageId: 'm4',
        ),
      );
      await tester.pump();
      expect(find.byKey(const Key('unread_mention_dot')), findsOneWidget);

      await tester.tap(find.byIcon(Icons.notifications_active));
      await tester.pumpAndSettle();

      final bell = tester.widget<Icon>(find.byIcon(Icons.notifications_active));
      expect(bell.color, isNull);
      expect(find.byKey(const Key('unread_mention_dot')), findsNothing);
    },
  );

  testWidgets(
    'Swiping to a channel with unread mention clears the bell color',
    (WidgetTester tester) async {
      final eventSub = _FakeEventSubService();
      final irc = _FakeIrcService();
      final recent = _ConfigurableRecentMessagesService(const []);
      await tester.pumpWidget(
        TwitchChatApp(
          eventSubService: eventSub,
          ircService: irc,
          recentMessagesService: recent,
          initialCurrentUserLogin: 'me',
        ),
      );
      await tester.pump();

      for (final name in ['b', 'a']) {
        await tester.tap(find.byIcon(Icons.add));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField).last, name);
        await tester.tap(find.text('Join'));
        await tester.pump();
      }

      irc.emitMessage(
        TwitchMessage(
          login: 'carol',
          text: 'hello @me',
          channel: 'b',
          messageId: 'm6',
        ),
      );
      await tester.pump();
      expect(
        tester.widget<Icon>(find.byIcon(Icons.notifications_active)).color,
        isNotNull,
      );

      // Switch via a TabBarView drag (not a tab tap). 'b' is at page 0 and
      // 'a' at page 1, so drag right (positive dx). The focus-change handler
      // clears the unread state mid-drag; on settle the index already equals
      // the selection so onSelectedIndexChanged is skipped, which is exactly
      // the path that used to leave the bell stale.
      final barSize = tester.getSize(find.byType(TabBarView));
      final barCenter = tester.getCenter(find.byType(TabBarView));
      final gesture = await tester.startGesture(barCenter);
      await gesture.moveBy(const Offset(1, 0));
      await tester.pump();
      await gesture.moveBy(Offset(barSize.width * 0.55, 0));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();
      await tester.pump();

      expect(
        tester.widget<Icon>(find.byIcon(Icons.notifications_active)).color,
        isNull,
      );
      expect(find.byKey(const Key('unread_mention_dot')), findsNothing);
    },
  );

  testWidgets('Leaving a channel with unread mentions clears the bell color', (
    WidgetTester tester,
  ) async {
    final eventSub = _FakeEventSubService();
    final irc = _FakeIrcService();
    final recent = _ConfigurableRecentMessagesService(const []);
    await tester.pumpWidget(
      TwitchChatApp(
        eventSubService: eventSub,
        ircService: irc,
        recentMessagesService: recent,
        initialCurrentUserLogin: 'me',
      ),
    );
    await tester.pump();

    for (final name in ['b', 'a']) {
      await tester.tap(find.byIcon(Icons.add));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, name);
      await tester.tap(find.text('Join'));
      await tester.pump();
    }

    irc.emitMessage(
      TwitchMessage(
        login: 'carol',
        text: 'hello @me',
        channel: 'b',
        messageId: 'm7',
      ),
    );
    await tester.pump();
    expect(
      tester.widget<Icon>(find.byIcon(Icons.notifications_active)).color,
      isNotNull,
    );

    // Leaving a channel must also drop its unread count, or the bell
    // stays red with no per-channel dot left to clear.
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Channels'));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.remove_circle_outline).first);
    await tester.pumpAndSettle();

    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();

    expect(
      tester.widget<Icon>(find.byIcon(Icons.notifications_active)).color,
      isNull,
    );
  });

  testWidgets(
    'Incoming whisper turns the bell red and shows in the Whispers tab',
    (WidgetTester tester) async {
      final eventSub = _FakeEventSubService();
      final irc = _FakeIrcService();
      final recent = _ConfigurableRecentMessagesService(const []);
      await tester.pumpWidget(
        TwitchChatApp(
          eventSubService: eventSub,
          ircService: irc,
          recentMessagesService: recent,
          initialCurrentUserLogin: 'me',
        ),
      );
      await tester.pump();

      for (final name in ['b', 'a']) {
        await tester.tap(find.byIcon(Icons.add));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField).last, name);
        await tester.tap(find.text('Join'));
        await tester.pump();
      }

      irc.emitWhisper(
        TwitchMessage(
          login: 'carol',
          text: 'hello @me',
          channel: null,
          messageId: 'w1',
        ),
      );
      await tester.pump();

      expect(
        tester.widget<Icon>(find.byIcon(Icons.notifications_active)).color,
        isNotNull,
      );

      await tester.tap(find.byIcon(Icons.notifications_active));
      await tester.pumpAndSettle();

      // The bell tap clears all unread (mentions + whispers).
      expect(
        tester.widget<Icon>(find.byIcon(Icons.notifications_active)).color,
        isNull,
      );

      await tester.tap(find.text('Whispers'));
      await tester.pumpAndSettle();

      expect(find.textContaining('hello @me'), findsOneWidget);
    },
  );

  testWidgets(
    'Type box unlocks only on the Whispers tab and hints the reply target',
    (WidgetTester tester) async {
      SharedPreferences.setMockInitialValues({'access_token': 'test_token'});
      FlutterSecureStorage.setMockInitialValues({'access_token': 'test_token'});
      final eventSub = _FakeEventSubService();
      final irc = _FakeIrcService();
      final recent = _ConfigurableRecentMessagesService(const []);
      await tester.pumpWidget(
        TwitchChatApp(
          eventSubService: eventSub,
          ircService: irc,
          recentMessagesService: recent,
        ),
      );
      await tester.pump();

      for (final name in ['b', 'a']) {
        await tester.tap(find.byIcon(Icons.add));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField).last, name);
        await tester.tap(find.text('Join'));
        await tester.pump();
      }
      irc.triggerConnect();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump();

      irc.emitWhisper(
        TwitchMessage(
          login: 'carol',
          text: 'hi',
          channel: null,
          messageId: 'w2',
        ),
      );
      await tester.pump();

      await tester.tap(find.byIcon(Icons.notifications_active));
      await tester.pumpAndSettle();

      // Mentions tab keeps the box locked.
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('message_input')))
            .enabled,
        isFalse,
      );

      await tester.tap(find.text('Whispers'));
      await tester.pumpAndSettle();

      expect(
        tester
            .widget<TextField>(find.byKey(const Key('message_input')))
            .enabled,
        isTrue,
      );
      expect(find.text('Whisper to carol...'), findsOneWidget);
    },
  );

  testWidgets(
    'Plain text in the Whispers tab sends a whisper to the latest partner',
    (WidgetTester tester) async {
      SharedPreferences.setMockInitialValues({'access_token': 'test_token'});
      FlutterSecureStorage.setMockInitialValues({
        'access_token': 'test_token',
        'user_login': 'me',
        'user_id': '42',
      });
      final eventSub = _FakeEventSubService();
      final irc = _FakeIrcService();
      final recent = _ConfigurableRecentMessagesService(const []);
      await tester.pumpWidget(
        TwitchChatApp(
          eventSubService: eventSub,
          ircService: irc,
          recentMessagesService: recent,
        ),
      );
      await tester.pump();

      for (final name in ['b', 'a']) {
        await tester.tap(find.byIcon(Icons.add));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField).last, name);
        await tester.tap(find.text('Join'));
        await tester.pump();
      }
      irc.triggerConnect();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump();

      irc.emitWhisper(
        TwitchMessage(
          login: 'carol',
          text: 'hi there',
          channel: null,
          messageId: 'w3',
        ),
      );
      await tester.pump();

      await tester.tap(find.byIcon(Icons.notifications_active));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Whispers'));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('message_input')),
        'back at you',
      );
      await tester.tap(find.byIcon(Icons.send));
      await tester.pumpAndSettle();
      await tester.pump();

      // Plain text is routed through the command handler as /w <target> <text>.
      // The Helix user lookup fails in the test environment (400), which
      // reports feedback into the whispers list.
      expect(find.textContaining('No user matching'), findsOneWidget);
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('message_input')))
            .controller!
            .text,
        isEmpty,
      );
    },
  );

  testWidgets('Shows Disconnected once when EventSub fails', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues({'access_token': 'test_token'});
    FlutterSecureStorage.setMockInitialValues({'access_token': 'test_token'});
    await tester.pumpWidget(const TwitchChatApp());
    await tester.pump();

    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'xqc');
    await tester.tap(find.text('Join'));
    await tester.pump();

    await tester.pump(const Duration(seconds: 5));

    // The sockets were already down before the channel was joined, so no
    // outage system message is emitted for it; the input hint reads
    // "Reconnecting...".
    expect(find.textContaining('Reconnecting'), findsOneWidget);
    expect(find.textContaining('Disconnected'), findsNothing);
    expect(find.textContaining('Chat reconnecting...'), findsNothing);
  });

  testWidgets('Duplicate channel join is silently ignored', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const TwitchChatApp());
    await tester.pump();

    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'xqc');
    await tester.tap(find.text('Join'));
    await tester.pumpAndSettle();

    expect(find.text('xqc'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'xqc');
    await tester.tap(find.text('Join'));
    await tester.pumpAndSettle();

    expect(find.text('xqc'), findsOneWidget);
  });

  testWidgets('Message timestamp shows HH:MM format', (
    WidgetTester tester,
  ) async {
    final fakeEventSub = _FakeEventSubService();
    final fakeIrc = _FakeIrcService();
    final fakeRecent = _FakeRecentMessagesService();

    await tester.pumpWidget(
      TwitchChatApp(
        eventSubService: fakeEventSub,
        ircService: fakeIrc,
        recentMessagesService: fakeRecent,
      ),
    );
    await tester.pump();

    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'xqc');
    await tester.tap(find.text('Join'));
    await tester.pump();

    fakeIrc.emitMessage(
      TwitchMessage(
        login: 'xqc',
        text: 'hello',
        channel: 'xqc',
        messageId: 'm1',
      ),
    );
    await tester.pump();

    final timeText = find.textContaining(RegExp(r'^\d{2}:\d{2}$'));
    expect(timeText, findsAtLeast(1));
  });

  testWidgets('Message timestamp respects custom 12-hour format', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'timestamp_format': 'h:mm a',
      'show_timestamps': true,
    });
    final fakeEventSub = _FakeEventSubService();
    final fakeIrc = _FakeIrcService();
    final fakeRecent = _FakeRecentMessagesService();

    await tester.pumpWidget(
      TwitchChatApp(
        eventSubService: fakeEventSub,
        ircService: fakeIrc,
        recentMessagesService: fakeRecent,
      ),
    );
    await tester.pump();

    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'xqc');
    await tester.tap(find.text('Join'));
    await tester.pump();

    fakeIrc.emitMessage(
      TwitchMessage(
        login: 'xqc',
        text: 'hello',
        channel: 'xqc',
        messageId: 'm1',
      ),
    );
    await tester.pump();

    expect(
      find.textContaining(RegExp(r'^\d{1,2}:\d{2} (AM|PM)$')),
      findsAtLeast(1),
    );
    expect(find.textContaining(RegExp(r'^\d{2}:\d{2}$')), findsNothing);
  });

  testWidgets('Timestamps can be hidden', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({
      'timestamp_format': 'HH:mm',
      'show_timestamps': false,
    });
    final fakeEventSub = _FakeEventSubService();
    final fakeIrc = _FakeIrcService();
    final fakeRecent = _FakeRecentMessagesService();

    await tester.pumpWidget(
      TwitchChatApp(
        eventSubService: fakeEventSub,
        ircService: fakeIrc,
        recentMessagesService: fakeRecent,
      ),
    );
    await tester.pump();

    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'xqc');
    await tester.tap(find.text('Join'));
    await tester.pump();

    fakeIrc.emitMessage(
      TwitchMessage(
        login: 'xqc',
        text: 'hello',
        channel: 'xqc',
        messageId: 'm1',
      ),
    );
    await tester.pump();

    expect(find.textContaining(RegExp(r'^\d{2}:\d{2}$')), findsNothing);
    expect(find.textContaining('hello'), findsWidgets);
  });

  testWidgets(
    'Connected message appears after EventSub connects and history loads',
    (WidgetTester tester) async {
      final fakeEventSub = _FakeEventSubService();
      final fakeRecent = _FakeRecentMessagesService();
      final fakeIrc = _FakeIrcService();

      SharedPreferences.setMockInitialValues({'access_token': 'test_token'});
      FlutterSecureStorage.setMockInitialValues({'access_token': 'test_token'});

      await tester.pumpWidget(
        TwitchChatApp(
          eventSubService: fakeEventSub,
          recentMessagesService: fakeRecent,
          ircService: fakeIrc,
        ),
      );
      await tester.pump();

      await tester.tap(find.byIcon(Icons.add));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, 'testchannel');
      await tester.tap(find.text('Join'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Connected'), findsNothing);

      fakeIrc.triggerConnect();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump();

      expect(find.textContaining('Connected'), findsOneWidget);
      expect(find.textContaining('Disconnected'), findsNothing);
    },
  );

  testWidgets('Reconnect re-fetches history and discards duplicate messages', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'access_token': 'test_token',
      'channels': ['xqc'],
    });
    FlutterSecureStorage.setMockInitialValues({'access_token': 'test_token'});

    final now = DateTime.now();
    final recent = _ScriptedRecentMessagesService([
      [
        TwitchMessage(
          login: 'alice',
          text: 'first message',
          channel: 'xqc',
          messageId: 'a1',
          timestamp: now.subtract(const Duration(minutes: 5)),
        ),
        TwitchMessage(
          login: 'bob',
          text: 'second message',
          channel: 'xqc',
          messageId: 'a2',
          timestamp: now.subtract(const Duration(minutes: 4)),
        ),
      ],
      [
        TwitchMessage(
          login: 'bob',
          text: 'second message',
          channel: 'xqc',
          messageId: 'a2',
          timestamp: now.subtract(const Duration(minutes: 4)),
        ),
        TwitchMessage(
          login: 'carol',
          text: 'third message',
          channel: 'xqc',
          messageId: 'a3',
          timestamp: now.subtract(const Duration(minutes: 3)),
        ),
      ],
    ]);
    final fakeEventSub = _FakeEventSubService();
    final fakeIrc = _FakeIrcService();

    await tester.pumpWidget(
      TwitchChatApp(
        eventSubService: fakeEventSub,
        ircService: fakeIrc,
        recentMessagesService: recent,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('first message'), findsOneWidget);
    expect(find.textContaining('second message'), findsOneWidget);

    // First connect must not trigger a history re-fetch.
    fakeIrc.triggerConnect();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump();
    expect(recent.callCount, 1);

    // Reconnect: robotty returns one duplicate + one new message.
    fakeIrc.triggerDisconnect();
    await tester.pump();
    fakeIrc.triggerConnect();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump();

    expect(recent.callCount, 2);
    expect(find.textContaining('third message'), findsOneWidget);
    expect(
      find.textContaining('second message'),
      findsOneWidget,
      reason: 'duplicate from re-fetch must be discarded',
    );
    expect(find.textContaining('first message'), findsOneWidget);
    expect(
      find.textContaining('History: Not all messages retrieved'),
      findsNothing,
    );
  });

  testWidgets(
    'Reconnect shows gap note when history does not reach old messages',
    (WidgetTester tester) async {
      SharedPreferences.setMockInitialValues({
        'access_token': 'test_token',
        'channels': ['xqc'],
      });
      FlutterSecureStorage.setMockInitialValues({'access_token': 'test_token'});

      final now = DateTime.now();
      final recent = _ScriptedRecentMessagesService([
        [
          TwitchMessage(
            login: 'alice',
            text: 'old message',
            channel: 'xqc',
            messageId: 'a1',
            timestamp: now.subtract(const Duration(minutes: 30)),
          ),
        ],
        [
          TwitchMessage(
            login: 'dave',
            text: 'fresh message',
            channel: 'xqc',
            messageId: 'd1',
            timestamp: now.subtract(const Duration(minutes: 1)),
          ),
        ],
      ]);
      final fakeEventSub = _FakeEventSubService();
      final fakeIrc = _FakeIrcService();

      await tester.pumpWidget(
        TwitchChatApp(
          eventSubService: fakeEventSub,
          ircService: fakeIrc,
          recentMessagesService: recent,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('old message'), findsOneWidget);
      expect(
        find.textContaining('History: Not all messages retrieved'),
        findsNothing,
      );

      fakeIrc.triggerDisconnect();
      await tester.pump();
      fakeIrc.triggerConnect();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump();

      expect(find.textContaining('fresh message'), findsOneWidget);
      expect(find.textContaining('old message'), findsOneWidget);
      expect(
        find.textContaining('History: Not all messages retrieved'),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'Connected appears before history and moves to top after history arrives',
    (WidgetTester tester) async {
      final fakeEventSub = _FakeEventSubService();
      final fakeIrc = _FakeIrcService();
      final historyCompleter = Completer<List<TwitchMessage>>();

      SharedPreferences.setMockInitialValues({'access_token': 'test_token'});
      FlutterSecureStorage.setMockInitialValues({'access_token': 'test_token'});

      await tester.pumpWidget(
        TwitchChatApp(
          eventSubService: fakeEventSub,
          recentMessagesService: _CompleterRecentMessagesService(
            historyCompleter,
          ),
          ircService: fakeIrc,
        ),
      );
      await tester.pump();

      await tester.tap(find.byIcon(Icons.add));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, 'testchannel');
      await tester.tap(find.text('Join'));
      await tester.pumpAndSettle();

      fakeIrc.triggerConnect();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump();

      expect(find.textContaining('Connected'), findsOneWidget);

      historyCompleter.complete([
        TwitchMessage(
          login: 'alice',
          text: 'hello world',
          channel: 'testchannel',
          messageId: 'hist-1',
          timestamp: DateTime.now().subtract(const Duration(minutes: 5)),
          isHistory: true,
        ),
      ]);
      await tester.pump();
      await tester.pumpAndSettle();

      expect(find.textContaining('Connected'), findsOneWidget);
      expect(find.textContaining('hello world'), findsOneWidget);
      // Chat renders newest-first at the bottom (reverse list): 'Connected'
      // must sit below the history message, i.e. at the most recent position.
      final connectedY = tester.getTopLeft(find.textContaining('Connected')).dy;
      final historyY = tester.getTopLeft(find.textContaining('hello world')).dy;
      expect(connectedY, greaterThan(historyY));
    },
  );

  testWidgets('Reconnect history merges below newer live messages', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'access_token': 'test_token',
      'channels': ['xqc'],
    });
    FlutterSecureStorage.setMockInitialValues({'access_token': 'test_token'});

    final now = DateTime.now();
    final refetchGate = Completer<void>();
    final recent = _GatedRecentMessagesService(
      [
        [
          TwitchMessage(
            login: 'alice',
            text: 'old history',
            channel: 'xqc',
            messageId: 'a1',
            timestamp: now.subtract(const Duration(minutes: 5)),
          ),
        ],
        [
          TwitchMessage(
            login: 'bob',
            text: 'missed message',
            channel: 'xqc',
            messageId: 'b1',
            timestamp: now.subtract(const Duration(minutes: 1)),
          ),
        ],
      ],
      gateOnCall: 2,
      gate: refetchGate,
    );
    final fakeEventSub = _FakeEventSubService();
    final fakeIrc = _FakeIrcService();

    await tester.pumpWidget(
      TwitchChatApp(
        eventSubService: fakeEventSub,
        ircService: fakeIrc,
        recentMessagesService: recent,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('old history'), findsOneWidget);

    fakeIrc.triggerConnect();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump();
    expect(recent.callCount, 1);

    fakeIrc.triggerDisconnect();
    await tester.pump();
    fakeIrc.triggerConnect();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump();
    expect(recent.callCount, 2, reason: 'reconnect must trigger a re-fetch');

    // Live messages arrive while the re-fetch is still in flight.
    fakeIrc.emitMessage(
      TwitchMessage(
        login: 'carol',
        text: 'live after reconnect',
        channel: 'xqc',
        messageId: 'c1',
        timestamp: now,
      ),
    );
    await tester.pump();
    expect(find.textContaining('live after reconnect'), findsOneWidget);

    refetchGate.complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump();

    expect(find.textContaining('missed message'), findsOneWidget);
    final liveY = tester
        .getTopLeft(find.textContaining('live after reconnect'))
        .dy;
    final missedY = tester.getTopLeft(find.textContaining('missed message')).dy;
    expect(
      liveY,
      greaterThan(missedY),
      reason: 'newer live messages must stay above re-fetched history',
    );
    final oldY = tester.getTopLeft(find.textContaining('old history')).dy;
    expect(
      missedY,
      greaterThan(oldY),
      reason: 'missed history is newer than pre-disconnect messages',
    );
  });

  testWidgets('join dialog removes the loading history message', (
    WidgetTester tester,
  ) async {
    final fakeEventSub = _FakeEventSubService();
    final fakeIrc = _FakeIrcService();
    final historyCompleter = Completer<List<TwitchMessage>>();

    SharedPreferences.setMockInitialValues({'access_token': 'test_token'});
    FlutterSecureStorage.setMockInitialValues({'access_token': 'test_token'});

    await tester.pumpWidget(
      TwitchChatApp(
        eventSubService: fakeEventSub,
        recentMessagesService: _CompleterRecentMessagesService(
          historyCompleter,
        ),
        ircService: fakeIrc,
      ),
    );
    await tester.pump();

    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'testchannel');
    await tester.tap(find.text('Join').last);
    await tester.pump();
    await tester.pump();

    expect(find.textContaining('Loading chat history...'), findsOneWidget);

    historyCompleter.complete([
      TwitchMessage(
        login: 'alice',
        text: 'hello world',
        channel: 'testchannel',
        messageId: 'hist-1',
        timestamp: DateTime.now().subtract(const Duration(minutes: 5)),
      ),
    ]);
    await tester.pump();
    await tester.pumpAndSettle();

    expect(find.textContaining('Loading chat history...'), findsNothing);
    expect(find.textContaining('hello world'), findsOneWidget);
  });

  group('Thread', () {
    late DateTime now;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      FlutterSecureStorage.setMockInitialValues({});
      now = DateTime.now();
    });

    Future<void> joinChannel(
      WidgetTester tester, {
      required String channelName,
      required List<TwitchMessage> history,
      _FakeIrcService? irc,
    }) async {
      final fakeIrc = irc ?? _FakeIrcService();
      final fakeRecent = _ConfigurableRecentMessagesService(history);
      final es = _FakeEventSubService();

      await tester.pumpWidget(
        TwitchChatApp(
          eventSubService: es,
          recentMessagesService: fakeRecent,
          ircService: fakeIrc,
        ),
      );
      await tester.pump();

      await tester.tap(find.byIcon(Icons.add));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, channelName);
      await tester.tap(find.text('Join').last);
      await tester.pump();
      await tester.pump();
    }

    testWidgets(
      'reply indicator on history child opens thread showing parent and child',
      (WidgetTester tester) async {
        const channel = 'testchannel';
        final parent = TwitchMessage(
          login: 'alice',
          text: 'parent msg',
          messageId: 'p1',
          timestamp: now.subtract(const Duration(minutes: 5)),
          channel: channel,
        );
        final child = TwitchMessage(
          login: 'bob',
          text: 'child msg',
          messageId: 'c1',
          replyToParentId: 'p1',
          replyToUser: 'alice',
          replyToText: 'parent msg',
          timestamp: now.subtract(const Duration(minutes: 4)),
          isHistory: true,
          channel: channel,
        );
        await joinChannel(
          tester,
          channelName: channel,
          history: [parent, child],
        );

        await tester.tap(find.textContaining('replying to alice: parent msg'));
        await tester.pumpAndSettle();

        expect(find.text('Reply Thread'), findsOneWidget);
        expect(find.byIcon(Icons.close), findsOneWidget);
        expect(find.textContaining('parent msg'), findsAtLeast(1));
        expect(find.textContaining('child msg'), findsAtLeast(1));
      },
    );

    testWidgets(
      'open thread panel survives scrollback trimming without going empty',
      (WidgetTester tester) async {
        const channel = 'testchannel';
        // Small window so flooding live chat pushes the thread out quickly.
        SharedPreferences.setMockInitialValues({'max_messages_per_channel': 5});
        final parent = TwitchMessage(
          login: 'alice',
          text: 'thread root',
          messageId: 'p1',
          timestamp: now.subtract(const Duration(minutes: 5)),
          channel: channel,
        );
        final child = TwitchMessage(
          login: 'bob',
          text: 'child msg',
          messageId: 'c1',
          replyToParentId: 'p1',
          replyThreadRootId: 'p1',
          replyToUser: 'alice',
          replyToText: 'parent msg',
          timestamp: now.subtract(const Duration(minutes: 4)),
          channel: channel,
        );
        final irc = _FakeIrcService();
        await joinChannel(
          tester,
          channelName: channel,
          history: [parent, child],
          irc: irc,
        );

        await tester.pump();
        await tester.pump();

        await tester.tap(find.textContaining('replying to alice'));
        await tester.pumpAndSettle();
        expect(find.text('Reply Thread'), findsOneWidget);
        expect(find.textContaining('thread root'), findsAtLeast(1));

        // Flood the channel so truncation evicts every thread member from
        // the main chat buffer while the panel is open.
        for (var i = 0; i < 12; i++) {
          irc.emitMessage(
            TwitchMessage(
              login: 'user$i',
              text: 'flood $i',
              messageId: 'fl$i',
              timestamp: now.add(Duration(seconds: i)),
              channel: channel,
            ),
          );
          await tester.pump();
        }
        await tester.pumpAndSettle();

        // The panel must not collapse to an empty state: the pinned root
        // keeps the thread viewable even though the buffer forgot it.
        expect(find.text('No messages found'), findsNothing);
        expect(find.textContaining('thread root'), findsAtLeast(1));
      },
    );

    testWidgets('emote menu overlays the reply thread instead of closing it', (
      WidgetTester tester,
    ) async {
      SharedPreferences.setMockInitialValues({'access_token': 'test_token'});
      FlutterSecureStorage.setMockInitialValues({'access_token': 'test_token'});
      const channel = 'testchannel';
      final parent = TwitchMessage(
        login: 'alice',
        text: 'parent msg',
        messageId: 'p1',
        timestamp: now.subtract(const Duration(minutes: 5)),
        channel: channel,
      );
      final child = TwitchMessage(
        login: 'bob',
        text: 'child msg',
        messageId: 'c1',
        replyToParentId: 'p1',
        replyToUser: 'alice',
        replyToText: 'parent msg',
        timestamp: now.subtract(const Duration(minutes: 4)),
        isHistory: true,
        channel: channel,
      );
      final irc = _FakeIrcService();
      await joinChannel(
        tester,
        channelName: channel,
        history: [parent, child],
        irc: irc,
      );
      irc.triggerConnect();
      await tester.pump();

      await tester.tap(find.textContaining('replying to alice: parent msg'));
      await tester.pumpAndSettle();
      expect(find.text('Reply Thread'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.emoji_emotions_outlined));
      await tester.pumpAndSettle();

      expect(find.text('Reply Thread'), findsOneWidget);
      expect(find.text('Recent'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.emoji_emotions_outlined));
      await tester.pumpAndSettle();

      expect(find.text('Recent'), findsNothing);
      expect(find.text('Reply Thread'), findsOneWidget);
    });

    testWidgets('long-press view thread on history child opens thread modal', (
      WidgetTester tester,
    ) async {
      const channel = 'testchannel';
      final parent = TwitchMessage(
        login: 'alice',
        text: 'parent msg',
        messageId: 'p1',
        timestamp: now.subtract(const Duration(minutes: 5)),
        channel: channel,
      );
      final child = TwitchMessage(
        login: 'bob',
        text: 'child msg',
        messageId: 'c1',
        replyToParentId: 'p1',
        replyToUser: 'alice',
        replyToText: 'parent msg',
        timestamp: now.subtract(const Duration(minutes: 4)),
        isHistory: true,
        channel: channel,
      );
      await joinChannel(tester, channelName: channel, history: [parent, child]);

      await tester.longPress(find.textContaining('bob: child msg'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('View thread'));
      await tester.pumpAndSettle();

      expect(find.text('Reply Thread'), findsOneWidget);
      expect(find.textContaining('parent msg'), findsAtLeast(1));
      expect(find.textContaining('child msg'), findsAtLeast(1));
    });

    testWidgets(
      'long-press view thread on parent with children opens thread with all messages',
      (WidgetTester tester) async {
        const channel = 'testchannel';
        final parent = TwitchMessage(
          login: 'alice',
          text: 'parent msg',
          messageId: 'p1',
          timestamp: now.subtract(const Duration(minutes: 5)),
          channel: channel,
        );
        final child1 = TwitchMessage(
          login: 'bob',
          text: 'child one',
          messageId: 'c1',
          replyToParentId: 'p1',
          replyToUser: 'alice',
          replyToText: 'parent preview',
          timestamp: now.subtract(const Duration(minutes: 4)),
          isHistory: true,
          channel: channel,
        );
        final child2 = TwitchMessage(
          login: 'charlie',
          text: 'child two',
          messageId: 'c2',
          replyToParentId: 'p1',
          replyToUser: 'alice',
          replyToText: 'parent preview',
          timestamp: now.subtract(const Duration(minutes: 3)),
          isHistory: true,
          channel: channel,
        );
        await joinChannel(
          tester,
          channelName: channel,
          history: [parent, child1, child2],
        );

        await tester.longPress(find.textContaining('alice: parent msg'));
        await tester.pumpAndSettle();

        await tester.tap(find.text('View thread'));
        await tester.pumpAndSettle();

        expect(find.text('Reply Thread'), findsOneWidget);
        expect(find.textContaining('parent msg'), findsAtLeast(1));
        expect(find.textContaining('child one'), findsAtLeast(1));
        expect(find.textContaining('child two'), findsAtLeast(1));
      },
    );

    testWidgets(
      'long-press on standalone message does not show view thread option',
      (WidgetTester tester) async {
        const channel = 'testchannel';
        final standalone = TwitchMessage(
          login: 'charlie',
          text: 'standalone msg',
          messageId: 's1',
          timestamp: now.subtract(const Duration(minutes: 3)),
          channel: channel,
        );
        await joinChannel(tester, channelName: channel, history: [standalone]);

        await tester.longPress(find.textContaining('charlie: standalone msg'));
        await tester.pumpAndSettle();

        expect(find.text('View thread'), findsNothing);
        expect(find.text('Reply to message'), findsOneWidget);
      },
    );

    testWidgets(
      'reply indicator on 3-level deep chain opens thread with all messages',
      (WidgetTester tester) async {
        const channel = 'testchannel';
        final root = TwitchMessage(
          login: 'alice',
          text: 'root level',
          messageId: 'd1',
          timestamp: now.subtract(const Duration(minutes: 7)),
          channel: channel,
        );
        final mid = TwitchMessage(
          login: 'bob',
          text: 'mid level',
          messageId: 'd2',
          replyToParentId: 'd1',
          replyToUser: 'alice',
          replyToText: 'root level',
          timestamp: now.subtract(const Duration(minutes: 5)),
          isHistory: true,
          channel: channel,
        );
        final leaf = TwitchMessage(
          login: 'charlie',
          text: 'leaf level',
          messageId: 'd3',
          replyToParentId: 'd2',
          replyToUser: 'bob',
          replyToText: 'mid level',
          timestamp: now.subtract(const Duration(minutes: 3)),
          isHistory: true,
          channel: channel,
        );
        await joinChannel(
          tester,
          channelName: channel,
          history: [root, mid, leaf],
        );

        await tester.tap(find.textContaining('replying to bob: mid level'));
        await tester.pumpAndSettle();

        expect(find.text('Reply Thread'), findsOneWidget);
        expect(find.textContaining('root level'), findsAtLeast(1));
        expect(find.textContaining('mid level'), findsAtLeast(1));
        expect(find.textContaining('leaf level'), findsAtLeast(1));
      },
    );

    testWidgets(
      'reply indicator on orphan reply opens thread showing the orphan alone',
      (WidgetTester tester) async {
        const channel = 'testchannel';
        final orphan = TwitchMessage(
          login: 'bob',
          text: 'orphan msg',
          messageId: 'o1',
          replyToParentId: 'nonexistent',
          replyToUser: 'unknown_user',
          replyToText: 'missing text',
          timestamp: now.subtract(const Duration(minutes: 4)),
          isHistory: true,
          channel: channel,
        );
        await joinChannel(tester, channelName: channel, history: [orphan]);

        await tester.tap(
          find.textContaining('replying to unknown_user: missing text'),
        );
        await tester.pumpAndSettle();

        expect(find.text('Reply Thread'), findsOneWidget);
        expect(find.textContaining('orphan msg'), findsAtLeast(1));
      },
    );

    testWidgets('long-press message inside thread panel opens context menu', (
      WidgetTester tester,
    ) async {
      const channel = 'testchannel';
      final parent = TwitchMessage(
        login: 'alice',
        text: 'parent msg',
        messageId: 'p1',
        timestamp: now.subtract(const Duration(minutes: 5)),
        channel: channel,
      );
      final child = TwitchMessage(
        login: 'bob',
        text: 'child msg',
        messageId: 'c1',
        replyToParentId: 'p1',
        replyToUser: 'alice',
        replyToText: 'parent msg',
        timestamp: now.subtract(const Duration(minutes: 4)),
        isHistory: true,
        channel: channel,
      );
      await joinChannel(tester, channelName: channel, history: [parent, child]);

      await tester.tap(find.textContaining('replying to alice: parent msg'));
      await tester.pumpAndSettle();
      expect(find.text('Reply Thread'), findsOneWidget);

      final childInThread = find.textContaining('bob: child msg');
      expect(childInThread, findsAtLeast(1));
      await tester.longPress(childInThread.last);
      await tester.pumpAndSettle();

      expect(find.text('Copy message'), findsOneWidget);
      expect(find.text('More...'), findsOneWidget);
    });

    testWidgets('swipe down on thread panel header closes the panel', (
      WidgetTester tester,
    ) async {
      const channel = 'testchannel';
      final parent = TwitchMessage(
        login: 'alice',
        text: 'parent msg',
        messageId: 'p1',
        timestamp: now.subtract(const Duration(minutes: 5)),
        channel: channel,
      );
      final child = TwitchMessage(
        login: 'bob',
        text: 'child msg',
        messageId: 'c1',
        replyToParentId: 'p1',
        replyToUser: 'alice',
        replyToText: 'parent msg',
        timestamp: now.subtract(const Duration(minutes: 4)),
        isHistory: true,
        channel: channel,
      );
      await joinChannel(tester, channelName: channel, history: [parent, child]);

      await tester.tap(find.textContaining('replying to alice: parent msg'));
      await tester.pumpAndSettle();
      expect(find.text('Reply Thread'), findsOneWidget);

      // Grab the header strip (title row, not the pill) and flick down.
      await tester.fling(find.text('Reply Thread'), const Offset(0, 300), 1000);
      await tester.pumpAndSettle();

      expect(find.text('Reply Thread'), findsNothing);
    });
  });

  group('System messages', () {
    Future<void> setupChannel(
      WidgetTester tester, {
      required _FakeEventSubService eventSub,
      required _FakeIrcService irc,
      RecentMessagesService? recent,
    }) async {
      SharedPreferences.setMockInitialValues({'access_token': 'test_token'});
      FlutterSecureStorage.setMockInitialValues({'access_token': 'test_token'});
      final fakeRecent = recent ?? _FakeRecentMessagesService();

      await tester.pumpWidget(
        TwitchChatApp(
          eventSubService: eventSub,
          recentMessagesService: fakeRecent,
          ircService: irc,
        ),
      );
      await tester.pump();

      await tester.tap(find.byIcon(Icons.add));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, 'testchannel');
      await tester.tap(find.text('Join').last);
      await tester.pump();
      await tester.pump();
    }

    Future<void> openEmoteMenu(WidgetTester tester) async {
      final eventSub = _FakeEventSubService();
      final irc = _FakeIrcService();
      await setupChannel(tester, eventSub: eventSub, irc: irc);
      irc.triggerConnect();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump();

      await tester.tap(find.byIcon(Icons.emoji_emotions_outlined));
      await tester.pumpAndSettle();
    }

    testWidgets('swipe down on emote tab bar closes the panel', (
      WidgetTester tester,
    ) async {
      await openEmoteMenu(tester);

      // The drag surface covers the tab bar strip, not just the pill.
      await tester.fling(find.text('Recent'), const Offset(0, 300), 1000);
      await tester.pumpAndSettle();

      expect(find.text('Recent'), findsNothing);
    });

    testWidgets('tab taps still work under the header drag surface', (
      WidgetTester tester,
    ) async {
      await openEmoteMenu(tester);

      await tester.tap(find.text('Subs'));
      await tester.pumpAndSettle();

      expect(find.text('No subscriber emotes available'), findsOneWidget);
    });

    testWidgets(
      'emote sheet box keeps full height until the keyboard overflows',
      (WidgetTester tester) async {
        await openEmoteMenu(tester);

        final sheetBox = find
            .ancestor(
              of: find.byKey(const ValueKey('emote_panel')),
              matching: find.byType(Positioned),
            )
            .first;
        final panelFinder = find.byKey(const ValueKey('emote_panel'));
        final closedH = tester.widget<Positioned>(sheetBox).height!;
        expect(closedH, greaterThan(0));

        addTearDown(tester.view.reset);

        // viewInsets are physical px; the test view has devicePixelRatio 3,
        // so bottom: 300 is a ~100px logical keyboard. A keyboard that leaves
        // room for the full sheet must not squash it.
        tester.view.viewInsets = FakeViewPadding(bottom: 300);
        await tester.pump();
        expect(tester.widget<Positioned>(sheetBox).height, closedH);

        // A tall keyboard squashes the box so the sheet fits the remaining
        // space, and the panel's top stays on screen (never past the top).
        tester.view.viewInsets = FakeViewPadding(bottom: 900);
        await tester.pump();
        final tallKbH = tester.widget<Positioned>(sheetBox).height!;
        expect(tallKbH, lessThan(closedH));
        expect(tester.getTopLeft(panelFinder).dy, greaterThanOrEqualTo(0));

        // A taller keyboard squashes it further and still keeps it on screen.
        tester.view.viewInsets = FakeViewPadding(bottom: 1200);
        await tester.pump();
        expect(tester.widget<Positioned>(sheetBox).height, lessThan(tallKbH));
        expect(tester.getTopLeft(panelFinder).dy, greaterThanOrEqualTo(0));

        // Keyboard closes -> box immediately back to the full height.
        tester.view.viewInsets = FakeViewPadding.zero;
        await tester.pump();
        expect(tester.widget<Positioned>(sheetBox).height, closedH);
      },
    );

    testWidgets('permanent ban shows "user was banned" message', (
      WidgetTester tester,
    ) async {
      final eventSub = _FakeEventSubService();
      final irc = _FakeIrcService();
      await setupChannel(tester, eventSub: eventSub, irc: irc);

      irc.emitBan('baduser', isTimeout: false, channel: 'testchannel');
      await tester.pump();

      expect(find.textContaining('baduser was banned'), findsOneWidget);
    });

    testWidgets('timeout with duration shows "timed out for Xs"', (
      WidgetTester tester,
    ) async {
      final eventSub = _FakeEventSubService();
      final irc = _FakeIrcService();
      await setupChannel(tester, eventSub: eventSub, irc: irc);

      irc.emitBan(
        'spammer',
        isTimeout: true,
        durationSeconds: 300,
        channel: 'testchannel',
      );
      await tester.pump();

      expect(
        find.textContaining('spammer was timed out for 300'),
        findsOneWidget,
      );
    });

    testWidgets('timeout without duration shows "timed out"', (
      WidgetTester tester,
    ) async {
      final eventSub = _FakeEventSubService();
      final irc = _FakeIrcService();
      await setupChannel(tester, eventSub: eventSub, irc: irc);

      irc.emitBan('spammer', isTimeout: true, channel: 'testchannel');
      await tester.pump();

      expect(find.textContaining('spammer was timed out'), findsOneWidget);
      expect(find.textContaining('for '), findsNothing);
    });

    testWidgets('notice shows the notice text', (WidgetTester tester) async {
      final eventSub = _FakeEventSubService();
      final irc = _FakeIrcService();
      await setupChannel(tester, eventSub: eventSub, irc: irc);

      irc.emitNotice('testchannel', 'This room requires a verified email.');
      await tester.pump();

      expect(
        find.textContaining('This room requires a verified email.'),
        findsOneWidget,
      );
    });

    testWidgets('message deletion shows "A message from X was deleted"', (
      WidgetTester tester,
    ) async {
      final eventSub = _FakeEventSubService();
      final irc = _FakeIrcService();
      await setupChannel(tester, eventSub: eventSub, irc: irc);

      irc.emitDeleted(
        'root-1',
        'testchannel',
        user: 'alice',
        deletedMessageText: 'hello world',
      );
      await tester.pump();

      expect(
        find.textContaining('A message from alice was deleted'),
        findsOneWidget,
      );
      expect(find.textContaining('hello world'), findsAtLeast(1));
    });

    testWidgets('settled message still greys out on CLEARMSG deletion', (
      WidgetTester tester,
    ) async {
      final eventSub = _FakeEventSubService();
      final irc = _FakeIrcService();
      await setupChannel(tester, eventSub: eventSub, irc: irc);

      // Send a live message and let its tile cache/element settle.
      irc.emitMessage(
        TwitchMessage(
          login: 'bob',
          text: 'will be deleted',
          channel: 'testchannel',
          messageId: 'live-1',
        ),
      );
      await tester.pump();
      // A second live message shifts the first, forcing a real reconciliation.
      irc.emitMessage(
        TwitchMessage(
          login: 'carol',
          text: 'shift me',
          channel: 'testchannel',
          messageId: 'live-2',
        ),
      );
      await tester.pump();

      irc.emitDeleted(
        'live-1',
        'testchannel',
        user: 'mod',
        deletedMessageText: 'will be deleted',
      );
      await tester.pump();

      final opacityWidgets = tester.widgetList<Opacity>(
        find.ancestor(
          of: find.textContaining('will be deleted'),
          matching: find.byType(Opacity),
        ),
      );
      expect(opacityWidgets.any((o) => o.opacity == 0.35), isTrue);
    });

    testWidgets('connected appears only once when EventSub connects', (
      WidgetTester tester,
    ) async {
      final eventSub = _FakeEventSubService();
      final irc = _FakeIrcService();
      await setupChannel(tester, eventSub: eventSub, irc: irc);

      irc.triggerConnect();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump();

      expect(find.textContaining('Connected'), findsOneWidget);

      irc.triggerConnect();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump();

      expect(find.textContaining('Connected'), findsOneWidget);
    });

    testWidgets('statuses: Connected survives Disconnected; reconnect folds', (
      WidgetTester tester,
    ) async {
      final eventSub = _FakeEventSubService();
      final irc = _FakeIrcService();
      await setupChannel(tester, eventSub: eventSub, irc: irc);

      irc.triggerConnect();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump();
      expect(find.textContaining('Connected'), findsOneWidget);

      irc.triggerDisconnect();
      await tester.pump();
      // "Connected" is NOT swallowed by "Disconnected": both stay separate.
      // (The input hint reads "Reconnecting..." while down, hence one
      // "Disconnected" system line and one "Reconnecting..." hint.)
      expect(find.textContaining('Connected'), findsOneWidget);
      expect(find.textContaining('Disconnected'), findsOneWidget);
      expect(find.textContaining('Reconnecting'), findsOneWidget);

      irc.triggerConnect();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump();

      // The transient "Disconnected" is folded into "Reconnected"; the
      // boot "Connected" survives as its own line.
      expect(find.textContaining('Connected'), findsOneWidget);
      expect(find.textContaining('Reconnected'), findsOneWidget);
      expect(find.textContaining('Disconnected'), findsNothing);
    });

    testWidgets('reconnect history backfill renders greyed out', (
      WidgetTester tester,
    ) async {
      final eventSub = _FakeEventSubService();
      final irc = _FakeIrcService();
      final recent = _GappedRecentMessagesService();
      await setupChannel(tester, eventSub: eventSub, irc: irc, recent: recent);

      irc.triggerConnect();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump();
      // Boot history loaded (first fetch), no backfill yet.
      expect(find.textContaining('early message'), findsWidgets);

      irc.triggerDisconnect();
      await tester.pump();
      irc.triggerConnect();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump();

      // The gap message recovered on reconnect renders at 0.5 opacity.
      final opacityWidgets = tester.widgetList<Opacity>(
        find.ancestor(
          of: find.textContaining('missed during gap'),
          matching: find.byType(Opacity),
        ),
      );
      expect(opacityWidgets.any((o) => o.opacity == 0.5), isTrue);
    });

    testWidgets(
      'system message on unfocused channel does not trigger unread indicator',
      (WidgetTester tester) async {
        SharedPreferences.setMockInitialValues({'access_token': 'test_token'});
        FlutterSecureStorage.setMockInitialValues({
          'access_token': 'test_token',
        });
        final eventSub = _FakeEventSubService();
        final irc = _FakeIrcService();
        final recent = _FakeRecentMessagesService();

        await tester.pumpWidget(
          TwitchChatApp(
            eventSubService: eventSub,
            ircService: irc,
            recentMessagesService: recent,
          ),
        );
        await tester.pump();

        for (final name in ['channelB', 'channelA']) {
          await tester.tap(find.byIcon(Icons.add));
          await tester.pumpAndSettle();
          await tester.enterText(find.byType(TextField).last, name);
          await tester.tap(find.text('Join'));
          await tester.pump();
          await tester.pump();
        }

        irc.emitNotice('channelB', 'This room requires a verified email.');
        await tester.pump();

        final channelBTabs = tester.widgetList<Text>(find.text('channelB'));
        expect(
          channelBTabs.every(
            (t) =>
                (t.style?.fontWeight ?? FontWeight.normal) ==
                    FontWeight.normal &&
                t.style?.color == null,
          ),
          isTrue,
        );
      },
    );

    testWidgets('banned user messages render at 35% opacity', (
      WidgetTester tester,
    ) async {
      final eventSub = _FakeEventSubService();
      final irc = _FakeIrcService();
      final recent = _ConfigurableRecentMessagesService([
        TwitchMessage(
          login: 'bob',
          text: 'i am a bad person',
          channel: 'testchannel',
          messageId: 'bad-1',
        ),
        TwitchMessage(
          login: 'gooduser',
          text: 'i am nice',
          channel: 'testchannel',
          messageId: 'good-1',
        ),
      ]);
      await setupChannel(tester, eventSub: eventSub, irc: irc, recent: recent);

      irc.emitBan('bob', isTimeout: false, channel: 'testchannel');
      await tester.pump();

      final opacityWidgets = tester.widgetList<Opacity>(
        find.ancestor(
          of: find.textContaining('i am a bad person'),
          matching: find.byType(Opacity),
        ),
      );
      expect(opacityWidgets.any((o) => o.opacity == 0.35), isTrue);
    });
  });

  group('Settings screen', () {
    testWidgets('Long-pressing the 3-dot button opens Settings directly', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(const TwitchChatApp());
      await tester.pump();

      await tester.longPress(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();

      // Settings screen is pushed, not the overflow menu.
      expect(find.text('Customization'), findsOneWidget);
      expect(find.text('Upload media'), findsNothing);
    });

    testWidgets('Account screen idle state shows login button', (
      WidgetTester tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      final auth = TwitchAuth();

      await tester.pumpWidget(
        MaterialApp(home: AccountScreen(twitchAuth: auth)),
      );
      await tester.pump();

      expect(find.text('Account'), findsOneWidget);
      expect(find.text('Login'), findsOneWidget);
      expect(find.text('Connected'), findsNothing);
    });

    testWidgets('Account screen success state shows connected and disconnect', (
      WidgetTester tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      final auth = TwitchAuth()..accessToken = 'test-token';

      await tester.pumpWidget(
        MaterialApp(home: AccountScreen(twitchAuth: auth)),
      );
      await tester.pump();

      expect(find.text('Connected'), findsOneWidget);
      expect(find.text('Disconnect'), findsOneWidget);
      expect(find.text('Login'), findsNothing);
    });

    testWidgets('Account screen shows "Connected as {user}" on lookup', (
      WidgetTester tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      final auth = TwitchAuth()..accessToken = 'test-token';
      final api = TwitchApi(
        client: MockClient((request) async {
          return http.Response(
            '{"data":[{"id":"1","login":"testuser","display_name":"TestUser"}]}',
            200,
          );
        }),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: AccountScreen(twitchAuth: auth, twitchApi: api),
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(find.text('Connected as testuser'), findsOneWidget);
      expect(find.text('Connected'), findsNothing);
    });

    testWidgets('Account screen disconnect transitions to idle', (
      WidgetTester tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      final auth = TwitchAuth()..accessToken = 'test-token';

      await tester.pumpWidget(
        MaterialApp(home: AccountScreen(twitchAuth: auth)),
      );
      await tester.pump();

      expect(find.text('Connected'), findsOneWidget);

      await tester.tap(find.text('Disconnect'));
      await tester.pump();
      await tester.pump();

      expect(find.text('Connected'), findsNothing);
      expect(find.text('Login'), findsOneWidget);
    });

    testWidgets('Customization dark mode toggle calls onThemeChanged', (
      WidgetTester tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      ThemeMode? changed;

      await tester.pumpWidget(
        MaterialApp(
          home: CustomizationScreen(onThemeChanged: (mode) => changed = mode),
        ),
      );
      await tester.pump();

      await tester.tap(find.widgetWithText(SwitchListTile, 'Dark mode'));
      await tester.pumpAndSettle();

      expect(changed, ThemeMode.dark);
    });

    testWidgets('Customization keep screen on toggle reflects value and calls '
        'onKeepScreenOnChanged', (WidgetTester tester) async {
      SharedPreferences.setMockInitialValues({});
      bool? changed;

      await tester.pumpWidget(
        MaterialApp(
          home: CustomizationScreen(
            onThemeChanged: (_) {},
            onKeepScreenOnChanged: (value) => changed = value,
          ),
        ),
      );
      await tester.pump();

      final tile = tester.widget<SwitchListTile>(
        find.widgetWithText(SwitchListTile, 'Keep screen on'),
      );
      expect(tile.value, isTrue);

      await tester.tap(find.widgetWithText(SwitchListTile, 'Keep screen on'));
      await tester.pumpAndSettle();

      expect(changed, isFalse);
    });

    testWidgets('Customization true dark toggle is disabled in light mode', (
      WidgetTester tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      bool? changed;

      await tester.pumpWidget(
        MaterialApp(
          home: CustomizationScreen(
            onThemeChanged: (_) {},
            onTrueDarkChanged: (value) => changed = value,
          ),
        ),
      );
      await tester.pump();

      final tile = tester.widget<SwitchListTile>(
        find.widgetWithText(SwitchListTile, 'True dark mode'),
      );
      expect(tile.onChanged, isNull);

      await tester.tap(find.widgetWithText(SwitchListTile, 'True dark mode'));
      await tester.pumpAndSettle();

      expect(changed, isNull);
    });

    testWidgets('Customization true dark toggle persists and calls '
        'onTrueDarkChanged', (WidgetTester tester) async {
      SharedPreferences.setMockInitialValues({});
      bool? changed;

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(brightness: Brightness.light),
          darkTheme: ThemeData(brightness: Brightness.dark),
          themeMode: ThemeMode.dark,
          home: CustomizationScreen(
            onThemeChanged: (_) {},
            onTrueDarkChanged: (value) => changed = value,
          ),
        ),
      );
      await tester.pump();

      final tile = tester.widget<SwitchListTile>(
        find.widgetWithText(SwitchListTile, 'True dark mode'),
      );
      expect(tile.value, isFalse);

      await tester.tap(find.widgetWithText(SwitchListTile, 'True dark mode'));
      await tester.pumpAndSettle();

      expect(changed, isTrue);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('true_dark'), isTrue);
    });

    testWidgets('Customization accent picker selects a preset and persists', (
      WidgetTester tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      String? changed;

      await tester.pumpWidget(
        MaterialApp(
          home: CustomizationScreen(
            onThemeChanged: (_) {},
            onAccentColorChanged: (value) => changed = value,
          ),
        ),
      );
      await tester.pump();

      expect(find.text('Accent color'), findsOneWidget);
      // 10 presets rendered as swatches.
      for (final key in kAccentPresets.keys) {
        expect(find.byKey(ValueKey('accent_$key')), findsOneWidget);
      }

      await tester.tap(find.byKey(const ValueKey('accent_red')));
      await tester.pumpAndSettle();

      expect(changed, 'red');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('accent_color'), 'red');
    });

    testWidgets('Channel settings shows joined channels', (
      WidgetTester tester,
    ) async {
      SharedPreferences.setMockInitialValues({});

      await tester.pumpWidget(
        MaterialApp(
          home: ChannelSettingsScreen(
            channelNotifier: ValueNotifier(['channel1', 'channel2']),
            onLeaveChannel: (_) {},
          ),
        ),
      );
      await tester.pump();

      expect(find.text('channel1'), findsOneWidget);
      expect(find.text('channel2'), findsOneWidget);
      expect(find.byIcon(Icons.remove_circle_outline), findsNWidgets(2));
    });

    testWidgets('Channel settings drag handle reorders channels', (
      WidgetTester tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      List<String>? reordered;

      await tester.pumpWidget(
        MaterialApp(
          home: ChannelSettingsScreen(
            channelNotifier: ValueNotifier(['a', 'b', 'c']),
            onReorderChannels: (channels) => reordered = channels,
          ),
        ),
      );
      await tester.pump();

      final gesture = await tester.startGesture(
        tester.getCenter(find.text('a')),
      );
      await tester.pump(const Duration(milliseconds: 700));
      await gesture.moveBy(const Offset(0, 120));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();

      expect(reordered, isNotNull);
      expect(reordered, isNot(equals(['a', 'b', 'c'])));
    });

    testWidgets('Channel settings join channel dialog', (
      WidgetTester tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      String? addedChannel;

      await tester.pumpWidget(
        MaterialApp(
          home: ChannelSettingsScreen(
            channelNotifier: ValueNotifier([]),
            onAddChannel: (ch) => addedChannel = ch,
          ),
        ),
      );
      await tester.pump();

      await tester.tap(find.text('Join channel'));
      await tester.pumpAndSettle();

      expect(find.text('Join channel'), findsWidgets);
      expect(find.text('Cancel'), findsOneWidget);
      expect(find.text('Join'), findsOneWidget);

      await tester.enterText(find.byType(TextField).last, 'newchannel');
      await tester.tap(find.text('Join').last);
      await tester.pumpAndSettle();

      expect(addedChannel, 'newchannel');
    });

    testWidgets('Chat settings timestamp toggle and format picker persist', (
      WidgetTester tester,
    ) async {
      SharedPreferences.setMockInitialValues({});

      await tester.pumpWidget(const MaterialApp(home: ChatSettingsScreen()));
      await tester.pump();

      final toggle = tester.widget<SwitchListTile>(
        find.widgetWithText(SwitchListTile, 'Show timestamps'),
      );
      expect(toggle.value, isTrue);
      // Interact with the top-of-list toggle before scrolling down: the
      // lazy ListView disposes items that scroll out of the cache extent.
      await tester.tap(find.widgetWithText(SwitchListTile, 'Show timestamps'));
      await tester.pumpAndSettle();
      var prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('show_timestamps'), isFalse);
      // The new FPS-cap rows sit between the gifs toggle and the timestamp
      // tile, pushing the format subtitle below the fold of the lazy list.
      await tester.scrollUntilVisible(
        find.widgetWithText(ListTile, 'Timestamp format'),
        120,
      );
      await tester.pumpAndSettle();
      expect(find.text('HH:mm'), findsOneWidget);

      final formatTile = find.widgetWithText(ListTile, 'Timestamp format');
      await tester.ensureVisible(formatTile);
      await tester.pumpAndSettle();
      await tester.tap(formatTile);
      await tester.pumpAndSettle();
      await tester.tap(find.text('h:mm a'));
      await tester.pumpAndSettle();

      prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('timestamp_format'), 'h:mm a');
      expect(find.text('h:mm a'), findsOneWidget);
    });

    testWidgets('max messages slider is log-scaled and snaps to steps', (
      WidgetTester tester,
    ) async {
      // Legacy value between steps snaps to the nearest log-scale step.
      SharedPreferences.setMockInitialValues({'max_messages_per_channel': 275});

      await tester.pumpWidget(const MaterialApp(home: ChatSettingsScreen()));
      await tester.pump();
      await tester.pump();

      expect(find.text('Max messages per channel: 300'), findsOneWidget);

      final slider = tester.widget<Slider>(find.byType(Slider).first);
      expect(slider.min, 0);
      expect(slider.max, 9);
      expect(slider.divisions, 9);

      // Tap the far right of the track: snaps to the max step (5000).
      final rect = tester.getRect(find.byType(Slider).first);
      await tester.tapAt(Offset(rect.right - 2, rect.center.dy));
      await tester.pump();
      await tester.pump();

      expect(find.text('Max messages per channel: 5000'), findsOneWidget);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt('max_messages_per_channel'), 5000);
    });

    testWidgets('tier slider change persists emote_fetch_tier and fires '
        'onEmoteTierChanged', (WidgetTester tester) async {
      SharedPreferences.setMockInitialValues({
        'emote_fetch_auto': EmoteFetchAutoMode.off.index,
      });
      int? changed;

      await tester.pumpWidget(
        MaterialApp(
          home: EmotesSettingsScreen(
            onEmoteTierChanged: (value) => changed = value,
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      final slider = tester.widget<Slider>(
        find.byKey(const Key('emote_tier_slider')),
      );
      slider.onChanged!(EmoteFetchTier.low.index.toDouble());
      await tester.pump();
      await tester.pump();

      expect(changed, EmoteFetchTier.low.index);
      expect(find.text('Low'), findsOneWidget);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt('emote_fetch_tier'), EmoteFetchTier.low.index);
    });

    testWidgets('provider toggles flip the manager and persist', (
      WidgetTester tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      final manager = EmoteManager(
        fetchStagger: Duration.zero,
        tier: EmoteFetchTier.nothing,
      );

      await tester.pumpWidget(
        MaterialApp(home: EmotesSettingsScreen(emoteManager: manager)),
      );
      await tester.pump();
      await tester.pump();

      // Twitch is always on and not offered as an option.
      expect(find.byKey(const Key('provider_toggle_twitch')), findsNothing);
      expect(find.text('Providers'), findsOneWidget);

      // The picker lives in a bottom sheet at the bottom of the page.
      expect(find.byKey(const Key('provider_toggle_bttv')), findsNothing);
      await tester.scrollUntilVisible(
        find.byKey(const Key('providers_tile')),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('providers_tile')));
      await tester.pumpAndSettle();
      expect(find.text('BetterTTV'), findsOneWidget);
      expect(find.text('FrankerFaceZ'), findsOneWidget);
      expect(find.text('7TV'), findsOneWidget);

      await tester.tap(find.byKey(const Key('provider_toggle_bttv')));
      await tester.pump();

      expect(manager.isProviderEnabled(EmoteType.bttv), isFalse);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getStringList('emote_providers_disabled'), ['bttv']);
    });

    testWidgets('allow-unlisted switch flips the manager and persists', (
      WidgetTester tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      final manager = EmoteManager(
        fetchStagger: Duration.zero,
        tier: EmoteFetchTier.nothing,
      );

      await tester.pumpWidget(
        MaterialApp(home: EmotesSettingsScreen(emoteManager: manager)),
      );
      await tester.pump();
      await tester.pump();

      await tester.scrollUntilVisible(
        find.byKey(const Key('allow_unlisted_tile')),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();

      expect(manager.allowUnlisted7tv, isFalse);
      await tester.tap(find.byKey(const Key('allow_unlisted_tile')));
      await tester.pump();

      expect(manager.allowUnlisted7tv, isTrue);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('emote_7tv_allow_unlisted'), isTrue);
    });

    testWidgets('auto-mode switch persists emote_fetch_auto, fires callback, '
        'and disables the tier slider', (WidgetTester tester) async {
      SharedPreferences.setMockInitialValues({});
      EmoteFetchAutoMode? changed;

      await tester.pumpWidget(
        MaterialApp(
          home: EmotesSettingsScreen(
            onEmoteAutoModeChanged: (mode) => changed = mode,
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(find.byKey(const Key('emote_auto_mode')), findsOneWidget);
      // Auto mode defaults to Balanced, so the manual tier slider is locked.
      expect(find.text('Balanced'), findsOneWidget);
      var slider = tester.widget<Slider>(
        find.byKey(const Key('emote_tier_slider')),
      );
      expect(slider.onChanged, isNull);

      await tester.tap(find.text('Aggressive'));
      await tester.pump();
      await tester.pump();

      expect(changed, EmoteFetchAutoMode.aggressive);
      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getInt('emote_fetch_auto'),
        EmoteFetchAutoMode.aggressive.index,
      );
      slider = tester.widget<Slider>(
        find.byKey(const Key('emote_tier_slider')),
      );
      expect(slider.onChanged, isNull);

      await tester.tap(find.text('Off'));
      await tester.pump();
      await tester.pump();

      expect(changed, EmoteFetchAutoMode.off);
      final unlocked = tester.widget<Slider>(
        find.byKey(const Key('emote_tier_slider')),
      );
      expect(unlocked.onChanged, isNotNull);
    });

    testWidgets('toggling auto mode keeps the section below fixed in place', (
      WidgetTester tester,
    ) async {
      SharedPreferences.setMockInitialValues({
        'emote_fetch_auto': EmoteFetchAutoMode.off.index,
      });

      await tester.pumpWidget(const MaterialApp(home: EmotesSettingsScreen()));
      await tester.pump();
      await tester.pump();

      final before = tester
          .getTopLeft(find.byKey(const Key('emote_auto_mode')))
          .dy;

      await tester.tap(find.text('Balanced'));
      await tester.pumpAndSettle();

      final after = tester
          .getTopLeft(find.byKey(const Key('emote_auto_mode')))
          .dy;
      expect(after, before);
    });

    testWidgets('auto mode slider reflects the effective tier and follows '
        'connectivity changes', (WidgetTester tester) async {
      SharedPreferences.setMockInitialValues({
        'emote_fetch_auto': EmoteFetchAutoMode.balanced.index,
      });
      final mobile = ValueNotifier<bool>(true);

      await tester.pumpWidget(
        MaterialApp(home: EmotesSettingsScreen(mobileNotifier: mobile)),
      );
      await tester.pump();
      await tester.pump();

      // Balanced + cellular => Low is being picked and shown on the slider.
      expect(find.text('Low'), findsOneWidget);
      var slider = tester.widget<Slider>(
        find.byKey(const Key('emote_tier_slider')),
      );
      expect(slider.value, EmoteFetchTier.low.index.toDouble());
      expect(slider.onChanged, isNull);

      // Hand off to Wi-Fi while the screen is open: the tier animates up to
      // High; wait for the animation to settle before asserting the value.
      mobile.value = false;
      await tester.pumpAndSettle();
      expect(find.text('High'), findsOneWidget);
      expect(find.text('Low'), findsNothing);
      slider = tester.widget<Slider>(
        find.byKey(const Key('emote_tier_slider')),
      );
      expect(slider.value, EmoteFetchTier.high.index.toDouble());
    });

    testWidgets('cache-size slider only applies on Apply', (
      WidgetTester tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      int? applied;

      await tester.pumpWidget(
        MaterialApp(
          home: EmotesSettingsScreen(
            onEmoteCacheMaxChanged: (value) => applied = value,
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      final slider = tester.widget<Slider>(
        find.byKey(const Key('emote_cache_slider')),
      );
      slider.onChanged!(1000.0);
      await tester.pump();

      expect(applied, isNull);
      var prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt('emote_cache_max'), isNull);

      await tester.tap(find.byKey(const Key('emote_cache_apply')));
      await tester.pump();
      await tester.pump();

      expect(applied, 1000);
      prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt('emote_cache_max'), 1000);
    });

    testWidgets('applying a cache cap of 0 evicts cached files immediately', (
      WidgetTester tester,
    ) async {
      SharedPreferences.setMockInitialValues({
        'emote_fetch_auto': EmoteFetchAutoMode.off.index,
      });
      final repo = FakeCacheRepo();
      final t = DateTime(2026, 1, 1, 12);
      repo.seed([
        CacheObject(
          'https://example.com/a.png',
          id: 1,
          relativePath: 'a.png',
          validTill: DateTime(2030),
          touched: t,
        ),
        CacheObject(
          'https://example.com/b.png',
          id: 2,
          relativePath: 'b.png',
          validTill: DateTime(2030),
          touched: t.add(const Duration(hours: 1)),
        ),
        CacheObject(
          'https://example.com/c.png',
          id: 3,
          relativePath: 'c.png',
          validTill: DateTime(2030),
          touched: t.add(const Duration(hours: 2)),
        ),
      ]);
      final manager = EmoteCacheManager.forTesting(
        Config('test', repo: repo, fileSystem: MemoryCacheSystem()),
      );

      await tester.pumpWidget(
        MaterialApp(home: EmotesSettingsScreen(cacheManager: manager)),
      );
      await tester.pump();
      await tester.pump();

      final slider = tester.widget<Slider>(
        find.byKey(const Key('emote_cache_slider')),
      );
      slider.onChanged!(0);
      await tester.pump();

      await tester.tap(find.byKey(const Key('emote_cache_apply')));
      await tester.pump();
      await tester.pump();

      expect(repo.keys, isEmpty);

      // Let the cache store's one-shot cleanup timer fire so the test ends
      // without pending timers.
      await tester.pump(const Duration(seconds: 10));
    });
  });

  group('Tools settings', () {
    testWidgets('Tools screen links to uploader, recents, and analytics', (
      WidgetTester tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      await tester.pumpWidget(
        MaterialApp(
          home: ToolsSettingsScreen(
            analyticsService: AnalyticsService(),
            channels: ['channel1'],
          ),
        ),
      );
      await tester.pump();

      expect(find.text('Tools'), findsOneWidget);
      expect(find.text('Image uploader'), findsOneWidget);
      expect(find.text('Recent uploads'), findsOneWidget);
      expect(find.text('Analytics'), findsOneWidget);

      await tester.tap(find.text('Image uploader'));
      await tester.pumpAndSettle();
      expect(find.text('Image uploader'), findsWidgets);
      expect(find.text('Save'), findsOneWidget);
    });

    testWidgets('Tools screen hides analytics when no service is provided', (
      WidgetTester tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      await tester.pumpWidget(const MaterialApp(home: ToolsSettingsScreen()));
      await tester.pump();

      expect(find.text('Image uploader'), findsOneWidget);
      expect(find.text('Recent uploads'), findsOneWidget);
      expect(find.text('Analytics'), findsNothing);
    });

    testWidgets(
      'Recent uploads screen shows stored uploads and copies on tap',
      (WidgetTester tester) async {
        SharedPreferences.setMockInitialValues({});
        final uploader = MediaUploader();
        await uploader.addRecent(
          const UploadResult(imageLink: 'https://kappa.lol/abc'),
        );
        await tester.pumpWidget(const MaterialApp(home: RecentUploadsScreen()));
        await tester.pump();
        await tester.pump();

        expect(find.text('https://kappa.lol/abc'), findsOneWidget);

        await tester.tap(find.byType(ListTile).first);
        await tester.pumpAndSettle();
        expect(find.text('Copied https://kappa.lol/abc'), findsOneWidget);
      },
    );
  });

  group('Message cutoff', () {
    Future<void> joinChannel(
      WidgetTester tester, {
      required String channelName,
      required List<TwitchMessage> history,
      _FakeIrcService? irc,
      int maxMessages = 500,
    }) async {
      SharedPreferences.setMockInitialValues({
        'max_messages_per_channel': maxMessages,
      });
      final fakeIrc = irc ?? _FakeIrcService();
      final fakeRecent = _ConfigurableRecentMessagesService(history);
      final es = _FakeEventSubService();

      await tester.pumpWidget(
        TwitchChatApp(
          eventSubService: es,
          recentMessagesService: fakeRecent,
          ircService: fakeIrc,
        ),
      );
      await tester.pump();

      await tester.tap(find.byIcon(Icons.add));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, channelName);
      await tester.tap(find.text('Join').last);
      await tester.pump();
      await tester.pump();
    }

    testWidgets('truncates non-thread messages when exceeding limit', (
      WidgetTester tester,
    ) async {
      const channel = 'testchannel';
      final history = List.generate(
        15,
        (i) => TwitchMessage(
          login: 'user$i',
          text: 'msg $i',
          messageId: 'm$i',
          timestamp: DateTime.now().subtract(Duration(minutes: 15 - i)),
          channel: channel,
        ),
      );
      final irc = _FakeIrcService();
      await joinChannel(
        tester,
        channelName: channel,
        history: history,
        irc: irc,
        maxMessages: 10,
      );

      await tester.pump();
      await tester.pump();

      expect(find.textContaining('msg 14'), findsOneWidget);
    });

    testWidgets('keeps entire thread when reply is within the limit', (
      WidgetTester tester,
    ) async {
      const channel = 'testchannel';
      final parent = TwitchMessage(
        login: 'alice',
        text: 'thread root',
        messageId: 'p1',
        timestamp: DateTime.now().subtract(const Duration(minutes: 12)),
        channel: channel,
      );
      final child = TwitchMessage(
        login: 'bob',
        text: 'thread reply',
        messageId: 'c1',
        replyToParentId: 'p1',
        replyToUser: 'alice',
        replyToText: 'thread root',
        timestamp: DateTime.now().subtract(const Duration(minutes: 11)),
        isHistory: true,
        channel: channel,
      );
      final filler = List.generate(
        9,
        (i) => TwitchMessage(
          login: 'user$i',
          text: 'filler $i',
          messageId: 'f$i',
          timestamp: DateTime.now().subtract(Duration(minutes: 10 - i)),
          channel: channel,
        ),
      );
      final irc = _FakeIrcService();
      await joinChannel(
        tester,
        channelName: channel,
        history: [parent, child, ...filler],
        irc: irc,
        maxMessages: 10,
      );

      await tester.pump();
      await tester.pump();

      // Expand viewport so lazy ListView builds all items without scrolling
      // (avoids triggering the frozen-snapshot behavior in scroll notifications).
      await tester.binding.setSurfaceSize(const Size(2000, 2000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpAndSettle();

      final taken = tester.takeException();
      if (taken != null) debugPrint('TAKEN EXCEPTION: $taken');

      expect(find.textContaining('thread root'), findsWidgets);
      expect(find.textContaining('thread reply'), findsOneWidget);
    });

    testWidgets('removes entire thread when all messages are past the limit', (
      WidgetTester tester,
    ) async {
      const channel = 'testchannel';
      final parent = TwitchMessage(
        login: 'alice',
        text: 'thread root',
        messageId: 'p2',
        timestamp: DateTime.now().subtract(const Duration(minutes: 14)),
        channel: channel,
      );
      final child = TwitchMessage(
        login: 'bob',
        text: 'thread reply',
        messageId: 'c2',
        replyToParentId: 'p2',
        replyToUser: 'alice',
        replyToText: 'thread root',
        timestamp: DateTime.now().subtract(const Duration(minutes: 13)),
        isHistory: true,
        channel: channel,
      );
      final filler = List.generate(
        13,
        (i) => TwitchMessage(
          login: 'user$i',
          text: 'filler $i',
          messageId: 'g$i',
          timestamp: DateTime.now().subtract(Duration(minutes: 12 - i)),
          channel: channel,
        ),
      );
      final irc = _FakeIrcService();
      await joinChannel(
        tester,
        channelName: channel,
        history: [parent, child, ...filler],
        irc: irc,
        maxMessages: 10,
      );

      await tester.pump();
      await tester.pump();

      expect(find.textContaining('thread root'), findsNothing);
      expect(find.textContaining('thread reply'), findsNothing);
    });

    testWidgets(
      'removes thread when new messages push last child past the limit',
      (WidgetTester tester) async {
        const channel = 'testchannel';
        final parent = TwitchMessage(
          login: 'alice',
          text: 'thread root',
          messageId: 'p3',
          timestamp: DateTime.now().subtract(const Duration(minutes: 12)),
          channel: channel,
        );
        final child = TwitchMessage(
          login: 'bob',
          text: 'thread reply',
          messageId: 'c3',
          replyToParentId: 'p3',
          replyToUser: 'alice',
          replyToText: 'thread root',
          timestamp: DateTime.now().subtract(const Duration(minutes: 11)),
          isHistory: true,
          channel: channel,
        );
        final filler = List.generate(
          9,
          (i) => TwitchMessage(
            login: 'user$i',
            text: 'filler $i',
            messageId: 'h$i',
            timestamp: DateTime.now().subtract(Duration(minutes: 10 - i)),
            channel: channel,
          ),
        );
        final irc = _FakeIrcService();
        await joinChannel(
          tester,
          channelName: channel,
          history: [parent, child, ...filler],
          irc: irc,
          maxMessages: 10,
        );

        await tester.pump();
        await tester.pump();

        // Expand viewport so lazy ListView builds all items without scrolling
        // (avoids triggering the frozen-snapshot behavior in scroll notifications).
        await tester.binding.setSurfaceSize(const Size(2000, 2000));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpAndSettle();

        // Thread is initially preserved - child is within the limit.
        expect(find.textContaining('thread root'), findsWidgets);
        expect(find.textContaining('thread reply'), findsOneWidget);

        // Emit new messages that push the thread past the limit.
        for (int i = 1; i <= 3; i++) {
          irc.emitMessage(
            TwitchMessage(
              login: 'newuser',
              text: 'new message $i',
              messageId: 'new$i',
              timestamp: DateTime.now(),
              channel: channel,
            ),
          );
          await tester.pump();
        }
        await tester.pump();

        // Truncation is coalesced (250ms window), so the full pass is
        // deferred: advance the clock and emit one more message so the
        // thread-aware pass runs and drops the thread.
        await tester.pump(const Duration(milliseconds: 300));
        irc.emitMessage(
          TwitchMessage(
            login: 'newuser',
            text: 'new message 4',
            messageId: 'new4',
            timestamp: DateTime.now(),
            channel: channel,
          ),
        );
        await tester.pump();
        await tester.pump();

        // Thread should now be removed - pushed past maxMessages=10.
        expect(find.textContaining('thread root'), findsNothing);
        expect(find.textContaining('thread reply'), findsNothing);
      },
    );
  });

  group('Chat pause', () {
    testWidgets(
      'scroll-to-bottom FAB appears when scrolled up and hides on tap',
      (WidgetTester tester) async {
        final now = DateTime.now();
        final manyMessages = List.generate(
          50,
          (i) => TwitchMessage(
            login: 'user$i',
            text: 'message number $i with some extra text to fill the line',
            channel: 'testchannel',
            messageId: 'msg-$i',
            timestamp: now.subtract(Duration(minutes: 50 - i)),
          ),
        );
        final fakeEventSub = _FakeEventSubService();
        final fakeIrc = _FakeIrcService();
        final fakeRecent = _ConfigurableRecentMessagesService(manyMessages);

        await tester.pumpWidget(
          TwitchChatApp(
            eventSubService: fakeEventSub,
            ircService: fakeIrc,
            recentMessagesService: fakeRecent,
          ),
        );
        await tester.pump();

        await tester.tap(find.byIcon(Icons.add));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField).last, 'testchannel');
        await tester.tap(find.text('Join').last);
        await tester.pump();
        await tester.pump();

        // Initially at bottom - FAB should not be visible
        expect(find.byIcon(Icons.keyboard_arrow_down), findsNothing);

        // Scroll up to trigger pause (with reverse:true, drag DOWN = scroll UP)
        await tester.drag(find.byType(ListView).first, const Offset(0, 500));
        await tester.pump();
        await tester.pump();

        // FAB should now be visible
        expect(find.byIcon(Icons.keyboard_arrow_down), findsOneWidget);

        // Tap FAB to scroll back to bottom
        await tester.tap(find.byIcon(Icons.keyboard_arrow_down));
        await tester.pump();
        await tester.pump();

        // FAB should be gone
        expect(find.byIcon(Icons.keyboard_arrow_down), findsNothing);
      },
    );

    testWidgets(
      'frozen snapshot prevents new messages from showing while scrolled up',
      (WidgetTester tester) async {
        final now = DateTime.now();
        final manyMessages = List.generate(
          50,
          (i) => TwitchMessage(
            login: 'user$i',
            text: 'message number $i',
            channel: 'testchannel',
            messageId: 'msg-$i',
            timestamp: now.subtract(Duration(minutes: 50 - i)),
          ),
        );
        final fakeEventSub = _FakeEventSubService();
        final fakeIrc = _FakeIrcService();
        final fakeRecent = _ConfigurableRecentMessagesService(manyMessages);

        await tester.pumpWidget(
          TwitchChatApp(
            eventSubService: fakeEventSub,
            ircService: fakeIrc,
            recentMessagesService: fakeRecent,
          ),
        );
        await tester.pump();

        await tester.tap(find.byIcon(Icons.add));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField).last, 'testchannel');
        await tester.tap(find.text('Join').last);
        await tester.pump();
        await tester.pump();

        // Scroll up - FAB appears (with reverse:true, drag DOWN = scroll UP)
        await tester.drag(find.byType(ListView).first, const Offset(0, 500));
        await tester.pump();
        await tester.pump();
        expect(find.byIcon(Icons.keyboard_arrow_down), findsOneWidget);

        // Emit a new message while paused
        fakeIrc.emitMessage(
          TwitchMessage(
            login: 'newuser',
            text: 'new message while paused',
            channel: 'testchannel',
            messageId: 'new-msg',
            timestamp: DateTime.now(),
          ),
        );
        await tester.pump();

        // FAB still visible - did not auto-scroll
        expect(find.byIcon(Icons.keyboard_arrow_down), findsOneWidget);

        // New message text NOT visible - frozen snapshot hides it
        expect(find.textContaining('new message while paused'), findsNothing);

        // Tap FAB to resume (clears snapshot, scrolls to bottom)
        await tester.tap(find.byIcon(Icons.keyboard_arrow_down));
        await tester.pump();
        await tester.pump();

        // FAB gone
        expect(find.byIcon(Icons.keyboard_arrow_down), findsNothing);

        // New message IS now visible after snapshot is removed
        expect(find.textContaining('new message while paused'), findsOneWidget);
      },
    );

    testWidgets('announcement system message renders a colored row', (
      WidgetTester tester,
    ) async {
      final fakeEventSub = _FakeEventSubService();
      final fakeIrc = _FakeIrcService();
      await tester.pumpWidget(
        TwitchChatApp(eventSubService: fakeEventSub, ircService: fakeIrc),
      );
      await tester.pump();
      await tester.tap(find.byIcon(Icons.add));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, 'testchannel');
      await tester.tap(find.text('Join').last);
      await tester.pump();
      await tester.pump();

      const accent = Color(0xFF1F69FF);
      final announcement = TwitchMessage(
        login: '',
        text: 'Announcement: Test announcement text',
        isSystem: true,
        systemAccent: accent,
        channel: 'testchannel',
      );
      fakeIrc.emitMessage(announcement);
      await tester.pump();

      expect(find.textContaining('Test announcement text'), findsOneWidget);
      final surface = Theme.of(
        tester.element(find.textContaining('Test announcement text')),
      ).colorScheme.surface;
      final blended = Color.alphaBlend(accent.withValues(alpha: 0.4), surface);
      final rows = find
          .ancestor(
            of: find.textContaining('Test announcement text'),
            matching: find.byType(ColoredBox),
          )
          .evaluate()
          .where((el) => (el.widget as ColoredBox).color == blended);
      expect(
        rows,
        isNotEmpty,
        reason: 'announcement should sit on a full-row accent background',
      );
    });

    testWidgets('plain system message has no accent background', (
      WidgetTester tester,
    ) async {
      final fakeEventSub = _FakeEventSubService();
      final fakeIrc = _FakeIrcService();
      await tester.pumpWidget(
        TwitchChatApp(eventSubService: fakeEventSub, ircService: fakeIrc),
      );
      await tester.pump();
      await tester.tap(find.byIcon(Icons.add));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, 'testchannel');
      await tester.tap(find.text('Join').last);
      await tester.pump();
      await tester.pump();

      final systemMsg = TwitchMessage(
        login: '',
        text: 'Plain system notice',
        isSystem: true,
        channel: 'testchannel',
      );
      fakeIrc.emitMessage(systemMsg);
      await tester.pump();

      expect(find.textContaining('Plain system notice'), findsOneWidget);
      final surface = Theme.of(
        tester.element(find.textContaining('Plain system notice')),
      ).colorScheme.surface;
      final blended = Color.alphaBlend(
        const Color(0xFF1F69FF).withValues(alpha: 0.25),
        surface,
      );
      final rows = find
          .ancestor(
            of: find.textContaining('Plain system notice'),
            matching: find.byType(ColoredBox),
          )
          .evaluate()
          .where((el) => (el.widget as ColoredBox).color == blended);
      expect(rows, isEmpty);
    });

    testWidgets('announcement renders child message plus label', (
      WidgetTester tester,
    ) async {
      final fakeEventSub = _FakeEventSubService();
      final fakeIrc = _FakeIrcService();
      await tester.pumpWidget(
        TwitchChatApp(eventSubService: fakeEventSub, ircService: fakeIrc),
      );
      await tester.pump();
      await tester.tap(find.byIcon(Icons.add));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, 'testchannel');
      await tester.tap(find.text('Join').last);
      await tester.pump();
      await tester.pump();

      fakeIrc.emitUserNotice(
        UserNoticeEvent(
          channel: 'testchannel',
          msgId: 'announcement',
          login: 'ermugo2',
          displayName: 'ermugo2',
          text: 'uuh',
          announcementColor: 'PURPLE',
          userId: '1468479097',
          messageId: 'ann-1',
          color: '#0000FF',
          badges: parseIrcBadges('broadcaster/1'),
        ),
      );
      await tester.pump();

      // DankChat-style: the child message plus the "Announcement" label.
      expect(find.textContaining('Announcement'), findsOneWidget);
      expect(find.textContaining('ermugo2: uuh'), findsOneWidget);
    });
  });

  group('Autocomplete', () {
    testWidgets('shows dropdown with user suggestion after typing', (
      WidgetTester tester,
    ) async {
      SharedPreferences.setMockInitialValues({'access_token': 'test_token'});
      FlutterSecureStorage.setMockInitialValues({'access_token': 'test_token'});
      final eventSub = _FakeEventSubService();
      final irc = _FakeIrcService();
      final recent = _FakeRecentMessagesService();

      await tester.pumpWidget(
        TwitchChatApp(
          eventSubService: eventSub,
          ircService: irc,
          recentMessagesService: recent,
        ),
      );
      await tester.pump();

      await tester.tap(find.byIcon(Icons.add));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, 'xqc');
      await tester.tap(find.text('Join'));
      await tester.pump();

      irc.emitMessage(
        TwitchMessage(
          login: 'UserOne',
          text: 'hello chat',
          channel: 'xqc',
          messageId: 'm1',
        ),
      );
      await tester.pump();

      expect(find.textContaining('UserOne'), findsOneWidget);

      irc.triggerConnect();
      await tester.pump();
      await tester.enterText(find.byKey(const Key('message_input')), 'Us');
      await tester.pump();

      final dropdown = find.byKey(const Key('autocomplete_dropdown'));
      expect(dropdown, findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const Key('autocomplete_dropdown')),
          matching: find.text('UserOne'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('backspace after autocomplete reverts to original text', (
      WidgetTester tester,
    ) async {
      SharedPreferences.setMockInitialValues({'access_token': 'test_token'});
      FlutterSecureStorage.setMockInitialValues({'access_token': 'test_token'});
      final eventSub = _FakeEventSubService();
      final irc = _FakeIrcService();
      final recent = _FakeRecentMessagesService();

      await tester.pumpWidget(
        TwitchChatApp(
          eventSubService: eventSub,
          ircService: irc,
          recentMessagesService: recent,
        ),
      );
      await tester.pump();

      // Join channel.
      await tester.tap(find.byIcon(Icons.add));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, 'xqc');
      await tester.tap(find.text('Join'));
      await tester.pump();

      // Populate user store so UserOne appears as a suggestion.
      irc.emitMessage(
        TwitchMessage(
          login: 'UserOne',
          text: 'hello chat',
          channel: 'xqc',
          messageId: 'm1',
        ),
      );
      await tester.pump();

      irc.triggerConnect();
      await tester.pump();

      // Type @Us to trigger autocomplete for user UserOne.
      final inputFinder = find.byKey(const Key('message_input'));
      await tester.enterText(inputFinder, '@Us');
      await tester.pump();

      // Directly invoke autocomplete callback (bypasses hit-test issues).
      final autocomplete = tester.widget<AutocompleteDropdown>(
        find.byType(AutocompleteDropdown),
      );
      autocomplete.onSelect(UserSuggestion(displayName: 'UserOne'));
      await tester.pump();

      // After autocomplete the text should be @UserOne followed by a space.
      final controller = tester.widget<TextField>(inputFinder).controller!;
      expect(controller.text, startsWith('@UserOne'));

      // Ensure the text ends with a trailing space.
      expect(controller.text, endsWith(' '));

      // Simulate backspace - remove trailing space.
      final textWithoutSpace = controller.text.trimRight();
      controller.value = TextEditingValue(
        text: textWithoutSpace,
        selection: TextSelection.collapsed(offset: textWithoutSpace.length),
      );
      await tester.pump();

      // Autocomplete should have reverted to the original text.
      expect(controller.text, '@Us');
    });

    testWidgets('dropdown hides when text fewer than 2 characters', (
      WidgetTester tester,
    ) async {
      SharedPreferences.setMockInitialValues({'access_token': 'test_token'});
      FlutterSecureStorage.setMockInitialValues({'access_token': 'test_token'});
      final eventSub = _FakeEventSubService();
      final irc = _FakeIrcService();
      final recent = _FakeRecentMessagesService();

      await tester.pumpWidget(
        TwitchChatApp(
          eventSubService: eventSub,
          ircService: irc,
          recentMessagesService: recent,
        ),
      );
      await tester.pump();

      await tester.tap(find.byIcon(Icons.add));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, 'xqc');
      await tester.tap(find.text('Join'));
      await tester.pump();

      irc.emitMessage(
        TwitchMessage(
          login: 'UserOne',
          text: 'hello chat',
          channel: 'xqc',
          messageId: 'm1',
        ),
      );
      await tester.pump();

      await tester.enterText(find.byKey(const Key('message_input')), 'U');
      await tester.pump();

      final dropdown = find.byKey(const Key('autocomplete_dropdown'));
      expect(dropdown, findsNothing);
    });
    testWidgets('typing slash shows all commands regardless of permission', (
      WidgetTester tester,
    ) async {
      SharedPreferences.setMockInitialValues({'access_token': 'test_token'});
      FlutterSecureStorage.setMockInitialValues({'access_token': 'test_token'});
      final eventSub = _FakeEventSubService();
      final irc = _FakeIrcService();
      final recent = _FakeRecentMessagesService();

      await tester.pumpWidget(
        TwitchChatApp(
          eventSubService: eventSub,
          ircService: irc,
          recentMessagesService: recent,
        ),
      );
      await tester.pump();

      await tester.tap(find.byIcon(Icons.add));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, 'xqc');
      await tester.tap(find.text('Join'));
      await tester.pump();

      irc.triggerConnect();
      await tester.pump();

      await tester.enterText(find.byKey(const Key('message_input')), '/');
      await tester.pump();

      final dropdown = find.byKey(const Key('autocomplete_dropdown'));
      expect(dropdown, findsOneWidget);
      expect(
        find.descendant(of: dropdown, matching: find.text('/me')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: dropdown, matching: find.text('/color')),
        findsOneWidget,
      );
      // Mod-only commands are suggested to everyone too; the API rejects
      // them with a clean error notice if the account cannot run them.
      expect(
        find.descendant(of: dropdown, matching: find.text('/ban')),
        findsOneWidget,
      );
    });

    testWidgets('selecting a command inserts it with a trailing space', (
      WidgetTester tester,
    ) async {
      SharedPreferences.setMockInitialValues({'access_token': 'test_token'});
      FlutterSecureStorage.setMockInitialValues({'access_token': 'test_token'});
      final eventSub = _FakeEventSubService();
      final irc = _FakeIrcService();
      final recent = _FakeRecentMessagesService();

      await tester.pumpWidget(
        TwitchChatApp(
          eventSubService: eventSub,
          ircService: irc,
          recentMessagesService: recent,
        ),
      );
      await tester.pump();

      await tester.tap(find.byIcon(Icons.add));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, 'xqc');
      await tester.tap(find.text('Join'));
      await tester.pump();

      final inputFinder = find.byKey(const Key('message_input'));
      await tester.enterText(inputFinder, '/');
      await tester.pump();

      // Directly invoke autocomplete callback (bypasses hit-test issues).
      final autocomplete = tester.widget<AutocompleteDropdown>(
        find.byType(AutocompleteDropdown),
      );
      autocomplete.onSelect(const CommandSuggestion(command: '/me'));
      await tester.pump();

      final controller = tester.widget<TextField>(inputFinder).controller!;
      expect(controller.text, '/me ');
    });
  });

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
  });

  Widget wrapAccountScreen(TwitchAuth auth) {
    return MaterialApp(home: AccountScreen(twitchAuth: auth));
  }

  TwitchAuth twoAccounts() {
    final auth = TwitchAuth();
    auth.setCredentials(accessToken: 'token_a');
    auth.setUser('alice', '111', profileImageUrl: 'https://example.com/a.png');
    auth.setCredentials(accessToken: 'token_b');
    auth.setUser('bob', '222');
    return auth;
  }

  testWidgets('lists saved accounts with the active one marked', (
    tester,
  ) async {
    final auth = twoAccounts();
    await tester.pumpWidget(wrapAccountScreen(auth));
    await tester.pump();

    expect(find.text('Accounts'), findsOneWidget);
    expect(find.text('alice'), findsOneWidget);
    expect(find.text('bob'), findsOneWidget);
    expect(find.text('Active'), findsOneWidget);
    expect(find.byIcon(Icons.check), findsOneWidget);
  });

  testWidgets('tapping an account switches the active account', (tester) async {
    final auth = twoAccounts();
    await tester.pumpWidget(wrapAccountScreen(auth));
    await tester.pump();
    expect(auth.login, 'bob');

    await tester.tap(find.text('alice'));
    await tester.pumpAndSettle();
    expect(auth.login, 'alice');
    expect(auth.accessToken, 'token_a');
  });

  testWidgets('avatar uses the saved profile image url', (tester) async {
    final auth = twoAccounts();
    await tester.pumpWidget(wrapAccountScreen(auth));
    await tester.pump();

    final avatars = tester.widgetList<CircleAvatar>(find.byType(CircleAvatar));
    final urls = avatars
        .map((a) => a.foregroundImage)
        .whereType<NetworkImage>()
        .map((n) => n.url)
        .toList();
    expect(urls, contains('https://example.com/a.png'));
  });

  testWidgets('long press asks for confirmation and removes the account', (
    tester,
  ) async {
    final auth = twoAccounts();
    await tester.pumpWidget(wrapAccountScreen(auth));
    await tester.pump();

    await tester.longPress(find.text('alice'));
    await tester.pumpAndSettle();
    expect(find.text('Remove account?'), findsOneWidget);
    expect(
      find.text('Are you sure you want to remove @alice?'),
      findsOneWidget,
    );

    await tester.tap(find.text('Remove'));
    await tester.pumpAndSettle();
    expect(auth.accounts.length, 1);
    expect(auth.accounts.single.login, 'bob');
    expect(find.text('alice'), findsNothing);
  });

  testWidgets('cancel keeps the account', (tester) async {
    final auth = twoAccounts();
    await tester.pumpWidget(wrapAccountScreen(auth));
    await tester.pump();

    await tester.longPress(find.text('alice'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(auth.accounts.length, 2);
    expect(find.text('alice'), findsOneWidget);
  });

  testWidgets('success state offers Add account and Disconnect', (
    tester,
  ) async {
    final auth = twoAccounts();
    await tester.pumpWidget(wrapAccountScreen(auth));
    await tester.pump();

    expect(find.text('Add account'), findsOneWidget);
    expect(find.text('Disconnect'), findsOneWidget);
  });

  testWidgets('removing the last account falls back to the login button', (
    tester,
  ) async {
    final auth = TwitchAuth();
    auth.setCredentials(accessToken: 'token_a');
    auth.setUser('alice', '111');
    await tester.pumpWidget(wrapAccountScreen(auth));
    await tester.pump();

    await tester.longPress(find.text('alice'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove'));
    await tester.pumpAndSettle();

    expect(auth.accounts, isEmpty);
    expect(find.text('Login'), findsOneWidget);
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  AnalyticsService seededService() {
    final service = AnalyticsService();
    service.recordMessage(
      'chan1',
      TwitchMessage(login: 'alice', text: 'hello world', channel: 'chan1'),
    );
    service.recordMessage(
      'chan1',
      TwitchMessage(login: 'bob', text: 'hello', channel: 'chan1'),
    );
    service.recordMessage(
      'chan2',
      TwitchMessage(login: 'carol', text: 'yo', channel: 'chan2'),
    );
    return service;
  }

  Widget wrapAnalytics(AnalyticsService service, List<String> channels) {
    return MaterialApp(
      home: AnalyticsScreen(analyticsService: service, channels: channels),
    );
  }

  testWidgets('shows empty state when no channels', (tester) async {
    await tester.pumpWidget(wrapAnalytics(AnalyticsService(), []));
    await tester.pump();
    expect(find.text('Join a channel to start tracking stats'), findsOneWidget);
  });

  testWidgets('renders summary and top lists for the first channel', (
    tester,
  ) async {
    await tester.pumpWidget(wrapAnalytics(seededService(), ['chan1', 'chan2']));
    await tester.pump();

    expect(find.text('Total messages'), findsOneWidget);
    expect(find.text('Unique chatters'), findsOneWidget);
    expect(find.text('Messages per minute'), findsOneWidget);
    expect(find.text('Tracking for'), findsOneWidget);
    expect(find.text('Top chatters'), findsOneWidget);
    expect(find.text('Top emotes'), findsOneWidget);
    expect(find.text('Top words'), findsOneWidget);
    expect(find.text('alice'), findsOneWidget);
    expect(find.text('bob'), findsOneWidget);
  });

  testWidgets('channel selector switches the displayed stats', (tester) async {
    await tester.pumpWidget(wrapAnalytics(seededService(), ['chan1', 'chan2']));
    await tester.pump();

    expect(find.text('carol'), findsNothing);

    await tester.tap(find.widgetWithText(Tab, 'chan2'));
    await tester.pumpAndSettle();

    expect(find.text('carol'), findsOneWidget);
    expect(find.text('alice'), findsNothing);
  });

  testWidgets('stopword toggle filters common words', (tester) async {
    final service = AnalyticsService();
    service.recordMessage(
      'chan',
      TwitchMessage(login: 'alice', text: 'the hello', channel: 'chan'),
    );
    await tester.pumpWidget(wrapAnalytics(service, ['chan']));
    await tester.pump();

    expect(find.text('the'), findsOneWidget);

    await tester.tap(find.text('Filter common words'));
    await tester.pump();

    expect(find.text('the'), findsNothing);
    expect(find.text('hello'), findsOneWidget);
  });

  testWidgets('reset this channel clears the stats', (tester) async {
    final service = seededService();
    await tester.pumpWidget(wrapAnalytics(service, ['chan1', 'chan2']));
    await tester.pump();

    await tester.tap(find.byIcon(Icons.refresh));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    await tester.tap(find.text('Reset this channel'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('No messages yet'), findsOneWidget);
    expect(find.text('alice'), findsNothing);
    expect(service.trackingStartedAt('chan1'), isNull);
  });

  testWidgets('shows moderation counts when bans occur', (tester) async {
    final service = AnalyticsService();
    service.recordModeration('chan', false);
    service.recordModeration('chan', true);
    await tester.pumpWidget(wrapAnalytics(service, ['chan']));
    await tester.pump();

    expect(find.text('Moderation'), findsOneWidget);
    expect(find.text('Bans'), findsOneWidget);
    expect(find.text('Timeouts'), findsOneWidget);
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });

  Future<void> joinChannel(WidgetTester tester, String name) async {
    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();
    final dialogField = find.descendant(
      of: find.byType(AlertDialog),
      matching: find.byType(TextField),
    );
    await tester.enterText(dialogField, name);
    await tester.tap(find.text('Join').last);
    await tester.pumpAndSettle();
    await tester.pump();
  }

  Future<void> tapChannel(WidgetTester tester, String channel) async {
    final barText = find.text(channel).first;
    await tester.ensureVisible(barText);
    await tester.pump();
    await tester.tap(barText);
    await tester.pumpAndSettle();
    await tester.pump();
  }

  group('Channel bar', () {
    testWidgets('is absent when no channels are joined', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(const TwitchChatApp());
      await tester.pump();

      expect(find.byType(TabBar), findsNothing);
      // Let the anonymous-mode socket attempts resolve so no timer pends.
      await tester.pumpAndSettle();
    });

    testWidgets('renders channel name after joining', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(const TwitchChatApp());
      await tester.pump();

      await joinChannel(tester, 'xqc');

      expect(find.text('xqc'), findsOneWidget);
    });

    testWidgets('channel bar disappears when last channel is removed', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(const TwitchChatApp());
      await tester.pump();

      await joinChannel(tester, 'xqc');

      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Settings'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Channels'));
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.remove_circle_outline));
      await tester.pump();
      await tester.pump();
      await tester.pump();

      await tester.tap(find.byIcon(Icons.arrow_back));
      await tester.pumpAndSettle();

      expect(find.text('xqc'), findsNothing);
      expect(find.byType(TabBar), findsNothing);
    });

    testWidgets('unselected channel has normal font weight', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(const TwitchChatApp());
      await tester.pump();

      await joinChannel(tester, 'a');
      await joinChannel(tester, 'b');

      expect(
        tester.widget<Text>(find.text('b')).style?.fontWeight,
        FontWeight.w600,
      );
      expect(
        tester.widget<Text>(find.text('a')).style?.fontWeight,
        FontWeight.normal,
      );
    });
  });

  group('Channel focus on swipe', () {
    testWidgets('swiping past halfway switches focus before settle', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(const TwitchChatApp());
      await tester.pump();
      await joinChannel(tester, 'a');
      await joinChannel(tester, 'b');
      await tapChannel(tester, 'a');

      final size = tester.getSize(find.byType(TabBarView));
      final center = tester.getCenter(find.byType(TabBarView));
      final gesture = await tester.startGesture(center);
      await gesture.moveBy(const Offset(-1, 0));
      await tester.pump();
      await gesture.moveBy(Offset(-size.width * 0.55, 0));
      await tester.pump();
      // Don't release - verify focus switched mid-drag
      expect(
        tester
            .widget<Text>(
              find.descendant(
                of: find.byType(TabBar),
                matching: find.text('b'),
              ),
            )
            .style
            ?.fontWeight,
        FontWeight.w600,
      );
      expect(
        tester
            .widget<Text>(
              find.descendant(
                of: find.byType(TabBar),
                matching: find.text('a'),
              ),
            )
            .style
            ?.fontWeight,
        FontWeight.normal,
      );

      await gesture.up();
      await tester.pumpAndSettle();
    });

    testWidgets('dragging under halfway keeps focus unchanged', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(const TwitchChatApp());
      await tester.pump();
      await joinChannel(tester, 'a');
      await joinChannel(tester, 'b');
      await tapChannel(tester, 'a');

      final size = tester.getSize(find.byType(TabBarView));
      final center = tester.getCenter(find.byType(TabBarView));
      final gesture = await tester.startGesture(center);
      await gesture.moveBy(const Offset(-1, 0));
      await tester.pump();
      await gesture.moveBy(Offset(-size.width * 0.45, 0)); // under 50%
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();

      expect(
        tester
            .widget<Text>(
              find.descendant(
                of: find.byType(TabBar),
                matching: find.text('a'),
              ),
            )
            .style
            ?.fontWeight,
        FontWeight.w600,
      );
      expect(
        tester
            .widget<Text>(
              find.descendant(
                of: find.byType(TabBar),
                matching: find.text('b'),
              ),
            )
            .style
            ?.fontWeight,
        FontWeight.normal,
      );
    });

    testWidgets('crossing then returning before release restores focus', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(const TwitchChatApp());
      await tester.pump();
      await joinChannel(tester, 'a');
      await joinChannel(tester, 'b');
      await tapChannel(tester, 'a');

      final size = tester.getSize(find.byType(TabBarView));
      final center = tester.getCenter(find.byType(TabBarView));
      final gesture = await tester.startGesture(center);
      await gesture.moveBy(const Offset(-1, 0));
      await tester.pump();
      // Cross 50%
      await gesture.moveBy(Offset(-size.width * 0.6, 0));
      await tester.pump();
      // Return below 50%
      await gesture.moveBy(Offset(size.width * 0.3, 0));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();

      expect(
        tester
            .widget<Text>(
              find.descendant(
                of: find.byType(TabBar),
                matching: find.text('a'),
              ),
            )
            .style
            ?.fontWeight,
        FontWeight.w600,
      );
    });
  });

  testWidgets('cutout swipes between pages and minimize fires callback', (
    tester,
  ) async {
    final controller = PageController();
    var minimized = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatWidgetCutout(
            pages: [
              PollCard(event: _poll()),
              HypeTrainCard(event: _hypeTrain()),
            ],
            controller: controller,
            onMinimize: () => minimized++,
          ),
        ),
      ),
    );

    expect(find.text('A or B?'), findsOneWidget);
    expect(find.byIcon(Icons.keyboard_arrow_down), findsOneWidget);

    await tester.drag(find.byType(PageView), const Offset(-500, 0));
    await tester.pumpAndSettle();
    expect(find.text('Hype Train'), findsOneWidget);
    expect(find.text('A or B?'), findsNothing);

    await tester.tap(find.byIcon(Icons.keyboard_arrow_down));
    expect(minimized, 1);

    controller.dispose();
  });

  TestWidgetsFlutterBinding.ensureInitialized();

  GenericEmote sevenTv(String id, String code) => GenericEmote(
    id: id,
    code: code,
    type: EmoteType.sevenTv,
    url: 'https://example.com/$id.png',
    scope: EmoteScope.channel,
  );

  Widget wrapEmoteMenu(EmoteManager manager) {
    return MaterialApp(
      home: Scaffold(
        body: EmoteMenuPanelWidget(
          isActive: true,
          selectedChannel: 'ch',
          onEmoteSelected: (_) {},
          onClose: () {},
          emoteManager: manager,
          scrollController: ScrollController(),
          sheetCtrl: DraggableScrollableController(),
          emoteMaxFraction: 0.8,
        ),
      ),
    );
  }

  testWidgets('a 7TV insert only builds cells at and below the change', (
    WidgetTester tester,
  ) async {
    final manager = EmoteManager(
      fetchStagger: Duration.zero,
      usageFlushDelay: Duration.zero,
      removeCachedFile: (url) async {},
    );
    manager.updateSevenTvEmotes(
      'ch',
      added: [
        sevenTv('a', 'Alpha'),
        sevenTv('c', 'Charlie'),
        sevenTv('d', 'Delta'),
      ],
    );

    await tester.pumpWidget(wrapEmoteMenu(manager));
    await tester.tap(find.text('Channel'));
    // The loading shimmer animates indefinitely, so pump fixed durations
    // instead of pumpAndSettle (which would never settle).
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    final alphaElement = tester.element(find.byKey(const ValueKey('a')));
    final deltaElement = tester.element(find.byKey(const ValueKey('d')));

    // Insert between Alpha and Charlie: Alpha stays in place (identical
    // element), Delta shifts down but keeps its element via keyed
    // reconciliation, and only the new cell is built.
    manager.updateSevenTvEmotes('ch', added: [sevenTv('b', 'Bravo')]);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(tester.element(find.byKey(const ValueKey('a'))), same(alphaElement));
    expect(tester.element(find.byKey(const ValueKey('d'))), same(deltaElement));
    expect(find.byKey(const ValueKey('b')), findsOneWidget);
  });

  testWidgets('a 7TV removal reuses the elements below the change', (
    WidgetTester tester,
  ) async {
    final manager = EmoteManager(
      fetchStagger: Duration.zero,
      usageFlushDelay: Duration.zero,
      removeCachedFile: (url) async {},
    );
    manager.updateSevenTvEmotes(
      'ch',
      added: [
        sevenTv('a', 'Alpha'),
        sevenTv('b', 'Bravo'),
        sevenTv('d', 'Delta'),
      ],
    );

    await tester.pumpWidget(wrapEmoteMenu(manager));
    await tester.tap(find.text('Channel'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    final alphaElement = tester.element(find.byKey(const ValueKey('a')));
    final deltaElement = tester.element(find.byKey(const ValueKey('d')));

    manager.updateSevenTvEmotes('ch', removedIds: ['b']);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(tester.element(find.byKey(const ValueKey('a'))), same(alphaElement));
    expect(tester.element(find.byKey(const ValueKey('d'))), same(deltaElement));
    expect(find.byKey(const ValueKey('b')), findsNothing);
  });

  testWidgets('the viewed channel sub group is pinned above the others', (
    WidgetTester tester,
  ) async {
    final manager = EmoteManager(
      fetchStagger: Duration.zero,
      usageFlushDelay: Duration.zero,
      removeCachedFile: (url) async {},
    );
    GenericEmote subOf(String id, String code, String owner) => GenericEmote(
      id: id,
      code: code,
      type: EmoteType.twitch,
      url: 'https://example.com/$id.png',
      scope: EmoteScope.channel,
      tier: '3',
      emoteType: 'subscriptions',
      ownerChannel: owner,
    );
    // Alphabetically 'alpha' would come first; 'ch' is the viewed channel.
    await manager.storeUserTwitchEmotes({
      'ch': [subOf('a1', 'AlphaEmote', 'alpha'), subOf('c1', 'ChEmote', 'ch')],
    });

    await tester.pumpWidget(wrapEmoteMenu(manager));
    await tester.tap(find.text('Subs'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(
      tester.getTopLeft(find.text('ch')).dy,
      lessThan(tester.getTopLeft(find.text('alpha')).dy),
    );
  });

  group('emote sheet geometry', () {
    double sheetFraction(WidgetTester t) => t
        .widget<FractionallySizedBox>(
          find
              .descendant(
                of: find.byType(DraggableScrollableSheet),
                matching: find.byType(FractionallySizedBox),
              )
              .first,
        )
        .heightFactor!;

    Future<void> tapEmoteToggle(WidgetTester t) async {
      await t.tap(find.byIcon(Icons.emoji_emotions_outlined));
      await t.pumpAndSettle();
    }

    testWidgets('sheet keeps its height across close and reopen', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({'access_token': 'test_token'});
      FlutterSecureStorage.setMockInitialValues({'access_token': 'test_token'});
      final irc = _FakeIrcService();
      await tester.pumpWidget(
        TwitchChatApp(
          eventSubService: _FakeEventSubService(),
          recentMessagesService: _ConfigurableRecentMessagesService(const []),
          ircService: irc,
        ),
      );
      await tester.pump();
      await tester.tap(find.byIcon(Icons.add));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, 'testchannel');
      await tester.tap(find.text('Join').last);
      await tester.pump();
      await tester.pump();
      irc.triggerConnect();
      await tester.pump();

      expect(sheetFraction(tester), moreOrLessEquals(0));
      await tapEmoteToggle(tester);
      final openFraction = sheetFraction(tester);
      expect(openFraction, greaterThan(0.5));

      await tapEmoteToggle(tester);
      expect(sheetFraction(tester), lessThan(0.001));

      await tapEmoteToggle(tester);
      expect(sheetFraction(tester), moreOrLessEquals(openFraction));
    });
  });

  group('emote sheet', () {
    late _FakeUrlLauncher emoteSheetLauncher;

    setUp(() {
      emoteSheetLauncher = _FakeUrlLauncher();
      UrlLauncherPlatform.instance = emoteSheetLauncher;
    });

    Widget wrapMany(List<GenericEmote> emotes) {
      return MaterialApp(
        home: Scaffold(
          body: EmoteSheet(
            emotes: emotes,
            messageController: TextEditingController(),
            focusNode: FocusNode(),
            onClose: () {},
          ),
        ),
      );
    }

    Widget wrapEmoteSheet(GenericEmote emote) => wrapMany([emote]);

    GenericEmote sevenTvEmote({String? baseName, bool zeroWidth = false}) {
      return GenericEmote(
        id: '7tv-1',
        code: 'Cope',
        type: EmoteType.sevenTv,
        url: 'https://cdn.7tv.app/emote/1/1x.webp',
        baseName: baseName,
        isZeroWidth: zeroWidth,
        ownerChannel: 'CopeQueen',
      );
    }

    testWidgets('shows name, type label and creator rows', (tester) async {
      await tester.pumpWidget(wrapEmoteSheet(sevenTvEmote()));
      await tester.pump();
      await tester.pump();

      expect(find.text('Cope'), findsOneWidget);
      expect(find.text('7TV Global Emote'), findsOneWidget);
      expect(find.text('Created by CopeQueen'), findsOneWidget);
      expect(find.textContaining('Alias of'), findsNothing);
    });

    testWidgets('shows "Alias of" row for 7TV alias emotes', (tester) async {
      await tester.pumpWidget(
        wrapEmoteSheet(sevenTvEmote(baseName: 'BaseEmote')),
      );
      await tester.pump();
      await tester.pump();

      expect(find.text('Alias of BaseEmote'), findsOneWidget);
    });

    testWidgets('type label appends Zero Width suffix', (tester) async {
      await tester.pumpWidget(wrapEmoteSheet(sevenTvEmote(zeroWidth: true)));
      await tester.pump();
      await tester.pump();

      expect(find.text('7TV Global Emote (Zero Width)'), findsOneWidget);
    });

    testWidgets('Open emote link opens the provider URL', (tester) async {
      await tester.pumpWidget(wrapEmoteSheet(sevenTvEmote()));
      await tester.pump();
      await tester.pump();

      await tester.tap(find.text('Open emote link'));
      await tester.pump();
      await tester.pump();

      expect(emoteSheetLauncher.lastUrl, 'https://7tv.app/emotes/7tv-1');
      expect(
        emoteSheetLauncher.lastMode,
        PreferredLaunchMode.externalApplication,
      );
    });

    testWidgets('Open emote link shows a snackbar when launch fails', (
      tester,
    ) async {
      emoteSheetLauncher.succeed = false;
      await tester.pumpWidget(wrapEmoteSheet(sevenTvEmote()));
      await tester.pump();
      await tester.pump();

      await tester.tap(find.text('Open emote link'));
      await tester.pump();
      await tester.pump();

      expect(find.textContaining('Could not open'), findsOneWidget);
    });

    testWidgets(
      'preview targets the 3x with the smaller scales as alternates',
      (tester) async {
        final emote = GenericEmote(
          id: 'scale-1',
          code: 'Scale',
          type: EmoteType.sevenTv,
          url: 'https://cdn.7tv.app/emote/scale/2x.webp',
          url1x: 'https://cdn.7tv.app/emote/scale/1x.webp',
          url3x: 'https://cdn.7tv.app/emote/scale/3x.webp',
        );

        await tester.pumpWidget(wrapEmoteSheet(emote));
        await tester.pump();

        final preview = tester.widget<EmoteImage>(find.byType(EmoteImage));
        expect(preview.url, 'https://cdn.7tv.app/emote/scale/3x.webp');
        expect(preview.alternateUrls, [
          'https://cdn.7tv.app/emote/scale/2x.webp',
          'https://cdn.7tv.app/emote/scale/1x.webp',
        ]);
      },
    );

    testWidgets('multi-emote sheet swipes sideways to the next emote', (
      tester,
    ) async {
      await tester.pumpWidget(
        wrapMany(
          List.generate(
            2,
            (i) => GenericEmote(
              id: 'e$i',
              code: 'Emote$i',
              type: EmoteType.sevenTv,
              url: 'https://cdn.7tv.app/emote/e$i/1x.webp',
              baseName: i == 1 ? 'BaseEmote' : null,
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(find.text('Emote0'), findsWidgets);
      expect(find.text('Alias of BaseEmote'), findsNothing);

      await tester.drag(find.byType(TabBarView), const Offset(-300, 0));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();

      expect(find.text('Alias of BaseEmote'), findsOneWidget);
    });
  });

  group('user profile sheet', () {
    late _FakeUrlLauncher profileLauncher;

    setUp(() {
      profileLauncher = _FakeUrlLauncher();
      UrlLauncherPlatform.instance = profileLauncher;
    });

    TwitchApi createApi() {
      return TwitchApi(
        client: MockClient(
          (_) async => http.Response(
            '{"data": [{"id": "123", "login": "testuser", "display_name": "TestUser", "created_at": "2020-01-01T00:00:00Z", "profile_image_url": "https://example.com/img.png"}]}',
            200,
          ),
        ),
      );
    }

    Widget wrapUserProfile(TwitchApi api) {
      return MaterialApp(
        home: Scaffold(
          body: UserProfileSheet(
            username: 'testuser',
            userId: '123',
            displayName: 'TestUser',
            twitchApi: api,
            twitchAuth: TwitchAuth()..accessToken = 'test-token',
            messageController: TextEditingController(),
            focusNode: FocusNode(),
            onClose: () {},
          ),
        ),
      );
    }

    testWidgets('Report button opens twitch.tv/<login>/report', (tester) async {
      await tester.pumpWidget(wrapUserProfile(createApi()));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Report'));
      await tester.pumpAndSettle();

      expect(profileLauncher.lastUrl, 'https://twitch.tv/testuser/report');
      expect(profileLauncher.lastMode, PreferredLaunchMode.externalApplication);
    });

    testWidgets('Report button shows snackbar when launch fails', (
      tester,
    ) async {
      profileLauncher.succeed = false;
      await tester.pumpWidget(wrapUserProfile(createApi()));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Report'));
      await tester.pumpAndSettle();

      expect(find.text('Could not open the report page'), findsOneWidget);
    });
  });
}
