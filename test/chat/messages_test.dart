import 'package:ermchat/chat/channel/messages.dart';
import 'package:ermchat/chat/chat.dart';
import 'package:ermchat/emotes/emote.dart';
import 'package:ermchat/models/twitch_message.dart';
import 'package:flutter_test/flutter_test.dart';

TwitchMessage _live(String id) => TwitchMessage(
  login: 'alice',
  text: 'hello',
  messageId: id,
  channel: 'test',
);

TwitchMessage _reply(String id, String rootId) => TwitchMessage(
  login: 'bob',
  text: 'reply $id',
  messageId: id,
  channel: 'test',
  replyToParentId: rootId,
  replyThreadRootId: rootId,
);

void main() {
  group('Messages system rows', () {
    List<String> texts(Messages m) => m.items.map((e) => e.text).toList();
    int count(Messages m, String text) =>
        m.items.where((e) => e.text == text).length;

    test('upsert inserts, updates in place, ignores identical text', () {
      final chat = Chat();
      addTearDown(chat.dispose);
      final messages = chat.ensure('test').messages;
      expect(messages.upsertSystem('~14s', messageId: 'wait'), isTrue);
      expect(messages.upsertSystem('~13s', messageId: 'wait'), isTrue);
      expect(texts(messages), ['~13s'], reason: 'ticks update, never stack');
      expect(messages.upsertSystem('~13s', messageId: 'wait'), isFalse);

      messages.addSystem('Connected');
      expect(messages.removeSystem('wait'), isTrue);
      expect(texts(messages), ['Connected']);
      expect(messages.removeSystem('wait'), isFalse);
    });

    test('addSystem inserts at the top with a generated id', () {
      final chat = Chat();
      addTearDown(chat.dispose);
      final messages = chat.ensure('test').messages;
      expect(messages.addSystem('Connected'), isTrue);
      expect(messages.addSystem('hello'), isTrue);
      expect(texts(messages), ['hello', 'Connected']);
      expect(messages.items.first.isSystem, isTrue);
      expect(messages.items.first.messageId, startsWith('sys_'));
    });

    test('reconnect markers fold into a single Reconnected line', () {
      final chat = Chat();
      addTearDown(chat.dispose);
      final messages = chat.ensure('test').messages;
      messages.addSystem('Connected');
      messages.addSystem('Disconnected');
      messages.addSystem('Chat reconnecting...');
      expect(messages.addSystem('Connected'), isTrue);
      expect(texts(messages), ['Reconnected', 'Connected']);

      // A second socket reporting recovery, more cycles and interleaved system
      // rows must not stack lines.
      expect(messages.addSystem('Reconnected'), isFalse);
      for (var i = 0; i < 3; i++) {
        messages.addSystem('Disconnected');
        messages.addSystem('Connected');
        messages.addSystem('Chat reconnecting...');
        messages.addSystem('Reconnected');
        messages.addSystem('Joined #test.');
      }
      expect(count(messages, 'Reconnected'), 1);
      expect(count(messages, 'Disconnected'), 0);

      final other = Chat();
      addTearDown(other.dispose);
      final open = other.ensure('test').messages;
      open.addSystem('Disconnected');
      expect(open.addSystem('Chat reconnecting...'), isFalse);
      expect(texts(open), ['Disconnected']);
    });

    test('recoveries fold inside the window and split beyond it', () {
      var at = DateTime(2026, 1, 1, 12);
      final chat = Chat(now: () => at);
      addTearDown(chat.dispose);
      final messages = chat.ensure('test').messages;
      messages.addSystem('Connected');
      for (var i = 0; i < 5; i++) {
        messages.addSystem('Chat reconnecting...');
        messages.addSystem('Reconnected');
        // Chat between flaps must not defeat the fold inside the window.
        messages.add(_live('m$i'), maxMessages: 100);
        at = at.add(const Duration(seconds: 3));
      }
      expect(count(messages, 'Reconnected'), 1);

      at = at.add(const Duration(seconds: 31));
      messages.addSystem('Disconnected');
      expect(messages.addSystem('Reconnected'), isTrue);
      expect(count(messages, 'Reconnected'), 2);
      expect(count(messages, 'Disconnected'), 0);
      // Rows render through a tile cache keyed by id: a shared id drew the
      // older Reconnected line with the newer one's timestamp.
      final ids = messages.items
          .where((e) => e.text == 'Reconnected')
          .map((e) => e.messageId)
          .toSet();
      expect(ids, hasLength(2), reason: 'each Reconnected row owns its id');
    });

    test('messageId and id-less dedup', () {
      final chat = Chat();
      addTearDown(chat.dispose);
      final messages = chat.ensure('test').messages;
      expect(messages.addSystem('subbed!', messageId: 'n1:label'), isTrue);
      expect(messages.addSystem('subbed!', messageId: 'n1:label'), isFalse);
      expect(messages.addSystem('subbed!', messageId: 'n2:label'), isTrue);
      expect(messages.items, hasLength(2));

      // The same delivery arriving twice (both sockets, server resend).
      expect(messages.addSystem('slow mode'), isTrue);
      expect(messages.addSystem('slow mode'), isFalse);
      expect(messages.addSystem('slow mode', messageId: 'n3:label'), isTrue);
      expect(messages.items, hasLength(4));
    });

    test('label id never collides with the child message id', () {
      final chat = Chat();
      addTearDown(chat.dispose);
      final channel = chat.ensure('test');
      expect(
        channel.messages.addSystem('Announcement', messageId: 'n1:label'),
        isTrue,
      );
      final child = TwitchMessage(
        login: 'mm2pl',
        text: 'hello',
        messageId: 'n1',
        channel: 'test',
      );
      expect(
        channel
            .receive(child, maxMessages: 10, isSelected: true, ownLogin: null)
            .inserted,
        isTrue,
        reason: 'the child chat message owns the raw id and must coexist',
      );
      expect(channel.messages.items, hasLength(2));
    });
  });

  group('Messages.add', () {
    test('inserts bump version while duplicates are quiet no-ops', () {
      final chat = Chat();
      addTearDown(chat.dispose);
      final channel = chat.ensure('test');
      final before = channel.messages.version.value;
      final first = channel.receive(
        _live('m1'),
        maxMessages: 10,
        isSelected: true,
        ownLogin: null,
      );
      expect(first.inserted, isTrue);
      expect(channel.messages.items.first.messageId, 'm1');
      expect(channel.messages.version.value, before + 1);

      final dup = channel.receive(
        _live('m1'),
        maxMessages: 10,
        isSelected: true,
        ownLogin: null,
      );
      expect(dup.inserted, isFalse);
      expect(channel.messages.items, hasLength(1));
      expect(channel.messages.version.value, before + 1);
    });

    test('user deletes emit only the affected ids', () {
      final messages = Messages(channel: 'test');
      addTearDown(messages.dispose);
      messages.add(_live('m1'), maxMessages: 100);
      messages.add(_live('m2'), maxMessages: 100);
      messages.add(
        TwitchMessage(
          login: 'bob',
          text: 'hello',
          messageId: 'm3',
          channel: 'test',
        ),
        maxMessages: 100,
      );
      final emitted = <String?>[];
      var allCount = 0;
      messages.mutations.addListener(emitted.add);
      messages.mutations.addAllListener(() => allCount++);

      final before = messages.version.value;
      expect(messages.markUserDeleted('alice'), isTrue);

      expect(messages.version.value, before + 1);
      expect(allCount, 0);
      expect(emitted, ['m2', 'm1']);

      messages.markAllDeleted();
      expect(messages.version.value, before + 2);
      expect(allCount, 1);
      expect(emitted, ['m2', 'm1']);
    });

    test('saved and pinned rows survive the cap through lazy exemptions', () {
      var t = DateTime(2026, 1, 1);
      final messages = Messages(channel: 'test', now: () => t);
      addTearDown(messages.dispose);
      var builds = 0;
      TruncateExemptions build() {
        builds++;
        return const TruncateExemptions(
          savedRootIds: {'r1'},
          pinnedMessageIds: {'c3'},
        );
      }

      messages.add(_live('lone'), maxMessages: 2, buildExemptions: build);
      expect(builds, 0);

      for (final m in [
        _live('r1'),
        _reply('c1', 'r1'),
        _reply('c2', 'r1'),
        _live('r2'),
        _reply('c3', 'r2'),
        _live('s1'),
        _live('s2'),
        _live('s3'),
      ]) {
        t = t.add(const Duration(seconds: 1));
        messages.add(m, maxMessages: 2, buildExemptions: build);
      }

      expect(builds, greaterThan(0));
      for (final id in ['r1', 'c1', 'c2', 'r2', 'c3', 's3', 's2']) {
        expect(messages.byId(id), isNotNull, reason: id);
      }
      expect(messages.byId('s1'), isNull);
      expect(messages.byId('lone'), isNull);
      expect(
        messages.chatRows.map((m) => m.messageId),
        ['s3', 's2'],
        reason: 'thread rows held past the cap show in the chat',
      );
    });
  });

  group('Messages.truncate coalescing', () {
    test('coalesce window is per channel', () {
      var t = DateTime(2026, 1, 1);
      DateTime now() => t;
      final a = Messages(channel: 'a', now: now);
      final b = Messages(channel: 'b', now: now);
      addTearDown(a.dispose);
      addTearDown(b.dispose);
      TwitchMessage filler(String id, String channel) => TwitchMessage(
        login: 'z',
        text: 'filler $id',
        messageId: id,
        channel: channel,
      );

      for (var i = 0; i < 6; i++) {
        a.add(filler('a$i', 'a'), maxMessages: 5);
      }
      expect(a.items.length, 5);
      // Same instant: b still gets its own pass instead of sharing a's timer.
      for (var i = 0; i < 6; i++) {
        b.add(filler('b$i', 'b'), maxMessages: 5);
      }
      expect(b.items.length, 5);
      // Immediate repeat on a is coalesced away: over budget, no pass runs.
      a.add(filler('a6', 'a'), maxMessages: 5);
      expect(a.items.length, 6);
      // Past the window the next add truncates again.
      t = t.add(const Duration(seconds: 1));
      a.add(filler('a7', 'a'), maxMessages: 5);
      expect(a.items.length, 5);
    });
  });

  group('Messages.truncate fast path', () {
    test('plain buffers keep the newest rows and prune evicted ids', () {
      var t = DateTime(2026, 1, 1);
      final m = Messages(channel: 'a', now: () => t);
      addTearDown(m.dispose);
      for (var i = 0; i < 8; i++) {
        m.add(_live('m$i'), maxMessages: 5);
        t = t.add(const Duration(seconds: 1));
      }
      expect(m.items.map((e) => e.messageId).toList(), [
        'm7',
        'm6',
        'm5',
        'm4',
        'm3',
      ]);
      expect(m.containsId('m7'), isTrue);
      expect(m.containsId('m2'), isFalse);
    });

    test('a reply row takes the thread-aware path and keeps order', () {
      var t = DateTime(2026, 1, 1);
      final m = Messages(channel: 'a', now: () => t);
      addTearDown(m.dispose);
      m.add(_live('root'), maxMessages: 4);
      m.add(_reply('r1', 'root'), maxMessages: 4);
      for (var i = 0; i < 4; i++) {
        m.add(_live('f$i'), maxMessages: 4);
        t = t.add(const Duration(seconds: 1));
      }
      expect(m.items.length, 4);
      expect(m.items.first.messageId, 'f3');
      expect(m.containsId('r1'), isFalse);
    });
  });

  group('Messages.mergeHistory', () {
    test('rows evicted by the merge are not reported as inserted', () {
      final chat = Chat();
      addTearDown(chat.dispose);
      final channel = chat.ensure('test');
      for (final id in ['l1', 'l2', 'l3']) {
        channel.receive(
          _live(id),
          maxMessages: 3,
          isSelected: true,
          ownLogin: null,
        );
      }
      final root = TwitchMessage(
        login: 'bob',
        text: 'root',
        messageId: 'h0',
        channel: 'test',
        timestamp: DateTime(2026, 1, 1),
      );
      final reply = TwitchMessage(
        login: 'bob',
        text: 'reply',
        messageId: 'h1',
        channel: 'test',
        replyToParentId: 'h0',
        replyThreadRootId: 'h0',
        timestamp: DateTime(2026, 1, 1, 0, 0, 1),
      );

      chat.receiveHistory(
        'test',
        [root, reply],
        rawHistory: [root, reply],
        maxMessages: 3,
        ownLogin: null,
      );

      // The older history rows fell off the cap, so the thread index must not
      // keep a thread that references rows no longer in the buffer.
      expect(channel.messages.byId('h0'), isNull);
      expect(channel.threads.threadFor('h0'), isNull);
      expect(channel.messages.length, 3);
    });
  });

  group('status lines are id-keyed', () {
    test('connect and loading rows are found by id after a rename', () {
      final chat = Chat();
      addTearDown(chat.dispose);
      final channel = chat.ensure('test');
      final messages = channel.messages;
      messages.addSystem('Connected');
      messages.addSystem('hello');
      // A copy change must not break the lookup: identity is the stable id.
      messages.items.last.text = 'Renamed';
      expect(messages.moveConnectedToTop(), isTrue);
      expect(messages.items.first.text, 'Renamed');

      final loading = chat.ensure('loading');
      loading.addLoadingHistory();
      loading.messages.items.first.text = 'Renamed';
      expect(loading.removeLoadingHistory(), isTrue);
      expect(loading.messages.items, isEmpty);
    });
  });

  group('Messages.restampPartialEmotes', () {
    TwitchMessage row(
      String id,
      String text, {
      List<EmoteToken>? tokens = const [],
      bool partial = true,
      bool history = false,
    }) =>
        TwitchMessage(
            login: 'alice',
            text: text,
            messageId: id,
            channel: 'test',
            isHistory: history,
          )
          ..emoteTokens = tokens
          ..emotesPartial = partial;

    EmoteToken token(String id, String code, int start) => EmoteToken(
      emote: Emote(
        id: id,
        code: code,
        meta: const SevenTvMeta(),
        scales: {EmoteScale.medium: 'https://example.com/$id.png'},
      ),
      text: code,
      start: start,
      end: start + code.length,
    );

    ({List<EmoteToken>? tokens, bool complete}) parsed(
      List<EmoteToken> tokens, {
      bool complete = true,
    }) => (tokens: tokens, complete: complete);

    test('heals partial rows by adding emotes only', () {
      final messages = Messages(channel: 'test');
      addTearDown(messages.dispose);
      final a = token('a', 'Alpha', 0);
      final b = token('b', 'Beta', 6);
      // Baked before the channel set: live and history rows both heal.
      final live = row('live', 'Alpha Beta', tokens: [a]);
      final history = row('hist', 'Alpha Beta', history: true);
      // The reparse lost Alpha (removed since): the row keeps what it shows.
      final removed = row('gone', 'Alpha Beta', tokens: [a]);
      // Baked against a complete catalog: frozen.
      final frozen = row('frozen', 'Alpha Beta', partial: false);
      final system =
          TwitchMessage(
              login: '',
              text: 'Alpha Beta',
              messageId: 'sys',
              channel: 'test',
              isSystem: true,
            )
            ..emoteTokens = const []
            ..emotesPartial = true;
      for (final m in [live, history, removed, frozen, system]) {
        messages.add(m, maxMessages: 100);
      }
      final emitted = <String?>[];
      messages.mutations.addListener(emitted.add);
      final before = messages.version.value;

      final count = messages.restampPartialEmotes(
        (msg) => msg.messageId == 'gone' ? parsed([b]) : parsed([a, b]),
      );

      expect(count, 2);
      expect(live.emoteTokens, [a, b]);
      expect(history.emoteTokens, [a, b]);
      expect(removed.emoteTokens, [a], reason: 'healing never drops');
      expect(frozen.emoteTokens, isEmpty);
      expect(system.emoteTokens, isEmpty);
      expect(
        [live, history, removed].any((m) => m.emotesPartial),
        isFalse,
        reason: 'a complete catalog ends candidacy',
      );
      expect(messages.version.value, before + 1);
      expect(emitted, unorderedEquals(['live', 'hist']));
    });

    test('an incomplete catalog keeps the row a candidate', () {
      final messages = Messages(channel: 'test');
      addTearDown(messages.dispose);
      final m = row('m1', 'Alpha');
      messages.add(m, maxMessages: 100);
      final before = messages.version.value;

      expect(
        messages.restampPartialEmotes((_) => parsed([], complete: false)),
        0,
      );
      expect(m.emotesPartial, isTrue);
      expect(messages.version.value, before);
    });

    test('an id-less healed row evicts the whole channel', () {
      final messages = Messages(channel: 'test');
      addTearDown(messages.dispose);
      final idless =
          TwitchMessage(login: 'alice', text: 'Alpha', channel: 'test')
            ..emoteTokens = const []
            ..emotesPartial = true;
      messages.add(idless, maxMessages: 100);
      var allCount = 0;
      messages.mutations.addAllListener(() => allCount++);

      expect(
        messages.restampPartialEmotes((_) => parsed([token('a', 'Alpha', 0)])),
        1,
      );
      expect(idless.emoteTokens, hasLength(1));
      expect(allCount, 1);
    });
  });
}
