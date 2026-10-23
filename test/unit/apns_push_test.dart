import 'package:ermchat/models/ping_rule.dart';
import 'package:ermchat/services/apns_push.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'turning push on asks for permission after a quiet token fetch',
    () async {
      const channel = MethodChannel('ermchat/apns');
      final prompts = <bool>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method != 'token') return null;
            prompts.add((call.arguments as Map)['prompt'] as bool);
            return 'a' * 64;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );

      final push = ApnsPush(
        active: true,
        endpoint: 'https://example.test',
        registration: () async => null,
        client: MockClient((_) async => http.Response('', 500)),
      );
      addTearDown(push.dispose);

      await push.sync(push: false);
      await push.sync(push: true);

      expect(prompts, [
        false,
        true,
      ], reason: 'the cached token skipped the ask');
    },
  );

  test('the push server gets only the rules that notify', () {
    final rules = ApnsPush.rules(
      pingRules: const [
        PingRule(
          id: 'n',
          kind: PingRuleKind.message,
          type: 'username',
          notify: true,
        ),
        PingRule(
          id: 'r',
          kind: PingRuleKind.message,
          type: 'reply',
          notify: false,
        ),
        PingRule(
          id: 't',
          kind: PingRuleKind.message,
          type: 'thread',
          notify: true,
          enabled: false,
        ),
        PingRule(
          id: 'w',
          kind: PingRuleKind.message,
          pattern: 'Fruit',
          wordBoundary: true,
          notify: true,
        ),
        PingRule(id: 'tint', kind: PingRuleKind.message, pattern: 'tintonly'),
        PingRule(
          id: 'u',
          kind: PingRuleKind.user,
          pattern: 'Alice',
          notify: true,
        ),
        PingRule(
          id: 'm',
          kind: PingRuleKind.user,
          pattern: 'bob',
          notify: true,
          mention: false,
        ),
        PingRule(id: 'b', kind: PingRuleKind.blacklist, pattern: 'Spammer'),
      ],
      channels: ['chan'],
      displayName: 'Ermu',
      blocked: ['Troll', 'spammer'],
      pausedUntil: DateTime.fromMillisecondsSinceEpoch(1700000000000),
    );
    expect(rules, {
      'display': 'Ermu',
      'channels': ['chan'],
      'name': true,
      'replies': false,
      'threads': false,
      'words': [
        {'pattern': 'Fruit', 'wholeWord': true},
      ],
      'users': ['alice'],
      'blocked': ['spammer', 'troll'],
      'pausedUntil': 1700000000,
    }, reason: 'only enabled rules that notify and fill @mentions push');
  });
}
