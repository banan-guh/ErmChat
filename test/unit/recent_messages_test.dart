import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ermchat/services/recent_messages.dart';

void main() {
  const privmsgLine =
      '@rm-received-ts=1566417979914;historical=1;id=3c33033a;'
      'display-name=Alice;color=#9ACD32;user-id=42239452 '
      ':alice!alice@alice.tmi.twitch.tv PRIVMSG #test :hello world';

  http.Response okBody() => http.Response(
    jsonEncode({
      'messages': [privmsgLine],
      'error': null,
      'error_code': null,
    }),
    200,
  );

  group('RecentMessagesService error handling', () {
    test(
      '200 with channel_not_joined still parses whatever history exists',
      () async {
        final calls = <Uri>[];
        final service = RecentMessagesService(
          client: MockClient((request) async {
            calls.add(request.url);
            return http.Response(
              jsonEncode({
                'messages': [privmsgLine],
                'error':
                    'The bot is currently not joined to this channel '
                    '(in progress or failed previously)',
                'error_code': 'channel_not_joined',
              }),
              200,
            );
          }),
        );

        final messages = await service.fetchRecent('test');

        expect(calls, hasLength(1), reason: 'informational error: no mirror');
        expect(messages, hasLength(1));
        expect(messages.single.text, 'hello world');
      },
    );

    test('invalid_channel_login throws clean and skips the mirror', () async {
      final service = RecentMessagesService(
        client: MockClient(
          (_) async => http.Response(
            jsonEncode({
              'status': 400,
              'error': 'Invalid channel login `this_is_wrong`',
              'error_code': 'invalid_channel_login',
            }),
            400,
          ),
        ),
      );

      await expectLater(
        service.fetchRecent('this_is_wrong'),
        throwsA(
          isA<RecentMessagesException>()
              .having((e) => e.message, 'message', 'Invalid channel name')
              .having((e) => e.definitive, 'definitive', isTrue),
        ),
      );
    });

    test(
      'channel_ignored maps to the excluded-channel message and skips mirror',
      () async {
        final service = RecentMessagesService(
          client: MockClient(
            (_) async => http.Response(
              jsonEncode({
                'status': 403,
                'error': 'The channel login `x` is excluded from this service',
                'error_code': 'channel_ignored',
              }),
              403,
            ),
          ),
        );

        await expectLater(
          service.fetchRecent('x'),
          throwsA(
            isA<RecentMessagesException>()
                .having(
                  (e) => e.message,
                  'message',
                  'History unavailable: channel excluded from the history '
                      'service',
                )
                .having((e) => e.definitive, 'definitive', isTrue),
          ),
        );
      },
    );

    test('5xx falls back to the mirror', () async {
      final service = RecentMessagesService(
        client: MockClient((request) async {
          if (request.url.host.contains('robotty')) {
            return http.Response('internal error', 500);
          }
          return okBody();
        }),
      );

      final messages = await service.fetchRecent('test');
      expect(messages.single.text, 'hello world');
    });

    test('unknown non-2xx codes get the generic message', () async {
      final service = RecentMessagesService(
        client: MockClient(
          (_) async =>
              http.Response(jsonEncode({'error_code': 'something_new'}), 503),
        ),
      );

      // 503 is not definitive: the mirror also fails, surfacing the generic
      // message from whichever attempt threw last.
      await expectLater(
        service.fetchRecent('test'),
        throwsA(
          isA<RecentMessagesException>().having(
            (e) => e.message,
            'message',
            'Failed to load chat history',
          ),
        ),
      );
    });
  });
}
