import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../panels/mod_panel.dart';
import '../panels/search.dart';
import '../widgets/message_input.dart';
import 'composer_controller.dart';

// DIAG STRIP: bare input bar, no subscriptions, no status row.
class ComposerBar extends StatelessWidget {
  const ComposerBar({
    super.key,
    required this.controller,
    required this.selectedTabIndex,
    required this.search,
    required this.mod,
    required this.dragTick,
    this.transparent = false,
  });

  final ComposerController controller;
  final ValueListenable<int> selectedTabIndex;
  final SearchPanels search;
  final ModPanels mod;
  final bool transparent;
  final Listenable dragTick;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final content = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        MessageInput(
          controller: controller.messageController,
          focusNode: controller.focusNode,
          onSend: controller.send,
          enabled: true,
          hintText: 'Type a message...',
        ),
      ],
    );
    if (transparent) return content;
    return ColoredBox(color: theme.scaffoldBackgroundColor, child: content);
  }
}
