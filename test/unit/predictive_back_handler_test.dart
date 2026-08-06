import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ermchat/widgets/predictive_back_handler.dart';

PredictiveBackEvent _event(double progress) {
  return PredictiveBackEvent.fromMap({
    'progress': progress,
    'swipeEdge': 0,
    'touchOffset': [10.0, 20.0],
  });
}

void main() {
  group('PanelPredictiveBackHandler', () {
    test('declines the gesture when no panel is open', () {
      var progressCalls = 0;
      final handler = PanelPredictiveBackHandler(
        isPanelOpen: () => false,
        onProgress: (_) => progressCalls++,
        onCancel: () {},
        onCommit: () {},
      );

      expect(handler.handleStartBackGesture(_event(0.1)), isFalse);
      handler.handleUpdateBackGestureProgress(_event(0.5));
      expect(progressCalls, 0);
    });

    test('accepts only when a panel is open and reports progress', () {
      var open = true;
      final progress = <double>[];
      final handler = PanelPredictiveBackHandler(
        isPanelOpen: () => open,
        onProgress: progress.add,
        onCancel: () {},
        onCommit: () {},
      );

      expect(handler.handleStartBackGesture(_event(0.0)), isTrue);
      handler.handleUpdateBackGestureProgress(_event(0.3));
      handler.handleUpdateBackGestureProgress(_event(0.7));
      expect(progress, [0.3, 0.7]);

      // Once declined, progress stops flowing.
      open = false;
      expect(handler.handleStartBackGesture(_event(0.0)), isFalse);
      handler.handleUpdateBackGestureProgress(_event(0.5));
      expect(progress, [0.3, 0.7]);
    });

    test('cancel restores, commit closes', () {
      var cancelled = 0;
      var committed = 0;
      final handler = PanelPredictiveBackHandler(
        isPanelOpen: () => true,
        onProgress: (_) {},
        onCancel: () => cancelled++,
        onCommit: () => committed++,
      );

      expect(handler.handleStartBackGesture(_event(0.0)), isTrue);
      handler.handleUpdateBackGestureProgress(_event(0.4));
      handler.handleCancelBackGesture();
      expect(cancelled, 1);
      expect(committed, 0);

      expect(handler.handleStartBackGesture(_event(0.0)), isTrue);
      handler.handleUpdateBackGestureProgress(_event(0.9));
      handler.handleCommitBackGesture();
      expect(committed, 1);
      expect(cancelled, 1);

      // A second commit after the gesture ended does nothing.
      handler.handleCommitBackGesture();
      expect(committed, 1);
    });
  });
}
