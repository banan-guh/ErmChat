import 'package:ermchat/chat/channel/moderation.dart';
import 'package:ermchat/chat/chat.dart';
import 'package:flutter_test/flutter_test.dart';

Moderation _mod(Chat chat) => chat.ensure('test').moderation;

HeldMessage _held(String id, [String channel = 'test']) => HeldMessage(
  messageId: id,
  channel: channel,
  userLogin: 'spammer',
  text: 'bad text',
  category: 'bullying',
);

WarnEntry _warn(String target, DateTime at) =>
    WarnEntry(at: at, channel: 'test', target: target, moderator: 'mod');

void main() {
  group('Moderation held queue', () {
    test('queues newest first, dedupes, re-queues resolved, caps, clears', () {
      final chat = Chat();
      addTearDown(chat.dispose);
      final mod = _mod(chat);
      mod.addHeld(_held('m1'));
      mod.addHeld(_held('m2'));
      expect(mod.held.map((m) => m.messageId), ['m2', 'm1']);
      final version = mod.heldVersion.value;
      mod.addHeld(_held('m1'));
      expect(mod.held, hasLength(2));
      expect(mod.heldVersion.value, version, reason: 'dup is a no-op');

      expect(mod.resolveHeld('m1'), isTrue);
      expect(mod.resolveHeld('m1'), isFalse);
      mod.addHeld(_held('m1'));
      expect(mod.held.map((m) => m.messageId), ['m1', 'm2']);

      for (var i = 0; i < Moderation.maxHeldPerChannel + 10; i++) {
        mod.addHeld(_held('cap$i'));
      }
      expect(mod.held, hasLength(Moderation.maxHeldPerChannel));
      expect(mod.held.first.messageId, 'cap209');
      expect(mod.held.last.messageId, 'cap10');

      final before = mod.heldVersion.value;
      mod.clearHeld();
      expect(mod.held, isEmpty);
      expect(mod.heldVersion.value, before + 1);
      mod.clearHeld();
      expect(mod.heldVersion.value, before + 1, reason: 'no-op is quiet');
    });
  });

  group('Moderation feed and rosters', () {
    final t0 = DateTime(2026, 1, 1);
    ModActivityEntry activity(String action, {String? target}) =>
        ModActivityEntry(
          at: t0,
          channel: 'test',
          action: action,
          moderator: 'moduser',
          target: target,
        );

    test('feed logs newest first, caps per channel', () {
      final chat = Chat();
      addTearDown(chat.dispose);
      final mod = _mod(chat);
      mod.addFeed(activity('ban', target: 'a'));
      mod.addFeed(activity('timeout', target: 'b'));
      expect(mod.feed.map((e) => e.target), ['b', 'a']);
      for (var i = 0; i < Moderation.maxActivityPerChannel + 10; i++) {
        mod.addFeed(activity('slow', target: 'u$i'));
      }
      expect(mod.feed, hasLength(Moderation.maxActivityPerChannel));
      expect(mod.feed.first.target, 'u209');
    });

    test(
      'warnings match case-insensitively, latest wins, dismiss per user',
      () {
        final chat = Chat();
        addTearDown(chat.dispose);
        final mod = _mod(chat);
        mod.addWarning(_warn('Spammer', DateTime(2026, 1, 2)));
        mod.addWarning(_warn('spammer', DateTime(2026, 1, 1)));
        mod.addWarning(_warn('other', DateTime(2026, 1, 3)));
        expect(mod.warningsFor('SPAMMER'), hasLength(2));
        expect(mod.warningsFor('missing'), isEmpty);
        final latest = mod.warnedLatest();
        expect(latest['spammer']!.at, DateTime(2026, 1, 2));
        expect(latest['other']!.at, DateTime(2026, 1, 3));

        expect(mod.dismissWarningsFor('SPAMMER'), isTrue);
        expect(mod.warningsFor('spammer'), isEmpty);
        expect(mod.warningsFor('other'), hasLength(1));
        expect(mod.dismissWarningsFor('spammer'), isFalse);
      },
    );

    test('ban roster overwrites, removes, and prunes expired timeouts', () {
      final chat = Chat();
      addTearDown(chat.dispose);
      final mod = _mod(chat);
      BanEntry ban(String login, {DateTime? expiresAt}) => BanEntry(
        at: t0,
        channel: 'test',
        login: login,
        expiresAt: expiresAt,
        moderator: 'mod',
      );
      expect(mod.banFor('Spammer'), isNull);
      mod.putBan(ban('Spammer'));
      expect(mod.banFor('spammer')!.expiresAt, isNull);
      final until = t0.add(const Duration(days: 1));
      mod.putBan(ban('SPAMMER', expiresAt: until));
      expect(mod.banFor('spammer')!.expiresAt, until);
      expect(mod.removeBan('Spammer'), isTrue);
      expect(mod.removeBan('spammer'), isFalse);

      mod.putBan(ban('gone', expiresAt: DateTime(2026, 1, 2)));
      mod.putBan(ban('live', expiresAt: DateTime(2026, 1, 5)));
      mod.putBan(ban('perm'));
      expect(mod.pruneExpiredBans(at: DateTime(2026, 1, 3)), 1);
      expect(mod.banFor('gone'), isNull);
      expect(mod.banFor('live'), isNotNull);
      expect(mod.banFor('perm'), isNotNull);
    });

    test('suspicious sightings upsert, query, and remove', () {
      final chat = Chat();
      addTearDown(chat.dispose);
      final mod = _mod(chat);
      expect(mod.suspiciousFor('spammer'), isNull);
      mod.noteSuspicious(
        SuspiciousInfo(
          at: t0,
          channel: 'test',
          login: 'Spammer',
          status: 'restricted',
          types: const ['manually_added'],
          banEvasion: 'possible',
          sharedBanChannelIds: const ['111'],
        ),
      );
      final seen = mod.suspiciousFor('spammer')!;
      expect(seen.status, 'restricted');
      expect(seen.sharedBanChannelIds, ['111']);
      expect(mod.removeSuspicious('SPAMMER'), isTrue);
      expect(mod.suspiciousFor('spammer'), isNull);
      expect(mod.removeSuspicious('spammer'), isFalse);
    });
  });

  group('Moderation versions', () {
    test('clearForAccountSwitch drops account state in one bump', () {
      final chat = Chat();
      addTearDown(chat.dispose);
      final mod = _mod(chat);
      final t0 = DateTime(2026, 1, 1);
      mod.addFeed(
        ModActivityEntry(
          at: t0,
          channel: 'test',
          action: 'ban',
          moderator: 'mod',
        ),
      );
      mod.addWarning(_warn('spammer', t0));
      mod.putBan(
        BanEntry(at: t0, channel: 'test', login: 'spammer', moderator: 'mod'),
      );
      mod.noteSuspicious(
        SuspiciousInfo(
          at: t0,
          channel: 'test',
          login: 'spammer',
          status: 'monitored',
        ),
      );
      final version = mod.modActivityVersion.value;
      mod.clearForAccountSwitch();
      expect(mod.feed, isEmpty);
      expect(mod.warnings, isEmpty);
      expect(mod.banFor('spammer'), isNull);
      expect(mod.suspiciousFor('spammer'), isNull);
      expect(mod.modActivityVersion.value, version + 1);
    });
  });

  group('suspicious sightings', () {
    final t0 = DateTime(2026, 1, 1);

    test('caps at the oldest', () {
      final chat = Chat();
      addTearDown(chat.dispose);
      final mod = _mod(chat);
      for (var i = 0; i < Moderation.maxSuspiciousPerChannel + 5; i++) {
        mod.noteSuspicious(
          SuspiciousInfo(
            at: t0,
            channel: 'test',
            login: 'u$i',
            status: 'monitored',
          ),
        );
      }
      expect(mod.suspicious, hasLength(Moderation.maxSuspiciousPerChannel));
      expect(mod.suspiciousFor('u0'), isNull);
      expect(mod.suspiciousFor('u204'), isNotNull);
    });
  });
}
