import 'package:flutter/material.dart';
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
        isRegex: true,
        caseSensitive: true,
        enabled: false,
        notify: true,
        colorArgb: 0xFFE57373,
      );
      final decoded = decodeRules(encodeRules([rule]));
      expect(decoded.single.toJson(), rule.toJson());
      expect(decodeRules('not json'), isEmpty);
      expect(decodeRules('{"id": "x"}'), isEmpty);
    });
  });

  group('username rule', () {
    test('matches whole word, @ prefix, case insensitive', () async {
      final m = await makeManager();
      m.setAccount('forsen');
      expect(
        m.evaluate(msg('hey @forsen'))?.types,
        contains(HighlightType.username),
      );
      expect(m.evaluate(msg('hello Forsen'))?.hasMention, isTrue);
      expect(m.evaluate(msg('forsenator')), isNull);
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

    test('username and reply builtins skip self messages', () async {
      final m = await makeManager();
      m.setAccount('forsen');
      expect(m.evaluate(msg('hi forsen', login: 'forsen')), isNull);
      expect(m.evaluate(msg('hi forsen', isSystem: true)), isNull);
    });
  });

  group('custom keyword rules', () {
    Future<PingManager> managerWith(PingRule rule) async {
      final m = await makeManager();
      m.setAccount('me');
      m.upsertRule(rule);
      return m;
    }

    test(
      'matches custom keywords by substring including own messages',
      () async {
        final m = await managerWith(
          const PingRule(
            id: 'c1',
            kind: PingRuleKind.message,
            type: 'custom',
            pattern: 'KEKW',
          ),
        );
        const cases = [
          ('KEKW', 'me', true),
          ('lol kekw', 'otheruser', true),
          ('nothing here', 'otheruser', false),
        ];
        for (final (text, login, shouldMatch) in cases) {
          final result = m.evaluate(msg(text, login: login));
          if (shouldMatch) {
            expect(
              result?.types,
              contains(HighlightType.custom),
              reason: 'text: $text login: $login',
            );
          } else {
            expect(result, isNull, reason: 'text: $text login: $login');
          }
        }
      },
    );

    test('regex matching with fallback on invalid patterns', () async {
      final m = await managerWith(
        const PingRule(
          id: 'c2',
          kind: PingRuleKind.message,
          type: 'custom',
          pattern: '\\bKappa\\d+\\b',
          isRegex: true,
        ),
      );
      expect(m.evaluate(msg('Kappa123')), isNotNull);
      expect(m.evaluate(msg('Kappa')), isNull);

      final bad = await managerWith(
        const PingRule(
          id: 'c3',
          kind: PingRuleKind.message,
          type: 'custom',
          pattern: '(unclosed',
          isRegex: true,
        ),
      );
      expect(bad.evaluate(msg('(unclosed lol')), isNotNull);
    });

    test('honors the case sensitive and enabled flags', () async {
      final sensitive = await managerWith(
        const PingRule(
          id: 'c4',
          kind: PingRuleKind.message,
          type: 'custom',
          pattern: 'KEKW',
          caseSensitive: true,
        ),
      );
      expect(sensitive.evaluate(msg('kekw')), isNull);
      expect(sensitive.evaluate(msg('KEKW')), isNotNull);

      final disabled = await managerWith(
        const PingRule(
          id: 'c5',
          kind: PingRuleKind.message,
          type: 'custom',
          pattern: 'ping',
          enabled: false,
        ),
      );
      expect(disabled.evaluate(msg('ping')), isNull);
    });

    test('whole word flag anchors literal patterns', () async {
      final m = await managerWith(
        const PingRule(
          id: 'c6',
          kind: PingRuleKind.message,
          type: 'custom',
          pattern: 'cat',
          wordBoundary: true,
        ),
      );
      expect(m.evaluate(msg('petting the cat')), isNotNull);
      expect(m.evaluate(msg('concatenate category')), isNull);
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

    test('user rule matches the login', () async {
      final m = await managerWith([
        const PingRule(id: 'u1', kind: PingRuleKind.user, pattern: 'spammy'),
      ]);
      expect(m.evaluate(msg('buy stuff', login: 'Spammy'))?.hasMention, isTrue);
      expect(m.evaluate(msg('buy stuff', login: 'other')), isNull);
    });

    test('badge rule matches a badge set id', () async {
      final m = await managerWith([
        const PingRule(id: 'b1', kind: PingRuleKind.badge, pattern: 'vip'),
      ]);
      final hit = msg('hey', badges: [badge('vip')]);
      expect(m.evaluate(hit)?.types, contains(HighlightType.badge));
      expect(m.evaluate(msg('hey', badges: [badge('moderator')])), isNull);
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

  group('blacklist', () {
    test('suppresses all highlights from a blacklisted user', () async {
      final m = await makeManager();
      m.setAccount('forsen');
      m.upsertRule(
        const PingRule(
          id: 'bl1',
          kind: PingRuleKind.blacklist,
          pattern: 'botlord',
        ),
      );
      expect(m.evaluate(msg('hey forsen', login: 'BotLord')), isNull);
    });
  });

  group('reply participation', () {
    test('direct replies ping', () async {
      final m = await makeManager();
      m.setAccount('forsen');
      expect(
        m.evaluate(msg('a reply', replyToUser: 'Forsen'))?.primary,
        HighlightType.reply,
      );
    });

    test('replies onto our own messages ping via registry', () async {
      final m = await makeManager();
      m.setAccount('forsen');
      m.registerOwnMessage('forsen', 'own-1', threadRootId: 'root-1');
      expect(
        m.evaluate(msg('chained', replyToParentId: 'own-1'))?.primary,
        HighlightType.reply,
      );
      expect(
        m.evaluate(msg('threaded', replyThreadRootId: 'root-1'))?.primary,
        HighlightType.reply,
      );
    });

    test('participation does not leak across channels', () async {
      final m = await makeManager();
      m.setAccount('forsen');
      m.registerOwnMessage('chan1', 'own-1');
      expect(
        m.evaluate(msg('chained', channel: 'chan2', replyToParentId: 'own-1')),
        isNull,
      );
    });

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

  group('state merging', () {
    test('notify aggregates across matched rules', () async {
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
      final both = m.evaluate(msg('alert x', customRewardId: 'r'));
      expect(both?.notify, isTrue);
      expect(
        m.evaluate(msg('no keywords', customRewardId: 'r'))?.notify,
        isFalse,
      );
    });

    test('mention-tier beats event types for priority', () async {
      final m = await makeManager();
      m.setAccount('forsen');
      final both = m.evaluate(msg('forsen', customRewardId: 'r'));
      expect(both?.primary, HighlightType.username);
      expect(both?.hasMention, isTrue);
    });
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
                final row = HighlightState(
                  types: {t},
                ).rowColor(surface, opacity: opacity);
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
          final plain = HighlightState(
            types: {HighlightType.firstMsg},
          ).rowColor(surface);
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
        final customRow = custom.rowColor(surfaceDark);
        final paletteRow = const HighlightState(
          types: {HighlightType.username},
        ).rowColor(surfaceDark);
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
