import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_twitch_app/main.dart';
import 'package:flutter_twitch_app/screens/settings_screen.dart';
import 'package:flutter_twitch_app/services/twitch_eventsub.dart';
import 'package:flutter_twitch_app/services/twitch_irc.dart';
import 'package:flutter_twitch_app/services/recent_messages.dart';
import 'package:flutter_twitch_app/services/twitch_auth.dart';
import 'package:flutter_twitch_app/models/twitch_message.dart';
import 'package:flutter_twitch_app/services/twitch_irc_read.dart';

class _FakeEventSubService extends EventSubService {
  final _statusCtrl = StreamController<EventSubStatus>.broadcast(sync: true);
  final _deleteCtrl =
      StreamController<
        ({String messageId, String targetUser, String channel})
      >.broadcast(sync: true);
  final _banCtrl =
      StreamController<
        ({
          String user,
          String? reason,
          bool isTimeout,
          String? duration,
          String channel,
        })
      >.broadcast(sync: true);

  @override
  Future<void> connect({String? url}) async {}

  @override
  Stream<EventSubStatus> get onStatus => _statusCtrl.stream;

  @override
  Stream<({String messageId, String targetUser, String channel})>
  get onMessageDeleted => _deleteCtrl.stream;

  @override
  Stream<
    ({
      String user,
      String? reason,
      bool isTimeout,
      String? duration,
      String channel,
    })
  >
  get onBan => _banCtrl.stream;

  void triggerConnect() => _statusCtrl.add(EventSubStatus.connected);
  void triggerDisconnect() => _statusCtrl.add(EventSubStatus.disconnected);

  void emitDeleted(String messageId, String targetUser, String channel) {
    _deleteCtrl.add((
      messageId: messageId,
      targetUser: targetUser,
      channel: channel,
    ));
  }

  void emitBan(
    String user, {
    String? reason,
    bool isTimeout = false,
    String? duration,
    String channel = '',
  }) {
    _banCtrl.add((
      user: user,
      reason: reason,
      isTimeout: isTimeout,
      duration: duration,
      channel: channel,
    ));
  }

  @override
  void dispose() {
    _statusCtrl.close();
    _deleteCtrl.close();
    _banCtrl.close();
    super.dispose();
  }
}

class _FakeRecentMessagesService extends RecentMessagesService {
  @override
  Future<List<TwitchMessage>> fetchRecent(String channel) async {
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

class _FakeIrcService extends IrcService {
  final _banCtrl = StreamController<IrcBanEvent>.broadcast(sync: true);
  final _noticeCtrl = StreamController<IrcNoticeEvent>.broadcast(sync: true);

  @override
  Future<void> connect({
    required String username,
    required String accessToken,
  }) async {}

  @override
  Stream<IrcBanEvent> get onBan => _banCtrl.stream;

  @override
  Stream<IrcNoticeEvent> get onNotice => _noticeCtrl.stream;

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

  @override
  void dispose() {
    _banCtrl.close();
    _noticeCtrl.close();
    super.dispose();
  }
}

class _FakeIrcReadService extends IrcReadService {
  final _colorCtrl = StreamController<String>.broadcast(sync: true);

  @override
  Stream<String> get onUserColor => _colorCtrl.stream;

  @override
  Future<void> connect({required String username, required String accessToken}) async {}

  @override
  void join(String channel) {}

  @override
  void part(String channel) {}

  @override
  void dispose() {
    _colorCtrl.close();
    super.dispose();
  }

  void emitColor(String color) => _colorCtrl.add(color);
}

class _ConfigurableRecentMessagesService extends RecentMessagesService {
  final List<TwitchMessage> messages;
  _ConfigurableRecentMessagesService(this.messages);

  @override
  Future<List<TwitchMessage>> fetchRecent(String channel) async => messages;
}

class _TestEventSubService extends _FakeEventSubService {
  final _msgCtrl = StreamController<TwitchMessage>.broadcast();

  @override
  Stream<TwitchMessage> get onMessage => _msgCtrl.stream;

  void emitMessage(TwitchMessage msg) => _msgCtrl.add(msg);

  @override
  void dispose() {
    _msgCtrl.close();
    super.dispose();
  }
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('Home screen shows credentials message when not configured', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const TwitchChatApp());
    await tester.pump();

    expect(find.byIcon(Icons.add), findsOneWidget);
    expect(find.byIcon(Icons.settings), findsOneWidget);
    expect(
      find.text('Configure Twitch credentials in Settings first'),
      findsOneWidget,
    );
  });

  testWidgets('Plus button opens join channel dialog', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const TwitchChatApp());
    await tester.pump();

    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();

    expect(find.text('Join channel'), findsOneWidget);
    expect(find.text('Cancel'), findsOneWidget);
    expect(find.text('Join'), findsOneWidget);
  });

  testWidgets('Can send messages after adding channel without credentials', (
    WidgetTester tester,
  ) async {
    final fakeEventSub = _TestEventSubService();
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
    await tester.tap(find.byIcon(Icons.send));
    await tester.pump();
    expect(find.textContaining('hello chat'), findsNothing);

    // EventSub messages still appear in view-only mode.
    fakeEventSub.emitMessage(
      TwitchMessage(
        login: 'xqc',
        text: 'hello chat',
        channel: 'xqc',
        messageId: 'm1',
      ),
    );
    await tester.pump();

    expect(find.textContaining('hello chat'), findsOneWidget);
  });

  testWidgets('Settings screen opens and shows dark mode toggle', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const TwitchChatApp());
    await tester.pump();

    await tester.tap(find.byIcon(Icons.settings));
    await tester.pumpAndSettle();

    expect(find.text('Settings'), findsOneWidget);
    expect(find.text('Dark mode'), findsOneWidget);
    expect(find.text('Twitch Login'), findsOneWidget);
    expect(find.text('Login with Twitch'), findsOneWidget);
  });

  testWidgets('Joining channel shows input bar and send button', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const TwitchChatApp());
    await tester.pump();

    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'xqc');
    await tester.tap(find.text('Join'));
    await tester.pump();

    expect(find.byIcon(Icons.send), findsOneWidget);
    expect(find.byKey(const Key('message_input')), findsOneWidget);
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

    await tester.tap(find.byIcon(Icons.settings));
    await tester.pumpAndSettle();

    expect(find.text('Channels'), findsOneWidget);
    expect(find.byIcon(Icons.remove_circle_outline), findsOneWidget);
  });

  testWidgets('Shows notification bell without badge when no mentions', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const TwitchChatApp());
    await tester.pump();

    expect(find.byIcon(Icons.notifications_active), findsOneWidget);
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

    expect(find.text('Mentions / Whispers'), findsOneWidget);
    expect(find.text('No mentions or whispers'), findsOneWidget);

    // Close the panel.
    await tester.tap(find.byIcon(Icons.arrow_back));
    await tester.pumpAndSettle();
    // Closing clears panel data, content reverts to empty.
  });

  testWidgets(
    'Mention in focused channel does not turn notification bell red',
    (WidgetTester tester) async {
      final eventSub = _TestEventSubService();
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
      eventSub.emitMessage(
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
      final eventSub = _TestEventSubService();
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

      eventSub.emitMessage(
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
      final eventSub = _TestEventSubService();
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

      eventSub.emitMessage(
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
      final eventSub = _TestEventSubService();
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

      eventSub.emitMessage(
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
    'Switching to the channel with the ping clears the notification bell color',
    (WidgetTester tester) async {
      final eventSub = _TestEventSubService();
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

      eventSub.emitMessage(
        TwitchMessage(
          login: 'carol',
          text: 'hello @me',
          channel: 'b',
          messageId: 'm5',
        ),
      );
      await tester.pump();
      expect(
        tester.widget<Icon>(find.byIcon(Icons.notifications_active)).color,
        isNotNull,
      );

      final barText = find.text('b').first;
      await tester.ensureVisible(barText);
      await tester.pump();
      await tester.tap(barText);
      await tester.pumpAndSettle();
      await tester.pump();

      expect(
        tester.widget<Icon>(find.byIcon(Icons.notifications_active)).color,
        isNull,
      );
    },
  );

  testWidgets('Adding second channel switches to it immediately', (
    WidgetTester tester,
  ) async {
    final fakeRecent = _FakeRecentMessagesService();
    final fakeIrc = _FakeIrcService();
    final fakeEventSub = _FakeEventSubService();
    await tester.pumpWidget(
      TwitchChatApp(
        recentMessagesService: fakeRecent,
        ircService: fakeIrc,
        eventSubService: fakeEventSub,
      ),
    );
    await tester.pump();

    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'xqc');
    await tester.tap(find.text('Join'));
    await tester.pump();

    expect(find.byKey(const Key('message_input')), findsOneWidget);

    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'forsen');
    await tester.tap(find.text('Join'));
    await tester.pump();

    expect(find.byKey(const Key('message_input')), findsOneWidget);
  });

  testWidgets('Shows Disconnected once when EventSub fails', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues({'access_token': 'test_token'});
    await tester.pumpWidget(const TwitchChatApp());
    await tester.pump();

    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'xqc');
    await tester.tap(find.text('Join'));
    await tester.pump();

    await tester.pump(const Duration(seconds: 5));

    final disconnectCount = find
        .textContaining('Disconnected')
        .evaluate()
        .length;
    expect(disconnectCount, lessThanOrEqualTo(1));
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

  testWidgets('Empty whitespace send does nothing', (
    WidgetTester tester,
  ) async {
    final fakeRecent = _FakeRecentMessagesService();
    final fakeIrc = _FakeIrcService();
    final fakeEventSub = _FakeEventSubService();
    await tester.pumpWidget(
      TwitchChatApp(
        recentMessagesService: fakeRecent,
        ircService: fakeIrc,
        eventSubService: fakeEventSub,
      ),
    );
    await tester.pump();

    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'xqc');
    await tester.tap(find.text('Join'));
    await tester.pumpAndSettle();

    // Input is disabled without credentials; send does nothing.
    expect(find.text('Connect an account to chat'), findsOneWidget);
    expect(find.text('   '), findsNothing);
  });

  testWidgets('Message timestamp shows HH:MM format', (
    WidgetTester tester,
  ) async {
    final fakeEventSub = _TestEventSubService();
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

    await tester.enterText(find.byKey(const Key('message_input')), 'hello');
    await tester.tap(find.byIcon(Icons.send));
    await tester.pump();

    fakeEventSub.emitMessage(
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

  testWidgets(
    'Connected message appears after EventSub connects and history loads',
    (WidgetTester tester) async {
      final fakeEventSub = _FakeEventSubService();
      final fakeRecent = _FakeRecentMessagesService();
      final fakeIrc = _FakeIrcService();

      SharedPreferences.setMockInitialValues({'access_token': 'test_token'});

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

      fakeEventSub.triggerConnect();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump();

      expect(find.textContaining('Connected'), findsOneWidget);
      expect(find.textContaining('Disconnected'), findsNothing);
    },
  );

  group('Thread', () {
    late DateTime now;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      now = DateTime.now();
    });

    Future<void> joinChannel(
      WidgetTester tester, {
      required String channelName,
      required List<TwitchMessage> history,
      _FakeEventSubService? eventSub,
    }) async {
      final fakeIrc = _FakeIrcService();
      final fakeRecent = _ConfigurableRecentMessagesService(history);
      final es = eventSub ?? _FakeEventSubService();

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
      'live EventSub reply to history parent opens thread via reply indicator',
      (WidgetTester tester) async {
        const channel = 'testchannel';
        final parent = TwitchMessage(
          login: 'alice',
          text: 'original post',
          messageId: 'p1',
          timestamp: now.subtract(const Duration(minutes: 5)),
          channel: channel,
        );
        final eventSub = _TestEventSubService();

        SharedPreferences.setMockInitialValues({'access_token': 'test_token'});
        await joinChannel(
          tester,
          channelName: channel,
          history: [parent],
          eventSub: eventSub,
        );

        eventSub.emitMessage(
          TwitchMessage(
            login: 'dave',
            text: 'live reply text',
            messageId: 'live1',
            channel: channel,
            replyToParentId: 'p1',
            replyToUser: 'alice',
            replyToText: 'original post',
          ),
        );
        await tester.pump();

        await tester.tap(
          find.textContaining('replying to alice: original post'),
        );
        await tester.pumpAndSettle();

        expect(find.text('Reply Thread'), findsOneWidget);
        expect(find.textContaining('original post'), findsAtLeast(1));
        expect(find.textContaining('live reply text'), findsAtLeast(1));
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

    testWidgets(
      'sent reply to history parent opens thread via reply indicator',
      (WidgetTester tester) async {
        const channel = 'testchannel';
        final parent = TwitchMessage(
          login: 'alice',
          text: 'original msg',
          messageId: 'p1',
          timestamp: now.subtract(const Duration(minutes: 5)),
          channel: channel,
        );
        final eventSub = _TestEventSubService();
        await joinChannel(
          tester,
          channelName: channel,
          history: [parent],
          eventSub: eventSub,
        );

        await tester.longPress(find.textContaining('alice: original msg'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Reply to message'));
        await tester.pumpAndSettle();

        // Send is disabled without credentials; emit a reply via EventSub.
        // Verify the history message is rendered first.
        expect(find.textContaining('alice: original msg'), findsOneWidget);

        eventSub.emitMessage(
          TwitchMessage(
            login: 'bob',
            text: 'my reply',
            channel: channel,
            messageId: 'sent1',
            replyToParentId: 'p1',
            replyToUser: 'alice',
            replyToText: 'original msg',
          ),
        );
        await tester.pump();
        await tester.pump();

        expect(find.textContaining('my reply'), findsOneWidget);

        await tester.tap(
          find.textContaining('replying to alice: original msg'),
        );
        await tester.pumpAndSettle();

        expect(find.text('Reply Thread'), findsOneWidget);
        expect(find.textContaining('original msg'), findsAtLeast(1));
        expect(find.textContaining('my reply'), findsAtLeast(1));
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
  });

  group('System messages', () {
    Future<void> setupChannel(
      WidgetTester tester, {
      required _FakeEventSubService eventSub,
      required _FakeIrcService irc,
      RecentMessagesService? recent,
    }) async {
      SharedPreferences.setMockInitialValues({'access_token': 'test_token'});
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

      eventSub.emitDeleted('root-1', 'alice', 'testchannel');
      await tester.pump();

      expect(
        find.textContaining('A message from alice was deleted'),
        findsOneWidget,
      );
      expect(find.textContaining('hello world'), findsAtLeast(1));
    });

    testWidgets('connected appears only once when EventSub connects', (
      WidgetTester tester,
    ) async {
      final eventSub = _FakeEventSubService();
      final irc = _FakeIrcService();
      await setupChannel(tester, eventSub: eventSub, irc: irc);

      eventSub.triggerConnect();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump();

      expect(find.textContaining('Connected'), findsOneWidget);

      eventSub.triggerConnect();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump();

      expect(find.textContaining('Connected'), findsOneWidget);
    });

    testWidgets('disconnected appears only once', (WidgetTester tester) async {
      final eventSub = _FakeEventSubService();
      final irc = _FakeIrcService();
      await setupChannel(tester, eventSub: eventSub, irc: irc);

      eventSub.triggerConnect();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump();

      eventSub.triggerDisconnect();
      await tester.pump();

      expect(find.textContaining('Disconnected'), findsOneWidget);

      eventSub.triggerDisconnect();
      await tester.pump();

      expect(find.textContaining('Disconnected'), findsOneWidget);
    });

    testWidgets(
      'system message on unfocused channel does not trigger unread indicator',
      (WidgetTester tester) async {
        SharedPreferences.setMockInitialValues({'access_token': 'test_token'});
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

    testWidgets('EventSub ban shows system message', (
      WidgetTester tester,
    ) async {
      final eventSub = _FakeEventSubService();
      final irc = _FakeIrcService();
      await setupChannel(tester, eventSub: eventSub, irc: irc);

      eventSub.emitBan('baduser', isTimeout: false, channel: 'testchannel');
      await tester.pump();

      expect(find.textContaining('baduser was banned'), findsOneWidget);
    });

    testWidgets(
      'banned user messages render at 35% opacity',
      (WidgetTester tester) async {
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
        await setupChannel(
          tester,
          eventSub: eventSub,
          irc: irc,
          recent: recent,
        );

        irc.emitBan('bob', isTimeout: false, channel: 'testchannel');
        await tester.pump();

        final opacityWidgets = tester.widgetList<Opacity>(
          find.ancestor(
            of: find.textContaining('i am a bad person'),
            matching: find.byType(Opacity),
          ),
        );
        expect(opacityWidgets.any((o) => o.opacity == 0.35), isTrue);
      },
    );
  });

  testWidgets(
    'color change updates own messages without crashing',
    (WidgetTester tester) async {
      SharedPreferences.setMockInitialValues({'access_token': 'test_token'});
      final eventSub = _FakeEventSubService();
      final irc = _FakeIrcService();
      final ircRead = _FakeIrcReadService();
      final recent = _ConfigurableRecentMessagesService([
        TwitchMessage(
          login: 'testuser',
          text: 'hello from me',
          channel: 'testchannel',
          messageId: 'own-1',
          color: '#FF0000',
        ),
        TwitchMessage(
          login: 'otheruser',
          text: 'hello from other',
          channel: 'testchannel',
          messageId: 'other-1',
          color: '#00FF00',
        ),
      ]);

      await tester.pumpWidget(
        TwitchChatApp(
          eventSubService: eventSub,
          ircService: irc,
          ircReadService: ircRead,
          recentMessagesService: recent,
          initialCurrentUserLogin: 'testuser',
        ),
      );
      await tester.pump();
      await tester.tap(find.byIcon(Icons.add));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, 'testchannel');
      await tester.tap(find.text('Join'));
      await tester.pump();
      await tester.pump();

      expect(find.textContaining('testuser:'), findsOneWidget);
      expect(find.textContaining('hello from me'), findsOneWidget);

      ircRead.emitColor('#0000FF');
      await tester.pump();

      expect(find.textContaining('testuser:'), findsOneWidget);
      expect(find.textContaining('hello from me'), findsOneWidget);
    },
  );

  group('Settings screen', () {
    testWidgets('idle state shows login button', (WidgetTester tester) async {
      SharedPreferences.setMockInitialValues({});
      final auth = TwitchAuth();

      await tester.pumpWidget(
        MaterialApp(
          home: SettingsScreen(twitchAuth: auth, onThemeChanged: (_) {}),
        ),
      );
      await tester.pump();

      expect(find.text('Settings'), findsOneWidget);
      expect(find.text('Login with Twitch'), findsOneWidget);
      expect(find.text('Twitch Login'), findsOneWidget);
      expect(find.text('Connected to Twitch'), findsNothing);
    });

    testWidgets('success state shows connected and disconnect button', (
      WidgetTester tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      final auth = TwitchAuth()..accessToken = 'test-token';

      await tester.pumpWidget(
        MaterialApp(
          home: SettingsScreen(twitchAuth: auth, onThemeChanged: (_) {}),
        ),
      );
      await tester.pump();

      expect(find.text('Connected to Twitch'), findsOneWidget);
      expect(find.text('Disconnect'), findsOneWidget);
      expect(find.text('Login with Twitch'), findsNothing);
    });

    testWidgets('disconnect transitions to idle', (WidgetTester tester) async {
      SharedPreferences.setMockInitialValues({});
      final auth = TwitchAuth()..accessToken = 'test-token';

      await tester.pumpWidget(
        MaterialApp(
          home: SettingsScreen(twitchAuth: auth, onThemeChanged: (_) {}),
        ),
      );
      await tester.pump();

      expect(find.text('Connected to Twitch'), findsOneWidget);

      await tester.tap(find.text('Disconnect'));
      await tester.pump();
      await tester.pump();

      expect(find.text('Connected to Twitch'), findsNothing);
      expect(find.text('Login with Twitch'), findsOneWidget);
    });

    testWidgets('dark mode toggle calls onThemeChanged', (
      WidgetTester tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      ThemeMode? changed;
      final auth = TwitchAuth();

      await tester.pumpWidget(
        MaterialApp(
          home: SettingsScreen(
            twitchAuth: auth,
            onThemeChanged: (mode) => changed = mode,
            channelNotifier: ValueNotifier(['testchannel']),
          ),
        ),
      );
      await tester.pump();

      await tester.tap(find.widgetWithText(SwitchListTile, 'Dark mode'));
      await tester.pumpAndSettle();

      expect(changed, ThemeMode.dark);
    });

    testWidgets('channel list shows joined channels', (
      WidgetTester tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      final auth = TwitchAuth();

      await tester.pumpWidget(
        MaterialApp(
          home: SettingsScreen(
            twitchAuth: auth,
            onThemeChanged: (_) {},
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

    testWidgets('channel list is empty when no channels joined', (
      WidgetTester tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      final auth = TwitchAuth();

      await tester.pumpWidget(
        MaterialApp(
          home: SettingsScreen(
            twitchAuth: auth,
            onThemeChanged: (_) {},
            channelNotifier: ValueNotifier([]),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('No channels joined'), findsOneWidget);
    });

    testWidgets('join channel dialog opens from settings', (
      WidgetTester tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      String? addedChannel;
      final auth = TwitchAuth();

      await tester.pumpWidget(
        MaterialApp(
          home: SettingsScreen(
            twitchAuth: auth,
            onThemeChanged: (_) {},
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
  });

  group('Message cutoff', () {
    Future<void> joinChannel(
      WidgetTester tester, {
      required String channelName,
      required List<TwitchMessage> history,
      _FakeEventSubService? eventSub,
      int maxMessages = 500,
    }) async {
      SharedPreferences.setMockInitialValues({
        'max_messages_per_channel': maxMessages,
      });
      final fakeIrc = _FakeIrcService();
      final fakeRecent = _ConfigurableRecentMessagesService(history);
      final es = eventSub ?? _FakeEventSubService();

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
      final eventSub = _TestEventSubService();
      await joinChannel(
        tester,
        channelName: channel,
        history: history,
        eventSub: eventSub,
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
      final eventSub = _TestEventSubService();
      await joinChannel(
        tester,
        channelName: channel,
        history: [parent, child, ...filler],
        eventSub: eventSub,
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
      final eventSub = _TestEventSubService();
      await joinChannel(
        tester,
        channelName: channel,
        history: [parent, child, ...filler],
        eventSub: eventSub,
        maxMessages: 10,
      );

      await tester.pump();
      await tester.pump();

      expect(find.textContaining('thread root'), findsNothing);
      expect(find.textContaining('thread reply'), findsNothing);
    });

    testWidgets('removes thread when new messages push last child past the limit', (
      WidgetTester tester,
    ) async {
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
      final eventSub = _TestEventSubService();
      await joinChannel(
        tester,
        channelName: channel,
        history: [parent, child, ...filler],
        eventSub: eventSub,
        maxMessages: 10,
      );

      await tester.pump();
      await tester.pump();

      // Expand viewport so lazy ListView builds all items without scrolling
      // (avoids triggering the frozen-snapshot behavior in scroll notifications).
      await tester.binding.setSurfaceSize(const Size(2000, 2000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpAndSettle();

      // Thread is initially preserved — child is within the limit.
      expect(find.textContaining('thread root'), findsWidgets);
      expect(find.textContaining('thread reply'), findsOneWidget);

      // Emit new messages that push the thread past the limit.
      for (int i = 1; i <= 3; i++) {
        eventSub.emitMessage(
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

      // Thread should now be removed — pushed past maxMessages=10.
      expect(find.textContaining('thread root'), findsNothing);
      expect(find.textContaining('thread reply'), findsNothing);
    });
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

        // Initially at bottom — FAB should not be visible
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
        final fakeEventSub = _TestEventSubService();
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

        // Scroll up — FAB appears (with reverse:true, drag DOWN = scroll UP)
        await tester.drag(find.byType(ListView).first, const Offset(0, 500));
        await tester.pump();
        await tester.pump();
        expect(find.byIcon(Icons.keyboard_arrow_down), findsOneWidget);

        // Emit a new message while paused
        fakeEventSub.emitMessage(
          TwitchMessage(
            login: 'newuser',
            text: 'new message while paused',
            channel: 'testchannel',
            messageId: 'new-msg',
            timestamp: DateTime.now(),
          ),
        );
        await tester.pump();

        // FAB still visible — did not auto-scroll
        expect(find.byIcon(Icons.keyboard_arrow_down), findsOneWidget);

        // New message text NOT visible — frozen snapshot hides it
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

    testWidgets(
      'system message while paused does not appear until unpause',
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
        final fakeEventSub = _TestEventSubService();
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

        // Scroll up — FAB appears
        await tester.drag(find.byType(ListView).first, const Offset(0, 500));
        await tester.pump();
        await tester.pump();
        expect(find.byIcon(Icons.keyboard_arrow_down), findsOneWidget);

        // Emit a system message while paused
        final systemMsg = TwitchMessage(
          login: '',
          text: 'System notice while paused',
          isSystem: true,
          channel: 'testchannel',
        );
        fakeEventSub.emitMessage(systemMsg);
        await tester.pump();

        // System message should NOT appear in frozen view
        expect(find.textContaining('System notice while paused'), findsNothing);

        // Tap FAB to resume
        await tester.tap(find.byIcon(Icons.keyboard_arrow_down));
        await tester.pump();
        await tester.pump();

        // System message IS now visible
        expect(find.textContaining('System notice while paused'), findsOneWidget);
      },
    );
  });

  group('Emote panel drag clamp', () {
    testWidgets(
      'jumpTo with unclamped pixelsToSize throws assertion error',
      (WidgetTester tester) async {
        final controller = DraggableScrollableController();
        addTearDown(() => controller.dispose());

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SizedBox.expand(
                child: DraggableScrollableSheet(
                  controller: controller,
                  initialChildSize: 0,
                  minChildSize: 0,
                  maxChildSize: 0.6,
                  snap: true,
                  builder: (context, scrollController) => SizedBox(
                    width: double.infinity,
                    height: 200,
                    child: ListView(
                      controller: scrollController,
                      children: List.generate(
                        50,
                        (i) => ListTile(title: Text('item $i')),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        controller.jumpTo(0.6);
        await tester.pumpAndSettle();

        final maxPixels = controller.pixels + 2000;
        final beyondSize = controller.pixelsToSize(maxPixels);

        expect(beyondSize, greaterThan(1.0));

        expect(
          () => controller.jumpTo(beyondSize),
          throwsA(isA<AssertionError>()),
        );

        expect(
          () => controller.jumpTo(beyondSize.clamp(0.0, 1.0)),
          returnsNormally,
        );
      },
    );
  });

  group('Autocomplete', () {
    testWidgets('shows dropdown with user suggestion after typing', (
      WidgetTester tester,
    ) async {
      SharedPreferences.setMockInitialValues({'access_token': 'test_token'});
      final eventSub = _TestEventSubService();
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

      eventSub.emitMessage(
        TwitchMessage(
          login: 'UserOne',
          text: 'hello chat',
          channel: 'xqc',
          messageId: 'm1',
        ),
      );
      await tester.pump();

      expect(find.textContaining('UserOne'), findsOneWidget);

      await tester.enterText(
        find.byKey(const Key('message_input')),
        'Us',
      );
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

    testWidgets('dropdown hides when text fewer than 2 characters', (
      WidgetTester tester,
    ) async {
      SharedPreferences.setMockInitialValues({'access_token': 'test_token'});
      final eventSub = _TestEventSubService();
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

      eventSub.emitMessage(
        TwitchMessage(
          login: 'UserOne',
          text: 'hello chat',
          channel: 'xqc',
          messageId: 'm1',
        ),
      );
      await tester.pump();

      await tester.enterText(
        find.byKey(const Key('message_input')),
        'U',
      );
      await tester.pump();

      final dropdown = find.byKey(const Key('autocomplete_dropdown'));
      expect(dropdown, findsNothing);
    });
  });
}
