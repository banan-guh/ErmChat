import 'dart:convert';

import 'package:ermchat/chat/chat.dart';
import 'package:ermchat/client/session.dart';
import 'package:ermchat/l10n/app_localizations_en.dart';
import 'package:ermchat/services/chat_status_composer.dart';
import 'package:ermchat/services/twitch_api.dart';
import 'package:ermchat/services/twitch_auth.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late Chat chat;
  late DateTime clockNow;
  late Map<String, dynamic>? stream;
  late int status;
  late ChatStatusComposer composer;
  final archived = <String>[];

  ChatStatusComposer build() {
    final api = TwitchApi(
      client: MockClient(
        (_) async => http.Response(
          jsonEncode({
            'data': [?stream],
          }),
          status,
        ),
      ),
    );
    return ChatStatusComposer(
      twitchApi: api,
      twitchAuth: TwitchAuth()..accessToken = 'tok',
      chat: chat,
      session: Session(),
      strings: AppLocalizationsEn.new,
      getMaxMessages: () => 1000,
      now: () => clockNow,
      onStreamSeen: (channel, id, startedAt, title, game) =>
          archived.add('seen $channel $id ${startedAt.toUtc()} $title $game'),
      onStreamEnded: (id, endedAt) =>
          archived.add('ended $id ${endedAt.toUtc()}'),
    )..startFor('test');
  }

  Map<String, dynamic> live(String id, String startedAt) => {
    'id': id,
    'user_id': '42',
    'type': 'live',
    'title': 'Speedrun',
    'game_name': 'Zelda',
    'started_at': startedAt,
  };

  Future<void> poll([Duration after = const Duration(seconds: 30)]) async {
    clockNow = clockNow.add(after);
    await composer.fetchAllChatStatus();
  }

  List<String> rows() => chat
      .channelFor('test')!
      .messages
      .items
      .where((m) => m.isSystem)
      .map((m) => '${m.messageId}|${m.text}')
      .toList();

  void restart() {
    composer.dispose();
    chat.dispose();
    chat = Chat();
    chat.ensure('test').info.setBroadcasterId('42');
    composer = build();
  }

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    chat = Chat();
    chat.ensure('test').info.setBroadcasterId('42');
    clockNow = DateTime.utc(2026, 10, 13, 12);
    stream = null;
    status = 200;
    archived.clear();
    composer = build();
  });

  tearDown(() {
    composer.dispose();
    chat.dispose();
  });

  test('poll transitions write one start and one end per stream id', () async {
    await poll();
    expect(rows(), isEmpty, reason: 'offline with no history writes nothing');

    stream = live('s1', '2026-10-13T09:00:00Z');
    await poll();
    expect(rows(), ['sys_stream:s1:start|Stream: Speedrun - Zelda']);
    final start = chat
        .channelFor('test')!
        .messages
        .byId('sys_stream:s1:start')!;
    expect(start.timestamp.toUtc(), DateTime.utc(2026, 10, 13, 9));

    await poll();
    expect(rows(), hasLength(1), reason: 'same id never repeats the start');

    stream = null;
    await poll();
    expect(rows(), hasLength(1), reason: 'one empty poll may be a failure');
    await poll();
    expect(rows(), contains('sys_stream:s1:end|Stream ended - 3h1m'));
    await poll();
    expect(rows(), hasLength(2), reason: 'end writes once');

    stream = live('s2', '2026-10-13T13:00:00Z');
    await poll();
    expect(rows(), hasLength(3));
    expect(rows().first, startsWith('sys_stream:s2:start'));
    expect(archived.toSet(), {
      'seen test s1 2026-10-13 09:00:00.000Z Speedrun Zelda',
      'ended s1 2026-10-13 12:01:30.000Z',
      'seen test s2 2026-10-13 13:00:00.000Z Speedrun Zelda',
    }, reason: 'the archive must get each stream and its end');
  });

  test('a new id while live closes the old stream first', () async {
    stream = live('s1', '2026-10-13T11:00:00Z');
    await poll();
    stream = live('s2', '2026-10-13T12:20:00Z');
    await poll();
    expect(
      rows().where((r) => r.startsWith('sys_stream:s1:end')),
      hasLength(1),
    );
    expect(
      rows().where((r) => r.startsWith('sys_stream:s2:start|')),
      hasLength(1),
    );
  });

  test('an ended id seen live again takes back its end', () async {
    stream = live('s1', '2026-10-13T09:00:00Z');
    await poll();
    stream = null;
    await poll();
    await poll();
    expect(rows(), contains(startsWith('sys_stream:s1:end')));
    stream = live('s1', '2026-10-13T09:00:00Z');
    await poll();
    expect(rows(), [
      'sys_stream:s1:start|Stream: Speedrun - Zelda',
    ], reason: 'Helix listed it live, so it never ended or restarted');
  });

  test('restart mid-stream does not repeat the start', () async {
    stream = live('s1', '2026-10-13T09:00:00Z');
    await poll();
    restart();

    // Helix fails while the token refreshes after the restart.
    status = 401;
    await composer.fetchChatStatus('test');
    await poll();
    await poll();
    expect(rows(), isEmpty, reason: 'failed polls are not offline polls');
    status = 200;
    await poll();
    expect(rows(), isEmpty, reason: 'persisted id marks the start as written');
  });

  test('app opened after the stream ended writes the end once', () async {
    stream = live('s1', '2026-10-13T09:00:00Z');
    await poll();
    final lastSeen = clockNow;
    stream = null;
    restart();

    await poll(const Duration(hours: 5));
    await poll();
    expect(rows(), ['sys_stream:s1:end|Stream ended - 3h0m']);
    expect(
      chat.channelFor('test')!.messages.items.single.timestamp.toUtc(),
      lastSeen.toUtc(),
      reason: 'the end sits at the last poll that saw it live',
    );
    await poll();
    expect(rows(), hasLength(1));
  });
}
