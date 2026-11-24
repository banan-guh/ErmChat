import 'package:ermchat/widgets/emote_frame_rate.dart';
import 'package:ermchat/widgets/emote_url_provider.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('tick alignment groups due emotes without waking early', () {
    const now = 1000000;
    final a = now + EmoteUrlProvider.alignWaitUs(2000, nowUs: now);
    final b = now + EmoteUrlProvider.alignWaitUs(9000, nowUs: now);
    expect(a, b);
    for (final fps in [60, 30]) {
      EmoteUrlProvider.frameRate = fps;
      final period = 1000000 ~/ fps;
      for (final wait in [0, 1, 5000, 20000, 40000]) {
        final aligned = EmoteUrlProvider.alignWaitUs(wait, nowUs: 1234567);
        expect(aligned, greaterThanOrEqualTo(wait));
        expect(aligned - wait, lessThan(period));
      }
    }
    EmoteUrlProvider.frameRate = 60;
  });

  test('a 0 frame rate freezes until a nonzero rate returns', () {
    addTearDown(() => EmoteUrlProvider.applyFrameRate(60));
    EmoteUrlProvider.applyFrameRate(0);
    expect(EmoteUrlProvider.animating, isFalse);
    // Alignment stays defined even with nothing ticking.
    expect(EmoteUrlProvider.alignWaitUs(1000, nowUs: 0), greaterThan(0));
    EmoteUrlProvider.applyFrameRate(30);
    expect(EmoteUrlProvider.animating, isTrue);
  });

  test('the shared tick groups, cancels, and joins callbacks', () {
    fakeAsync((async) {
      EmoteUrlProvider.frameRate = 1;
      var fired = 0;
      for (var i = 0; i < 10; i++) {
        EmoteUrlProvider.runOnTick(1000, () => fired++);
      }
      expect(async.pendingTimers.length, 1);
      async.elapse(const Duration(seconds: 2));
      expect(fired, 10);

      fired = 0;
      final a = EmoteUrlProvider.runOnTick(1000, () => fired++);
      final b = EmoteUrlProvider.runOnTick(1000, () => fired += 10);
      a.cancel();
      expect(a.isActive, isFalse);
      expect(b.isActive, isTrue);
      async.elapse(const Duration(seconds: 2));
      expect(fired, 10);

      final c = EmoteUrlProvider.runOnTick(1000, () => fired++);
      c.cancel();
      expect(async.pendingTimers, isEmpty);

      expect(EmoteUrlProvider.joinPendingTick(() {}), isNull);
      final order = <String>[];
      EmoteUrlProvider.runOnTick(0, () => order.add('emote'));
      final joined = EmoteUrlProvider.joinPendingTick(
        () => order.add('joined'),
      );
      expect(joined, isNotNull);
      expect(async.pendingTimers.length, 1);
      async.elapse(const Duration(seconds: 2));
      expect(order, ['emote', 'joined']);
      EmoteUrlProvider.frameRate = 60;
    });
  });

  group('EmoteFrameRatePolicy', () {
    late List<int> applied;
    late List<bool> frozen;
    late bool saver;
    late EmoteFrameRatePolicy policy;

    Future<void> pumpApp(
      WidgetTester tester, {
      bool adaptive = true,
      bool freezePaints = false,
    }) async {
      applied = [];
      frozen = [];
      saver = false;
      policy = EmoteFrameRatePolicy(
        readSaver: () async => saver,
        apply: applied.add,
        freezePaints: frozen.add,
      );
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: TextField())),
      );
      policy
        ..start()
        ..adaptive = adaptive
        ..freezePaintsWhileIdle = freezePaints;
      await tester.pump();
    }

    testWidgets(
      'idle adapts, touches restart it, and a focused field stays active',
      (tester) async {
        await pumpApp(tester);
        expect(policy.fps, kActiveEmoteFps);

        await tester.pump(const Duration(seconds: 29));
        expect(policy.fps, kActiveEmoteFps);
        await tester.pump(const Duration(seconds: 1));
        expect(policy.fps, kIdleEmoteFps);

        await tester.tapAt(const Offset(5, 300));
        expect(policy.fps, kActiveEmoteFps);
        await tester.pump(const Duration(seconds: 20));
        await tester.tapAt(const Offset(5, 300));
        await tester.pump(const Duration(seconds: 20));
        expect(policy.fps, kActiveEmoteFps);

        await tester.tap(find.byType(TextField));
        await tester.pump(const Duration(minutes: 2));
        expect(policy.fps, kActiveEmoteFps);
        policy.dispose();
      },
    );

    testWidgets(
      'battery saver caps use while the chosen idle rate may freeze',
      (tester) async {
        await pumpApp(tester);
        policy.idleFps = 15;
        await tester.pump(const Duration(seconds: 30));
        expect(policy.fps, 15);

        policy.idleFps = 0;
        expect(applied.last, 0);
        saver = true;
        await tester.pump(const Duration(minutes: 1));
        await tester.tapAt(const Offset(5, 300));
        expect(policy.fps, kSaverEmoteFps);

        await tester.pump(const Duration(seconds: 30));
        expect(policy.fps, 0);

        saver = false;
        await tester.pump(const Duration(minutes: 1));
        await tester.tapAt(const Offset(5, 300));
        expect(policy.fps, kActiveEmoteFps);
        policy.dispose();
      },
    );

    testWidgets('paint freezing is independent from the emote frame rate', (
      tester,
    ) async {
      await pumpApp(tester, adaptive: false, freezePaints: true);
      expect(frozen, isEmpty);

      await tester.pump(const Duration(seconds: 29));
      expect(frozen, isEmpty);
      await tester.pump(const Duration(seconds: 1));
      expect(frozen, [true]);
      expect(policy.paintsFrozen, isTrue);
      expect(policy.fps, kActiveEmoteFps);

      await tester.tapAt(const Offset(5, 300));
      expect(frozen, [true, false]);
      expect(policy.paintsFrozen, isFalse);

      policy.adaptive = true;
      await tester.pump(const Duration(seconds: 30));
      expect(policy.fps, kIdleEmoteFps);
      expect(frozen, [true, false, true]);

      policy.adaptive = false;
      expect(policy.fps, kActiveEmoteFps);
      policy.dispose();
    });
  });
}
