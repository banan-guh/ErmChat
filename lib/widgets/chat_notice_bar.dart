import 'dart:async';

import 'package:flutter/material.dart';

import 'app_snack.dart';

// Inline chat notice: lives in the chat column above the composer, so it
// tracks keyboard and composer height changes by layout instead of a
// frozen snackbar margin. Single-notice replace policy with auto-dismiss.
class ChatBarNotice {
  const ChatBarNotice(this.message, {this.actionLabel, this.onAction});

  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;
}

class ChatNoticeController extends ChangeNotifier {
  ChatBarNotice? _current;
  Timer? _timer;

  ChatBarNotice? get current => _current;

  void show(
    String message, {
    String? actionLabel,
    VoidCallback? onAction,
    Duration duration = AppSnack.defaultDuration,
  }) {
    _timer?.cancel();
    _current = ChatBarNotice(
      message,
      actionLabel: actionLabel,
      onAction: onAction,
    );
    notifyListeners();
    _timer = Timer(duration, dismiss);
  }

  void dismiss() {
    _timer?.cancel();
    _timer = null;
    if (_current == null) return;
    _current = null;
    notifyListeners();
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
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeInOut,
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
                      borderRadius: BorderRadius.circular(8),
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
