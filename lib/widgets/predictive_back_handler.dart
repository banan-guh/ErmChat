import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Routes Android predictive back gestures to the inline thread/mentions
/// panels.
///
/// Registered as a [WidgetsBindingObserver] while the home screen is mounted.
/// Accepts the gesture only when a panel is open (thread/mentions); the
/// closed state (and the emote menu) declines, so the home route's normal
/// back handling — PopScope — keeps working for them.
///
/// While accepted, the system draws the predictive back arrow and this handler
/// reports gesture progress so the panel can shrink following the drag.
/// Holding the gesture freezes the panel; cancel animates it back; commit
/// closes it.
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
