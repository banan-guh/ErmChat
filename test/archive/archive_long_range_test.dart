import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:ermchat/archive/archive_block.dart';
import 'package:ermchat/archive/archive_row.dart';
import 'package:ermchat/models/twitch_badge.dart';
import 'package:ermchat/models/twitch_message.dart';
import 'package:ermchat/services/archive_reader.dart';
import 'package:ermchat/services/archive_store.dart';
import 'package:ermchat/services/archive_writer.dart';
import 'package:ermchat/util/chat_search.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _NoTimer implements Timer {
  @override
  void cancel() {}
  @override
  bool get isActive => false;
  @override
  int get tick => 0;
}

/// One simulated channel: messages a day, share of new chatters, and the
/// days it is joined.
class _Chan {
  _Chan(this.name, this.perDay, this.newRate, {this.untilDay});
  final String name;
  final int perDay;
  final double newRate;
  final int? untilDay;
  final pool = <int>[];
  final subSince = <int, int>{};
  final recent = <String>[];
  var nextUser = 0;
}

/// Months of synthetic chat over three channels through the real writer,
/// store and upkeep, with restarts, edits, moderation, pins, streams and a
/// retention change. Every 15 days it checks invariants on a cold copy and
/// prints table sizes. Opt in: `SIM_DAYS=180 flutter test <this file>`
/// (`SIM_SCALE` scales the message rates).
void main() {
  sqfliteFfiInit();
  test(
    'archive stays bounded and consistent over months',
    () async {
      final days = int.parse(Platform.environment['SIM_DAYS'] ?? '0');
      final scale = double.parse(Platform.environment['SIM_SCALE'] ?? '1');
      final dir = await Directory.systemTemp.createTemp('archsim');
      final path = '${dir.path}/archive.db';
      final t0 = DateTime.utc(2026, 1, 1);
      final rng = Random(3);
      final chans = [
        _Chan('mid', (10000 * scale).round(), 0.06),
        _Chan('quiet', (200 * scale).round(), 0.2),
        _Chan('left', (5000 * scale).round(), 0.08, untilDay: 20),
      ];
      final problems = <String>[];
      void fail(String p) {
        if (problems.length < 40) problems.add(p);
        // ignore: avoid_print
        print('PROBLEM $p');
      }

      late ArchiveStore store;
      late ArchiveWriter writer;
      Future<void> open() async {
        store = await ArchiveStore.open(
          path,
          factory: databaseFactoryFfi,
          now: () => t0,
        );
        writer = ArchiveWriter(
          Future.value(store),
          createTimer: (_, _) => _NoTimer(),
          encode: (rows) async => ArchiveBlock.encode(rows),
        );
      }

      await open();
      final probe = await databaseFactoryFfi.openDatabase(
        path,
        options: OpenDatabaseOptions(singleInstance: false),
      );
      Future<int> one(String sql, [List<Object?>? args]) async =>
          (await probe.rawQuery(sql, args)).first.values.first as int? ?? 0;

      final baseWords = List.generate(20000, (i) => 'w${i.toRadixString(36)}');
      String word() {
        if (rng.nextDouble() < 0.03) {
          // Novel tokens: numbers, typos, link fragments.
          return rng.nextInt(1 << 31).toRadixString(36);
        }
        return baseWords[(pow(rng.nextDouble(), 3) * baseWords.length).floor()];
      }

      var msgNo = 0;
      // Planted rows: (channel, unique word, time) the archive must find while
      // inside retention.
      final planted = <(String, String, DateTime)>[];
      final pinFrom = t0.add(const Duration(days: 10)).millisecondsSinceEpoch;
      final pinTo = pinFrom + 86400000 - 1;
      var pinned = false;
      var retentionDays = 30;
      var floor = 0;

      Future<void> upkeep(DateTime now) async {
        floor = max(
          floor,
          now.subtract(Duration(days: retentionDays)).millisecondsSinceEpoch,
        );
        await writer.flush();
        await store.prune(now);
        await store.compact(now);
        await store.backfillRefs();
        await store.bakeEdits(held: writer.heldIds);
        await store.strip(now);
        await store.backfillWords();
        await store.pruneUsers(held: writer.heldStates);
        await store.pruneVocab();
        await store.reclaimSpace();
      }

      Future<void> check(DateTime now, int day) async {
        // The newest cutoff any prune applied: shortening retention deletes
        // rows that lengthening it later cannot bring back.
        final cutoff = floor = max(
          floor,
          now.subtract(Duration(days: retentionDays)).millisecondsSinceEpoch,
        );
        // Cold reopen of a copy: what a restart sees.
        final copy = '${dir.path}/cold$day.db';
        await probe.rawQuery('PRAGMA wal_checkpoint(FULL)');
        await File(path).copy(copy);
        if (File('$path-wal').existsSync()) {
          await File('$path-wal').copy('$copy-wal');
        }
        final cold = await ArchiveStore.open(
          copy,
          factory: databaseFactoryFfi,
          now: () => t0,
        );
        final coldReader = ArchiveReader(Future.value(cold));
        for (final c in chans) {
          final t = await cold.tables(c.name);
          final blocks = await probe.rawQuery(
            'SELECT id, start_ts, end_ts, count, data FROM blocks '
            'WHERE channel = ?',
            [c.name],
          );
          final ids = <String>{};
          final named = <int>{};
          var recentRows = 0;
          for (final b in blocks) {
            final List<ArchiveRow> rows;
            try {
              rows = ArchiveBlock.decode(b['data']! as Uint8List);
            } on Object catch (e) {
              fail('day $day ${c.name}: block ${b['id']} fails to decode: $e');
              continue;
            }
            if (rows.length != b['count']) {
              fail('day $day ${c.name}: block count ${b['count']} != rows');
            }
            final end = b['end_ts']! as int;
            final isPinned = end >= pinFrom && (b['start_ts']! as int) <= pinTo;
            if (end < cutoff && !(pinned && isPinned)) {
              fail('day $day ${c.name}: block past retention kept');
            }
            for (final r in rows) {
              named.add(r.user);
              final s = t.states[r.user];
              if (s == null ||
                  t.whos[s.who] == null ||
                  t.looks[s.look] == null) {
                fail('day $day ${c.name}: row names pruned user ${r.user}');
              }
              final id = r.messageId;
              if (id != null && !ids.add(id)) {
                fail('day $day ${c.name}: id $id stored twice');
              }
              if (r.timestampMs >= cutoff) recentRows++;
            }
          }
          if (named.length < t.states.length - 64) {
            fail(
              'day $day ${c.name}: tables hold ${t.states.length} states, '
              'blocks name ${named.length}',
            );
          }
          final counted = await one(
            'SELECT sum(count) FROM minute_counts WHERE channel = ? '
            'AND minute >= ?',
            [c.name, cutoff ~/ 60000 + 1],
          );
          final rowsAfter = [
            for (final b in blocks)
              ...() {
                try {
                  return ArchiveBlock.decode(b['data']! as Uint8List);
                } on Object {
                  return <ArchiveRow>[];
                }
              }(),
          ].where((r) => r.timestampMs ~/ 60000 >= cutoff ~/ 60000 + 1).length;
          if (counted != rowsAfter) {
            fail(
              'day $day ${c.name}: minute counts $counted vs rows $rowsAfter '
              '(recent $recentRows)',
            );
          }
          final newest = await coldReader.newestRows(c.name, 600);
          for (var i = 1; i < newest.length; i++) {
            if (newest[i].timestamp.isBefore(newest[i - 1].timestamp)) {
              fail('day $day ${c.name}: newest rows out of order');
              break;
            }
          }
          if (newest.any((m) => !m.isSystem && m.login.isEmpty)) {
            fail('day $day ${c.name}: newest rows lost their user');
          }
        }
        for (final (ch, w, at) in planted) {
          if (at.millisecondsSinceEpoch < cutoff + 3600000) continue;
          final found = await coldReader.search(
            ch,
            w,
            scope: ChatSearchScope.all,
          );
          if (!found.any((m) => m.text.contains(w))) {
            fail('day $day $ch: search misses $w from ${at.toIso8601String()}');
          }
        }
        await cold.close();
        await File(copy).delete();
      }

      final lines = <String>[];
      for (var day = 0; day < days; day++) {
        if (day > 0 && day % 7 == 0) {
          // Restart: the writer seals, the store closes, both reopen.
          await writer.dispose();
          await open();
        }
        if (day == 10) {
          await store.addPin('mid', pinFrom, pinTo, ArchiveReader.dayPin);
          pinned = true;
        }
        if (day == 100) {
          retentionDays = 7;
          ArchiveStore.retention = const Duration(days: 7);
        }
        if (day == 115) {
          retentionDays = 30;
          ArchiveStore.retention = const Duration(days: 30);
        }
        final dayStart = t0.add(Duration(days: day));
        // A daily 4h stream on mid; an eternal one on quiet; left parts live.
        await store.putStream(
          channel: 'mid',
          id: 'mid-$day',
          startedTs: dayStart
              .add(const Duration(hours: 18))
              .millisecondsSinceEpoch,
        );
        await store.endStream(
          'mid-$day',
          dayStart.add(const Duration(hours: 22)).millisecondsSinceEpoch,
        );
        if (day == 0) {
          await store.putStream(
            channel: 'quiet',
            id: 'eternal',
            startedTs: t0.millisecondsSinceEpoch,
          );
        }
        if (day == 19) {
          await store.putStream(
            channel: 'left',
            id: 'left-live',
            startedTs: dayStart.millisecondsSinceEpoch,
          );
        }
        final events = <(DateTime, _Chan, int)>[
          for (final c in chans)
            if (c.untilDay == null || day < c.untilDay!)
              for (var i = 0; i < c.perDay; i++)
                (
                  dayStart.add(
                    Duration(milliseconds: i * 86400000 ~/ max(1, c.perDay)),
                  ),
                  c,
                  i,
                ),
        ]..sort((a, b) => a.$1.compareTo(b.$1));
        var nextUpkeep = dayStart.add(const Duration(hours: 6));
        for (final (ts, c, i) in events) {
          if (!ts.isBefore(nextUpkeep)) {
            await upkeep(nextUpkeep);
            nextUpkeep = nextUpkeep.add(const Duration(hours: 6));
          }
          int user;
          if (c.pool.isEmpty || rng.nextDouble() < c.newRate) {
            user = c.nextUser++;
            if (rng.nextDouble() < 0.3) c.pool.add(user);
            if (rng.nextDouble() < 0.3) c.subSince[user] = day;
          } else {
            user = c.pool[(pow(rng.nextDouble(), 2) * c.pool.length).floor()];
          }
          final badges = <MessageBadge>[
            if (c.subSince[user] case final since?)
              MessageBadge(
                setId: 'subscriber',
                versionId: '${(day - since) ~/ 30}',
              ),
            if (day % 3 == 0 && user % 10 == 0)
              MessageBadge(setId: 'predictions', versionId: 'blue-${day ~/ 3}'),
          ];
          final id = 'id-${msgNo++}';
          final reply = c.recent.isNotEmpty && rng.nextDouble() < 0.05
              ? c.recent[rng.nextInt(c.recent.length)]
              : null;
          var text = List.generate(1 + rng.nextInt(8), (_) => word()).join(' ');
          if (i == c.perDay ~/ 2 && c.perDay > 0) {
            final mark = 'zzmark${c.name}$day';
            text = '$text $mark';
            planted.add((c.name, mark, ts));
          }
          writer.add(
            c.name,
            TwitchMessage(
              login: 'user$user',
              userId: '${c.name}$user',
              text: text,
              messageId: id,
              channel: c.name,
              color: '#${(user * 2654435761 % 0xFFFFFF).toRadixString(16)}',
              timestamp: ts,
              badges: badges,
              replyToParentId: reply,
              replyThreadRootId: reply,
            ),
          );
          c.recent.add(id);
          if (c.recent.length > 200) c.recent.removeAt(0);
          // Moderation: deletes of fresh and of old rows, a few a day.
          if (rng.nextDouble() < 0.0005 && c.recent.length > 100) {
            await writer.recordEdits(c.name, [
              c.recent[rng.nextInt(100)],
            ], rng.nextBool() ? ArchiveEdit.remove : ArchiveEdit.deleted);
          }
          if (rng.nextDouble() < 0.0002) {
            await store.addModeration(
              c.name,
              'user$user',
              ts.subtract(const Duration(hours: 1)).millisecondsSinceEpoch,
              ts.millisecondsSinceEpoch,
            );
          }
        }
        final end = dayStart.add(const Duration(days: 1));
        await upkeep(end);
        if ((day + 1) % 15 == 0 || day + 1 == days) {
          await check(end, day + 1);
          final pageSize = await one('PRAGMA page_size');
          final pages = await one('PRAGMA page_count');
          final free = await one('PRAGMA freelist_count');
          final t = await store.tables('mid');
          final tl = await store.tables('left');
          final streams = await probe.rawQuery(
            'SELECT stream_id, ended_at FROM streams '
            "WHERE stream_id IN ('eternal', 'left-live')",
          );
          lines.add(
            'day ${day + 1}: '
            'blocks ${await one('SELECT count(*) FROM blocks')} '
            '(${(await one('SELECT sum(length(data)) FROM blocks')) ~/ 1024} KB), '
            'mid states ${t.states.length} whos ${t.whos.length} '
            'looks ${t.looks.length}, left states ${tl.states.length}, '
            'ref_ids ${await one('SELECT count(*) FROM ref_ids')}, '
            'edits ${await one('SELECT count(*) FROM edits')}, '
            'vocab ${(await one('SELECT sum(length(words)) FROM vocab')) ~/ 1024} KB '
            '(${await one('SELECT count(*) FROM vocab')} rows), '
            'file ${pages * pageSize ~/ 1024} KB free ${free * pageSize ~/ 1024} KB, '
            'streams ${[for (final s in streams) '${s['stream_id']}=${s['ended_at'] == null ? 'open' : 'ended'}'].join(' ')}',
          );
          // ignore: avoid_print
          print(lines.last);
        }
      }
      await writer.dispose();
      await probe.close();
      await dir.delete(recursive: true);
      expect(problems, isEmpty);
    },
    timeout: const Timeout(Duration(minutes: 60)),
    skip: Platform.environment['SIM_DAYS'] == null,
  );
}
