import 'package:ermchat/widgets/emote_frame_rate.dart';
import 'package:ermchat/widgets/emote_url_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('alignWaitUs', () {
    tearDown(() => EmoteUrlProvider.frameRate = 60);

    test('emotes due within one tick wake together', () {
      const now = 1000000;
      final a = now + EmoteUrlProvider.alignWaitUs(2000, nowUs: now);
      final b = now + EmoteUrlProvider.alignWaitUs(9000, nowUs: now);
      expect(a, b);
    });

    test('never wakes early and waits at most one tick extra', () {
      for (final fps in [60, 30]) {
        EmoteUrlProvider.frameRate = fps;
        final period = 1000000 ~/ fps;
        for (final wait in [0, 1, 5000, 20000, 40000]) {
          final aligned = EmoteUrlProvider.alignWaitUs(wait, nowUs: 1234567);
          expect(aligned, greaterThanOrEqualTo(wait));
          expect(aligned - wait, lessThan(period));
        }
      }
    });
  });

  group('EmoteFrameRatePolicy', () {
    late List<int> applied;
    late bool saver;
    late EmoteFrameRatePolicy policy;

    Future<void> pumpApp(WidgetTester tester, {bool adaptive = true}) async {
      applied = [];
      saver = false;
      policy = EmoteFrameRatePolicy(
        readSaver: () async => saver,
        apply: applied.add,
      );
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: TextField())),
      );
      policy
        ..start()
        ..adaptive = adaptive;
      await tester.pump();
    }

    testWidgets('fixed mode stays at 60 when idle', (tester) async {
      await pumpApp(tester, adaptive: false);
      await tester.pump(const Duration(minutes: 2));
      expect(policy.fps, kActiveEmoteFps);
      expect(applied, [kActiveEmoteFps]);
    });

    testWidgets('drops to 30 when idle, back to 60 on touch', (tester) async {
      await pumpApp(tester);
      expect(policy.fps, kActiveEmoteFps);

      await tester.pump(const Duration(seconds: 29));
      expect(policy.fps, kActiveEmoteFps);
      await tester.pump(const Duration(seconds: 1));
      expect(policy.fps, kIdleEmoteFps);

      await tester.tapAt(const Offset(5, 300));
      expect(policy.fps, kActiveEmoteFps);
      policy.dispose();
    });

    testWidgets('a touch restarts the idle countdown', (tester) async {
      await pumpApp(tester);
      await tester.pump(const Duration(seconds: 20));
      await tester.tapAt(const Offset(5, 300));
      await tester.pump(const Duration(seconds: 20));
      expect(policy.fps, kActiveEmoteFps);
      policy.dispose();
    });

    testWidgets('battery saver drops to 30 while active', (tester) async {
      await pumpApp(tester);
      saver = true;
      await tester.pump(const Duration(minutes: 1));
      await tester.tapAt(const Offset(5, 300));
      expect(policy.fps, kIdleEmoteFps);

      saver = false;
      await tester.pump(const Duration(minutes: 1));
      await tester.tapAt(const Offset(5, 300));
      expect(policy.fps, kActiveEmoteFps);
      policy.dispose();
    });

    testWidgets('a focused text field counts as use', (tester) async {
      await pumpApp(tester);
      await tester.tap(find.byType(TextField));
      await tester.pump(const Duration(minutes: 2));
      expect(policy.fps, kActiveEmoteFps);
      policy.dispose();
    });

    testWidgets('turning adaptive off restores 60', (tester) async {
      await pumpApp(tester);
      await tester.pump(const Duration(seconds: 30));
      expect(policy.fps, kIdleEmoteFps);
      policy.adaptive = false;
      expect(policy.fps, kActiveEmoteFps);
      policy.dispose();
    });
  });
}
