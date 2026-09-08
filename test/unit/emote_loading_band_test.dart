import 'package:ermchat/widgets/emote_probe_memo.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('EmoteProbeMemo', () {
    test('dedupes concurrent probes into one check', () async {
      final memo = EmoteProbeMemo();
      var calls = 0;
      Future<bool> probe(String url) => Future<bool>.delayed(Duration.zero, () {
        calls++;
        return true;
      });
      final results = await Future.wait([
        memo.probe('u', probe),
        memo.probe('u', probe),
        memo.probe('u', probe),
      ]);
      expect(results, everyElement(isTrue));
      expect(calls, 1);
    });

    test('caches results of either kind until ttl', () async {
      var now = DateTime(2026, 1, 1);
      final memo = EmoteProbeMemo(
        ttl: const Duration(seconds: 60),
        now: () => now,
      );
      var missCalls = 0;
      var hitCalls = 0;
      Future<bool> miss(String url) async {
        missCalls++;
        return false;
      }

      Future<bool> hit(String url) async {
        hitCalls++;
        return true;
      }

      await memo.probe('miss', miss);
      await memo.probe('miss', miss);
      expect(missCalls, 1);

      await memo.probe('hit', hit);
      await memo.probe('hit', hit);
      expect(hitCalls, 1);

      // Both kinds expire together so cache changes are picked up.
      now = now.add(const Duration(seconds: 61));
      await memo.probe('miss', miss);
      await memo.probe('hit', hit);
      expect(missCalls, 2);
      expect(hitCalls, 2);
    });

    test('errors propagate to all waiters and allow retry', () async {
      final memo = EmoteProbeMemo();
      var fail = true;
      final results = await Future.wait([
        memo
            .probe('u', (_) async {
              if (fail) throw StateError('disk gone');
              return true;
            })
            .catchError((Object _) => false),
        memo
            .probe('u', (_) async {
              if (fail) throw StateError('disk gone');
              return true;
            })
            .catchError((Object _) => false),
      ]);
      expect(results, [false, false]);

      fail = false;
      expect(await memo.probe('u', (_) async => true), isTrue);
    });
  });
}
