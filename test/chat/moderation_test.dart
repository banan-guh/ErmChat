import 'package:ermchat/chat/channel/moderation.dart';
import 'package:ermchat/chat/chat.dart';
import 'package:ermchat/util/mod_activity_format.dart';
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
    test('queues newest first and ignores duplicate deliveries', () {
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
    });

    test('resolve drops the entry', () {
      final chat = Chat();
      addTearDown(chat.dispose);
      final mod = _mod(chat);
      mod.addHeld(_held('m1'));
      mod.addHeld(_held('m2'));
      expect(mod.resolveHeld('m1'), isTrue);
      expect(mod.held.map((m) => m.messageId), ['m2']);
      expect(mod.resolveHeld('m1'), isFalse);
      expect(mod.resolveHeld('m2'), isTrue);
      expect(mod.held, isEmpty);
    });

    test('resolved ids re-queue, and the per-channel cap drops oldest', () {
      final chat = Chat();
      addTearDown(chat.dispose);
      final mod = _mod(chat);
      mod.addHeld(_held('m1'));
      expect(mod.resolveHeld('m1'), isTrue);
      mod.addHeld(_held('m1'));
      expect(mod.held.map((m) => m.messageId), [
        'm1',
      ], reason: 're-hold after resolve queues again');
      for (var i = 0; i < Moderation.maxHeldPerChannel + 10; i++) {
        mod.addHeld(_held('cap$i'));
      }
      final queue = mod.held;
      expect(queue, hasLength(Moderation.maxHeldPerChannel));
      expect(queue.first.messageId, 'cap209');
      expect(queue.last.messageId, 'cap10');
    });

    test('clearHeld drops the queue in one bump and is quiet when empty', () {
      final chat = Chat();
      addTearDown(chat.dispose);
      final mod = _mod(chat);
      mod.addHeld(_held('m1'));
      mod.addHeld(_held('m2'));
      final version = mod.heldVersion.value;
      mod.clearHeld();
      expect(mod.held, isEmpty);
      expect(mod.heldVersion.value, version + 1);
      mod.clearHeld();
      expect(mod.heldVersion.value, version + 1, reason: 'no-op is quiet');
    });

    test('Chat.remove drops the channel queue with it', () {
      final chat = Chat();
      addTearDown(chat.dispose);
      chat.ensure('test').moderation.addHeld(_held('m1'));
      chat.ensure('other').moderation.addHeld(_held('m2', 'other'));
      expect(chat.channelFor('missing'), isNull);
      chat.channelFor('test')!.moderation.clearHeld();
      expect(chat.channelFor('test')!.moderation.held, isEmpty);
      expect(chat.channelFor('other')!.moderation.held, hasLength(1));
      chat.remove('other');
      expect(chat.channelFor('other'), isNull);
    });
  });

  group('Moderation feed', () {
    final t0 = DateTime(2026, 1, 1);
    ModActivityEntry activity(
      String action, {
      String channel = 'test',
      String? target,
      String? reason,
      List<String> terms = const [],
    }) => ModActivityEntry(
      at: t0,
      channel: channel,
      action: action,
      moderator: 'moduser',
      target: target,
      reason: reason,
      terms: terms,
    );

    test('logs newest first and caps per channel', () {
      final chat = Chat();
      addTearDown(chat.dispose);
      final mod = _mod(chat);
      mod.addFeed(activity('ban', target: 'a'));
      mod.addFeed(activity('timeout', target: 'b'));
      expect(mod.feed.map((e) => e.target), ['b', 'a']);
      for (var i = 0; i < Moderation.maxActivityPerChannel + 10; i++) {
        mod.addFeed(activity('slow', target: 'u$i'));
      }
      final feed = mod.feed;
      expect(feed, hasLength(Moderation.maxActivityPerChannel));
      expect(feed.first.target, 'u209');
    });

    test('clearFeed is quiet when empty', () {
      final chat = Chat();
      addTearDown(chat.dispose);
      final mod = _mod(chat);
      final version = mod.modActivityVersion.value;
      mod.clearFeed();
      expect(mod.modActivityVersion.value, version);
      mod.addFeed(activity('ban'));
      mod.clearFeed();
      expect(mod.feed, isEmpty);
    });

    test('warnings filter case-insensitively per user', () {
      final chat = Chat();
      addTearDown(chat.dispose);
      final mod = _mod(chat);
      mod.addWarning(
        WarnEntry(
          at: t0,
          channel: 'test',
          target: 'Spammer',
          moderator: 'moduser',
          reason: 'spam',
        ),
      );
      mod.addWarning(
        WarnEntry(
          at: t0,
          channel: 'test',
          target: 'other',
          moderator: 'moduser',
        ),
      );
      final found = mod.warningsFor('spammer');
      expect(found, hasLength(1));
      expect(found.first.reason, 'spam');
      expect(mod.warningsFor('missing'), isEmpty);
    });

    test('ban roster puts, queries, and removes case-insensitively', () {
      final chat = Chat();
      addTearDown(chat.dispose);
      final mod = _mod(chat);
      expect(mod.banFor('Spammer'), isNull);
      mod.putBan(
        BanEntry(
          at: t0,
          channel: 'test',
          login: 'Spammer',
          moderator: 'moduser',
        ),
      );
      expect(mod.banFor('spammer')!.expiresAt, isNull);
      // A timeout overwrites the ban entry.
      mod.putBan(
        BanEntry(
          at: t0,
          channel: 'test',
          login: 'SPAMMER',
          expiresAt: t0.add(const Duration(seconds: 600)),
          moderator: 'moduser',
        ),
      );
      expect(
        mod.banFor('spammer')!.expiresAt,
        t0.add(const Duration(seconds: 600)),
      );
      expect(mod.removeBan('Spammer'), isTrue);
      expect(mod.banFor('spammer'), isNull);
      expect(mod.removeBan('spammer'), isFalse);
    });

    test('suspicious sightings upsert, query, and clear', () {
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

    test('touchInbox bumps the inbox version', () {
      final chat = Chat();
      addTearDown(chat.dispose);
      final mod = _mod(chat);
      final version = mod.modInboxVersion.value;
      mod.touchInbox();
      expect(mod.modInboxVersion.value, version + 1);
    });
  });

  group('Moderation warnings', () {
    test('warnedLatest picks newest regardless of order', () {
      final chat = Chat();
      addTearDown(chat.dispose);
      final mod = _mod(chat);
      mod.addWarning(_warn('Spammer', DateTime(2026, 1, 2)));
      mod.addWarning(_warn('spammer', DateTime(2026, 1, 1)));
      mod.addWarning(_warn('other', DateTime(2026, 1, 3)));
      final latest = mod.warnedLatest();
      expect(latest['spammer']!.at, DateTime(2026, 1, 2));
      expect(latest['other']!.at, DateTime(2026, 1, 3));
    });

    test('dismissWarningsFor drops one user case-insensitively', () {
      final chat = Chat();
      addTearDown(chat.dispose);
      final mod = _mod(chat);
      mod.addWarning(_warn('Spammer', DateTime(2026, 1, 1)));
      mod.addWarning(_warn('other', DateTime(2026, 1, 2)));
      expect(mod.dismissWarningsFor('SPAMMER'), isTrue);
      expect(mod.warningsFor('spammer'), isEmpty);
      expect(mod.warningsFor('other'), hasLength(1));
      expect(mod.dismissWarningsFor('spammer'), isFalse);
    });
  });

  group('Moderation bans', () {
    test('drops expired timeouts, keeps bans and live timeouts', () {
      final chat = Chat();
      addTearDown(chat.dispose);
      final mod = _mod(chat);
      mod.putBan(
        BanEntry(
          at: DateTime(2026, 1, 1),
          channel: 'test',
          login: 'gone',
          expiresAt: DateTime(2026, 1, 2),
          moderator: 'mod',
        ),
      );
      mod.putBan(
        BanEntry(
          at: DateTime(2026, 1, 1),
          channel: 'test',
          login: 'live',
          expiresAt: DateTime(2026, 1, 5),
          moderator: 'mod',
        ),
      );
      mod.putBan(
        BanEntry(
          at: DateTime(2026, 1, 1),
          channel: 'test',
          login: 'perm',
          moderator: 'mod',
        ),
      );
      expect(mod.pruneExpiredBans(at: DateTime(2026, 1, 3)), 1);
      expect(mod.banFor('gone'), isNull);
      expect(mod.banFor('live'), isNotNull);
      expect(mod.banFor('perm'), isNotNull);
    });
  });

  group('Moderation versions', () {
    test('settings bumps do not touch inbox version', () {
      final chat = Chat();
      addTearDown(chat.dispose);
      final mod = _mod(chat);
      final inbox = mod.modInboxVersion.value;
      mod.touchSettings();
      expect(mod.modSettingsVersion.value, inbox + 1);
      expect(mod.modInboxVersion.value, inbox);
    });

    test('feed ticks skip users-only mutations', () {
      final chat = Chat();
      addTearDown(chat.dispose);
      final mod = _mod(chat);
      final feed = mod.modFeedVersion.value;
      mod.addWarning(
        WarnEntry(
          at: DateTime(2026, 1, 1),
          channel: 'test',
          target: 'spammer',
          moderator: 'mod',
        ),
      );
      expect(mod.modFeedVersion.value, feed);
      mod.addFeed(
        ModActivityEntry(
          at: DateTime(2026, 1, 1),
          channel: 'test',
          action: 'ban',
          moderator: 'mod',
          target: 'spammer',
        ),
      );
      expect(mod.modFeedVersion.value, feed + 1);
    });

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

  group('formatModActivity', () {
    final t0 = DateTime(2026, 1, 1);
    ModActivityEntry entry(
      String action, {
      String? target = 'spammer',
      String? reason,
      int? duration,
      List<String> terms = const [],
    }) => ModActivityEntry(
      at: t0,
      channel: 'test',
      action: action,
      moderator: 'moduser',
      target: target,
      reason: reason,
      durationSeconds: duration,
      terms: terms,
    );

    test('renders each action', () {
      for (final (action, expected) in [
        ('ban', 'moduser banned spammer.'),
        ('untimeout', 'moduser unbanned spammer.'),
        ('delete', 'moduser deleted a message from spammer.'),
        ('clear', 'moduser cleared the chat.'),
        ('mod', 'moduser modded spammer.'),
        ('unvip', 'moduser removed spammer as a VIP.'),
        ('warn_ack', 'spammer acknowledged a warning.'),
        ('slow', 'moduser enabled slow mode.'),
        ('followersoff', 'moduser disabled followers-only mode.'),
        ('uniquechat', 'moduser enabled unique chat.'),
        ('raid', 'moduser started a raid.'),
        ('shield_on', 'moduser enabled Shield Mode.'),
        ('shoutout', 'moduser shouted out spammer.'),
        ('automod_settings', 'moduser updated AutoMod settings.'),
      ]) {
        expect(formatModActivity(entry(action)), expected, reason: action);
      }
      expect(
        formatModActivity(entry('timeout', duration: 90)),
        'moduser timed out spammer for 1m 30s.',
      );
      expect(
        formatModActivity(entry('warn', reason: 'spam')),
        'moduser warned spammer: "spam".',
      );
      expect(
        formatModActivity(entry('deny_unban_request', reason: 'too soon')),
        'moduser denied spammer\'s unban request: "too soon".',
      );
      expect(
        formatModActivity(entry('deny_unban_request', reason: 'too soon')),
        'moduser denied spammer\'s unban request: "too soon".',
      );
      expect(
        formatModActivity(entry('suspicious_flag', reason: 'restricted')),
        'moduser flagged spammer: "restricted".',
      );
      expect(
        formatModActivity(
          entry('remove_blocked_term', target: null, terms: ['a', 'b']),
        ),
        'moduser removed 2 blocked terms.',
      );
      expect(
        formatModActivity(entry('some_future_action', target: null)),
        'moduser did some future action.',
      );
    });
  });
}
