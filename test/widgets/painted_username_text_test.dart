import 'dart:ui' as ui;

import 'package:ermchat/widgets/painted_username_text.dart';
import 'package:ermchat/widgets/seven_tv_paint_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

class _CountingService extends SevenTvPaintService {
  _CountingService() : super(gqlQuery: (_) async => null);

  int shaderCalls = 0;

  @override
  Shader? shaderFor(SevenTvPaint paint, Size size) {
    shaderCalls++;
    return ui.Gradient.linear(Offset.zero, Offset(size.width, 0), const [
      Colors.red,
      Colors.blue,
    ]);
  }

  @override
  Listenable? frameTicker(SevenTvPaint paint) => null;
}

const _gradientPaint = SevenTvPaint(
  id: 'g',
  name: 'g',
  layers: [
    SevenTvLinearGradientLayer(
      stops: [SevenTvPaintStop(at: 0, color: Colors.red)],
      angleDegrees: 90,
      repeating: false,
      opacity: 1,
    ),
  ],
  shadows: [],
);

const _imagePaint = SevenTvPaint(
  id: 'i',
  name: 'i',
  layers: [
    SevenTvImagePaintLayer(
      images: [SevenTvPaintImage(url: 'x', width: 16, height: 16, scale: 1)],
      opacity: 1,
    ),
  ],
  shadows: [],
);

Widget _harness(
  _CountingService service,
  SevenTvPaint paint, {
  Color baseColor = Colors.red,
}) {
  return MaterialApp(
    home: Scaffold(
      body: PaintedUsernameText(
        key: const Key('name'),
        service: service,
        paint: paint,
        text: 'alice',
        baseStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
        fallbackColor: Colors.white,
        baseColor: baseColor,
      ),
    ),
  );
}

RenderCustomPaint _render(WidgetTester tester) =>
    tester.renderObject<RenderCustomPaint>(
      find.descendant(
        of: find.byKey(const Key('name')),
        matching: find.byType(CustomPaint),
      ),
    );

CustomPainter _painter(WidgetTester tester) => _render(tester).painter!;

void _repaint(WidgetTester tester) {
  final render = _render(tester);
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  render.painter!.paint(canvas, render.size);
  recorder.endRecording().dispose();
}

void main() {
  testWidgets('static paint reuses its shader across repaints', (tester) async {
    final service = _CountingService();
    addTearDown(service.dispose);
    await tester.pumpWidget(_harness(service, _gradientPaint));
    final first = service.shaderCalls;
    expect(first, greaterThan(0));

    _repaint(tester);
    _repaint(tester);
    expect(service.shaderCalls, first);
    expect(find.bySemanticsLabel('alice'), findsOneWidget);
  });

  testWidgets('image paint refreshes its shader on every repaint', (
    tester,
  ) async {
    final service = _CountingService();
    addTearDown(service.dispose);
    await tester.pumpWidget(_harness(service, _imagePaint));
    final first = service.shaderCalls;
    expect(first, greaterThan(0));

    _repaint(tester);
    expect(service.shaderCalls, first + 1);
    _repaint(tester);
    expect(service.shaderCalls, first + 2);
  });

  testWidgets('changed visual inputs invalidate the cached shader', (
    tester,
  ) async {
    final service = _CountingService();
    addTearDown(service.dispose);
    await tester.pumpWidget(_harness(service, _gradientPaint));
    final initial = service.shaderCalls;
    final old = _painter(tester);

    await tester.pumpWidget(
      _harness(service, _gradientPaint, baseColor: Colors.green),
    );
    final updated = _painter(tester);
    expect(updated.shouldRepaint(old), isTrue);
    expect(service.shaderCalls, initial + 1);

    await tester.pumpWidget(
      _harness(service, _gradientPaint, baseColor: Colors.green),
    );
    expect(service.shaderCalls, initial + 1);
  });

  test('shadow lists are cached per paint', () {
    final shadows = paintTextShadows(_gradientPaint);
    expect(paintTextShadows(_gradientPaint), same(shadows));

    const withShadow = SevenTvPaint(
      id: 's',
      name: 's',
      layers: [],
      shadows: [
        SevenTvPaintShadow(
          color: Color(0xFF0000FF),
          offsetX: 2,
          offsetY: 2,
          blur: 4,
        ),
      ],
    );
    final other = paintTextShadows(withShadow);
    expect(other, isNot(same(shadows)));
    expect(other.single.color, const Color(0xFF0000FF));
    expect(paintTextShadows(withShadow), same(other));
  });
}
