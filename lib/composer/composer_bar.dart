import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../panels/mod_panel.dart';
import '../panels/search.dart';
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
    required this.search,
    required this.mod,
    required this.dragTick,
  });

  final ComposerController controller;
  final ValueListenable<int> selectedTabIndex;
  final SearchPanels search;
  final ModPanels mod;

  /// Panel tab drag crossings. The morph tracks 50% through this alone,
  /// without a full HomeScreen rebuild per crossing (main chat's focus
  /// path skips setState the same way); settle still marks dirty.
  final Listenable dragTick;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ColoredBox(
      color: theme.scaffoldBackgroundColor,
      child: ListenableBuilder(
        listenable: Listenable.merge([
          controller.cooldownLabel,
          controller.chatConn.connectionStateNotifier,
          // Auth switches must re-render immediately (anon to user and
          // back), not wait for the next connection-state bump.
          controller.twitchAuth,
          mod.termsAdding,
          dragTick,
        ]),
        builder: (context, _) {
          // Search borrows the input box: same field, own controllers.
          // Reads the live channel per event so tab flips never leak.
          final searchBorrowed =
              search.open && search.host.selectedChannel != null;
          // Terms borrows the input box while its tab is open; every
          // other mod tab keeps the greyed-out chat box below.
          final termsBorrowed = !searchBorrowed && mod.termsInputActive;
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (searchBorrowed)
                MessageInput(
                  controller: search.field,
                  focusNode: search.focusNode,
                  onSend: () {},
                  onChanged: (q) {
                    final channel = search.host.selectedChannel;
                    if (channel != null) search.setQuery(channel, q);
                  },
                  onSubmitted: (_) => search.focusNode.unfocus(),
                  enabled: true,
                  hintText: 'Search...',
                  searchMode: true,
                  prefixOverride: search.closeButton(),
                  suffixOverride: search.filterButton(),
                )
              else if (termsBorrowed)
                MessageInput(
                  controller: mod.termsField,
                  focusNode: mod.composer.focusNode,
                  onSend: mod.submitTerms,
                  onSubmitted: (_) => mod.submitTerms(),
                  enabled: true,
                  hintText: 'Block a word or phrase...',
                  searchMode: true,
                  prefixOverride: mod.termsPrefixSlot(),
                  suffixOverride: mod.termsSubmitSlot(),
                )
              else
                MessageInput(
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
                ),
              if (searchBorrowed || mod.termsChromeHidden)
                const SizedBox.shrink()
              else
                _StatusRow(
                  controller: controller,
                  selectedTabIndex: selectedTabIndex,
                ),
            ],
          );
        },
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
