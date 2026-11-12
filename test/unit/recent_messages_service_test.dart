import 'package:ermchat/color_utils.dart';
import 'package:ermchat/models/twitch_message.dart';
import 'package:ermchat/services/recent_messages.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _unjoined =
    '{"messages":[],"error":"not joined","error_code":"channel_not_joined"}';

const _payload =
    '{"messages":["@rm-received-ts=1700000000000;historical=1;id=m1;'
    'display-name=User;color=#00FF00;emotes;badges;user-id=42 '
    ':user!user@user.tmi.twitch.tv PRIVMSG #test :hi"]}';

RecentMessagesService _service(MockClient client) => RecentMessagesService(
  client: client,
  config: RecentMessagesConfig(mode: RecentMessagesMode.robotty),
);

void main() {
  test('an unjoined provider is retried before settling', () {
    fakeAsync((async) {
      var calls = 0;
      final client = MockClient((_) async {
        calls++;
        return http.Response(calls == 1 ? _unjoined : _payload, 200);
      });
      List<TwitchMessage>? rows;
      _service(client).fetchRecent('test', limit: 5).then((r) => rows = r);
      async.flushMicrotasks();
      expect(calls, 1);

      async.elapse(const Duration(seconds: 2));
      async.flushMicrotasks();
      expect(calls, 2);
      expect(rows?.single.text, 'hi');
    });
  });

  test('a joined provider is not retried', () {
    fakeAsync((async) {
      var calls = 0;
      final client = MockClient((_) async {
        calls++;
        return http.Response(_payload, 200);
      });
      List<TwitchMessage>? rows;
      _service(client).fetchRecent('test').then((r) => rows = r);
      async.flushMicrotasks();

      expect(calls, 1);
      expect(rows, hasLength(1));
    });
  });

  test('a still-unjoined retry settles on the stale batch', () {
    fakeAsync((async) {
      var calls = 0;
      final client = MockClient((_) async {
        calls++;
        return http.Response(_unjoined, 200);
      });
      List<TwitchMessage>? rows;
      _service(client).fetchRecent('test').then((r) => rows = r);
      async.flushMicrotasks();

      async.elapse(const Duration(seconds: 2));
      async.flushMicrotasks();
      expect(calls, 2);
      expect(rows, isEmpty);
    });
  });

  test('a history row without a color tag takes the palette color', () {
    fakeAsync((async) {
      const payload =
          '{"messages":["@rm-received-ts=1700000000000;historical=1;id=m2;'
          'login=user;display-name=User;emotes;badges;user-id=42 '
          ':user!user@user.tmi.twitch.tv PRIVMSG #test :hi"]}';
      final client = MockClient((_) async => http.Response(payload, 200));
      List<TwitchMessage>? rows;
      _service(client).fetchRecent('test').then((r) => rows = r);
      async.flushMicrotasks();

      expect(
        rows?.single.color,
        pickColor('user'),
        reason: 'live rows without a tag already take the palette color',
      );
    });
  });
}
