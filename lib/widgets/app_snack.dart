import 'package:flutter/material.dart';

// Single style for overlay snackbars: floating, swipe-to-dismiss,
// explicit duration, replace-by-default so rapid messages never queue.
abstract final class AppSnack {
  static const defaultDuration = Duration(seconds: 4);

  static ScaffoldFeatureController<SnackBar, SnackBarClosedReason> show(
    BuildContext context,
    String message, {
    String? actionLabel,
    VoidCallback? onAction,
    Duration duration = defaultDuration,
    bool replace = true,
  }) {
    final messenger = ScaffoldMessenger.of(context);
    if (replace) messenger.removeCurrentSnackBar();
    return messenger.showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        dismissDirection: DismissDirection.horizontal,
        duration: duration,
        action: actionLabel != null && onAction != null
            ? SnackBarAction(label: actionLabel, onPressed: onAction)
            : null,
      ),
    );
  }

  // Errors share the standard duration; the name marks intent at call sites.
  static ScaffoldFeatureController<SnackBar, SnackBarClosedReason> showError(
    BuildContext context,
    String message, {
    Duration duration = defaultDuration,
    bool replace = true,
  }) => show(context, message, duration: duration, replace: replace);

  static void clear(BuildContext context) =>
      ScaffoldMessenger.of(context).clearSnackBars();
}

// Root messenger key: lets the route observer pop snackbars on screen
// change without a BuildContext.
final rootScaffoldMessengerKey = GlobalKey<ScaffoldMessengerState>();

// Pops overlay snackbars on fullscreen screen changes so a settings toast
// never lingers onto chat (or vice versa). Dialogs and bottom sheets are
// PopupRoutes, not PageRoutes, so they never trigger a clear.
class SnackPopObserver extends NavigatorObserver {
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route is PageRoute) {
      rootScaffoldMessengerKey.currentState?.clearSnackBars();
    }
    super.didPush(route, previousRoute);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route is PageRoute) {
      rootScaffoldMessengerKey.currentState?.clearSnackBars();
    }
    super.didPop(route, previousRoute);
  }
}
