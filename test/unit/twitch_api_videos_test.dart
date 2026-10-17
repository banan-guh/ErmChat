import 'package:ermchat/services/twitch_api.dart';
import 'package:ermchat/services/twitch_auth.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('archive videos map by the stream they recorded', () async {
    Uri? asked;
    final api = TwitchApi(
      client: MockClient((req) async {
        asked = req.url;
        return http.Response(
          '{"data":[{"id":"2100","stream_id":"4001","user_id":"9",'
          '"type":"archive","created_at":"2026-10-14T18:00:00Z"},'
          '{"id":"2101","stream_id":null,"type":"archive"},'
          '{"id":"2102","type":"archive"}]}',
          200,
        );
      }),
    );
    final auth = TwitchAuth()..accessToken = 'tok';
    final videos = await api.getArchiveVideos(auth, '9');
    expect(videos, {'4001': '2100'}, reason: 'rows without a stream id skip');
    expect(asked?.queryParameters['type'], 'archive');
    expect(asked?.queryParameters['user_id'], '9');
  });
}
