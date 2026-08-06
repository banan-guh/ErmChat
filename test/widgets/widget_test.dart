import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'package:ermchat/main.dart';
import 'package:ermchat/screens/settings/account_screen.dart';
import 'package:ermchat/screens/settings/channel_settings_screen.dart';
import 'package:ermchat/screens/settings/customization_screen.dart';
import 'package:ermchat/services/twitch_api.dart';
import 'package:ermchat/services/twitch_eventsub.dart';
import 'package:ermchat/services/base_irc_connection.dart';
import 'package:ermchat/services/twitch_irc.dart';
import 'package:ermchat/services/recent_messages.dart';
import 'package:ermchat/services/twitch_auth.dart';
import 'package:ermchat/models/twitch_message.dart';
import 'package:ermchat/services/suggestion.dart';
import 'package:ermchat/widgets/autocomplete_dropdown.dart';
import 'package:ermchat/widgets/chat_message_tile.dart';

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

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
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
      await tester.tap(find.byIcon(Icons.send));
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

    await tester.tap(find.byIcon(Icons.settings));
    await tester.pumpAndSettle();

    expect(find.text('Settings'), findsOneWidget);
    expect(find.text('Dark mode'), findsNothing);
    expect(find.text('Customization'), findsOneWidget);

    await tester.tap(find.text('Account'));
    await tester.pumpAndSettle();

    expect(find.text('Login'), findsOneWidget);
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

    await tester.tap(find.text('Channels'));
    await tester.pumpAndSettle();

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

    expect(find.text('Mentions'), findsNWidgets(2)); // title + tab
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
    'Switching to the channel with the ping clears the notification bell color',
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
    await tester.tap(find.byIcon(Icons.settings));
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
    FlutterSecureStorage.setMockInitialValues({'access_token': 'test_token'});
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
    expect(disconnectCount, 1);
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
        final irc = _FakeIrcService();

        SharedPreferences.setMockInitialValues({'access_token': 'test_token'});
        FlutterSecureStorage.setMockInitialValues({
          'access_token': 'test_token',
        });
        await joinChannel(
          tester,
          channelName: channel,
          history: [parent],
          irc: irc,
        );

        irc.emitMessage(
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
        final irc = _FakeIrcService();
        await joinChannel(
          tester,
          channelName: channel,
          history: [parent],
          irc: irc,
        );

        await tester.longPress(find.textContaining('alice: original msg'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Reply to message'));
        await tester.pumpAndSettle();

        // Send is disabled without credentials; emit a reply via EventSub.
        // Verify the history message is rendered first.
        expect(find.textContaining('alice: original msg'), findsOneWidget);

        irc.emitMessage(
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
      // (Chip also reads "Disconnected" while down, hence x2.)
      expect(find.textContaining('Connected'), findsOneWidget);
      expect(find.textContaining('Disconnected'), findsNWidgets(2));

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

    testWidgets(
      'reconnect storm: one Reconnected per reconnect, final Disconnected',
      (WidgetTester tester) async {
        final eventSub = _FakeEventSubService();
        final irc = _FakeIrcService();
        await setupChannel(tester, eventSub: eventSub, irc: irc);

        irc.triggerConnect();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 600));
        await tester.pump();

        for (var i = 0; i < 4; i++) {
          irc.triggerDisconnect();
          await tester.pump();
          irc.triggerConnect();
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 600));
          await tester.pump();
        }

        irc.triggerDisconnect();
        await tester.pump();

        // Chat shows: Connected, Reconnected x4, Disconnected. The input
        // chip also reads "Disconnected" while disconnected, hence x2.
        expect(find.textContaining('Disconnected'), findsNWidgets(2));
        expect(find.textContaining('Reconnected'), findsNWidgets(4));
        expect(find.textContaining('Connected'), findsOneWidget);
      },
    );

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

    testWidgets('disconnected appears only once', (WidgetTester tester) async {
      final eventSub = _FakeEventSubService();
      final irc = _FakeIrcService();
      await setupChannel(tester, eventSub: eventSub, irc: irc);

      irc.triggerConnect();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump();

      irc.triggerDisconnect();
      await tester.pump();

      expect(find.textContaining('Disconnected'), findsNWidgets(2));

      irc.triggerDisconnect();
      await tester.pump();

      expect(find.textContaining('Disconnected'), findsNWidgets(2));
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

    testWidgets('Channel settings empty when no channels joined', (
      WidgetTester tester,
    ) async {
      SharedPreferences.setMockInitialValues({});

      await tester.pumpWidget(
        MaterialApp(
          home: ChannelSettingsScreen(channelNotifier: ValueNotifier([])),
        ),
      );
      await tester.pump();

      expect(find.text('No channels joined'), findsOneWidget);
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

        // Thread is initially preserved — child is within the limit.
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

        // Thread should now be removed — pushed past maxMessages=10.
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

        // Scroll up — FAB appears (with reverse:true, drag DOWN = scroll UP)
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
      'last chat message stays flush with list bottom in any keyboard state',
      (WidgetTester tester) async {
        final now = DateTime.now();
        final messages = List.generate(
          3,
          (i) => TwitchMessage(
            login: 'user$i',
            text: 'message number $i',
            channel: 'testchannel',
            messageId: 'msg-$i',
            timestamp: now.subtract(Duration(minutes: 3 - i)),
          ),
        );
        final fakeEventSub = _FakeEventSubService();
        final fakeIrc = _FakeIrcService();
        final fakeRecent = _ConfigurableRecentMessagesService(messages);

        // Keyboard down: nav bar visible, no keyboard inset.
        tester.view.padding = const FakeViewPadding(bottom: 48);
        addTearDown(tester.view.reset);

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

        final listBottom = tester
            .getBottomRight(find.byType(ListView).first)
            .dy;
        final lastTileBottom = tester
            .getBottomRight(find.byType(ChatMessageTile).first)
            .dy;

        // The newest message (index 0 in a reverse list) hugs the viewport
        // bottom instead of the implicit nav-bar safe-area padding creating
        // a blank strip below it.
        expect(lastTileBottom, closeTo(listBottom, 1.0));

        // Keyboard up: nav bar covered by the keyboard, inset reported.
      tester.view.padding = FakeViewPadding.zero;
      tester.view.viewInsets = const FakeViewPadding(bottom: 400);
        await tester.pump();

        final listBottomUp = tester
            .getBottomRight(find.byType(ListView).first)
            .dy;
        final lastTileBottomUp = tester
            .getBottomRight(find.byType(ChatMessageTile).first)
            .dy;

        // Still flush — no padding gap in either keyboard state.
        expect(lastTileBottomUp, closeTo(listBottomUp, 1.0));
        // The list did move up with the keyboard (viewport bottom rose).
        expect(listBottomUp, lessThan(listBottom));
      },
    );

    testWidgets('system message while paused does not appear until unpause', (
      WidgetTester tester,
    ) async {
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
      fakeIrc.emitMessage(systemMsg);
      await tester.pump();

      // System message should NOT appear in frozen view
      expect(find.textContaining('System notice while paused'), findsNothing);

      // Tap FAB to resume
      await tester.tap(find.byIcon(Icons.keyboard_arrow_down));
      await tester.pump();
      await tester.pump();

      // System message IS now visible
      expect(find.textContaining('System notice while paused'), findsOneWidget);
    });

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

  group('Emote panel drag clamp', () {
    testWidgets('jumpTo with unclamped pixelsToSize throws assertion error', (
      WidgetTester tester,
    ) async {
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

      // Simulate backspace — remove trailing space.
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
}
