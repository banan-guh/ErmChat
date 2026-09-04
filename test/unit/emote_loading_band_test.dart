import 'package:ermchat/widgets/emote_loading_band.dart';
import 'package:ermchat/widgets/emote_probe_memo.dart';
import 'package:flutter/material.dart';
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

  group('EmoteLoadingClock', () {
    testWidgets('placeholders share one clock lifecycle with refcounting', (
      tester,
    ) async {
      late ValueNotifier<double> phase;
      await tester.pumpWidget(
        const MaterialApp(home: LoadingBand(width: 28, height: 28)),
      );
      expect(EmoteLoadingClock.isActive, isTrue);
      phase = EmoteLoadingClock.phase;

      await tester.pump(const Duration(milliseconds: 300));
      final first = phase.value;
      expect(first, greaterThan(0));

      await tester.pump(const Duration(milliseconds: 300));
      expect(phase.value, isNot(first));

      await tester.pumpWidget(
        const MaterialApp(
          home: Column(
            children: [LoadingBand(width: 28, height: 28), LoadingBand()],
          ),
        ),
      );
      expect(EmoteLoadingClock.isActive, isTrue);

      await tester.pumpWidget(
        const MaterialApp(home: Column(children: [LoadingBand()])),
      );
      expect(EmoteLoadingClock.isActive, isTrue);

      await tester.pumpWidget(const SizedBox.shrink());
      expect(EmoteLoadingClock.isActive, isFalse);

      await tester.pumpWidget(
        const MaterialApp(home: LoadingBand(width: 28, height: 28)),
      );
      expect(EmoteLoadingClock.isActive, isTrue);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(EmoteLoadingClock.isActive, isFalse);
    });
  });
}
