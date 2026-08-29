import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Routes Android predictive back to thread/mentions panels. Accepts when panel open; reports progress for shrink/freeze/cancel/commit.
class PanelPredictiveBackHandler with WidgetsBindingObserver {
  PanelPredictiveBackHandler({
    required this._isPanelOpen,
    required this._onProgress,
    required this._onCancel,
    required this._onCommit,
  });

  final bool Function() _isPanelOpen;
  final void Function(double progress) _onProgress;
  final VoidCallback _onCancel;
  final VoidCallback _onCommit;

  bool _accepting = false;

  @override
  bool handleStartBackGesture(PredictiveBackEvent backEvent) {
    if (!_isPanelOpen()) {
      // A new gesture supersedes any previous one.
      _accepting = false;
      return false;
    }
    _accepting = true;
    return true;
  }

  @override
  void handleUpdateBackGestureProgress(PredictiveBackEvent backEvent) {
    if (!_accepting) return;
    _onProgress(backEvent.progress);
  }

  @override
  void handleCancelBackGesture() {
    if (!_accepting) return;
    _accepting = false;
    _onCancel();
  }

  @override
  void handleCommitBackGesture() {
    if (!_accepting) return;
    _accepting = false;
    _onCommit();
  }
}
