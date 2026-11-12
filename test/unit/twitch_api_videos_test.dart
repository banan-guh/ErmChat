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
          '"type":"archive","created_at":"2026-10-14T18:00:00Z",'
          '"thumbnail_url":"https://t/%{width}x%{height}.jpg"},'
          '{"id":"2101","stream_id":null,"type":"archive"},'
          '{"id":"2102","type":"archive"}]}',
          200,
        );
      }),
    );
    final auth = TwitchAuth()..accessToken = 'tok';
    final videos = await api.getArchiveVideos(auth, '9');
    expect(videos, {
      '4001': (id: '2100', thumbnail: 'https://t/%{width}x%{height}.jpg'),
    }, reason: 'rows without a stream id skip');
    expect(asked?.queryParameters['type'], 'archive');
    expect(asked?.queryParameters['user_id'], '9');
  });

  test('latest archive video gives the recorded stream start and end', () async {
    Uri? asked;
    final api = TwitchApi(
      client: MockClient((req) async {
        asked = req.url;
        return http.Response(
          '{"data":['
          '{"id":"2100","type":"archive","duration":"1h2m3s"},'
          '{"id":"2101","stream_id":"","created_at":"2026-10-14T18:00:00Z",'
          '"duration":"1h2m3s"},'
          '{"id":"2104","stream_id":"4003","duration":"1h2m3s"},'
          '{"id":"2105","stream_id":"4003","created_at":"2026-10-14T18:00:00Z",'
          '"duration":"soon"},'
          '{"id":"2102","stream_id":"4001","created_at":"2026-10-14T18:00:00Z",'
          '"duration":"1h2m3s"},'
          '{"id":"2103","stream_id":"4002","created_at":"2026-10-15T18:00:00Z",'
          '"duration":"1h2m3s"}]}',
          200,
        );
      }),
    );
    final auth = TwitchAuth()..accessToken = 'tok';
    final video = await api.getLatestArchiveVideo(auth, '9');
    expect(asked?.path, '/helix/videos');
    expect(asked?.queryParameters['first'], '5');
    expect(asked?.queryParameters['type'], 'archive');
    expect(asked?.queryParameters['user_id'], '9');
    expect(
      video,
      (
        vodId: '2102',
        streamId: '4001',
        startedAt: DateTime.utc(2026, 10, 14, 18),
        endedAt: DateTime.utc(2026, 10, 14, 19, 2, 3),
      ),
      reason:
          'the newest usable video wins and rows without a stream id, '
          'start or duration skip',
    );
  });

  test('video durations parse with any empty leading unit', () async {
    for (final (duration, expected) in [
      ('1h2m3s', const Duration(hours: 1, minutes: 2, seconds: 3)),
      ('2m3s', const Duration(minutes: 2, seconds: 3)),
      ('3s', const Duration(seconds: 3)),
      ('1h', const Duration(hours: 1)),
    ]) {
      final api = TwitchApi(
        client: MockClient(
          (_) async => http.Response(
            '{"data":[{"id":"1","stream_id":"7",'
            '"created_at":"2026-10-14T18:00:00Z",'
            '"duration":"$duration"}]}',
            200,
          ),
        ),
      );
      final video = await api.getLatestArchiveVideo(
        TwitchAuth()..accessToken = 'tok',
        '9',
      );
      expect(
        video!.endedAt.difference(video.startedAt),
        expected,
        reason: 'duration "$duration"',
      );
    }
  });
}
