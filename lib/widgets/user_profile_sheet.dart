import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:cached_network_image/cached_network_image.dart';
import 'package:url_launcher/url_launcher.dart';
import '../models/moderation_entries.dart';
import '../models/twitch_badge.dart';
import '../models/twitch_message.dart';
import '../services/mod_actions.dart';
import '../services/twitch_api.dart';
import '../services/twitch_auth.dart';
import '../util/date_format.dart';
import '../util/haptics.dart';
import '../util/layout_density.dart';
import '../util/log.dart';
import '../util/mention.dart';
import '../util/prefs.dart';
import 'app_snack.dart';
import 'badge_chip.dart';
import 'mod_view.dart';
import 'sheet_action_row.dart';

class UserProfileSheet extends StatefulWidget {
  final String username;
  final String? userId;
  final String displayName;
  final TwitchApi twitchApi;
  final TwitchAuth twitchAuth;
  final TextEditingController messageController;
  final FocusNode focusNode;
  final VoidCallback onClose;
  final void Function(String login)? onUserBlocked;
  final VoidCallback? onWhisperUser;

  /// Mod action executor plus the channel they apply to. Null (or
  /// [canModerate] false) hides the Timeout/Ban/Unban/Warn rows. The opener
  /// gates [canModerate] on live plus moderator status.
  final ModActions? modActions;
  final String? channel;
  final bool canModerate;

  /// Broadcaster user id for the follow-age lookup. Null hides the row.
  final String? broadcasterUserId;

  /// Local moderation record snapshot from the opener (warn log + active
  /// ban/timeout). Empty/absent hides the record rows.
  final List<WarnEntry> userWarnings;
  final BanEntry? banEntry;

  /// Last-seen suspicious context from the opener. Null hides the row.
  final SuspiciousInfo? suspiciousInfo;

  /// True for your own card; mod rows never apply to yourself.
  final bool isSelf;

  /// Scroll controller for the history list. Kept separate from [anchor] so
  /// list drags scroll only the list and never resize the sheet. A local one
  /// is used when null (tests embedding the sheet directly).
  final ScrollController? scrollController;

  /// Controller handed over by the wrapping DraggableScrollableSheet. It is
  /// attached to a zero-size, non-scrolling anchor so the sheet's programmatic
  /// controller keeps working while the list scrolls independently.
  final ScrollController? anchor;

  /// Sheet controller for the wrapping DraggableScrollableSheet. Card drags
  /// resize the sheet through it; null in tests, where the card is static.
  final DraggableScrollableController? sheetController;

  /// Target of the in-flight measurement-driven sheet resize, null when idle.
  /// The history stays hidden while the sheet animates to it, so a card whose
  /// height changed cannot flash its list before the divider settles.
  final ValueListenable<double?>? autoSeek;

  /// Minimum sheet extent. Card drags clamp here; releasing at it dismisses.
  final double sheetMinExtent;

  /// Card natural height in logical px, reported post-frame whenever it
  /// changes. The sheet sizes its detents off it.
  final ValueChanged<double>? onCardMeasured;

  /// Badges active in this channel, resolved by the opener from buffered
  /// messages. Empty hides the row.
  final List<CardBadge> cardBadges;

  /// Snapshot of this user's buffered messages, oldest first. Rendered
  /// read-only below the fold; empty shows a placeholder row instead.
  final List<TwitchMessage> userMessages;

  /// Builds one history row with full chat styling. Null hides the section.
  final Widget Function(BuildContext context, TwitchMessage message)?
  messageRowBuilder;

  /// Releases the sheet-owning controllers when the widget unmounts. The
  /// route's future completes before its exit animation, so disposing there
  /// would hit a disposed controller while the sheet still lays out.
  final VoidCallback? onDispose;

  /// Liquid glass on: the jump-to-latest button matches chat's glass one.
  final bool glass;

  const UserProfileSheet({
    super.key,
    required this.username,
    this.userId,
    required this.displayName,
    required this.twitchApi,
    required this.twitchAuth,
    required this.messageController,
    required this.focusNode,
    required this.onClose,
    this.onUserBlocked,
    this.onWhisperUser,
    this.modActions,
    this.channel,
    this.canModerate = false,
    this.broadcasterUserId,
    this.userWarnings = const [],
    this.banEntry,
    this.suspiciousInfo,
    this.isSelf = false,
    this.scrollController,
    this.anchor,
    this.sheetController,
    this.autoSeek,
    this.sheetMinExtent = 0.25,
    this.onCardMeasured,
    this.cardBadges = const [],
    this.glass = false,
    this.userMessages = const [],
    this.messageRowBuilder,
    this.onDispose,
  });

  @override
  State<UserProfileSheet> createState() => UserProfileSheetState();
}

class UserProfileSheetState extends State<UserProfileSheet> {
  Map<String, dynamic>? _profile;
  bool _loading = true;
  String? _error;
  String? _followDate;
  bool _anonymous = false;
  bool _arrowVisible = false;
  ScrollController? _fallbackController;
  // Natural card height from the offstage measure copy. Null until the
  // first post-frame read; _measureDirty forces a re-read after content or
  // text-scale changes.
  double? _naturalCardH;
  bool _measureDirty = true;
  // Set once the sheet first rises past the card detent; see sheetBody.
  bool _historyBuilt = false;
  final _cardMeasureKey = GlobalKey();
  ScrollController get _scrollController =>
      widget.scrollController ?? (_fallbackController ??= ScrollController());

  bool get _hasHistory =>
      widget.messageRowBuilder != null && widget.userMessages.isNotEmpty;

  // Rebuilds on sheet size changes and on auto-seek start/stop.
  Listenable get _sheetTicker {
    final controller = widget.sheetController;
    if (controller == null) return _scrollController;
    final auto = widget.autoSeek;
    return auto == null ? controller : Listenable.merge([controller, auto]);
  }

  // True while the sheet is animating to a measured card height. Also true
  // before the list controller attaches, where a seek is still pending.
  bool get _autoSeeking {
    final target = widget.autoSeek?.value;
    final controller = widget.sheetController;
    if (target == null || controller == null) return false;
    if (!controller.isAttached) return true;
    return (controller.size - target).abs() > 0.005;
  }

  @override
  void initState() {
    super.initState();
    _fetchProfile();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _measureDirty = true;
  }

  @override
  void dispose() {
    _fallbackController?.dispose();
    widget.onDispose?.call();
    super.dispose();
  }

  // Reversed history with the latest at offset 0: the arrow shows
  // only while scrolled up toward older messages.
  void _onScrollPixels(double pixels) {
    final away = pixels > 4;
    if (away != _arrowVisible && mounted) {
      setState(() => _arrowVisible = away);
    }
  }

  void _onArrowTap() {
    if (!_scrollController.hasClients) return;
    iosHaptic(HapticFeedback.lightImpact);
    _scrollController.animateTo(
      _scrollController.position.minScrollExtent,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
    );
  }

  // Card drags resize the sheet; release settles via the sheet detents.
  // The card holds no scrollable, so its touches never reach the history.
  void _onCardDrag(DragUpdateDetails details) {
    final controller = widget.sheetController;
    if (controller == null || !controller.isAttached) return;
    final dy = details.primaryDelta;
    if (dy == null || dy == 0) return;
    final fullH = MediaQuery.sizeOf(context).height;
    if (fullH <= 0) return;
    controller.jumpTo(
      (controller.size - dy / fullH)
          .clamp(widget.sheetMinExtent, 1.0)
          .toDouble(),
    );
  }

  // Reads the offstage card height; reports and rebuilds only on change.
  void _syncMeasure() {
    if (!_measureDirty) return;
    final h = _cardMeasureKey.currentContext?.size?.height;
    if (h == null) return;
    _measureDirty = false;
    if (h == _naturalCardH) return;
    if (!mounted) return;
    setState(() => _naturalCardH = h);
    widget.onCardMeasured?.call(h);
  }

  String get _formattedDisplayName {
    final display = _profile?['display_name'] as String? ?? widget.displayName;
    if (display.toLowerCase() == widget.username.toLowerCase()) return display;
    return '${widget.username}($display)';
  }

  Future<void> _fetchProfile() async {
    // No token = show anonymous profile instead of failing.
    if (!widget.twitchAuth.isConfigured) {
      if (!mounted) return;
      setState(() {
        _anonymous = true;
        _loading = false;
        _measureDirty = true;
      });
      return;
    }
    // With the user id known up front, follow age loads alongside the profile.
    final follow = widget.userId != null ? _fetchFollowAge() : null;
    try {
      final profile = await widget.twitchApi.getUserProfile(
        widget.twitchAuth,
        widget.username,
      );
      if (!mounted) return;
      if (profile != null) {
        setState(() {
          _profile = profile;
          _loading = false;
          _measureDirty = true;
        });
        await (follow ?? _fetchFollowAge());
      } else {
        setState(() {
          _error = widget.twitchApi.lastError ?? 'User not found';
          _loading = false;
          _measureDirty = true;
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
        _measureDirty = true;
      });
    }
  }

  // Follow age is a nicety for mods; a failed lookup leaves the line blank.
  Future<void> _fetchFollowAge() async {
    final broadcasterId = widget.broadcasterUserId;
    final userId = _targetUserId;
    if (!_showFollowLine || broadcasterId == null || userId == null) return;
    try {
      final date = await widget.twitchApi.getFollowDate(
        widget.twitchAuth,
        broadcasterId: broadcasterId,
        userId: userId,
      );
      if (!mounted || date == null) return;
      setState(() {
        _followDate = date;
        _measureDirty = true;
      });
    } catch (_) {
      // Line stays blank.
    }
  }

  bool get _showMod =>
      widget.canModerate &&
      !widget.isSelf &&
      widget.modActions != null &&
      widget.channel != null;

  // Reserved from the first frame so the answer never changes card height.
  bool get _showFollowLine => _showMod && widget.broadcasterUserId != null;

  String _formatDate(String iso) {
    final dt = DateTime.tryParse(iso);
    return dt == null ? iso : formatYmd(dt);
  }

  // Top rounding follows the sheet theme; falls back to the M3 default.
  BorderRadius _topRadius(ThemeData theme) {
    const fallback = BorderRadius.vertical(top: Radius.circular(28));
    final shape = theme.bottomSheetTheme.shape;
    if (shape is RoundedRectangleBorder) {
      final resolved = shape.borderRadius.resolve(Directionality.of(context));
      return BorderRadius.only(
        topLeft: resolved.topLeft,
        topRight: resolved.topRight,
      );
    }
    return fallback;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Built while loading too, so the card opens at its final height.
    final actions = _anonymous ? const <Widget>[] : _buildActionTiles();
    final media = MediaQuery.sizeOf(context);
    // Opaque card surface (a Material, so tile ink still renders) with the
    // sheet's top rounding; rows can never bleed through or poke past it.
    final surface =
        theme.bottomSheetTheme.modalBackgroundColor ??
        theme.bottomSheetTheme.backgroundColor ??
        theme.colorScheme.surfaceContainerLow;
    // Built once per state build, outside the sheet ticker: identical
    // instances let drag ticks relayout without rebuilding card or rows.
    final card = Material(
      color: surface,
      borderRadius: _topRadius(theme),
      clipBehavior: Clip.antiAlias,
      child: KeyedSubtree(
        key: _cardMeasureKey,
        child: _buildCard(theme, actions),
      ),
    );
    final Widget? history = widget.messageRowBuilder == null
        ? null
        // Hidden while loading so no row flashes before the card.
        : _loading
        ? const SizedBox.shrink()
        : widget.userMessages.isEmpty
        ? _buildHistoryEmpty(theme)
        : NotificationListener<ScrollUpdateNotification>(
            onNotification: (notification) {
              _onScrollPixels(notification.metrics.pixels);
              return false;
            },
            child: ListView.builder(
              controller: _scrollController,
              reverse: true,
              itemCount: widget.userMessages.length,
              itemBuilder: (context, i) => widget.messageRowBuilder!(
                context,
                widget.userMessages[widget.userMessages.length - 1 - i],
              ),
            ),
          );
    // Card takes its natural height first; the history gets whatever is
    // left (possibly nothing at the card detent) and is revealed by
    // expanding the sheet. The list is reversed (latest at offset 0), so
    // resizes keep the latest glued without any re-pinning. While the sheet
    // auto-seeks, the card fills it so the history cannot flash mid-resize.
    Widget sheetBody(double sheetH, {required bool seeking}) {
      final avail = sheetH.isFinite ? sheetH : media.height;
      if (avail <= 0) return const SizedBox.shrink();
      final natural = _naturalCardH;
      final cardH = (seeking || natural == null) ? avail : min(natural, avail);
      // The list builds the first time the sheet rises past the card
      // detent, then stays built; opening at the card never builds rows.
      // Without an anchor the list's controller is what attaches the sheet,
      // so it must build at once.
      if (!_historyBuilt &&
          (widget.anchor == null || (!seeking && avail - cardH > 1))) {
        _historyBuilt = true;
      }
      return Column(
        children: [
          SizedBox(
            height: cardH,
            child: ClipRect(
              clipper: const _BoxClipper(),
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onVerticalDragUpdate: _onCardDrag,
                child: OverflowBox(
                  minHeight: 0,
                  maxHeight: double.infinity,
                  alignment: Alignment.topCenter,
                  child: card,
                ),
              ),
            ),
          ),
          if (history != null)
            Expanded(child: _historyBuilt ? history : const SizedBox.shrink()),
        ],
      );
    }

    WidgetsBinding.instance.addPostFrameCallback((_) => _syncMeasure());
    // Ticks with the sheet (or the list standalone) so resizes relayout.
    final sheet = AnimatedBuilder(
      animation: _sheetTicker,
      builder: (_, _) {
        final seeking = _autoSeeking;
        return LayoutBuilder(
          builder: (_, constraints) => sheetBody(
            constraints.maxHeight.isFinite
                ? constraints.maxHeight
                : media.height,
            seeking: seeking,
          ),
        );
      },
    );
    return Stack(
      children: [
        sheet,
        // Keeps the DraggableScrollableSheet's scroll controller attached so
        // its programmatic controller works, without letting list drags
        // resize the sheet.
        if (widget.anchor != null)
          SizedBox(
            width: 0,
            height: 0,
            child: SingleChildScrollView(
              controller: widget.anchor,
              physics: const NeverScrollableScrollPhysics(),
              child: const SizedBox.shrink(),
            ),
          ),
        if (_hasHistory)
          Positioned(
            right: 16,
            bottom: 16 + MediaQuery.paddingOf(context).bottom,
            child: AnimatedOpacity(
              opacity: _arrowVisible ? 1 : 0,
              duration: const Duration(milliseconds: 200),
              child: IgnorePointer(
                ignoring: !_arrowVisible,
                child: ExcludeSemantics(
                  excluding: !_arrowVisible,
                  child: _buildHistoryArrow(theme),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildCard(ThemeData theme, List<Widget> actions) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 10),
          child: Center(
            child: Container(
              width: 32,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.grey[400],
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
        ),
        const SizedBox(height: 10),
        if (_error != null)
          Center(
            child: Text(
              _error!,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          )
        else ...[
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: _buildProfileHeader(theme),
          ),
          // Inert until the profile lands; the rows already hold their space.
          IgnorePointer(
            ignoring: _loading,
            child: AnimatedOpacity(
              opacity: _loading ? 0.5 : 1,
              duration: const Duration(milliseconds: 150),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: actions,
              ),
            ),
          ),
        ],
        // Pins with the card, separating it from the scrolling history.
        const Padding(
          padding: EdgeInsets.only(bottom: 8),
          child: Divider(height: 1),
        ),
      ],
    );
  }

  // Same scroll-down FAB as ChatView: appears when scrolled up, jumps to
  // the latest message. Own hero tag so it never collides with chat FABs.
  Widget _buildHistoryArrow(ThemeData theme) {
    if (widget.glass) {
      return GlassIconButton(
        key: const ValueKey('user_history_scroll_down'),
        icon: const Icon(Icons.keyboard_arrow_down),
        shape: GlassIconButtonShape.roundedSquare,
        onPressed: _onArrowTap,
        quality: GlassQuality.minimal,
      );
    }
    return FloatingActionButton(
      key: const ValueKey('user_history_scroll_down'),
      heroTag: 'user_history_scroll_down',
      tooltip: 'Jump to latest',
      onPressed: _onArrowTap,
      child: const Icon(Icons.keyboard_arrow_down),
    );
  }

  Widget _buildHistoryEmpty(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Text(
        'No recent messages from this user here yet',
        style: TextStyle(
          fontSize: 13,
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }

  Widget _buildProfileHeader(ThemeData theme) {
    if (_anonymous) {
      return Row(
        children: [
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(
              Icons.person,
              size: 32,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _formattedDisplayName,
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                    color: theme.colorScheme.onSurface,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'Connect an account to see profile',
                  style: TextStyle(
                    fontSize: 13,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      );
    }
    final detailStyle = TextStyle(
      fontSize: 13,
      color: theme.colorScheme.onSurfaceVariant,
    );
    final avatarSlot = Container(
      width: 96,
      height: 96,
      color: theme.colorScheme.surfaceContainerHighest,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: _profile == null
                  ? avatarSlot
                  : CachedNetworkImage(
                      imageUrl: _profile!['profile_image_url'] as String? ?? '',
                      width: 96,
                      height: 96,
                      fit: BoxFit.cover,
                      memCacheWidth:
                          (96 * MediaQuery.devicePixelRatioOf(context)).round(),
                      fadeInDuration: Duration.zero,
                      placeholder: (_, _) => avatarSlot,
                      errorWidget: (_, _, _) => Container(
                        width: 96,
                        height: 96,
                        color: theme.colorScheme.surfaceContainerHighest,
                        child: Icon(
                          Icons.person,
                          size: 32,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _formattedDisplayName,
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                      color: theme.colorScheme.onSurface,
                    ),
                  ),
                  const SizedBox(height: 2),
                  // Empty lines while loading still hold their height.
                  Text(
                    _profile == null
                        ? ''
                        : 'Created: ${_formatDate(_profile!['created_at'] as String? ?? '')}',
                    style: detailStyle,
                  ),
                  if (_showFollowLine)
                    Text(
                      _followDate == null
                          ? ''
                          : 'Following since ${_formatDate(_followDate!)}',
                      style: detailStyle,
                    ),
                  if (widget.cardBadges.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 4,
                      runSpacing: 4,
                      children: [
                        for (final badge in widget.cardBadges)
                          BadgeChip(
                            label: badge.label,
                            child: _cardBadgeImage(badge),
                          ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
      ],
    );
  }

  static const _cardBadgeSize = 24.0;

  Widget _cardBadgeImage(CardBadge badge) {
    final image = CachedNetworkImage(
      imageUrl: badge.url,
      width: _cardBadgeSize,
      height: _cardBadgeSize,
      fit: badge.circular ? BoxFit.cover : BoxFit.contain,
      fadeInDuration: Duration.zero,
      placeholder: (_, _) =>
          const SizedBox(width: _cardBadgeSize, height: _cardBadgeSize),
      errorWidget: (_, url, error) {
        logDebug('User card badge image failed: $url - $error');
        return const SizedBox(width: _cardBadgeSize, height: _cardBadgeSize);
      },
    );
    return badge.circular ? ClipOval(child: image) : image;
  }

  String? get _targetUserId => widget.userId ?? _profile?['id'] as String?;

  Future<void> _modTimeout() async {
    final modActions = widget.modActions;
    final channel = widget.channel;
    if (modActions == null || channel == null) return;
    final picked = await showTimeoutDialog(context, widget.username);
    if (picked == null || !mounted) return;
    final result = await modActions.timeoutUser(
      widget.twitchAuth,
      channel,
      login: widget.username,
      userId: _targetUserId,
      duration: picked.seconds,
      reason: picked.reason,
    );
    if (!mounted) return;
    showModError(context, result);
  }

  Future<void> _modBan({required bool ban}) async {
    final modActions = widget.modActions;
    final channel = widget.channel;
    if (modActions == null || channel == null) return;
    if (ban) {
      final reason = await showModTextDialog(
        context,
        title: 'Ban ${widget.username}?',
        label: 'Reason (optional)',
        confirmLabel: 'Ban',
        allowEmpty: true,
      );
      if (reason == null || !mounted) return;
      final result = await modActions.banUser(
        widget.twitchAuth,
        channel,
        login: widget.username,
        userId: _targetUserId,
        reason: reason.isEmpty ? null : reason,
      );
      if (!mounted) return;
      showModError(context, result);
    } else {
      final result = await modActions.unbanUser(
        widget.twitchAuth,
        channel,
        login: widget.username,
        userId: _targetUserId,
      );
      if (!mounted) return;
      showModError(context, result);
    }
  }

  Future<void> _modWarn() async {
    final modActions = widget.modActions;
    final channel = widget.channel;
    if (modActions == null || channel == null) return;
    final reason = await showModTextDialog(
      context,
      title: 'Warn ${widget.username}?',
      label: 'Reason (optional)',
      confirmLabel: 'Warn',
      allowEmpty: true,
    );
    if (reason == null || !mounted) return;
    final result = await modActions.warnUser(
      widget.twitchAuth,
      channel,
      login: widget.username,
      userId: _targetUserId,
      reason: reason.isEmpty ? null : reason,
    );
    if (!mounted) return;
    showModError(context, result);
  }

  Future<void> _clearSuspicious() async {
    final modActions = widget.modActions;
    final channel = widget.channel;
    if (modActions == null || channel == null) return;
    final result = await modActions.clearSuspiciousStatus(
      widget.twitchAuth,
      channel,
      login: widget.username,
      userId: _targetUserId,
    );
    if (!mounted) return;
    if (result.ok) {
      AppSnack.show(context, 'Flag cleared for ${widget.displayName}');
    } else {
      showModError(context, result);
    }
  }

  String _recordSubtitle(String? reason, String moderator) {
    if (reason != null && reason.isNotEmpty) return '"$reason" · by $moderator';
    return 'by $moderator';
  }

  // Display-only moderation record: active ban/timeout, warning history,
  // and suspicious context. Empty hides the whole block.
  List<Widget> _recordTiles() {
    final ban = widget.banEntry;
    final warnings = widget.userWarnings;
    final suspicious = widget.suspiciousInfo;
    if (ban == null && warnings.isEmpty && suspicious == null) {
      return const [];
    }
    return [
      if (ban != null)
        ListTile(
          dense: true,
          visualDensity: VisualDensity.compact,
          leading: const Icon(Icons.gavel_outlined),
          title: Text(ban.expiresAt == null ? 'Banned' : 'Timed out'),
          subtitle: Text(_recordSubtitle(ban.reason, ban.moderator)),
        ),
      if (warnings.isNotEmpty)
        ListTile(
          dense: true,
          visualDensity: VisualDensity.compact,
          leading: const Icon(Icons.warning_amber_outlined),
          title: Text(
            warnings.length == 1 ? '1 warning' : '${warnings.length} warnings',
          ),
          subtitle: Text(
            _recordSubtitle(warnings.first.reason, warnings.first.moderator),
          ),
        ),
      if (suspicious != null)
        ListTile(
          dense: true,
          visualDensity: VisualDensity.compact,
          leading: const Icon(Icons.shield_outlined),
          title: Text(_suspiciousTitle(suspicious.status)),
          subtitle: Text(_suspiciousSubtitle(suspicious)),
        ),
      const Divider(height: 1),
    ];
  }

  String _suspiciousTitle(String status) {
    final lower = status.toLowerCase();
    if (lower.contains('restrict')) return 'Restricted user';
    if (lower.contains('monitor')) return 'Monitored user';
    if (lower.isEmpty) return 'Flagged user';
    return 'Flagged user ($status)';
  }

  String _suspiciousSubtitle(SuspiciousInfo info) {
    final parts = <String>[];
    final evasion = info.banEvasion;
    if (evasion != null && evasion.isNotEmpty && evasion != 'unknown') {
      parts.add('$evasion ban evasion');
    }
    if (info.sharedBanChannelIds.isNotEmpty) {
      final n = info.sharedBanChannelIds.length;
      parts.add('banned in $n shared channel${n == 1 ? '' : 's'}');
    }
    if (info.types.isNotEmpty) {
      parts.add(info.types.map((t) => t.replaceAll('_', ' ')).join(', '));
    }
    if (parts.isEmpty) return 'Flagged';
    return parts.join(' · ');
  }

  Future<void> _mentionUser() async {
    widget.onClose();
    final prefs = await Prefs.load();
    final username = widget.username;
    // Mention format preference: how name is inserted into compose box.
    final prefix = formatMention(prefs.mentionFormat, username);
    final text = widget.messageController.text;
    widget.messageController.text = '$prefix$text';
    widget.messageController.selection = TextSelection.fromPosition(
      TextPosition(offset: widget.messageController.text.length),
    );
    widget.focusNode.requestFocus();
  }

  Future<void> _blockUser() async {
    final userId = widget.userId ?? _profile?['id'] as String?;
    if (userId == null) {
      AppSnack.show(context, 'Cannot block: user ID unknown');
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Block user'),
        content: Text(
          'Block ${widget.displayName}? They will not be able to whisper you or host your channel.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Block'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final ok = await widget.twitchApi.blockUser(widget.twitchAuth, userId);
    if (!mounted) return;
    AppSnack.show(
      context,
      ok
          ? '${widget.displayName} blocked'
          : 'Block failed: ${widget.twitchApi.lastError ?? "unknown"}',
    );
    if (ok) widget.onUserBlocked?.call(widget.username);
    widget.onClose();
  }

  Future<void> _reportUser() async {
    final url = Uri.parse('https://twitch.tv/${widget.username}/report');
    final ok = await launchUrl(url, mode: LaunchMode.externalApplication);
    if (!ok && mounted) {
      AppSnack.show(context, 'Could not open the report page');
    }
  }

  List<Widget> _buildActionTiles() {
    final compact = layoutOverridesOf(context).horizontalSheetActions;
    final showMod = _showMod;
    final modActions = <SheetAction>[
      SheetAction(
        icon: Icons.timer_outlined,
        label: 'Timeout',
        onTap: _modTimeout,
      ),
      SheetAction(
        icon: Icons.gavel_outlined,
        label: 'Ban',
        onTap: () => _modBan(ban: true),
      ),
      SheetAction(
        icon: Icons.undo_outlined,
        label: 'Unban',
        onTap: () => _modBan(ban: false),
      ),
      SheetAction(
        icon: Icons.warning_amber_outlined,
        label: 'Warn',
        onTap: _modWarn,
      ),
      if (widget.suspiciousInfo != null)
        SheetAction(
          icon: Icons.visibility_off_outlined,
          label: 'Clear flag',
          onTap: _clearSuspicious,
        ),
    ];
    final userActions = <SheetAction>[
      SheetAction(
        icon: Icons.alternate_email,
        label: compact ? 'Mention' : 'Mention user',
        onTap: _mentionUser,
      ),
      SheetAction(
        icon: Icons.chat_bubble_outline,
        label: compact ? 'Whisper' : 'Whisper user',
        onTap: () {
          widget.onClose();
          widget.onWhisperUser?.call();
        },
      ),
      SheetAction(icon: Icons.block, label: 'Block', onTap: _blockUser),
      SheetAction(
        icon: Icons.flag_outlined,
        label: 'Report',
        onTap: _reportUser,
      ),
    ];
    return [
      if (showMod) ...[
        ..._recordTiles(),
        if (compact)
          SheetActionRow(actions: modActions)
        else
          ..._actionTiles(modActions),
        const Divider(height: 1),
      ],
      if (compact)
        SheetActionRow(actions: userActions)
      else
        ..._actionTiles(userActions),
    ];
  }

  // Full layout keeps the vertical stack of dense list tiles.
  List<Widget> _actionTiles(List<SheetAction> actions) => [
    for (final action in actions)
      ListTile(
        dense: true,
        leading: Icon(action.icon),
        title: Text(action.label),
        onTap: action.onTap,
      ),
  ];
}

// Clips paint and hit testing to the box, so clipped-away card buttons can
// neither show nor fire.
class _BoxClipper extends CustomClipper<Rect> {
  const _BoxClipper();

  @override
  Rect getClip(Size size) => Offset.zero & size;

  @override
  bool shouldReclip(_BoxClipper oldClipper) => false;
}
