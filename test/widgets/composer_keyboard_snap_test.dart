import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ermchat/widgets/chat_body.dart';

// The keyboard gesture must be monotonic: the composer only ever travels with
// the keyboard (up while opening, down while closing). The platform hands the
// IME inset through WindowInsetsAnimation.onProgress, but the IME animation is
// the only inset type ImeSyncDeferringInsetsCallback defers; the systemBars
// (nav bar) inset is taken from the captured FINAL WindowInsets and can step
// on the first animated frame. Flutter then composes
//   padding.bottom = max(0, viewPadding.bottom - viewInsets.bottom)
// (lib/ui/hooks.dart:238) and the composer parks at
//   screenH - max(viewInsets, viewPadding).
// A nav-bar hide while the keyboard is still in the safe-area dead zone
// (viewInsets < viewPadding) therefore drops the composer for a frame before
// the rising keyboard lifts it again: the "snap then snap back". These tests
// drive both chrome modes through that platform sequence frame by frame.
void main() {
  const dpr = 3.0;
  const nav = 45.0;
  const screenH = 2340.0 / dpr;

  Widget harness({required bool glass}) {
    return MaterialApp(
      home: Builder(
        builder: (outer) {
          // Read above the Scaffold: the body subtree sees viewInsets
          // stripped to zero once the Scaffold consumes them, exactly like
          // HomeScreen reads them (lib/screens/home_screen.dart:1704).
          final keyboardH = MediaQuery.viewInsetsOf(outer).bottom;
          return Scaffold(
            resizeToAvoidBottomInset: true,
            body: ChatBody(
              liquidGlass: glass,
              emoteMaxFraction: 0.6,
              keyboardH: keyboardH,
              // ChatBody wraps the composer with the shared inputBarKey; this
              // key stays on the content itself in whichever path is live, so
              // its rect ignores the pill/safe-area padding around it.
              composer: const SizedBox(key: Key('composer_content'), height: 56),
              bodyBuilder:
                  (
                    context, {
                    required hideChromeForKeyboard,
                    required maxWidth,
                    required maxHeight,
                    required keyboardH,
                    required composerH,
                  }) => const ColoredBox(
                    color: Colors.green,
                    child: SizedBox.expand(),
                  ),
              threadPanel: const SizedBox.shrink(),
              mentionsPanel: const SizedBox.shrink(),
              modViewPanel: const SizedBox.shrink(),
              emotePickerBuilder: (_, {required sheetBoxHeight}) =>
                  const SizedBox.shrink(),
              autocomplete: const SizedBox.shrink(),
            ),
          );
        },
      ),
    );
  }

  // One platform frame: viewInsets animates, viewPadding is whatever the
  // engine is currently reporting for the nav bar.
  Future<void> frame(
    WidgetTester tester, {
    required double inset,
    required double navVisible,
  }) async {
    tester.view.viewInsets = FakeViewPadding(bottom: inset * dpr);
    tester.view.viewPadding = FakeViewPadding(bottom: navVisible * dpr);
    tester.view.padding = FakeViewPadding(
      bottom: (navVisible - inset).clamp(0.0, navVisible) * dpr,
    );
    await tester.pump(const Duration(milliseconds: 16));
  }

  // Distance the composer content rides above the physical screen bottom.
  double composerOffset(WidgetTester tester) {
    final rect = tester.getRect(find.byKey(const Key('composer_content')));
    return screenH - rect.bottom;
  }

  testWidgets('opening holds the composer against a nav-bar step (glass)', (
    tester,
  ) async {
    for (final glass in <bool>[false, true]) {
      tester.view.physicalSize = const Size(1080, 2340);
      tester.view.devicePixelRatio = dpr;
      addTearDown(tester.view.reset);
      await frame(tester, inset: 0, navVisible: nav);
      await tester.pumpWidget(harness(glass: glass));
      await tester.pumpAndSettle();

      // Keyboard opens. On the first animated frame the engine reports the
      // final systemBars (nav hidden, 0) while the IME is only 5dp up.
      final openOffsets = <double>[composerOffset(tester)];
      for (final h in [5.0, 15.0, 30.0, 45.0, 90.0, 160.0, 240.0, 300.0]) {
        await frame(tester, inset: h, navVisible: 0);
        openOffsets.add(composerOffset(tester));
      }
      for (var i = 1; i < openOffsets.length; i++) {
        expect(
          openOffsets[i],
          greaterThanOrEqualTo(openOffsets[i - 1] - 0.5),
          reason:
              'composer dropped while opening (glass=$glass): $openOffsets',
        );
      }

      // Close: the engine reports the final systemBars (nav visible) from the
      // first frame. The composer must only travel down.
      final closeOffsets = <double>[openOffsets.last];
      for (final h in [240.0, 160.0, 90.0, 45.0, 30.0, 15.0, 5.0, 0.0]) {
        await frame(tester, inset: h, navVisible: nav);
        closeOffsets.add(composerOffset(tester));
      }
      for (var i = 1; i < closeOffsets.length; i++) {
        expect(
          closeOffsets[i],
          lessThanOrEqualTo(closeOffsets[i - 1] + 0.5),
          reason:
              'composer bounced up while closing (glass=$glass): $closeOffsets',
        );
      }
      expect(tester.takeException(), isNull);
    }
  });

  // A focus/edit change can make the engine clear the TextInput client, and
  // viewInsets.bottom momentarily reads 0 before the animation resumes
  // (flutter_keyboard_controller changelog; flutter/flutter#187364). The
  // Scaffold un-resizes for that frame; composerPad has to compensate so the
  // composer does not fall to the bottom and pop back.
  testWidgets('transient zero inset mid-open holds the composer (glass)', (
    tester,
  ) async {
    for (final glass in <bool>[false, true]) {
      tester.view.physicalSize = const Size(1080, 2340);
      tester.view.devicePixelRatio = dpr;
      addTearDown(tester.view.reset);
      await frame(tester, inset: 0, navVisible: nav);
      await tester.pumpWidget(harness(glass: glass));
      await tester.pumpAndSettle();

      final offsets = <double>[composerOffset(tester)];
      for (final h in [60.0, 150.0, 300.0]) {
        await frame(tester, inset: h, navVisible: 0);
        offsets.add(composerOffset(tester));
      }
      final held = offsets.last;
      // One frame of zero, then the inset returns.
      await frame(tester, inset: 0, navVisible: nav);
      offsets.add(composerOffset(tester));
      await frame(tester, inset: 300, navVisible: 0);
      offsets.add(composerOffset(tester));

      for (var i = 1; i < offsets.length; i++) {
        expect(
          offsets[i],
          greaterThanOrEqualTo(offsets[i - 1] - 0.5),
          reason: 'composer fell at the transient zero (glass=$glass): '
              '$offsets (held $held)',
        );
      }
      expect(tester.takeException(), isNull);
    }
  });
}
