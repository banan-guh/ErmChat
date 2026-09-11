import 'package:ermchat/services/twitch_api.dart';
import 'package:ermchat/services/twitch_badge_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

class _RecordingClient extends http.BaseClient {
  bool closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    throw UnimplementedError();
  }

  @override
  void close() => closed = true;
}

void main() {
  test('TwitchApi.close closes the injected client', () {
    final client = _RecordingClient();
    TwitchApi(client: client).close();
    expect(client.closed, isTrue);
  });

  test('TwitchBadgeService.close closes the injected client', () {
    final client = _RecordingClient();
    TwitchBadgeService(client: client).close();
    expect(client.closed, isTrue);
  });
}
