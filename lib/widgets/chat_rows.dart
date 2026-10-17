import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show Clipboard, ClipboardData, HapticFeedback;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import '../l10n/l10n.dart';
import '../models/twitch_message.dart';
import '../providers/feature_providers.dart' show chatNoticeProvider;
import '../services/link_whitelist.dart';
import '../util/haptics.dart';
import '../util/mention.dart';
import '../util/prefs.dart';
import '../util/thread_utils.dart';
import '../util/timestamp_formatter.dart';
import 'chat_message_tile.dart';
import 'emote_text.dart';
import 'glass_chrome.dart' show kGlassPillSettings;
import 'message_builder.dart';
import 'seven_tv_paint_service.dart';

/// How the chat lists build one row: the tile, its taps and its reply line.
/// [ChatView] and the channel history list share it, so a row behaves the
/// same in both. Caching and row parity stay with each list.
class ChatRows {
  const ChatRows({
    required this.channel,
    required this.messageBuilder,
    required this.onShowUserProfile,
    this.onShowMessageMenu,
    this.onTapMessage,
    this.onCopyMessage,
    this.onFindThreadRoot,
    this.onShowThreadView,
    this.showReplyIndicators = true,
    this.fadeDeleted = true,
    this.showChannel = false,
    this.showTimestamp = true,
    this.timestampFormat = kDefaultTimestampFormat,
    this.checkeredMessages = false,
    this.highlightOpacity = 0.6,
    this.lineSeparator = false,
    this.sharedChatMode = 'spotlight',
    this.paintService,
    this.linkWhitelist,
  });

  final String channel;
  final MessageBuilder messageBuilder;

  /// Opens the user profile sheet.
  final void Function(String login, String? userId, {String? displayName})
  onShowUserProfile;

  /// Null disables the long-press message menu.
  final void Function(TwitchMessage)? onShowMessageMenu;

  /// A tap on a row's body; search results jump to the message.
  final void Function(TwitchMessage)? onTapMessage;

  /// Null disables copy-on-double-tap for chat messages.
  final void Function(TwitchMessage)? onCopyMessage;
  final TwitchMessage? Function(TwitchMessage)? onFindThreadRoot;
  final void Function(TwitchMessage)? onShowThreadView;

  /// Off when thread callbacks are absent or every row is already a reply.
  final bool showReplyIndicators;

  /// Off in the mentions tab so deleted rows stay readable.
  final bool fadeDeleted;

  /// Prefixes rows with their source channel (mentions inbox).
  final bool showChannel;
  final bool showTimestamp;
  final String timestampFormat;
  final bool checkeredMessages;
  final double highlightOpacity;
  final bool lineSeparator;
  final String sharedChatMode;
  final SevenTvPaintService? paintService;

  /// Link whitelist for system-message parser. Null = use messageBuilder's.
  final LinkWhitelist? linkWhitelist;

  /// The row for [msg] at text [scale] over [surface], in a repaint
  /// boundary.
  Widget tile(
    BuildContext context,
    TwitchMessage msg, {
    required bool alternate,
    required double scale,
    required Color surface,
  }) {
    // Use the row's own channel for badge/emote resolution.
    final tileChannel = msg.channel ?? channel;
    // System rows take no taps, reply line, paint, or embeds; the tile reads
    // their body from systemBodyBuilder.
    final chatRow = !msg.isSystem;
    final body = ChatMessageTile(
      message: msg,
      channel: tileChannel,
      surface: surface,
      textScale: scale,
      showTimestamp: showTimestamp,
      timestampFormat: timestampFormat,
      buildBadgeSpans: messageBuilder.buildBadgeSpans,
      buildMessageSpans: messageBuilder.buildMessageSpans,
      bodyIsCached: messageBuilder.bodyIsCached,
      systemBodyBuilder: (msg, scale) => parseTextWithLinks(
        msg.text,
        linkWhitelist: linkWhitelist?.entries,
        onEmailTap: messageBuilder.onEmailTap,
      ),
      onTapUser: chatRow
          ? (login, userId) =>
                onShowUserProfile(login, userId, displayName: msg.displayName)
          : null,
      onDoubleTapUser: chatRow && messageBuilder.doubleTapNameCopy
          ? () => _copyUsername(context, msg)
          : null,
      onLongPress: chatRow && onShowMessageMenu != null
          ? () => onShowMessageMenu!(msg)
          : null,
      onTap: chatRow && onTapMessage != null ? () => onTapMessage!(msg) : null,
      onDoubleTap: chatRow && onCopyMessage != null
          ? () => onCopyMessage!(msg)
          : null,
      replyIndicator:
          chatRow &&
              showReplyIndicators &&
              onFindThreadRoot != null &&
              onShowThreadView != null &&
              msg.replyToUser != null
          ? _replyIndicator(context, msg, scale)
          : null,
      checkeredMessages: checkeredMessages,
      highlightOpacity: highlightOpacity,
      lineSeparator: lineSeparator,
      isAlternateBackground: alternate,
      fadeDeleted: fadeDeleted,
      sharedChatMode: sharedChatMode,
      showChannel: showChannel,
      paintService: chatRow ? paintService : null,
      showImages: chatRow && messageBuilder.showImages,
      imageHeight: messageBuilder.imageHeight,
      linkWhitelist:
          linkWhitelist?.entries ?? messageBuilder.linkWhitelist.entries,
    );
    return RepaintBoundary(child: body);
  }

  /// Copies the sender in the mention format pref, trailing space included
  /// like an inserted emote, and confirms in the chat notice bar with Paste.
  Future<void> _copyUsername(BuildContext context, TwitchMessage msg) async {
    final prefs = await Prefs.load();
    final text = formatMention(prefs.mentionFormat, mentionName(msg));
    await Clipboard.setData(ClipboardData(text: text));
    if (!context.mounted) return;
    final notice = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(chatNoticeProvider);
    notice.show(
      context.l10n.copiedValue(text.trimRight()),
      actionLabel: context.l10n.paste,
      onAction: notice.paste,
    );
  }

  Widget _replyIndicator(
    BuildContext context,
    TwitchMessage msg,
    double scale,
  ) {
    final preview = formatReplyPreview(msg.replyToText ?? '');
    final variant = Theme.of(context).colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.only(left: 12, top: 2),
      child: InkWell(
        onTap: () {
          final root = onFindThreadRoot?.call(msg);
          if (root != null) onShowThreadView?.call(root);
        },
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.reply, size: 16 * scale, color: variant),
            SizedBox(width: 4 * scale),
            Flexible(
              child: Text(
                context.l10n.replyingToUser(
                  msg.replyToUser ?? context.l10n.unknownUser,
                  preview,
                ),
                style: TextStyle(fontSize: 12 * scale, color: variant),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Chat row that pauses its emotes while it sits outside the viewport.
/// Starts enabled so a row built offscreen still decodes its first frame.
class RowGate extends StatefulWidget {
  const RowGate({super.key, required this.gates, required this.child});

  final Set<RowGateState> gates;
  final Widget child;

  @override
  State<RowGate> createState() => RowGateState();
}

class RowGateState extends State<RowGate> {
  final ValueNotifier<bool> visible = ValueNotifier(true);

  @override
  void initState() {
    super.initState();
    widget.gates.add(this);
  }

  @override
  void didUpdateWidget(RowGate oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.gates, widget.gates)) {
      oldWidget.gates.remove(this);
      widget.gates.add(this);
    }
  }

  @override
  void dispose() {
    widget.gates.remove(this);
    visible.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<bool>(
    valueListenable: visible,
    builder: (_, on, child) => TickerMode(enabled: on, child: child!),
    child: widget.child,
  );
}

/// Freezes emotes in rows that sit in the cache extent: laid out beyond the
/// viewport of [pos] but never painted, so their animation is pure waste.
void syncRowGates(Set<RowGateState> gates, ScrollPosition pos) {
  final viewport = pos.context.notificationContext?.findRenderObject();
  if (viewport is! RenderBox || !viewport.hasSize) return;
  final extent = viewport.size.height;
  for (final gate in gates) {
    final box = gate.context.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) continue;
    final top = box.localToGlobal(Offset.zero, ancestor: viewport).dy;
    gate.visible.value = top < extent && top + box.size.height > 0;
  }
}

/// Jump-to-newest button, shown while [atBottom] is false. Glass chrome
/// ([glass]) gets the glass button, otherwise a FAB tagged [heroTag].
class ScrollDownButton extends StatelessWidget {
  const ScrollDownButton({
    super.key,
    required this.atBottom,
    required this.glass,
    required this.heroTag,
    required this.onPressed,
  });

  final bool atBottom;
  final bool glass;
  final Object heroTag;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    void press() {
      iosHaptic(HapticFeedback.lightImpact);
      onPressed();
    }

    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 100),
      transitionBuilder: (child, animation) =>
          FadeTransition(opacity: animation, child: child),
      child: atBottom
          ? const SizedBox.shrink()
          : glass
          ? GlassIconButton(
              key: const ValueKey('scroll_down'),
              icon: const Icon(Icons.keyboard_arrow_down),
              shape: GlassIconButtonShape.roundedSquare,
              onPressed: press,
              useOwnLayer: true,
              settings: kGlassPillSettings,
              quality: GlassQuality.premium,
            )
          : FloatingActionButton(
              key: const ValueKey('scroll_down'),
              heroTag: heroTag,
              onPressed: press,
              child: const Icon(Icons.keyboard_arrow_down),
            ),
    );
  }
}
