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

    test('addSystemAt lands by timestamp and dedups by id', () {
      final chat = Chat();
      addTearDown(chat.dispose);
      final messages = chat.ensure('test').messages;
      final t = DateTime.utc(2026, 1, 1, 12);
      TwitchMessage at(String id, int min) => TwitchMessage(
        login: 'a',
        text: id,
        messageId: id,
        channel: 'test',
        timestamp: t.add(Duration(minutes: min)),
      );
      messages.add(at('old', 0), maxMessages: 100);
      messages.add(at('new', 10), maxMessages: 100);
      final mid = t.add(const Duration(minutes: 5));
      expect(messages.addSystemAt('mid', messageId: 'sys_a', at: mid), isTrue);
      expect(texts(messages), ['new', 'mid', 'old']);
      expect(
        messages.addSystemAt('mid', messageId: 'sys_a', at: t),
        isFalse,
        reason: 'a repeated id never stacks',
      );
      expect(texts(messages), hasLength(3));
    });

    test('reconnect markers fold into a single Reconnected line', () {
      final chat = Chat();
      addTearDown(chat.dispose);
      final messages = chat.ensure('test').messages;
      messages.addConnStatus(SystemLine.connected);
      messages.addConnStatus(SystemLine.disconnected);
      messages.addConnStatus(SystemLine.reconnecting);
      expect(messages.addConnStatus(SystemLine.connected), isTrue);
      expect(texts(messages), ['reconnected', 'connected']);

      // A second socket reporting recovery, more cycles and interleaved system
      // rows must not stack lines.
      expect(messages.addConnStatus(SystemLine.reconnected), isFalse);
      for (var i = 0; i < 3; i++) {
        messages.addConnStatus(SystemLine.disconnected);
        messages.addConnStatus(SystemLine.connected);
        messages.addConnStatus(SystemLine.reconnecting);
        messages.addConnStatus(SystemLine.reconnected);
        messages.addSystem('Joined #test.');
      }
      expect(count(messages, 'reconnected'), 1);
      expect(count(messages, 'disconnected'), 0);

      final other = Chat();
      addTearDown(other.dispose);
      final open = other.ensure('test').messages;
      open.addConnStatus(SystemLine.disconnected);
      expect(open.addConnStatus(SystemLine.reconnecting), isFalse);
      expect(texts(open), ['disconnected']);
    });

    test('recoveries fold inside the window and split beyond it', () {
      var at = DateTime(2026, 1, 1, 12);
      final chat = Chat(now: () => at);
      addTearDown(chat.dispose);
      final messages = chat.ensure('test').messages;
      messages.addConnStatus(SystemLine.connected);
      for (var i = 0; i < 5; i++) {
        messages.addConnStatus(SystemLine.reconnecting);
        messages.addConnStatus(SystemLine.reconnected);
        // Chat between flaps must not defeat the fold inside the window.
        messages.add(_live('m$i'), maxMessages: 100);
        at = at.add(const Duration(seconds: 3));
      }
      expect(count(messages, 'reconnected'), 1);

      at = at.add(const Duration(seconds: 31));
      messages.addConnStatus(SystemLine.disconnected);
      expect(messages.addConnStatus(SystemLine.reconnected), isTrue);
      expect(count(messages, 'reconnected'), 2);
      expect(count(messages, 'disconnected'), 0);
      // Rows render through a tile cache keyed by id: a shared id drew the
      // older Reconnected line with the newer one's timestamp.
      final ids = messages.items
          .where((e) => e.text == 'reconnected')
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

      messages.truncate(2, build);
      expect(builds, greaterThan(0));
      for (final id in ['r1', 'c1', 'c2', 'r2', 'c3', 's3', 's2']) {
        expect(messages.byId(id), isNotNull, reason: id);
      }
      expect(messages.byId('s1'), isNull);
      expect(messages.byId('lone'), isNull);
      expect(messages.chatRows.map((m) => m.messageId), [
        's3',
        's2',
      ], reason: 'thread rows held past the cap show in the chat');
    });
  });

  group('Messages.truncate slack', () {
    test(
      'live trims wait for slack past the cap and chat never shows more',
      () {
        final m = Messages(channel: 'a');
        addTearDown(m.dispose);
        // Cap 8 gives slack 2: trims run once the buffer holds more than 10.
        for (var i = 0; i < 10; i++) {
          m.add(_live('m$i'), maxMessages: 8);
        }
        expect(
          m.items.length,
          10,
          reason: 'within the slack, a full buffer does not trim per message',
        );
        expect(
          m.chatRows.length,
          8,
          reason: 'rows past the cap are never visible between trims',
        );
        expect(m.chatRows.first.messageId, 'm9');
        m.add(_live('m10'), maxMessages: 8);
        expect(
          m.items.length,
          8,
          reason: 'crossing the slack trims to the cap',
        );
        expect(m.chatRows.length, 8);
      },
    );
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
      m.truncate(5);
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

    test('a fetch reaching back past the newest held row notes no gap', () {
      TwitchMessage row(String? id, int minute) => TwitchMessage(
        login: 'bob',
        text: 'm$minute',
        messageId: id,
        channel: 'test',
        timestamp: DateTime.utc(2026, 1, 1, 0, minute),
      );
      int gaps(Messages m) => m.items.where((r) => r.isSystem).length;
      for (final (name, from, gap) in [
        ('overlap', 2, false),
        ('after', 5, true),
      ]) {
        final chat = Chat();
        addTearDown(chat.dispose);
        final channel = chat.ensure('test');
        // Archived rows older than a day carry no ids.
        final archived = [for (var i = 0; i < 4; i++) row(null, i)];
        chat.receiveHistory(
          'test',
          archived,
          rawHistory: archived,
          maxMessages: 100,
          ownLogin: null,
        );
        final fetched = [for (var i = from; i < from + 4; i++) row('h$i', i)];
        chat.receiveHistory(
          'test',
          fetched,
          rawHistory: fetched,
          maxMessages: 100,
          ownLogin: null,
        );
        expect(gaps(channel.messages), gap ? 1 : 0, reason: name);
      }
    });
  });

  group('history gaps', () {
    TwitchMessage row(String id, int minute) => TwitchMessage(
      login: 'bob',
      text: 'm$minute',
      messageId: id,
      channel: 'test',
      timestamp: DateTime.utc(2026, 1, 1, 0, minute),
    );
    List<TwitchMessage> fetch(int from, int to) => [
      for (var i = from; i < to; i++) row('r$i', i),
    ];
    List<TwitchMessage> merge(Chat chat, List<TwitchMessage> rows) {
      final outcome = chat.receiveHistory(
        'test',
        rows,
        rawHistory: rows,
        maxMessages: 100,
        ownLogin: null,
      );
      return outcome.inserted;
    }

    List<TwitchMessage> notes(Chat chat) => [
      for (final m in chat.channelFor('test')!.messages.items)
        if (m.messageId?.startsWith(Messages.historyGapIdPrefix) ?? false) m,
    ];

    test('a gap note is keyed by its time and returned as inserted', () {
      final chat = Chat();
      addTearDown(chat.dispose);
      chat.ensure('test');
      expect(merge(chat, fetch(0, 4)), hasLength(4));
      final inserted = merge(chat, fetch(10, 14));
      final note = notes(chat).single;
      expect(
        inserted,
        contains(same(note)),
        reason: 'the archive only keeps inserted rows',
      );
      expect(note.isSystem, isTrue);
      expect(
        note.timestamp,
        DateTime.utc(
          2026,
          1,
          1,
          0,
          10,
        ).subtract(const Duration(milliseconds: 1)),
        reason: 'the note sits just before the first fetched row',
      );
      expect(
        note.messageId,
        '${Messages.historyGapIdPrefix}${note.timestamp.millisecondsSinceEpoch}',
      );
    });

    test('gap notes: one per gap, none without held chat', () {
      for (final (name, fetches, want) in [
        ('first fetch into an empty buffer', [(0, 4)], 0),
        ('overlapping fetches', [(0, 4), (2, 8)], 0),
        ('a fetch after a gap', [(0, 4), (10, 14)], 1),
        ('the same late fetch twice', [(0, 4), (10, 14), (10, 14)], 1),
        ('two separate gaps', [(0, 4), (10, 14), (20, 24)], 2),
        ('a later fetch bridging the gap', [(0, 4), (10, 14), (2, 16)], 0),
        (
          'a later fetch bridging one of two gaps',
          [(0, 4), (10, 14), (20, 24), (12, 26)],
          1,
        ),
      ]) {
        final chat = Chat();
        addTearDown(chat.dispose);
        chat.ensure('test');
        for (final (from, to) in fetches) {
          merge(chat, fetch(from, to));
        }
        expect(notes(chat), hasLength(want), reason: name);
      }
    });

    test('a failed fetch notes its gap once per place', () {
      DateTime t(int minute) => DateTime.utc(2026, 1, 1, 0, minute);
      void live(Chat chat, int minute) => chat.receive(
        'test',
        row('c$minute', minute),
        maxMessages: 100,
        isSelected: true,
        ownLogin: null,
      );
      for (final (name, script, want) in [
        ('nothing held yet', [('fail', 5)], <int>[]),
        ('chat before the failure', [('chat', 1), ('fail', 5)], [5]),
        (
          'failing again with no chat between',
          [('chat', 1), ('fail', 5), ('fail', 9), ('fail', 12)],
          [5],
        ),
        (
          'chat between two failures',
          [('chat', 1), ('fail', 5), ('chat', 7), ('fail', 9)],
          [5, 9],
        ),
        (
          'live rows already past the failure point',
          [('chat', 1), ('chat', 6), ('fail', 5)],
          [5],
        ),
        (
          'a fetch gap, then a failure after its rows',
          [('chat', 1), ('chat', 3), ('fetch', 20), ('fail', 30)],
          [19, 30],
        ),
        (
          'a failure, then a fetch that cannot reach back',
          [('chat', 1), ('fail', 5), ('fetch', 20)],
          [5],
        ),
      ]) {
        final chat = Chat();
        addTearDown(chat.dispose);
        chat.ensure('test');
        final messages = chat.channelFor('test')!.messages;
        for (final (step, minute) in script) {
          switch (step) {
            case 'chat':
              live(chat, minute);
            case 'fetch':
              merge(chat, [row('f$minute', minute)]);
            case 'fail':
              messages.noteHistoryGap(t(minute));
          }
        }
        expect(
          [for (final n in notes(chat).reversed) n.timestamp.minute],
          want,
          reason: name,
        );
      }
      // The note sits between the rows it separates, not after live rows.
      final chat = Chat();
      addTearDown(chat.dispose);
      chat.ensure('test');
      live(chat, 1);
      live(chat, 6);
      chat.channelFor('test')!.messages.noteHistoryGap(t(5));
      expect(
        [for (final m in chat.channelFor('test')!.messages.items) m.messageId],
        [
          'c6',
          '${Messages.historyGapIdPrefix}${t(5).millisecondsSinceEpoch}',
          'c1',
        ],
      );
    });

    test('an archived gap note restored on a cold start is not doubled', () {
      final chat = Chat();
      addTearDown(chat.dispose);
      chat.ensure('test');
      merge(chat, fetch(0, 4));
      merge(chat, fetch(10, 14));
      final note = notes(chat).single;
      // The cold start restores what the archive held, note included, and
      // the same network rows arrive again.
      final restored = Chat();
      addTearDown(restored.dispose);
      restored.ensure('test');
      final archived = [
        ...fetch(0, 4),
        TwitchMessage(
          login: '',
          text: note.text,
          isSystem: true,
          messageId: note.messageId,
          channel: 'test',
          timestamp: note.timestamp,
        ),
        ...fetch(10, 14),
      ];
      merge(restored, archived);
      merge(restored, fetch(10, 14));
      expect(notes(restored), hasLength(1));
    });
  });

  group('status lines are id-keyed', () {
    test('connect and loading rows are found by id after a rename', () {
      final chat = Chat();
      addTearDown(chat.dispose);
      final channel = chat.ensure('test');
      final messages = channel.messages;
      messages.addConnStatus(SystemLine.connected);
      messages.addSystem('hello');
      // A copy change must not break the lookup: identity is the stable id.
      messages.items.last.text = 'Renamed';
      expect(messages.moveConnectedToTop(), isTrue);
      expect(messages.items.first.text, 'Renamed');

      // Signed in, the first connect names the account in its one row.
      var account = 'as me';
      final named = Chat(
        systemText: (line) => line == SystemLine.signedIn ? account : line.name,
      );
      addTearDown(named.dispose);
      final rows = named.ensure('test').messages;
      rows.addConnStatus(SystemLine.connected);
      // A newer row lands above it, as history merging in does.
      rows.addSystem('history');
      expect(rows.moveConnectedToTop(), isTrue);
      expect(rows.items.map((m) => m.text), [
        'as me',
        'history',
      ], reason: 'one "connected as" row, kept newest');

      // Busy chat truncated the first Connected away; the next connect
      // must not name the same account again.
      for (var i = 0; i < 300; i++) {
        rows.add(
          TwitchMessage(login: 'a', text: 'm$i', messageId: 'id$i'),
          maxMessages: 100,
        );
      }
      expect(rows.items.where((m) => m.isSystem), isEmpty);
      rows.addConnStatus(SystemLine.connected);
      expect(rows.items.where((m) => m.isSystem).map((m) => m.text), [
        'reconnected',
      ], reason: 'the account line posts once per session');

      // An account switch reconnects right away, inside the fold window.
      account = 'as you';
      rows.addConnStatus(SystemLine.connected);
      rows.addSystem('history');
      expect(rows.moveConnectedToTop(), isTrue);
      expect(rows.items.where((m) => m.isSystem).map((m) => m.text), [
        'as you',
        'history',
      ], reason: 'a switched account names itself in its reconnect row');

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

  group('Messages.mergeMentions', () {
    TwitchMessage at(String id, int sec) => TwitchMessage(
      login: 'alice',
      text: id,
      messageId: id,
      channel: 'test',
      timestamp: DateTime(2026, 1, 1, 0, 0, sec),
    );
    List<String?> ids(Messages m) => m.items.map((e) => e.messageId).toList();

    test('live mentions go on top, ties keep the resident row first', () {
      final m = Messages(channel: '@mentions');
      addTearDown(m.dispose);
      m.mergeMentions([at('a', 1)], maxMessages: 3);
      m.mergeMentions([at('b', 2)], maxMessages: 3);
      m.mergeMentions([at('c', 2)], maxMessages: 3);
      expect(ids(m), ['b', 'c', 'a'], reason: 'tie sorts behind the resident');
      m.mergeMentions([at('b', 5)], maxMessages: 3);
      expect(ids(m), ['b', 'c', 'a'], reason: 'duplicate id is dropped');
      m.mergeMentions([at('d', 3), at('e', 3), at('f', 4)], maxMessages: 4);
      expect(ids(m), ['f', 'd', 'e', 'b'], reason: 'unsorted batch, capped');
      expect(m.containsId('a'), isFalse, reason: 'capped rows leave the map');
    });
  });
}
