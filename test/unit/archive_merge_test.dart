import 'package:ermchat/chat/channel/threads.dart';
import 'package:ermchat/models/twitch_message.dart';
import 'package:ermchat/panels/threads.dart';
import 'package:ermchat/sheets/user_sheet.dart';
import 'package:flutter_test/flutter_test.dart';

final _now = DateTime.utc(2026, 11, 6, 12);

TwitchMessage _msg(String id, int seconds) => TwitchMessage(
  login: 'alice',
  text: 'msg $id',
  messageId: id,
  channel: 'test',
  timestamp: _now.add(Duration(seconds: seconds)),
);

ThreadSummary _summary(
  String rootId,
  Duration ago,
  int replies, {
  TwitchMessage? root,
}) => ThreadSummary(
  rootId: rootId,
  root: root,
  lastActivity: _now.subtract(ago),
  replyCount: replies,
);

void main() {
  group('mergeActiveThreads', () {
    test('orders by length, then newest activity', () {
      final archived = [
        (
          rootId: 'a',
          lastActivity: _now.subtract(const Duration(hours: 2)),
          replyCount: 8,
        ),
        (
          rootId: 'b',
          lastActivity: _now.subtract(const Duration(hours: 1)),
          replyCount: 3,
        ),
        (
          rootId: 'c',
          lastActivity: _now.subtract(const Duration(minutes: 30)),
          replyCount: 3,
        ),
        (
          rootId: 'old',
          lastActivity: _now.subtract(const Duration(hours: 25)),
          replyCount: 40,
        ),
      ];
      final live = [
        _summary('a', const Duration(minutes: 10), 2),
        _summary('d', const Duration(hours: 3), 2),
      ];
      final merged = mergeActiveThreads(live, archived, _now);
      expect(
        [for (final t in merged) t.rootId],
        ['a', 'c', 'b', 'd'],
        reason:
            'a 24 hour window, longest thread, newest tie, archive plus live',
      );
      expect(
        merged.first.replyCount,
        8,
        reason: 'archive count beats a short live buffer',
      );
      expect(
        merged.first.lastActivity,
        _now.subtract(const Duration(minutes: 10)),
        reason: 'live activity is newer than the sealed reply',
      );
      expect(
        [for (final t in merged) t.rootId],
        isNot(contains('old')),
        reason: 'a root past the window left',
      );
    });

    test('caps the list at fifty rows', () {
      final archived = [
        for (var i = 0; i < 60; i++)
          (rootId: 'r$i', lastActivity: _now, replyCount: i),
      ];
      expect(mergeActiveThreads(const [], archived, _now), hasLength(50));
    });
  });

  group('mergeThreadMessages', () {
    test('merges archived replies, dedupes by id and adds the root', () {
      final root = _msg('root', 0);
      final archived = [_msg('r1', 1), _msg('r2', 2)];
      final live = [_msg('live', 4), _msg('r2', 2)];
      final saved = [
        TwitchMessage(
          login: 'alice',
          text: 'saved copy',
          messageId: 'r3',
          channel: 'test',
          timestamp: _now.add(const Duration(seconds: 3)),
        ),
      ];
      final merged = mergeThreadMessages(
        live: live,
        saved: saved,
        archived: archived,
        root: root,
      );
      expect(
        [for (final m in merged) m.messageId],
        ['live', 'r3', 'r2', 'r1', 'root'],
        reason: 'newest first, live rows win, root first of the thread',
      );
      expect(
        merged.where((m) => m.messageId == 'r2').single,
        isNot(same(archived.last)),
        reason: 'the archived copy replaced the live row',
      );
    });

    test('leaves the rows alone without archived replies', () {
      final root = _msg('root', 0);
      final live = [_msg('live', 4)];
      expect(
        [
          for (final m in mergeThreadMessages(
            live: live,
            saved: const [],
            archived: const [],
            root: root,
          ))
            m.messageId,
        ],
        ['live'],
      );
    });
  });

  group('mergeUserHistory', () {
    test('pages older rows in and skips ids the live buffer holds', () {
      final live = [_msg('m1', 1), _msg('m2', 2)];
      final seen = {for (final m in live) m.messageId!};
      final page = [_msg('m4', 4), _msg('m3', 3), _msg('m2', 2)];
      final merged = mergeUserHistory(live, page, seen);
      expect(
        [for (final m in merged) m.messageId],
        ['m1', 'm2', 'm3', 'm4'],
        reason: 'oldest first and one row per id',
      );
      expect(merged[1], same(live.last), reason: 'the live row won');
    });
  });
}
