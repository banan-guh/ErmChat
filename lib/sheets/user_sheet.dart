import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../models/generic_emote.dart';
import '../models/twitch_badge.dart';
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
import 'message_menu.dart';

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
  UserSheets({
    required this.chatStore,
    required this.chatConn,
    required this.twitchApi,
    required this.twitchAuth,
    required this.modActions,
    required this.emoteManager,
    required this.messageBuilder,
    required this.composer,
    required this.menus,
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
  final MessageMenus menus;
  final UserSheetHost host;

  // Card detent in sheet fractions, derived from the measured card height
  // plus history peek. Starts at the hand-tuned guess until measurement.
  double _cardExtent = 0.5;

  // Last settled target. Late measures skip the yank if the user moved on.
  double _settledTarget = 0.5;

  void showUserProfile(
    BuildContext context,
    String username,
    String? userId, {
    String? displayName,
  }) {
    final channel = host.selectedChannel;
    // Buffer snapshot oldest-first like chat; short-lived, no subscription.
    // The sheet opens pinned to the latest message.
    final history = channel == null
        ? const <TwitchMessage>[]
        : chatStore.recentMessagesFromUser(channel, username).reversed.toList();
    // Badges active in this channel, newest message first. Empty when the
    // user has no buffered messages or nothing resolves.
    var cardBadges = const <CardBadge>[];
    if (channel != null) {
      for (var i = history.length - 1; i >= 0; i--) {
        final resolved = messageBuilder.resolveCardBadges(channel, history[i]);
        if (resolved.isNotEmpty) {
          cardBadges = resolved;
          break;
        }
      }
    }
    // useSafeArea already insets to the status bar; a full fraction lands
    // on the same edge the thread/mention panels top out at.
    const maxChildSize = 1.0;
    final sheetController = DraggableScrollableController();
    // Compact card: history reveals by scrolling. Settle releases only when
    // the gesture moved the sheet, so list scrolling cannot collapse it.
    // Dismiss through the route for one continuous exit motion. Mod rows
    // show wherever the user moderates (EventSub-gated, works offline).
    final canModerate = channel != null && chatConn.isModerationActive(channel);
    final login = host.sessionLogin;
    final isSelf =
        login != null && username.toLowerCase() == login.toLowerCase();
    final screenH = MediaQuery.sizeOf(context).height;
    const minExtent = 0.25;
    // First measurement parks the sheet exactly on the card; the history
    // hides below the fold until expansion. Later measures only retarget
    // the detents. Risk: opens on the estimate, then eases here; rotation
    // mid-open or very slow devices may show that jump.
    void onCardMeasured(double naturalH) {
      final availH =
          screenH -
          MediaQuery.paddingOf(context).top -
          MediaQuery.paddingOf(context).bottom;
      final target = (naturalH / availH)
          .clamp(minExtent, maxChildSize)
          .toDouble();
      _cardExtent = target;
      if (!sheetController.isAttached) return;
      if ((sheetController.size - _settledTarget).abs() > 0.05) return;
      if ((sheetController.size - target).abs() <= 0.02) return;
      sheetController.animateTo(
        target,
        duration: PanelManager.sheetAnimDuration,
        curve: Curves.easeOutCubic,
      );
      _settledTarget = target;
    }

    // Opening estimates until the first measurement lands and settles the
    // sheet onto the real card size.
    final initialChildSize = canModerate && !isSelf ? 0.675 : 0.43;
    _cardExtent = initialChildSize;
    _settledTarget = initialChildSize;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (ctx) {
        var tracker = VelocityTracker.withKind(PointerDeviceKind.touch);
        var sizeAtDown = initialChildSize;
        ScrollController? listController;
        var listOffsetAtDown = 0.0;
        var listMoved = false;
        // Route-level SafeArea clears the nav bar; useSafeArea skips bottom.
        return SafeArea(
          top: false,
          bottom: true,
          child: Listener(
            onPointerDown: (e) {
              sizeAtDown = sheetController.isAttached
                  ? sheetController.size
                  : initialChildSize;
              tracker = VelocityTracker.withKind(PointerDeviceKind.touch);
              tracker.addPosition(e.timeStamp, e.position);
              listMoved = false;
              if (listController?.hasClients ?? false) {
                listOffsetAtDown = listController!.offset;
              }
            },
            onPointerMove: (e) => tracker.addPosition(e.timeStamp, e.position),
            onPointerUp: (_) {
              if (!sheetController.isAttached) return;
              if (listController?.hasClients ?? false) {
                listMoved =
                    (listController!.offset - listOffsetAtDown).abs() > 4;
              }
              final size = sheetController.size;
              final sizeMoved = (size - sizeAtDown).abs() > 0.001;
              final velocityDy = tracker.getVelocity().pixelsPerSecond.dy;
              final target = userSheetTargetDetent(
                size,
                minExtent: minExtent,
                cardExtent: _cardExtent,
                maxExtent: maxChildSize,
                velocityDy: velocityDy,
              );
              final flingDown = velocityDy >= kUserSheetFlingVelocity;
              if (target == minExtent) {
                // Pure list gestures never dismiss; still taps stay put.
                if (listMoved || (!sizeMoved && !flingDown)) return;
                sheetController.jumpTo(size);
                if (ModalRoute.of(ctx)?.isCurrent ?? false) {
                  Navigator.pop(ctx);
                }
                return;
              }
              if (!sizeMoved) return;
              if ((target - size).abs() <= 0.02) return;
              _settledTarget = target;
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
              builder: (_, scrollController) {
                listController = scrollController;
                return UserProfileSheet(
                  username: username,
                  displayName: displayName ?? username,
                  userId: userId,
                  twitchApi: twitchApi,
                  twitchAuth: twitchAuth,
                  modActions: modActions,
                  channel: channel,
                  canModerate: canModerate,
                  broadcasterUserId: channel == null
                      ? null
                      : chatStore.channelUserIds[channel],
                  userWarnings: channel == null
                      ? const []
                      : chatStore.warningsFor(channel, username),
                  banEntry: channel == null
                      ? null
                      : chatStore.banFor(channel, username),
                  suspiciousInfo: channel == null
                      ? null
                      : chatStore.suspiciousFor(channel, username),
                  isSelf: isSelf,
                  messageController: composer.messageController,
                  focusNode: composer.focusNode,
                  onClose: () => Navigator.pop(ctx),
                  onUserBlocked: host.onUserBlocked,
                  onWhisperUser: () => host.showWhispersForUser(username),
                  scrollController: scrollController,
                  sheetController: sheetController,
                  sheetMinExtent: minExtent,
                  onCardMeasured: onCardMeasured,
                  cardBadges: cardBadges,
                  userMessages: history,
                  messageRowBuilder: (ctx, msg) => userHistoryRow(ctx, msg),
                );
              },
            ),
          ),
        );
      },
    ).whenComplete(sheetController.dispose);
  }

  // Read-only history row for the user card: full chat styling, but no
  // profile recursion or reply affordances. Long-press shows the panel
  // menu (copy + mod actions + more); double-tap copies.
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
        onLongPress: () => menus.showPanelMessageMenu(context, msg),
        showTimestamp: host.showTimestamps,
        showImages: messageBuilder.showImages,
        imageHeight: messageBuilder.imageHeight,
        linkWhitelist: messageBuilder.linkWhitelist.entries,
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
      useSafeArea: true,
      builder: (ctx) => SafeArea(
        top: false,
        bottom: true,
        child: EmoteSheet(
          emotes: emotes,
          messageController: composer.messageController,
          focusNode: composer.focusNode,
          onClose: () => Navigator.pop(ctx),
          onUseEmote: emoteManager.markEmoteUsed,
        ),
      ),
    );
  }
}
