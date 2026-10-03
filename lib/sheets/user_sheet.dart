import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../chat/chat.dart';
import '../client/session.dart';
import '../emotes/emote.dart';
import '../models/twitch_badge.dart';
import '../models/twitch_message.dart';
import '../composer/composer_controller.dart';
import '../util/prefs.dart';
import '../services/chat_connection_manager.dart';
import '../services/emote_manager.dart';
import '../services/emote_usage_registry.dart';
import '../services/mod_actions.dart';
import '../widgets/seven_tv_paint_service.dart';
import '../services/twitch_api.dart';
import '../services/twitch_auth.dart';
import '../widgets/chat_message_tile.dart';
import '../widgets/emote_sheet.dart';
import '../widgets/glass_chrome.dart';
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

// Detent a sheet resting with no finger down eases to: the nearer of card and
// max. Null when it already sits on one, or is closing at min.
double? userSheetRestTarget(
  double size, {
  required double minExtent,
  required double cardExtent,
  required double maxExtent,
}) {
  if (size <= minExtent + 0.001) return null;
  final target = (size - cardExtent).abs() <= (size - maxExtent).abs()
      ? cardExtent
      : maxExtent;
  return (target - size).abs() <= 0.001 ? null : target;
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

// User card modal with history, plus the per-message emote list sheet.
class UserSheets {
  UserSheets({
    required this.chat,
    required this.chatConn,
    required this.twitchApi,
    required this.twitchAuth,
    required this.modActions,
    required this.emoteSource,
    required this.emoteUsage,
    required this.messageBuilder,
    required this.composer,
    required this.menus,
    required this.selectedChannel,
    required this.session,
    required this.paintService,
    required this.onUserBlocked,
    required this.showWhispersForUser,
    required this.copyMessage,
    required this.prefs,
  });

  final Chat chat;
  final ChatConnectionManager chatConn;
  final TwitchApi twitchApi;
  final TwitchAuth twitchAuth;
  final ModActions modActions;
  final EmoteLookupSource emoteSource;
  final EmoteUsageRegistry emoteUsage;
  final MessageBuilder messageBuilder;
  final ComposerController composer;
  final MessageMenus menus;
  final String? Function() selectedChannel;
  final Session session;
  final SevenTvPaintService paintService;
  final void Function(String login) onUserBlocked;
  final void Function(String login) showWhispersForUser;
  final void Function(TwitchMessage msg) copyMessage;
  final Prefs prefs;

  // Card detent in sheet fractions, derived from the measured card height.
  double _cardExtent = 0.0;

  Future<void> showUserProfile(
    BuildContext context,
    String username,
    String? userId, {
    String? displayName,
  }) async {
    final prefs = this.prefs;
    final channel = selectedChannel();
    // Buffer snapshot oldest-first like chat; short-lived, no subscription.
    // The sheet opens pinned to the latest message.
    final history = channel == null
        ? const <TwitchMessage>[]
        : _recentMessagesFromUser(channel, username).reversed.toList();
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
    // Separate controller for the history list, so list drags scroll only the
    // list and never resize the sheet (a reversed list inverts the sheet's
    // built-in resize coupling).
    final historyController = ScrollController();
    // Compact card: history reveals by scrolling. Settle releases only when
    // the gesture moved the sheet, so list scrolling cannot collapse it.
    // Dismiss through the route for one continuous exit motion. Mod rows
    // show only when the channel is live and the user moderates it.
    final canModerate =
        channel != null &&
        chatConn.isModerationActive(channel) &&
        (chat.channelFor(channel)?.info.status ?? '').contains('Live');
    final login = session.login;
    final isSelf =
        login != null && username.toLowerCase() == login.toLowerCase();
    final screenH = MediaQuery.sizeOf(context).height;
    // Real sheet viewport height, captured during layout below. The card
    // detent divides by it so the divider lands on the sheet's bottom edge
    // on any device and text scale.
    double? sheetAvailH;
    // True between pointer down and up, so a content measure does not yank
    // the sheet while the user is dragging it.
    var sheetDragging = false;
    // No floor: a short card must be able to seek to its own height.
    const minExtent = 0.0;
    // Target of the in-flight measurement-driven resize, null when idle. The
    // sheet body hides the history while seeking so a card that changed
    // height cannot flash its list before the divider settles.
    final autoSeek = ValueNotifier<double?>(null);
    // Target of the running seek, so a newer measurement retargets it instead
    // of being ignored because the sheet happens to sit on the new height.
    double? seekTarget;
    // Animates to the latest measured card detent, retargeting if needed.
    void seekToCard() {
      final target = _cardExtent;
      if (seekTarget == target) return;
      if (seekTarget == null &&
          (sheetController.size - target).abs() <= 0.002) {
        return;
      }
      seekTarget = target;
      autoSeek.value = target;
      sheetController.animateTo(
        target,
        duration: PanelManager.sheetAnimDuration,
        curve: Curves.easeOutCubic,
      );
    }

    var measured = false;
    // Every measurement retargets the card detent, so the divider always
    // rests on the sheet's bottom edge and the history hides below the fold.
    void onCardMeasured(double naturalH) {
      // Window box fallback until the first layout reports.
      final fallbackAvail =
          screenH -
          MediaQuery.paddingOf(context).top -
          MediaQuery.paddingOf(context).bottom;
      final availH = sheetAvailH ?? fallbackAvail;
      final target = (naturalH / availH)
          .clamp(minExtent, maxChildSize)
          .toDouble();
      // Never yank a sheet the user expanded above the card. Only retarget
      // when an auto-seek is already in flight (loading card to real card).
      final attached = sheetController.isAttached;
      final size = attached ? sheetController.size : 0.0;
      final seeking = seekTarget != null && (size - seekTarget!).abs() > 0.005;
      final userExpanded = !seeking && attached && size > _cardExtent + 0.05;
      _cardExtent = target;
      if (sheetDragging || userExpanded) {
        autoSeek.value = null;
        return;
      }
      // The first measurement lands while the route is still sliding in;
      // jumping keeps that slide the only motion instead of stacking a
      // resize on it.
      if (!measured) {
        measured = true;
        void jump() {
          if (!sheetController.isAttached) return;
          sheetController.jumpTo(target);
          autoSeek.value = null;
        }

        if (attached) {
          jump();
        } else {
          WidgetsBinding.instance.addPostFrameCallback((_) => jump());
        }
        return;
      }
      // Hide the history until the sheet reaches the measured card. The list
      // controller attaches a frame late, so keep the flag set and seek from
      // a post-frame callback the first time.
      autoSeek.value = target;
      if (!attached) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!sheetDragging && sheetController.isAttached) seekToCard();
        });
        return;
      }
      seekToCard();
    }

    // The first frame must have a positive height or the history list never
    // attaches and the controller cannot animate. Reuse the last measured
    // card when we have one; otherwise start at a sliver. The resting height
    // is always the measurement, never this.
    final initialChildSize = _cardExtent > 0.02 ? _cardExtent : 0.001;
    _cardExtent = initialChildSize;
    // Safety net for motion no release handler sees (a list fling that runs
    // into the sheet, a cancelled pointer): once the sheet rests between
    // detents with no finger down, it eases to the nearest one.
    Timer? restTimer;
    void settleIfStranded() {
      if (sheetDragging || !sheetController.isAttached) return;
      if (autoSeek.value != null) return;
      final target = userSheetRestTarget(
        sheetController.size,
        minExtent: minExtent,
        cardExtent: _cardExtent,
        maxExtent: maxChildSize,
      );
      if (target == null) return;
      sheetController.animateTo(
        target,
        duration: PanelManager.sheetAnimDuration,
        curve: Curves.easeOutCubic,
      );
    }

    sheetController.addListener(() {
      restTimer?.cancel();
      if (sheetDragging) return;
      restTimer = Timer(const Duration(milliseconds: 150), settleIfStranded);
    });
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      // The route's own drag moves the whole modal, including on list
      // overscroll; resizing and dismissal are owned here instead.
      enableDrag: false,
      // Dismissal pops mid-fling, so the exit must start fast and ease out.
      // The stock reverse curve starts flat, stalling the released sheet.
      sheetAnimationStyle: const AnimationStyle(
        reverseCurve: Curves.easeInCubic,
      ),
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
              sheetDragging = true;
              autoSeek.value = null;
              seekTarget = null;
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
            onPointerCancel: (_) {
              sheetDragging = false;
              settleIfStranded();
            },
            onPointerUp: (_) {
              sheetDragging = false;
              if (!sheetController.isAttached) return;
              if (listController?.hasClients ?? false) {
                listMoved =
                    (listController!.offset - listOffsetAtDown).abs() > 4;
              }
              final size = sheetController.size;
              final sizeMoved = (size - sizeAtDown).abs() > 0.001;
              // A gesture that only scrolled the list never resizes or
              // dismisses the sheet; one that also moved it still settles.
              if (listMoved && !sizeMoved) return;
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
                // Still taps stay put.
                if (!sizeMoved && !flingDown) return;
                sheetController.jumpTo(size);
                if (ModalRoute.of(ctx)?.isCurrent ?? false) {
                  Navigator.pop(ctx);
                }
                return;
              }
              if (!sizeMoved) return;
              if ((target - size).abs() <= 0.001) return;
              sheetController.animateTo(
                target,
                duration: PanelManager.sheetAnimDuration,
                curve: Curves.easeOutCubic,
              );
            },
            child: LayoutBuilder(
              builder: (_, sheetConstraints) {
                // Same constraints the sheet sizes against, so naturalH
                // over this height is the exact detent.
                sheetAvailH = sheetConstraints.maxHeight;
                return DraggableScrollableSheet(
                  controller: sheetController,
                  initialChildSize: initialChildSize,
                  minChildSize: minExtent,
                  maxChildSize: maxChildSize,
                  expand: false,
                  snap: false,
                  shouldCloseOnMinExtent: false,
                  builder: (_, scrollController) {
                    listController = historyController;
                    return UserProfileSheet(
                      glass: glassEnabled(context, prefs.liquidGlass),
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
                          : chat.channelFor(channel)?.info.broadcasterId,
                      userWarnings: channel == null
                          ? const []
                          : chat
                                    .channelFor(channel)
                                    ?.moderation
                                    .warningsFor(username) ??
                                const [],
                      banEntry: channel == null
                          ? null
                          : chat
                                .channelFor(channel)
                                ?.moderation
                                .banFor(username),
                      suspiciousInfo: channel == null
                          ? null
                          : chat
                                .channelFor(channel)
                                ?.moderation
                                .suspiciousFor(username),
                      isSelf: isSelf,
                      messageController: composer.messageController,
                      focusNode: composer.focusNode,
                      onClose: () => Navigator.pop(ctx),
                      onUserBlocked: onUserBlocked,
                      onWhisperUser: () => showWhispersForUser(username),
                      scrollController: historyController,
                      anchor: scrollController,
                      sheetController: sheetController,
                      autoSeek: autoSeek,
                      sheetMinExtent: minExtent,
                      onCardMeasured: onCardMeasured,
                      cardBadges: cardBadges,
                      userMessages: history,
                      messageRowBuilder: (ctx, msg) =>
                          userHistoryRow(ctx, msg, prefs),
                      // Disposing on the route future would run before the
                      // sheet's exit animation and crash its controllers.
                      onDispose: () {
                        restTimer?.cancel();
                        sheetController.dispose();
                        historyController.dispose();
                        autoSeek.dispose();
                      },
                    );
                  },
                );
              },
            ),
          ),
        );
      },
    );
  }

  // Newest-first non-system messages from login.
  List<TwitchMessage> _recentMessagesFromUser(
    String channel,
    String login, {
    int limit = 50,
  }) {
    final want = login.toLowerCase();
    if (want.isEmpty || limit <= 0) return [];
    final msgs = chat.channelFor(channel)?.messages.items;
    if (msgs == null) return [];
    final out = <TwitchMessage>[];
    for (final msg in msgs) {
      if (out.length >= limit) break;
      if (msg.isSystem || msg.login.toLowerCase() != want) continue;
      out.add(msg);
    }
    return out;
  }

  // Read-only history row for the user card: full chat styling, but no
  // profile recursion or reply affordances. Long-press shows the panel
  // menu (copy + mod actions + more); double-tap copies.
  Widget userHistoryRow(BuildContext context, TwitchMessage msg, Prefs prefs) {
    final theme = Theme.of(context);
    // Same background the modal sheet paints, so rows blend into the card.
    final surface =
        theme.bottomSheetTheme.modalBackgroundColor ??
        theme.bottomSheetTheme.backgroundColor ??
        theme.colorScheme.surfaceContainerLow;
    return RepaintBoundary(
      child: ChatMessageTile(
        message: msg,
        channel: msg.channel ?? selectedChannel() ?? '',
        surface: surface,
        textScale:
            MediaQuery.textScalerOf(context).scale(1.0) *
            prefs.chatFontSize /
            14.0,
        buildBadgeSpans: messageBuilder.buildBadgeSpans,
        buildMessageSpans: messageBuilder.buildMessageSpans,
        bodyIsCached: messageBuilder.bodyIsCached,
        onDoubleTap: () => copyMessage(msg),
        onLongPress: () => menus.showPanelMessageMenu(context, msg),
        showTimestamp: prefs.showTimestamps,
        showImages: messageBuilder.showImages,
        imageHeight: messageBuilder.imageHeight,
        linkWhitelist: messageBuilder.linkWhitelist.entries,
        timestampFormat: prefs.timestampFormat,
        checkeredMessages: prefs.checkeredMessages,
        highlightOpacity: prefs.highlightOpacity,
        lineSeparator: prefs.lineSeparator,
        sharedChatMode: prefs.sharedChatMode,
        fadeDeleted: false,
        paintService: prefs.seventvNamePaints ? paintService : null,
      ),
    );
  }

  void showEmoteSheet(BuildContext context, List<Emote> emotes) {
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
          onUseEmote: emoteUsage.markEmoteUsed,
          images: emoteSource.images,
        ),
      ),
    );
  }
}
