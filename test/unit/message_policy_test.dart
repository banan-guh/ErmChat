import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ermchat/client/session.dart';
import 'package:ermchat/models/highlight_state.dart';
import 'package:ermchat/models/twitch_message.dart';
import 'package:ermchat/services/ignore_manager.dart';
import 'package:ermchat/services/message_policy.dart';
import 'package:ermchat/services/ping_manager.dart';
import 'package:ermchat/services/user_store.dart';

TwitchMessage msg(
  String text, {
  String login = 'otheruser',
  String? displayName,
  bool isSystem = false,
  String? msgId,
}) => TwitchMessage(
  login: login,
  displayName: displayName ?? login,
  text: text,
  isSystem: isSystem,
  msgId: msgId,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late IgnoreManager ignores;
  late PingManager pings;
  late UserStore users;
  late Session session;
  late ChatMessagePolicy policy;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    ignores = IgnoreManager();
    await ignores.load();
    pings = PingManager();
    await pings.load();
    users = UserStore();
    session = Session();
    policy = ChatMessagePolicy(
      ignoreManager: ignores,
      pingManager: pings,
      userStore: users,
      session: session,
    );
    addTearDown(() {
      ignores.dispose();
      pings.dispose();
      session.dispose();
    });
  });

  test('the hide rule covers blocks, ignores, phrases, shared hide, ready', () {
    ignores.upsertUser(const IgnoreEntry(id: 'u1', pattern: 'baduser'));
    ignores.upsertKeyword(
      const IgnoreEntry(id: 'k1', pattern: 'banme', block: true),
    );
    var ready = true;
    var mode = 'spotlight';
    final hides = ChatHideRule(
      isReady: () => ready,
      isBlocked: (login) => login == 'blockeduser',
      ignoreManager: ignores,
      sharedChatMode: () => mode,
    );
    final foreign = TwitchMessage(
      login: 'guest',
      text: 'hi',
      sourceBroadcasterId: '42',
    );
    expect(hides(msg('hi', login: 'BadUser')), isTrue, reason: 'ignored');
    expect(hides(msg('hi', login: 'blockeduser')), isTrue, reason: 'blocked');
    expect(hides(msg('please banme now')), isTrue, reason: 'block phrase');
    expect(hides(msg('nothing here')), isFalse);
    expect(hides(foreign), isFalse);
    mode = 'hide';
    expect(hides(foreign), isTrue, reason: 'foreign row in hide mode');
    foreign.highlight = const HighlightState(types: {HighlightType.username});
    expect(hides(foreign), isFalse, reason: 'pings survive hide mode');
    ready = false;
    expect(hides(msg('early')), isTrue, reason: 'live rows wait for ready');
    expect(
      hides(TwitchMessage(login: 'x', text: 'old', isHistory: true)),
      isFalse,
    );
  });

  group('keyword rewrite', () {
    test('replaces non-block keyword matches', () {
      ignores.upsertKeyword(
        const IgnoreEntry(id: 'k1', pattern: 'KEKW', replacement: '[lol]'),
      );
      final message = msg('that is KEKW');
      policy.rewriteKeywords(message);
      expect(message.text, 'that is [lol]');
    });
  });

  group('ping highlight', () {
    test('sets a highlight when a rule matches', () {
      pings.setAccount('forsen');
      final message = msg('hey forsen');
      policy.applyPingHighlight(message);
      expect(message.highlight?.hasMention, isTrue);
    });

    test('mention-only mode drops non-mentions and keeps existing', () {
      final plain = msg('reward', msgId: 'highlighted-message');
      policy.applyPingHighlight(plain, mentionOnly: true);
      expect(plain.highlight, isNull);

      pings.setAccount('forsen');
      const existing = HighlightState(types: {HighlightType.username});
      final message = msg('hey forsen')..highlight = existing;
      policy.applyPingHighlight(message, mentionOnly: true);
      expect(message.highlight, same(existing));
    });
  });

  group('user learning', () {
    test('stores the login or a case-only display name', () {
      policy.learnUser(
        'ch',
        msg('hi', login: 'loginname', displayName: 'DisplayName'),
      );
      policy.learnUser('ch', msg('hi', login: 'foobar', displayName: 'FooBar'));
      expect(users.usersForChannel('ch'), containsAll(['loginname', 'FooBar']));
    });
  });
}
