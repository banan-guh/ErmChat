import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../widgets/message_input.dart';
import 'composer_controller.dart';

// Single key for measuring the composer (snackbar margin, video sizing).
final inputBarKey = GlobalKey();

// Message input plus connection status row. Bottom padding comes from
// ChatBody, which owns the layout's single inset subscription.
class ComposerBar extends StatelessWidget {
  const ComposerBar({
    super.key,
    required this.controller,
    required this.selectedTabIndex,
  });

  final ComposerController controller;
  final ValueListenable<int> selectedTabIndex;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ColoredBox(
      color: theme.scaffoldBackgroundColor,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListenableBuilder(
            listenable: Listenable.merge([
              controller.cooldownLabel,
              controller.chatConn.connectionStateNotifier,
            ]),
            builder: (context, _) {
              return MessageInput(
                controller: controller.messageController,
                focusNode: controller.focusNode,
                onSend: controller.send,
                onSendLongPress: controller.recallLastSent,
                onTap: controller.onTapClearSuggestions,
                onEmoteToggle: controller.toggleEmoteMenu,
                replyToMsg: controller.replyToMsg,
                onCancelReply: controller.clearReply,
                enabled: controller.enabled,
                hintText: controller.hintText,
              );
            },
          ),
          _StatusRow(
            controller: controller,
            selectedTabIndex: selectedTabIndex,
          ),
        ],
      ),
    );
  }
}

class _StatusRow extends StatelessWidget {
  const _StatusRow({required this.controller, required this.selectedTabIndex});

  final ComposerController controller;
  final ValueListenable<int> selectedTabIndex;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([
        controller.chatStore.versionNotifier(controller.selectedChannel ?? ''),
        selectedTabIndex,
        controller.chatStore.loadFailedChannels,
      ]),
      builder: (context, _) {
        final channel = controller.selectedChannel;
        final status = controller.chatStore.chatStatus[channel];
        final hasStatus = status != null && status.isNotEmpty;
        final hasLoadFailure =
            channel != null &&
            controller.chatStore.loadFailedChannels.value.contains(channel);
        return AnimatedSize(
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeInOut,
          alignment: Alignment.topCenter,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (hasStatus)
                Padding(
                  padding: const EdgeInsets.only(
                    left: 12,
                    right: 12,
                    bottom: 4,
                  ),
                  child: Text(
                    status,
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ),
              if (hasLoadFailure)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: InkWell(
                    onTap: () => controller.chatConn.retryChannelData(channel),
                    child: Text(
                      'Retry failed emotes/badges',
                      style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.primary,
                        decoration: TextDecoration.underline,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}
