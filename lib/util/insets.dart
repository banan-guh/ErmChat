import 'package:flutter/widgets.dart';

/// Status bar height from the app root, notifying only when it changes.
///
/// Below a Scaffold both padding and viewPadding carry the bottom inset,
/// which animates with the keyboard, and MediaQuery has no top-only aspect.
/// The root sits above every Scaffold, where the top inset holds still.
class StatusBarScope extends InheritedWidget {
  const StatusBarScope({super.key, required this.top, required super.child});

  final double top;

  @override
  bool updateShouldNotify(StatusBarScope oldWidget) => top != oldWidget.top;
}

/// Status bar height without subscribing the caller to keyboard ticks.
/// Falls back to viewPadding when no [StatusBarScope] is mounted (tests).
double statusBarHeight(BuildContext context) =>
    context.dependOnInheritedWidgetOfExactType<StatusBarScope>()?.top ??
    MediaQuery.viewPaddingOf(context).top;
