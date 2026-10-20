import 'dart:async';

import 'package:flutter/material.dart';

import 'app_snack.dart';
import 'design_tokens.dart';

// Inline chat notice: lives in the chat column above the composer, so it
// tracks keyboard and composer height changes by layout instead of a
// frozen snackbar margin. A new notice replaces the current one unless it
// asks to queue; each auto-dismisses.
class ChatBarNotice {
  const ChatBarNotice(this.message, {this.actionLabel, this.onAction});

  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;
}

class ChatNoticeController extends ChangeNotifier {
  ChatBarNotice? _current;
  Timer? _timer;
  final _queue = <(ChatBarNotice, Duration)>[];

  ChatBarNotice? get current => _current;

  /// Inserts the clipboard into the chat input. Set by the screen that owns
  /// the composer, so any copy notice can offer Paste.
  VoidCallback? paste;

  void show(
    String message, {
    String? actionLabel,
    VoidCallback? onAction,
    Duration duration = AppSnack.defaultDuration,
    bool queue = false,
  }) {
    final notice = ChatBarNotice(
      message,
      actionLabel: actionLabel,
      onAction: onAction,
    );
    // Startup notices land at unpredictable times; queued ones wait their
    // turn instead of wiping each other out.
    if (queue && _current != null) {
      _queue.add((notice, duration));
      return;
    }
    _present(notice, duration);
  }

  void _present(ChatBarNotice notice, Duration duration) {
    _timer?.cancel();
    _current = notice;
    notifyListeners();
    _timer = Timer(duration, dismiss);
  }

  /// Ends the current notice; the next queued one, if any, takes its place.
  void dismiss() {
    _timer?.cancel();
    _timer = null;
    if (_queue.isNotEmpty) {
      final (notice, duration) = _queue.removeAt(0);
      _present(notice, duration);
      return;
    }
    if (_current == null) return;
    _current = null;
    notifyListeners();
  }

  /// Drops the current notice and everything queued (screen change).
  void clear() {
    _queue.clear();
    dismiss();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}

// Renders the controller's notice styled like a floating snackbar, with an
// 8dp gap below so it never touches the composer. Collapses to nothing
// when there is no notice, so no stray gap remains.
class ChatNoticeBar extends StatelessWidget {
  const ChatNoticeBar({super.key, required this.controller});

  final ChatNoticeController controller;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final notice = controller.current;
        return AnimatedSize(
          duration: Motion.normal,
          curve: Motion.move,
          alignment: Alignment.bottomCenter,
          child: notice == null
              ? const SizedBox.shrink()
              : Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Dismissible(
                    key: ValueKey(notice),
                    direction: DismissDirection.horizontal,
                    onDismissed: (_) => controller.dismiss(),
                    child: Material(
                      color: Theme.of(context).colorScheme.inverseSurface,
                      borderRadius: BorderRadius.circular(Radii.medium),
                      elevation: 3,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 14, 8, 14),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                notice.message,
                                style: TextStyle(
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.onInverseSurface,
                                ),
                              ),
                            ),
                            if (notice.actionLabel != null)
                              TextButton(
                                onPressed: () {
                                  notice.onAction?.call();
                                  controller.dismiss();
                                },
                                style: TextButton.styleFrom(
                                  foregroundColor: Theme.of(
                                    context,
                                  ).colorScheme.inversePrimary,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                  ),
                                  minimumSize: Size.zero,
                                  tapTargetSize:
                                      MaterialTapTargetSize.shrinkWrap,
                                ),
                                child: Text(notice.actionLabel!),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
        );
      },
    );
  }
}
