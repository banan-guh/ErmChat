import 'package:flutter_test/flutter_test.dart';
import 'package:ermchat/color_utils.dart';
import 'package:ermchat/models/highlight_state.dart';
import 'package:ermchat/models/ping_rule.dart';
import 'package:ermchat/models/twitch_badge.dart';
import 'package:ermchat/models/twitch_message.dart';
import 'package:ermchat/services/ping_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

TwitchMessage msg(
  String text, {
  String login = 'otheruser',
  String? displayName,
  String channel = 'forsen',
  bool isSystem = false,
  bool isFirstMessage = false,
  String? customRewardId,
  String? msgId,
  String? pinnedPaidAmount,
  String? replyToUser,
  String? replyToParentId,
  String? replyThreadRootId,
  List<MessageBadge> badges = const [],
}) {
  return TwitchMessage(
    login: login,
    displayName: displayName ?? login,
    text: text,
    channel: channel,
    isSystem: isSystem,
    isFirstMessage: isFirstMessage,
    customRewardId: customRewardId,
    msgId: msgId,
    pinnedPaidAmount: pinnedPaidAmount,
    replyToUser: replyToUser,
    replyToParentId: replyToParentId,
    replyThreadRootId: replyThreadRootId,
    badges: badges,
  );
}

MessageBadge badge(String setId, [String version = '1']) =>
    MessageBadge(setId: setId, versionId: version);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<PingManager> makeManager([
    Map<String, Object> initialPrefs = const {},
  ]) async {
    SharedPreferences.setMockInitialValues(initialPrefs);
    final manager = PingManager();
    await manager.load();
    return manager;
  }

  group('PingManager defaults', () {
    test('drops the legacy alt_pings key', () async {
      await makeManager({
        'alt_pings': <String>['kekw'],
      });
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.containsKey('alt_pings'), isFalse);
      expect(prefs.containsKey('ping_rules_v1'), isTrue);
    });

    test('round-trips rules through JSON and tolerates garbage input', () {
      const rule = PingRule(
        id: 'r1',
        kind: PingRuleKind.message,
        type: 'custom',
        pattern: 'KEKW',
        wordBoundary: true,
        enabled: false,
        notify: true,
        colorArgb: 0xFFE57373,
      );
      final decoded = decodeRules(encodeRules([rule]));
      expect(decoded.single.toJson(), rule.toJson());
      expect(decodeRules('not json'), isEmpty);
      expect(decodeRules('{"id": "x"}'), isEmpty);
    });

    test('saved notify flags only survive with mention push on', () async {
      const saved =
          '[{"id":"builtin_username","kind":"message","type":"username",'
          '"enabled":true,"notify":true}]';
      final off = await makeManager({'ping_rules_v1': saved});
      expect(
        off.rules.any((r) => r.notify),
        isFalse,
        reason: 'push was off, so these rules never notified',
      );
      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getString('ping_rules_v1'),
        isNot(contains('"notify":true')),
      );

      final on = await makeManager({
        'ping_rules_v1': saved,
        'mention_push': true,
      });
      expect(on.rules.first.notify, isTrue);
    });

    test('rules saved with the removed regex flags still load', () async {
      final m = await makeManager({
        'ping_rules_v1':
            '[{"id":"old","kind":"message","type":"custom",'
            r'"pattern":"\\bKappa\\d+","isRegex":true,"caseSensitive":true}]',
      });
      expect(m.rules.firstWhere((r) => r.id == 'old').pattern, r'\bKappa\d+');
      expect(m.evaluate(msg('Kappa123')), isNull, reason: 'now plain text');
      expect(m.evaluate(msg(r'see \bkappa\d+')), isNotNull);
    });
  });

  group('username rule', () {
    test('matches whole word, @ prefix, case insensitive, not self', () async {
      final m = await makeManager();
      m.setAccount('forsen');
      expect(
        m.evaluate(msg('hey @forsen'))?.types,
        contains(HighlightType.username),
      );
      expect(m.evaluate(msg('hello Forsen'))?.hasMention, isTrue);
      expect(m.evaluate(msg('forsenator')), isNull);
      // Self and system messages never ping.
      expect(m.evaluate(msg('hi forsen', login: 'forsen')), isNull);
      expect(m.evaluate(msg('hi forsen', isSystem: true)), isNull);
    });

    test('matches our own display name when it differs from login', () async {
      final m = await makeManager();
      m.setAccount('xseb');
      m.setOwnDisplayName('Sebastian');
      final state = m.evaluate(
        msg('go Sebastian!', login: 'otheruser', displayName: 'Otheruser'),
      );
      expect(state?.hasMention, isTrue);
      expect(m.evaluate(msg('go seb!', login: 'otheruser')), isNull);
      // A display name that only differs in casing from the login adds
      // nothing new and must not double-match.
      m.setOwnDisplayName('Xseb');
      expect(
        m.evaluate(msg('hey xseb', login: 'otheruser'))?.primary,
        HighlightType.username,
      );
    });
  });

  group('custom keyword rules', () {
    PingRule custom(String pattern, {bool enabled = true, bool word = false}) =>
        PingRule(
          id: 'c',
          kind: PingRuleKind.message,
          type: 'custom',
          pattern: pattern,
          enabled: enabled,
          wordBoundary: word,
        );

    for (final (name, rule, hits, misses) in [
      ('substring, case-insensitive', custom('KEKW'), ['lol kekw'], ['nope']),
      (
        'regex syntax is plain text',
        custom('what?', word: true),
        ['wait what?'],
        ['wha', 'what'],
      ),
      ('disabled', custom('ping', enabled: false), <String>[], ['ping']),
      (
        'whole word anchors literals',
        custom('cat', word: true),
        ['petting the CAT'],
        ['concatenate category'],
      ),
      (
        'whole word anchors punctuation',
        custom(':)', word: true),
        ['nice :)'],
        ['nice:)'],
      ),
    ]) {
      test(name, () async {
        final m = await makeManager();
        m.setAccount('me');
        m.upsertRule(rule);
        for (final text in hits) {
          expect(
            m.evaluate(msg(text))?.types,
            contains(HighlightType.custom),
            reason: text,
          );
        }
        for (final text in misses) {
          expect(m.evaluate(msg(text)), isNull, reason: text);
        }
      });
    }

    test('matches own messages too', () async {
      final m = await makeManager();
      m.setAccount('me');
      m.upsertRule(custom('KEKW'));
      expect(m.evaluate(msg('KEKW', login: 'me')), isNotNull);
    });

    test('tint-only rules stay out of @mentions and never notify', () async {
      final m = await makeManager();
      m.setAccount('me');
      m.upsertRule(custom('KEKW').copyWith(mention: false, notify: true));
      final state = m.evaluate(msg('KEKW'));
      expect(state?.types, {HighlightType.tint});
      expect(state?.hasMention, isFalse);
      expect(state?.notify, isFalse);
    });
  });

  group('user / badge / event rules', () {
    Future<PingManager> managerWith(List<PingRule> rules) async {
      final m = await makeManager();
      for (final r in rules) {
        m.upsertRule(r);
      }
      return m;
    }

    test('user and badge rules match; blacklist suppresses', () async {
      final m = await managerWith([
        const PingRule(id: 'u1', kind: PingRuleKind.user, pattern: 'spammy'),
        const PingRule(id: 'b1', kind: PingRuleKind.badge, pattern: 'vip'),
      ]);
      expect(m.evaluate(msg('buy stuff', login: 'Spammy'))?.hasMention, isTrue);
      expect(m.evaluate(msg('buy stuff', login: 'other')), isNull);
      final hit = msg('hey', badges: [badge('vip')]);
      expect(m.evaluate(hit)?.types, contains(HighlightType.badge));
      expect(
        m.evaluate(hit)?.hasMention,
        isFalse,
        reason: 'badges tint only, never fill @mentions',
      );
      expect(m.evaluate(msg('hey', badges: [badge('moderator')])), isNull);

      m.upsertRule(
        const PingRule(
          id: 'bl1',
          kind: PingRuleKind.blacklist,
          pattern: 'spammy',
        ),
      );
      expect(m.evaluate(msg('buy stuff', login: 'Spammy')), isNull);
    });

    test('redemption, elevated, first message builtins', () async {
      final m = await managerWith([]);
      expect(
        m.evaluate(msg('for the reward', customRewardId: 'rew-1'))?.primary,
        HighlightType.redemption,
      );
      // Twitch flags redemption highlights via msg-id on the wire.
      expect(
        m.evaluate(msg('reward!', msgId: 'highlighted-message'))?.primary,
        HighlightType.redemption,
      );
      expect(
        m.evaluate(msg('big money', pinnedPaidAmount: '500'))?.primary,
        HighlightType.elevated,
      );
      expect(
        m.evaluate(msg('first!!!', isFirstMessage: true))?.primary,
        HighlightType.firstMsg,
      );
    });
  });

  group('reply participation', () {
    test('direct replies and replies onto own messages ping', () async {
      final m = await makeManager();
      m.setAccount('forsen');
      expect(
        m.evaluate(msg('a reply', replyToUser: 'Forsen'))?.primary,
        HighlightType.reply,
      );
      m.registerOwnMessage('forsen', 'own-1', threadRootId: 'root-1');
      expect(
        m.evaluate(msg('chained', replyToParentId: 'own-1'))?.primary,
        HighlightType.reply,
      );
      expect(
        m.evaluate(msg('threaded', replyThreadRootId: 'root-1'))?.primary,
        HighlightType.reply,
      );
      // A thread rooted at our own message counts as one we are in.
      m.registerOwnMessage('forsen', 'own-2');
      expect(
        m.evaluate(msg('in my thread', replyThreadRootId: 'own-2'))?.primary,
        HighlightType.reply,
      );
      // Participation is per channel.
      expect(
        m.evaluate(msg('chained', channel: 'chan2', replyToParentId: 'own-1')),
        isNull,
      );
    });

    test('replies and threads toggle separately', () async {
      final m = await makeManager();
      m.setAccount('forsen');
      m.registerOwnMessage('forsen', 'own-1', threadRootId: 'root-1');
      final thread = m.rules.firstWhere((r) => r.id == 'builtin_thread');
      m.upsertRule(thread.copyWith(enabled: false));
      expect(
        m.evaluate(msg('threaded', replyThreadRootId: 'root-1')),
        isNull,
        reason: 'thread rule off',
      );
      expect(m.evaluate(msg('direct', replyToParentId: 'own-1')), isNotNull);
    });

    test(
      'rules saved before the thread split inherit the reply rule',
      () async {
        final m = await makeManager({
          'ping_rules_v1':
              '[{"id":"builtin_reply","kind":"message","type":"reply",'
              '"enabled":true,"notify":false,"color":4293212469}]',
        });
        final ids = m.rules.map((r) => r.id).toList();
        expect(ids, ['builtin_reply', 'builtin_thread']);
        final thread = m.rules.last;
        expect(thread.notify, isFalse);
        expect(thread.colorArgb, 4293212469);
      },
    );

    test(
      'switching accounts drops the departed account learned state',
      () async {
        final m = await makeManager();
        m.setAccount('forsen');
        m.setOwnDisplayName('ForsenFan');
        m.registerOwnMessage('forsen', 'own-1', threadRootId: 'root-1');

        // Account switch passes through null before the new login lands.
        m.setAccount(null);
        m.setAccount('xseb');

        // The old display name no longer pings...
        expect(m.evaluate(msg('hi ForsenFan')), isNull);
        // ...and the old reply-participation registries are gone too.
        expect(m.evaluate(msg('chained', replyToParentId: 'own-1')), isNull);
        expect(
          m.evaluate(msg('threaded', replyThreadRootId: 'root-1')),
          isNull,
        );
      },
    );
  });

  test('notify aggregates and mention tier wins priority', () async {
    final m = await makeManager();
    m.setAccount('forsen');
    m.upsertRule(
      const PingRule(
        id: 'n1',
        kind: PingRuleKind.message,
        type: 'custom',
        pattern: 'alert',
        notify: true,
      ),
    );
    // Redemption alone never notifies; with a notifying keyword it must.
    expect(m.evaluate(msg('alert x', customRewardId: 'r'))?.notify, isTrue);
    expect(
      m.evaluate(msg('no keywords', customRewardId: 'r'))?.notify,
      isFalse,
    );
    final both = m.evaluate(msg('forsen', customRewardId: 'r'));
    expect(both?.primary, HighlightType.username);
    expect(both?.hasMention, isTrue);
  });

  test('system highlights outrank colored user rules', () async {
    final m = await makeManager();
    m.setAccount('forsen');
    m.upsertRule(
      const PingRule(
        id: 'k',
        kind: PingRuleKind.message,
        pattern: 'pog',
        colorArgb: 0xFF64B5F6,
      ),
    );
    expect(
      m.evaluate(msg('pog'))?.customColor,
      const Color(0xFF64B5F6),
      reason: 'keyword alone keeps its color',
    );
    for (final hit in [msg('pog forsen'), msg('pog', isFirstMessage: true)]) {
      final state = m.evaluate(hit);
      expect(state?.primary, isNot(HighlightType.custom), reason: hit.text);
      expect(state?.customColor, isNull, reason: 'palette, not the keyword');
    }
  });

  group('rowColor contrast equalization', () {
    test(
      'normalizes every highlight to equal contrast with custom colors winning',
      () {
        double dist(Color c, Color s) => (brightness(c) - brightness(s)).abs();
        const cases = [(Color(0xFF0E0E10), 0.5), (Color(0xFFFFFFFF), 1.0)];
        const types = [
          HighlightType.username,
          HighlightType.redemption,
          HighlightType.elevated,
          HighlightType.firstMsg,
        ];
        for (final (surface, opacity) in cases) {
          final distances = <double>[
            for (final t in types)
              (() {
                final row = highlightRowColor(
                  HighlightState(types: {t}),
                  surface,
                  opacity: opacity,
                );
                return (brightness(row) - brightness(surface)).abs();
              })(),
          ];
          for (final d in distances) {
            expect(
              d,
              closeTo(distances.first, 0.02),
              reason: 'surface: $surface',
            );
          }
          final plain = highlightRowColor(
            HighlightState(types: {HighlightType.firstMsg}),
            surface,
          );
          expect(
            dist(plain, surface),
            closeTo(
              dist(highlightAnchor(surface), surface) * highlightStrength,
              0.02,
            ),
            reason: 'surface: $surface matches the scaled anchor',
          );
        }

        // Custom colors win over the palette without changing the budget.
        const surfaceDark = Color(0xFF000000);
        const custom = HighlightState(
          types: {HighlightType.username},
          customColor: Color(0xFFABCDEF),
        );
        final customRow = highlightRowColor(custom, surfaceDark);
        final paletteRow = highlightRowColor(
          const HighlightState(types: {HighlightType.username}),
          surfaceDark,
        );
        expect(customRow, isNot(equals(paletteRow)));
        expect(
          dist(customRow, surfaceDark),
          closeTo(
            dist(highlightAnchor(surfaceDark), surfaceDark) * highlightStrength,
            0.02,
          ),
        );
      },
    );
  });
}
