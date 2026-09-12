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

  group('ignore filtering', () {
    test('drops ignored senders but not system messages', () {
      ignores.upsertUser(const IgnoreEntry(id: 'u1', pattern: 'baduser'));
      expect(policy.shouldDropForIgnore(msg('hi', login: 'BadUser')), isTrue);
      expect(policy.shouldDropForIgnore(msg('hi', login: 'gooduser')), isFalse);
      expect(
        policy.shouldDropForIgnore(msg('hi', login: 'baduser', isSystem: true)),
        isFalse,
      );
    });

    test('drops block-mode keyword matches', () {
      ignores.upsertKeyword(
        const IgnoreEntry(id: 'k1', pattern: 'banme', block: true),
      );
      expect(
        policy.shouldDropForBlockedPhrase(msg('please banme now')),
        isTrue,
      );
      expect(policy.shouldDropForBlockedPhrase(msg('nothing here')), isFalse);
    });
  });

  group('blocked users', () {
    test('drops blocked senders but not system messages', () {
      final blocked = ChatMessagePolicy(
        ignoreManager: ignores,
        pingManager: pings,
        userStore: users,
        session: session,
        isBlocked: (login) => login == 'blockeduser',
      );
      expect(
        blocked.shouldDropForBlockedUser(msg('hi', login: 'blockeduser')),
        isTrue,
      );
      expect(
        blocked.shouldDropForBlockedUser(msg('hi', login: 'gooduser')),
        isFalse,
      );
      expect(
        blocked.shouldDropForBlockedUser(
          msg('hi', login: 'blockeduser', isSystem: true),
        ),
        isFalse,
      );
    });
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

    test('mention-only mode ignores non-mention highlights', () {
      final message = msg('reward', msgId: 'highlighted-message');
      policy.applyPingHighlight(message, mentionOnly: true);
      expect(message.highlight, isNull);
    });

    test('mention-only mode keeps an existing highlight', () {
      pings.setAccount('forsen');
      const existing = HighlightState(types: {HighlightType.username});
      final message = msg('hey forsen')..highlight = existing;
      policy.applyPingHighlight(message, mentionOnly: true);
      expect(message.highlight, same(existing));
    });
  });

  group('user learning', () {
    test('stores the login when the display name differs', () {
      policy.learnUser(
        'ch',
        msg('hi', login: 'loginname', displayName: 'DisplayName'),
      );
      expect(users.usersForChannel('ch'), contains('loginname'));
    });

    test('stores the display name when it only differs in case', () {
      policy.learnUser('ch', msg('hi', login: 'foobar', displayName: 'FooBar'));
      expect(users.usersForChannel('ch'), contains('FooBar'));
    });
  });

  group('self rewrite', () {
    test('rewrites self-authored system lines to first person', () {
      session.apply('mylogin');
      final message = msg(
        'MyLogin was banned.',
        login: 'MyLogin',
        isSystem: true,
      );
      policy.applySelfRewrite(message);
      expect(message.text, 'You were banned.');
    });

    test('leaves non-system and other users alone', () {
      session.apply('mylogin');
      final own = msg('MyLogin was here.', login: 'MyLogin');
      policy.applySelfRewrite(own);
      expect(own.text, 'MyLogin was here.');
      final other = msg('Other was banned.', login: 'Other', isSystem: true);
      policy.applySelfRewrite(other);
      expect(other.text, 'Other was banned.');
    });
  });
}
