import 'dart:async';

import 'package:ermchat/chat/chat.dart';
import 'package:ermchat/services/mod_actions.dart';
import 'package:ermchat/services/twitch_api.dart';
import 'package:ermchat/services/twitch_auth.dart';
import 'package:ermchat/widgets/mod_view/scope.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  late List<String> notices;
  late List<Completer<http.Response>> responses;
  late ModContext mod;

  setUp(() {
    notices = [];
    responses = [];
    final api = TwitchApi(
      client: MockClient((_) {
        final response = Completer<http.Response>();
        responses.add(response);
        return response.future;
      }),
    );
    mod = ModContext(
      channel: 'testchannel',
      chat: Chat(),
      actions: ModActions(
        twitchApi: api,
        getChannelUserIds: () => {'testchannel': 'b1'},
        getCurrentUserId: () => 'm1',
      ),
      auth: TwitchAuth()..accessToken = 'tok',
      notify: notices.add,
    );
  });

  ModLoader<List<String>> moderators() => ModLoader(
    mod,
    (mod) => mod.actions.getModerators(mod.auth, mod.channel),
    failure: 'Could not load moderators.',
    statusFailure: (status) => status == 403 ? 'Not yours.' : null,
  );

  http.Response logins(List<String> names) => http.Response(
    '{"data":[${names.map((n) => '{"user_login":"$n"}').join(',')}],'
    '"pagination":{}}',
    200,
  );

  Future<void> settle() => Future<void>.delayed(Duration.zero);

  test('a newer load wins over a slower older one', () async {
    final loader = moderators();
    final first = loader.load();
    final second = loader.load();
    await settle();
    responses[1].complete(logins(['new']));
    await second;
    responses[0].complete(logins(['old']));
    await first;
    expect(loader.value, ['new']);
  });

  test('a failed first load shows the status copy', () async {
    final loader = moderators();
    final load = loader.load();
    await settle();
    responses[0].complete(http.Response('{"message":"nope"}', 403));
    await load;
    expect(loader.value, isNull);
    expect(loader.error, 'Not yours.');
    expect(notices, isEmpty);
  });

  test('a failed refresh keeps the data and becomes a notice', () async {
    final loader = moderators();
    var load = loader.load();
    await settle();
    responses[0].complete(logins(['a']));
    await load;

    load = loader.load();
    await settle();
    responses[1].complete(http.Response('{"message":"down"}', 500));
    await load;
    expect(loader.value, ['a']);
    expect(loader.error, isNull);
    expect(notices, ['down']);
  });

  test('reset clears what is shown before reloading', () async {
    final loader = moderators();
    var load = loader.load();
    await settle();
    responses[0].complete(logins(['a']));
    await load;

    load = loader.reset();
    expect(loader.value, isNull);
    await settle();
    responses[1].complete(logins(['b']));
    await load;
    expect(loader.value, ['b']);
  });
}
