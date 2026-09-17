import 'package:ermchat/util/keyboard_governor.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('KeyboardInsetGovernor', () {
    test('passes raw through while settled is unknown', () {
      final gov = KeyboardInsetGovernor();
      expect(gov.consume(100), 100);
      expect(gov.consume(331), 331);
      gov.dispose();
    });

    test('clamps the end-of-animation overshoot to settled plus slack', () {
      final gov = KeyboardInsetGovernor(settled: 302.9);
      expect(gov.consume(286.2), 286.2);
      expect(gov.consume(331.0), closeTo(303.9, 0.01));
      expect(gov.consume(302.9), 302.9);
      gov.dispose();
    });

    test('falling close passes through untouched', () {
      var changed = 0;
      final gov = KeyboardInsetGovernor(
        settled: 302.9,
        onChanged: () => changed++,
      );
      FakeAsync().run((async) {
        for (final raw in [200.0, 100.0, 3.9, 1.8, 0.4]) {
          expect(gov.consume(raw), raw);
        }
        // Tail easing out below the tick threshold: held value stands, and
        // no timer is involved, so nothing can step afterwards.
        expect(gov.consume(0.0), 0.4);
        async.elapse(const Duration(milliseconds: 500));
        expect(changed, 0);
        expect(gov.consume(0.0), 0.4);
      });
      gov.dispose();
    });

    test('distinct zero while falling lands at once', () {
      final gov = KeyboardInsetGovernor(settled: 302.9);
      expect(gov.consume(50.0), 50.0);
      expect(gov.consume(2.0), 2.0);
      expect(gov.consume(0.0), 0.0);
      gov.dispose();
    });

    test('zero amid a rise is held, reopen cancels it', () {
      var changed = 0;
      final gov = KeyboardInsetGovernor(
        settled: 302.9,
        onChanged: () => changed++,
      );
      FakeAsync().run((async) {
        expect(gov.consume(132.0), 132.0);
        expect(gov.consume(218.0), 218.0);
        expect(gov.consume(0.0), 218.0);
        expect(gov.consume(302.9), 302.9);
        async.elapse(const Duration(milliseconds: 200));
        expect(changed, 0);
      });
      gov.dispose();
    });

    test('held zero with silence still closes', () {
      var changed = 0;
      final gov = KeyboardInsetGovernor(
        settled: 302.9,
        onChanged: () => changed++,
      );
      FakeAsync().run((async) {
        expect(gov.consume(218.0), 218.0);
        expect(gov.consume(0.0), 218.0);
        async.elapse(const Duration(milliseconds: 48));
        expect(changed, 1);
        expect(gov.consume(0.0), 0.0);
      });
      gov.dispose();
    });

    test('drift shut without a distinct tick follows it', () {
      final gov = KeyboardInsetGovernor(settled: 302.9);
      expect(gov.consume(5.0), 5.0);
      expect(gov.consume(3.0), 3.0);
      expect(gov.consume(0.6), 0.6);
      expect(gov.consume(0.4), 0.4);
      gov.dispose();
    });

    test('learns a taller keyboard after it holds still', () {
      final saved = <double>[];
      final gov = KeyboardInsetGovernor(settled: 302.9, onSettled: saved.add);
      FakeAsync().run((async) {
        gov.consume(340.0);
        // Clamped until learned.
        expect(gov.consume(340.0), gov.settled + gov.slack);
        async.elapse(const Duration(milliseconds: 120));
        expect(gov.settled, 340.0);
        expect(saved, [340.0]);
        // Next open passes the new height through.
        expect(gov.consume(341.0), 341.0);
      });
      gov.dispose();
    });

    test('ignores unsettled values and tiny heights', () {
      final gov = KeyboardInsetGovernor(settled: 302.9);
      FakeAsync().run((async) {
        gov.consume(200.0);
        async.elapse(const Duration(milliseconds: 50));
        gov.consume(250.0);
        async.elapse(const Duration(milliseconds: 120));
        expect(gov.settled, 250.0);
      });
      gov.dispose();

      final fresh = KeyboardInsetGovernor();
      FakeAsync().run((async) {
        fresh.consume(3.0);
        async.elapse(const Duration(milliseconds: 200));
        expect(fresh.settled, 0);
      });
      fresh.dispose();
    });
  });
}
