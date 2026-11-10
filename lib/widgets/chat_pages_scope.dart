import 'package:flutter/material.dart';

/// The chat page stack a spam button anchors under, so it follows the tabs
/// and stream instead of the app bar.
class ChatPagesScope extends InheritedWidget {
  const ChatPagesScope({
    super.key,
    required this.pagesKey,
    required super.child,
  });

  final GlobalKey? pagesKey;

  static GlobalKey? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ChatPagesScope>()?.pagesKey;

  @override
  bool updateShouldNotify(ChatPagesScope oldWidget) =>
      pagesKey != oldWidget.pagesKey;
}
