import 'package:ermchat/chat/channel/messages.dart';
import 'package:ermchat/chat/chat.dart';
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
  group('Messages.upsertSystem', () {
    test(
      'inserts when the id is new, updates in place afterwards and treats identical text as a no-op',
      () {
        final chat = Chat();
        addTearDown(chat.dispose);
        final messages = chat.ensure('test').messages;
        expect(
          messages.upsertSystem(
            'Joining · position 12 · ~14s',
            messageId: 'join_wait_test',
          ),
          isTrue,
        );
        expect(
          messages.upsertSystem(
            'Joining · position 12 · ~13s',
            messageId: 'join_wait_test',
          ),
          isTrue,
        );

        expect(
          messages.items,
          hasLength(1),
          reason: 'ticks update, never stack',
        );
        expect(messages.items.first.text, 'Joining · position 12 · ~13s');
        expect(messages.items.first.messageId, 'join_wait_test');

        expect(messages.upsertSystem('same', messageId: 'id1'), isTrue);
        expect(
          messages.upsertSystem('same', messageId: 'id1'),
          isFalse,
          reason: 'identical text is a no-op',
        );
      },
    );

    test('removeSystem drops only the matching row', () {
      final chat = Chat();
      addTearDown(chat.dispose);
      final messages = chat.ensure('test').messages;
      messages.addSystem('Connected');
      messages.upsertSystem('Joining', messageId: 'wait');

      expect(messages.removeSystem('wait'), isTrue);
      expect(messages.items.map((m) => m.text).toList(), ['Connected']);
      expect(messages.removeSystem('wait'), isFalse);
      expect(chat.channelFor('missing'), isNull);
    });
  });

  group('Messages.addSystem', () {
    test('inserts at the top of the buffer', () {
      final chat = Chat();
      addTearDown(chat.dispose);
      final messages = chat.ensure('test').messages;
      expect(messages.addSystem('Connected'), isTrue);
      expect(messages.addSystem('hello'), isTrue);

      expect(messages.items.first.text, 'hello');
      expect(messages.items.last.text, 'Connected');
      expect(messages.items.first.isSystem, isTrue);
      expect(messages.items.first.messageId, startsWith('sys_'));
    });

    test('second Connected becomes Reconnected', () {
      final chat = Chat();
      addTearDown(chat.dispose);
      final messages = chat.ensure('test').messages;
      messages.addSystem('Connected');
      messages.addSystem('Disconnected');
      messages.addSystem('Connected');

      expect(
        messages.items.map((m) => m.text).toList(),
        contains('Reconnected'),
      );
    });

    test(
      'Reconnected folds transient markers, dedups itself and suppresses the reconnecting marker while Disconnected is present',
      () {
        final chat = Chat();
        addTearDown(chat.dispose);
        final messages = chat.ensure('test').messages;
        messages.addSystem('Disconnected');
        messages.addSystem('Chat reconnecting...');
        expect(messages.addSystem('Reconnected'), isTrue);

        expect(messages.items.map((m) => m.text).toList(), ['Reconnected']);

        // The second socket reporting recovery must not stack a line.
        expect(messages.addSystem('Reconnected'), isFalse);
        expect(messages.items, hasLength(1));

        final suppressed = Chat();
        addTearDown(suppressed.dispose);
        final suppressedMessages = suppressed.ensure('test').messages;
        suppressedMessages.addSystem('Disconnected');
        expect(suppressedMessages.addSystem('Chat reconnecting...'), isFalse);
        expect(suppressedMessages.items.map((m) => m.text), ['Disconnected']);
      },
    );

    test(
      'messageId dedup skips a repeat insert while distinct ids with identical text both insert',
      () {
        final table = [
          ('repeat id is skipped', 'n1:label', 'n1:label', false, 1),
          ('distinct id inserts', 'n1:label', 'n2:label', true, 2),
        ];
        for (final (label, firstId, secondId, secondResult, count) in table) {
          final chat = Chat();
          addTearDown(chat.dispose);
          final messages = chat.ensure('test').messages;
          expect(
            messages.addSystem('ronni subscribed!', messageId: firstId),
            isTrue,
            reason: label,
          );
          expect(
            messages.addSystem('ronni subscribed!', messageId: secondId),
            secondResult ? isTrue : isFalse,
            reason: label,
          );
          expect(messages.items, hasLength(count), reason: label);
        }
      },
    );

    test('identical id-less text within the window inserts once', () {
      final chat = Chat();
      addTearDown(chat.dispose);
      final messages = chat.ensure('test').messages;
      expect(messages.addSystem('This room is now in slow mode.'), isTrue);
      // Same delivery arriving twice (both sockets, server resend).
      expect(messages.addSystem('This room is now in slow mode.'), isFalse);
      expect(messages.items, hasLength(1));
      // Labeled rows keep their id dedup and still insert alongside.
      expect(
        messages.addSystem(
          'This room is now in slow mode.',
          messageId: 'n1:label',
        ),
        isTrue,
      );
      expect(messages.items, hasLength(2));
    });

    test('label id never collides with the child message id', () {
      final chat = Chat();
      addTearDown(chat.dispose);
      final channel = chat.ensure('test');
      expect(
        channel.messages.addSystem('Announcement', messageId: 'n1:label'),
        isTrue,
      );
      expect(
        channel
            .receive(
              TwitchMessage(
                login: 'mm2pl',
                text: 'hello',
                messageId: 'n1',
                channel: 'test',
              ),
              maxMessages: 10,
              isSelected: true,
              ownLogin: null,
            )
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

    test('mass deletes bump once and emit one emitAll', () {
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
      expect(allCount, 1);
      expect(emitted, isEmpty);

      messages.markAllDeleted();
      expect(messages.version.value, before + 2);
      expect(allCount, 2);
      expect(emitted, isEmpty);
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

  group('status lines are id-keyed', () {
    test('moveConnectedToTop finds a renamed connect row by id', () {
      final chat = Chat();
      addTearDown(chat.dispose);
      final messages = chat.ensure('test').messages;
      messages.addSystem('Connected');
      messages.addSystem('hello');
      // A copy change must not break the lookup: identity is the stable id.
      messages.items.last.text = 'Renamed';
      expect(messages.moveConnectedToTop(), isTrue);
      expect(messages.items.first.text, 'Renamed');
    });

    test('removeLoadingHistory removes a renamed loading row by id', () {
      final chat = Chat();
      addTearDown(chat.dispose);
      final channel = chat.ensure('test');
      channel.addLoadingHistory();
      channel.messages.items.first.text = 'Renamed';
      expect(channel.removeLoadingHistory(), isTrue);
      expect(channel.messages.items, isEmpty);
    });
  });
}
