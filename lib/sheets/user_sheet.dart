import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../models/generic_emote.dart';
import '../models/twitch_message.dart';
import '../composer/composer_controller.dart';
import '../services/chat_connection_manager.dart';
import '../services/chat_store.dart';
import '../services/emote_manager.dart';
import '../services/mod_actions.dart';
import '../services/seven_tv_paint_service.dart';
import '../services/twitch_api.dart';
import '../services/twitch_auth.dart';
import '../widgets/chat_message_tile.dart';
import '../widgets/emote_sheet.dart';
import '../widgets/message_builder.dart';
import '../widgets/panel_manager.dart';
import '../widgets/user_profile_sheet.dart';

// Speed above which release direction overrides distance when choosing the
// user-card target. Mirrors the framework's dismiss-fling scale.
const double kUserSheetFlingVelocity = 500.0;

// Nearest user-card detent, for slow releases in the manual eased settle.
double userSheetNearestDetent(
  double size, {
  required double minExtent,
  required double cardExtent,
  required double maxExtent,
}) {
  var target = minExtent;
  var best = (size - minExtent).abs();
  for (final d in <double>[cardExtent, maxExtent]) {
    final dist = (size - d).abs();
    if (dist < best) {
      best = dist;
      target = d;
    }
  }
  return target;
}

// Velocity-directed detent: fast flings move one detent, slow ones use nearest.
double userSheetTargetDetent(
  double size, {
  required double minExtent,
  required double cardExtent,
  required double maxExtent,
  double velocityDy = 0,
}) {
  if (velocityDy <= -kUserSheetFlingVelocity) {
    return size < cardExtent ? cardExtent : maxExtent;
  }
  if (velocityDy >= kUserSheetFlingVelocity) {
    return size <= cardExtent ? minExtent : cardExtent;
  }
  return userSheetNearestDetent(
    size,
    minExtent: minExtent,
    cardExtent: cardExtent,
    maxExtent: maxExtent,
  );
}

// Shell-owned state the user sheet reads but does not own.
abstract class UserSheetHost extends ShellState {
  double get chatFontSize;
  bool get checkeredMessages;
  double get highlightOpacity;
  bool get lineSeparator;
  String get sharedChatMode;
  SevenTvPaintService? get namePaintService;
  void onUserBlocked(String login);
  void showWhispersForUser(String login);
  void copyMessage(TwitchMessage msg);
}

// User card modal with history, plus the per-message emote list sheet.
class UserSheets {
  const UserSheets({
    required this.chatStore,
    required this.chatConn,
    required this.twitchApi,
    required this.twitchAuth,
    required this.modActions,
    required this.emoteManager,
    required this.messageBuilder,
    required this.composer,
    required this.host,
  });

  final ChatStore chatStore;
  final ChatConnectionManager chatConn;
  final TwitchApi twitchApi;
  final TwitchAuth twitchAuth;
  final ModActions modActions;
  final EmoteManager emoteManager;
  final MessageBuilder messageBuilder;
  final ComposerController composer;
  final UserSheetHost host;

  void showUserProfile(
    BuildContext context,
    String username,
    String? userId, {
    String? displayName,
  }) {
    final channel = host.selectedChannel;
    // Buffer snapshot oldest-first like chat; short-lived, no subscription.
    final history = channel == null
        ? const <TwitchMessage>[]
        : chatStore.recentMessagesFromUser(channel, username).reversed.toList();
    // Threads panels top out below the status bar; match that edge here.
    final screenH = MediaQuery.sizeOf(context).height;
    final maxChildSize =
        (screenH - MediaQuery.paddingOf(context).top) / screenH;
    final sheetController = DraggableScrollableController();
    // Compact card: history reveals by scrolling. Settle releases only when
    // the gesture moved the sheet, so list scrolling cannot collapse it.
    // Dismiss through the route for one continuous exit motion. Mod rows add
    // four tiles, so the card opens taller to reach the same history cutoff.
    final canModerate = channel != null && chatConn.isModerationActive(channel);
    final login = host.sessionLogin;
    final isSelf =
        login != null && username.toLowerCase() == login.toLowerCase();
    final initialChildSize = canModerate && !isSelf ? 0.65 : 0.4;
    const minExtent = 0.25;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) {
        var tracker = VelocityTracker.withKind(PointerDeviceKind.touch);
        var sizeAtDown = initialChildSize;
        return Listener(
          onPointerDown: (e) {
            sizeAtDown = sheetController.isAttached
                ? sheetController.size
                : initialChildSize;
            tracker = VelocityTracker.withKind(PointerDeviceKind.touch);
            tracker.addPosition(e.timeStamp, e.position);
          },
          onPointerMove: (e) => tracker.addPosition(e.timeStamp, e.position),
          onPointerUp: (_) {
            if (!sheetController.isAttached) return;
            final size = sheetController.size;
            if ((size - sizeAtDown).abs() <= 0.001) return;
            final target = userSheetTargetDetent(
              size,
              minExtent: minExtent,
              cardExtent: initialChildSize,
              maxExtent: maxChildSize,
              velocityDy: tracker.getVelocity().pixelsPerSecond.dy,
            );
            if (target == minExtent) {
              sheetController.jumpTo(size);
              if (ModalRoute.of(ctx)?.isCurrent ?? false) {
                Navigator.pop(ctx);
              }
              return;
            }
            if ((target - size).abs() <= 0.02) return;
            sheetController.animateTo(
              target,
              duration: PanelManager.sheetAnimDuration,
              curve: Curves.easeOutCubic,
            );
          },
          child: DraggableScrollableSheet(
            controller: sheetController,
            initialChildSize: initialChildSize,
            minChildSize: minExtent,
            maxChildSize: maxChildSize,
            expand: false,
            snap: false,
            builder: (_, scrollController) => UserProfileSheet(
              username: username,
              displayName: displayName ?? username,
              userId: userId,
              twitchApi: twitchApi,
              twitchAuth: twitchAuth,
              modActions: modActions,
              channel: channel,
              canModerate: canModerate,
              isSelf: isSelf,
              messageController: composer.messageController,
              focusNode: composer.focusNode,
              onClose: () => Navigator.pop(ctx),
              onUserBlocked: host.onUserBlocked,
              onWhisperUser: () => host.showWhispersForUser(username),
              scrollController: scrollController,
              sheetController: sheetController,
              sheetCollapsedExtent: initialChildSize,
              userMessages: history,
              messageRowBuilder: (ctx, msg) => userHistoryRow(ctx, msg),
            ),
          ),
        );
      },
    ).whenComplete(sheetController.dispose);
  }

  // Read-only history row for the user card: full chat styling, but no
  // profile recursion, menus, or reply affordances. Double-tap copies.
  Widget userHistoryRow(BuildContext context, TwitchMessage msg) {
    final theme = Theme.of(context);
    // Same background the modal sheet paints, so rows blend into the card.
    final surface =
        theme.bottomSheetTheme.modalBackgroundColor ??
        theme.bottomSheetTheme.backgroundColor ??
        theme.colorScheme.surfaceContainerLow;
    return RepaintBoundary(
      child: ChatMessageTile(
        message: msg,
        channel: msg.channel ?? host.selectedChannel ?? '',
        surface: surface,
        textScale:
            MediaQuery.textScalerOf(context).scale(1.0) *
            host.chatFontSize /
            14.0,
        buildBadgeSpans: messageBuilder.buildBadgeSpans,
        buildMessageSpans: messageBuilder.buildMessageSpans,
        onDoubleTap: () => host.copyMessage(msg),
        showTimestamp: host.showTimestamps,
        timestampFormat: host.timestampFormat,
        checkeredMessages: host.checkeredMessages,
        highlightOpacity: host.highlightOpacity,
        lineSeparator: host.lineSeparator,
        sharedChatMode: host.sharedChatMode,
        fadeDeleted: false,
        paintService: host.namePaintService,
      ),
    );
  }

  void showEmoteSheet(BuildContext context, List<GenericEmote> emotes) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => EmoteSheet(
        emotes: emotes,
        messageController: composer.messageController,
        focusNode: composer.focusNode,
        onClose: () => Navigator.pop(ctx),
        onUseEmote: emoteManager.markEmoteUsed,
      ),
    );
  }
}
