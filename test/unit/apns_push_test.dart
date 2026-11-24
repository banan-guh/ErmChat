import 'dart:async';
import 'dart:convert';

import 'package:ermchat/models/ping_rule.dart';
import 'package:ermchat/services/apns_push.dart';
import 'package:ermchat/screens/settings/pings_screen.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fake_async/fake_async.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('ermchat/apns');
  void mockNative(Future<Object?>? Function(MethodCall) handler) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, handler);
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
  }

  Future<void> emitNative(MethodCall call, {bool pump = true}) async {
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          channel.name,
          const StandardMethodCodec().encodeMethodCall(call),
          (_) {},
        );
    if (pump) await pumpEventQueue();
  }

  test(
    'turning push on asks for permission after a quiet token fetch',
    () async {
      final prompts = <bool>[];
      mockNative((call) async {
        if (call.method != 'token') return null;
        prompts.add((call.arguments as Map)['prompt'] as bool);
        return 'a' * 64;
      });

      final push = ApnsPush(
        active: true,
        endpoint: 'https://example.test',
        registration: () async => null,
        retryDelays: const [],
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

  test('resuming registers again even when nothing changed', () async {
    mockNative((call) async => call.method == 'token' ? 'a' * 64 : null);
    var registers = 0;
    final push = ApnsPush(
      active: true,
      endpoint: 'https://example.test',
      registration: () async => (token: 't', rules: <String, Object?>{}),
      client: MockClient((request) async {
        if (request.url.path.endsWith('/register')) registers++;
        return http.Response('', 204);
      }),
    );
    addTearDown(push.dispose);

    await push.sync(push: true);
    await push.sync(push: true);
    push.resumed();
    await pumpEventQueue();

    expect(
      registers,
      2,
      reason: 'a restarted server holds nothing until the app registers again',
    );
  });

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

  test('iOS rules can reach every notification level', () {
    const rules = [
      PingRule(id: 'word', kind: PingRuleKind.message, pattern: 'fruit'),
      PingRule(id: 'user', kind: PingRuleKind.user, pattern: 'alice'),
      PingRule(id: 'name', kind: PingRuleKind.message, type: 'username'),
      PingRule(id: 'reply', kind: PingRuleKind.message, type: 'reply'),
      PingRule(id: 'thread', kind: PingRuleKind.message, type: 'thread'),
      PingRule(id: 'first', kind: PingRuleKind.message, type: 'firstMsg'),
    ];
    for (final rule in rules) {
      expect(
        pingRuleLevelCount(rule, push: true),
        rule.type == 'firstMsg' ? 2 : 5,
        reason: '${rule.id} lost its notify stop on iOS',
      );
    }
  });

  test(
    'an account switch replaces the bearer token for identical rules',
    () async {
      mockNative((call) async => call.method == 'token' ? 'device' : null);
      var token = 'account-a';
      final paths = <String>[];
      final auth = <String?>[];
      final push = ApnsPush(
        active: true,
        endpoint: 'https://example.test',
        registration: () async => (token: token, rules: <String, Object?>{}),
        client: MockClient((request) async {
          paths.add(request.url.pathSegments.last);
          auth.add(request.headers['authorization']);
          return http.Response('', 204);
        }),
      );
      addTearDown(push.dispose);

      await push.sync(push: true);
      token = 'account-b';
      await push.sync(push: true);

      expect(paths, ['register', 'unregister', 'register']);
      expect(auth, ['Bearer account-a', null, 'Bearer account-b']);
    },
  );

  test('logging out unregisters the device', () async {
    mockNative((call) async => call.method == 'token' ? 'device' : null);
    PushRegistration? registration = (token: 'account', rules: {});
    final paths = <String>[];
    final push = ApnsPush(
      active: true,
      endpoint: 'https://example.test',
      registration: () async => registration,
      client: MockClient((request) async {
        paths.add(request.url.pathSegments.last);
        return http.Response('', 204);
      }),
    );
    addTearDown(push.dispose);

    await push.sync(push: true);
    registration = null;
    await push.sync(push: true);

    expect(paths, ['register', 'unregister']);
    expect(push.failed.value, isFalse);
  });

  test(
    'the latest enable or disable wins across overlapping requests',
    () async {
      mockNative((call) async => call.method == 'token' ? 'device' : null);
      final gate = Completer<void>();
      final paths = <String>[];
      final push = ApnsPush(
        active: true,
        endpoint: 'https://example.test',
        registration: () async =>
            (token: 'account', rules: <String, Object?>{}),
        client: MockClient((request) async {
          paths.add(request.url.pathSegments.last);
          if (paths.length == 1) await gate.future;
          return http.Response('', 204);
        }),
      );
      addTearDown(push.dispose);

      final enabling = push.sync(push: true);
      await pumpEventQueue();
      final disabling = push.sync(push: false);
      await pumpEventQueue();
      gate.complete();
      await Future.wait([enabling, disabling]);

      expect(paths, ['register', 'unregister']);
      expect(push.failed.value, isFalse);
    },
  );

  test('a stale rule snapshot cannot overwrite a newer registration', () async {
    mockNative((call) async => call.method == 'token' ? 'device' : null);
    final entered = Completer<void>();
    final stale = Completer<PushRegistration?>();
    var calls = 0;
    final bodies = <String>[];
    final push = ApnsPush(
      active: true,
      endpoint: 'https://example.test',
      registration: () async {
        calls++;
        if (calls == 1) {
          entered.complete();
          return stale.future;
        }
        return (
          token: 'account',
          rules: {
            'channels': ['new'],
          },
        );
      },
      client: MockClient((request) async {
        bodies.add(request.body);
        return http.Response('', 204);
      }),
    );
    addTearDown(push.dispose);

    final first = push.sync(push: true);
    await entered.future;
    final second = push.sync(push: true);
    stale.complete((
      token: 'account',
      rules: {
        'channels': ['old'],
      },
    ));
    await Future.wait([first, second]);

    expect(bodies, hasLength(1));
    expect(bodies.single, contains('new'));
    expect(bodies.single, isNot(contains('old')));
  });

  test('transient registration failures retry and then clear', () {
    mockNative((call) async => call.method == 'token' ? 'device' : null);
    fakeAsync((async) {
      var attempts = 0;
      final push = ApnsPush(
        active: true,
        endpoint: 'https://example.test',
        registration: () async =>
            (token: 'account', rules: <String, Object?>{}),
        retryDelays: [const Duration(seconds: 1)],
        client: MockClient((request) async {
          attempts++;
          return http.Response('', attempts == 1 ? 503 : 204);
        }),
      );
      addTearDown(push.dispose);
      Object? error;
      push.sync(push: true).catchError((Object e) {
        error = e;
      });

      async.flushMicrotasks();
      async.elapse(Duration.zero);
      async.flushMicrotasks();
      expect(attempts, 1);
      async.elapse(const Duration(seconds: 1));
      async.flushMicrotasks();

      expect(attempts, 2);
      expect(push.failed.value, isFalse);
      expect(error, isNull);
    });
  });

  test('a failed unregister retries after connectivity returns', () async {
    mockNative((call) async => call.method == 'token' ? 'device' : null);
    var unregisters = 0;
    final push = ApnsPush(
      active: true,
      endpoint: 'https://example.test',
      registration: () async => null,
      retryDelays: const [],
      client: MockClient((request) async {
        unregisters++;
        return http.Response('', unregisters == 1 ? 500 : 204);
      }),
    );
    addTearDown(push.dispose);

    await push.sync(push: false);
    expect(push.failed.value, isTrue);
    push.retry();
    await pumpEventQueue();

    expect(unregisters, 2);
    expect(push.failed.value, isFalse);
  });

  test('a nil token result never uploads the previous token', () async {
    final tokens = ['old-device', null, 'new-device'];
    mockNative(
      (call) async => call.method == 'token' ? tokens.removeAt(0) : null,
    );
    final devices = <String>[];
    final push = ApnsPush(
      active: true,
      endpoint: 'https://example.test',
      registration: () async => (token: 'account', rules: <String, Object?>{}),
      client: MockClient((request) async {
        devices.add((jsonDecode(request.body) as Map)['device'] as String);
        return http.Response('', 204);
      }),
    );
    addTearDown(push.dispose);

    await push.sync(push: false);
    await push.sync(push: true);
    expect(push.failed.value, isTrue);
    await push.sync(push: true);

    expect(devices, ['old-device', 'new-device']);
    expect(push.failed.value, isFalse);
  });

  test('token rotation while idle replaces the old server binding', () async {
    mockNative((call) async => call.method == 'token' ? 'old-device' : null);
    final paths = <String>[];
    final devices = <String>[];
    final push = ApnsPush(
      active: true,
      endpoint: 'https://example.test',
      registration: () async => (token: 'account', rules: <String, Object?>{}),
      client: MockClient((request) async {
        paths.add(request.url.pathSegments.last);
        devices.add((jsonDecode(request.body) as Map)['device'] as String);
        return http.Response('', 204);
      }),
    );
    addTearDown(push.dispose);

    await push.sync(push: true);
    await emitNative(
      const MethodCall('token', {
        'token': 'new-device',
        'previous': 'old-device',
      }),
    );

    expect(paths, ['register', 'unregister', 'register']);
    expect(devices, ['old-device', 'old-device', 'new-device']);
  });

  test('a missing native token times out and surfaces failure', () {
    mockNative((_) async => null);
    fakeAsync((async) {
      var posts = 0;
      var tokenCalls = 0;
      final push = ApnsPush(
        active: true,
        endpoint: 'https://example.test',
        tokenProvider: (_) {
          tokenCalls++;
          return Completer<String?>().future;
        },
        tokenTimeout: const Duration(seconds: 1),
        registration: () async =>
            (token: 'account', rules: <String, Object?>{}),
        client: MockClient((request) async {
          posts++;
          return http.Response('', 204);
        }),
      );
      addTearDown(push.dispose);
      push.sync(push: true);

      async.flushMicrotasks();
      async.elapse(Duration.zero);
      async.flushMicrotasks();
      expect(tokenCalls, 1);
      async.elapse(const Duration(seconds: 1));
      async.flushMicrotasks();

      expect(push.failed.value, isTrue);
      expect(posts, 0);
    });
  });

  test(
    'a failed disable stays retryable until the device is removed',
    () async {
      String? token = 'old-device';
      mockNative((call) async => call.method == 'token' ? token : null);
      var unregisters = 0;
      final devices = <String>[];
      final push = ApnsPush(
        active: true,
        endpoint: 'https://example.test',
        registration: () async =>
            (token: 'account', rules: <String, Object?>{}),
        retryDelays: const [],
        client: MockClient((request) async {
          if (request.url.path.endsWith('/unregister')) {
            unregisters++;
            devices.add((jsonDecode(request.body) as Map)['device'] as String);
          }
          return http.Response('', 204);
        }),
      );
      addTearDown(push.dispose);

      await push.sync(push: true);
      token = null;
      await emitNative(const MethodCall('tokenError'));
      await push.sync(push: false);
      expect(push.failed.value, isTrue);
      expect(unregisters, 0);

      token = 'old-device';
      push.retry();
      await pumpEventQueue();
      expect(unregisters, 1);
      expect(devices, ['old-device']);
      expect(push.failed.value, isFalse);
    },
  );

  test(
    'token rotation overlapping logout removes both device tokens',
    () async {
      var token = 'old-device';
      mockNative((call) async => call.method == 'token' ? token : null);
      final paths = <String>[];
      final devices = <String>[];
      final push = ApnsPush(
        active: true,
        endpoint: 'https://example.test',
        registration: () async =>
            (token: 'account', rules: <String, Object?>{}),
        client: MockClient((request) async {
          paths.add(request.url.pathSegments.last);
          devices.add((jsonDecode(request.body) as Map)['device'] as String);
          return http.Response('', 204);
        }),
      );
      addTearDown(push.dispose);

      await push.sync(push: true);
      token = 'new-device';
      await emitNative(
        const MethodCall('token', {
          'token': 'new-device',
          'previous': 'old-device',
        }),
        pump: false,
      );
      await push.sync(push: false);

      expect(paths, ['register', 'unregister', 'unregister']);
      expect(devices, ['old-device', 'new-device', 'old-device']);
      expect(push.failed.value, isFalse);
    },
  );

  test('registration waits for account data to be ready', () async {
    mockNative((call) async => call.method == 'token' ? 'device' : null);
    final ready = Completer<void>();
    var registers = 0;
    final push = ApnsPush(
      active: true,
      endpoint: 'https://example.test',
      ready: () => ready.future,
      registration: () async => (token: 'account', rules: <String, Object?>{}),
      client: MockClient((request) async {
        registers++;
        return http.Response('', 204);
      }),
    );
    addTearDown(push.dispose);

    final syncing = push.sync(push: true);
    await pumpEventQueue();
    expect(registers, 0);
    ready.complete();
    await syncing;
    expect(registers, 1);
  });

  test('the launch channel stays until the app clears it', () async {
    String? launch = 'channel';
    final cleared = <bool>[];
    mockNative((call) async {
      if (call.method == 'launchChannel') return launch;
      if (call.method == 'clearLaunchChannel') {
        cleared.add(true);
        launch = null;
      }
      return null;
    });
    final push = ApnsPush(
      active: true,
      endpoint: 'https://example.test',
      registration: () async => null,
    );
    addTearDown(push.dispose);

    expect(await push.launchChannel(), 'channel');
    expect(await push.launchChannel(), 'channel');
    await push.clearLaunchChannel();
    expect(await push.launchChannel(), isNull);
    expect(cleared, hasLength(1));
  });
}
