import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:cached_network_image/cached_network_image.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import '../models/twitch_badge.dart';
import '../models/twitch_message.dart';
import '../services/mod_actions.dart';
import '../services/twitch_api.dart';
import '../services/twitch_auth.dart';
import '../util/haptics.dart';
import '../util/log.dart';
import 'app_snack.dart';
import 'mod_view.dart';

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
  /// [canModerate] false) hides the Timeout/Ban/Unban/Warn rows.
  final ModActions? modActions;
  final String? channel;
  final bool canModerate;

  /// True for your own card; mod rows never apply to yourself.
  final bool isSelf;

  /// Scroll controller from the wrapping DraggableScrollableSheet. The
  /// history list uses it so its drags coordinate with sheet resizing. A
  /// local one is used when null (tests embedding the sheet directly).
  final ScrollController? scrollController;

  /// Sheet controller for the wrapping DraggableScrollableSheet. Card drags
  /// resize the sheet through it; null in tests, where the card is static.
  final DraggableScrollableController? sheetController;

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
    this.isSelf = false,
    this.scrollController,
    this.sheetController,
    this.sheetMinExtent = 0.25,
    this.onCardMeasured,
    this.cardBadges = const [],
    this.userMessages = const [],
    this.messageRowBuilder,
  });

  @override
  State<UserProfileSheet> createState() => UserProfileSheetState();
}

class UserProfileSheetState extends State<UserProfileSheet> {
  Map<String, dynamic>? _profile;
  bool _loading = true;
  String? _error;
  bool _anonymous = false;
  bool _arrowVisible = false;
  ScrollController? _fallbackController;
  // Natural card height from the offstage measure copy. Null until the
  // first post-frame read; _measureDirty forces a re-read after content or
  // text-scale changes.
  double? _naturalCardH;
  bool _measureDirty = true;
  final _cardMeasureKey = GlobalKey();
  // Max offset our programmatic pin last set. While the offset still sits
  // there, card growth (profile landing, measure settling) moves the
  // goalposts, so later frames re-pin; a user scroll away disables it.
  double _pinnedMax = -1;

  ScrollController get _scrollController =>
      widget.scrollController ?? (_fallbackController ??= ScrollController());

  bool get _hasHistory =>
      widget.messageRowBuilder != null && widget.userMessages.isNotEmpty;

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
    super.dispose();
  }

  // Chronological history with the latest at the bottom: the arrow shows
  // only while scrolled up toward older messages.
  void _onScrollPixels(double pixels, double maxExtent) {
    final away = pixels < maxExtent - 4;
    if (away != _arrowVisible && mounted) {
      setState(() => _arrowVisible = away);
    }
  }

  void _onArrowTap() {
    if (!_scrollController.hasClients) return;
    iosHaptic(HapticFeedback.lightImpact);
    _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
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
      });
      _measureDirty = true;
      return;
    }
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
        });
      } else {
        setState(() {
          _error = widget.twitchApi.lastError ?? 'User not found';
          _loading = false;
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
    _measureDirty = true;
  }

  String _formatDate(String iso) {
    try {
      final dt = DateTime.parse(iso);
      return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
    } catch (_) {
      logDebug('[UserProfileSheet] failed to parse date: $iso');
      return iso;
    }
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
    final actions = _profile != null ? _buildActionTiles() : const <Widget>[];
    final media = MediaQuery.sizeOf(context);
    final measureW = media.width - MediaQuery.paddingOf(context).horizontal;
    // Opaque card surface (a Material, so tile ink still renders) with the
    // sheet's top rounding; rows can never bleed through or poke past it.
    final surface =
        theme.bottomSheetTheme.modalBackgroundColor ??
        theme.bottomSheetTheme.backgroundColor ??
        theme.colorScheme.surfaceContainerLow;
    // Card takes its natural height first; the history gets whatever is
    // left (possibly nothing at the card detent) and is revealed by
    // expanding the sheet.
    Widget sheetBody(double sheetH) {
      final avail = sheetH.isFinite ? sheetH : media.height;
      if (avail <= 0) return const SizedBox.shrink();
      final natural = _naturalCardH;
      final cardH = natural == null ? avail : min(natural, avail);
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
                  maxHeight: double.infinity,
                  alignment: Alignment.topCenter,
                  child: Material(
                    color: surface,
                    borderRadius: _topRadius(theme),
                    clipBehavior: Clip.antiAlias,
                    child: _buildCard(theme, actions),
                  ),
                ),
              ),
            ),
          ),
          if (widget.messageRowBuilder != null) ...[
            Expanded(
              child: widget.userMessages.isEmpty
                  ? _buildHistoryEmpty(theme)
                  : NotificationListener<ScrollUpdateNotification>(
                      onNotification: (notification) {
                        _onScrollPixels(
                          notification.metrics.pixels,
                          notification.metrics.maxScrollExtent,
                        );
                        return false;
                      },
                      child: ListView.builder(
                        controller: _scrollController,
                        itemCount: widget.userMessages.length,
                        itemBuilder: (context, i) => widget.messageRowBuilder!(
                          context,
                          widget.userMessages[i],
                        ),
                      ),
                    ),
            ),
          ],
        ],
      );
    }

    WidgetsBinding.instance.addPostFrameCallback((_) => _syncMeasure());
    // First paints with history land on the latest. Post-frame runs before
    // the paint, so there is no visible flash.
    if (_hasHistory) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_scrollController.hasClients) return;
        final position = _scrollController.position;
        if (position.pixels < position.maxScrollExtent - 4 &&
            position.pixels >= _pinnedMax - 4) {
          _pinnedMax = position.maxScrollExtent;
          _scrollController.jumpTo(position.maxScrollExtent);
        } else if (position.pixels >= position.maxScrollExtent - 4) {
          _pinnedMax = position.maxScrollExtent;
        }
      });
    }
    final sheet = LayoutBuilder(
      builder: (_, constraints) => sheetBody(
        constraints.maxHeight.isFinite ? constraints.maxHeight : media.height,
      ),
    );
    return Stack(
      children: [
        sheet,
        // Offstage copy reads true natural height. OverflowBox lifts the
        // sheet cap; skipped while loading so the spinner never sticks.
        if (_measureDirty && !_loading)
          Offstage(
            child: SizedBox(
              width: measureW,
              child: OverflowBox(
                maxHeight: double.infinity,
                alignment: Alignment.topCenter,
                child: KeyedSubtree(
                  key: _cardMeasureKey,
                  child: _buildCard(theme, actions),
                ),
              ),
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
          padding: const EdgeInsets.only(top: 16),
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
        const SizedBox(height: 16),
        if (_loading)
          const Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: CircularProgressIndicator(),
            ),
          )
        else if (_error != null)
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
          if (_profile != null) ...actions,
        ],
        // Pins with the card, separating it from the scrolling history.
        const Padding(
          padding: EdgeInsets.only(bottom: 12),
          child: Divider(height: 1),
        ),
      ],
    );
  }

  // Same scroll-down FAB as ChatView: appears when scrolled up, jumps to
  // the latest message. Own hero tag so it never collides with chat FABs.
  Widget _buildHistoryArrow(ThemeData theme) {
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.network(
                _profile!['profile_image_url'] as String? ?? '',
                width: 96,
                height: 96,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => Container(
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
                  Text(
                    'Created: ${_formatDate(_profile!['created_at'] as String? ?? '')}',
                    style: TextStyle(
                      fontSize: 13,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  if (widget.cardBadges.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 4,
                      runSpacing: 4,
                      children: [
                        for (final badge in widget.cardBadges)
                          Semantics(
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
        const SizedBox(height: 12),
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

  List<Widget> _buildActionTiles() {
    final showMod =
        widget.canModerate &&
        !widget.isSelf &&
        widget.modActions != null &&
        widget.channel != null;
    return [
      if (showMod) ...[
        ListTile(
          dense: true,
          leading: const Icon(Icons.timer_outlined),
          title: const Text('Timeout'),
          onTap: _modTimeout,
        ),
        ListTile(
          dense: true,
          leading: const Icon(Icons.gavel_outlined),
          title: const Text('Ban'),
          onTap: () => _modBan(ban: true),
        ),
        ListTile(
          dense: true,
          leading: const Icon(Icons.undo_outlined),
          title: const Text('Unban'),
          onTap: () => _modBan(ban: false),
        ),
        ListTile(
          dense: true,
          leading: const Icon(Icons.warning_amber_outlined),
          title: const Text('Warn'),
          onTap: _modWarn,
        ),
        const Divider(height: 1),
      ],
      ListTile(
        dense: true,
        leading: const Icon(Icons.alternate_email),
        title: const Text('Mention user'),
        onTap: () async {
          widget.onClose();
          final prefs = await SharedPreferences.getInstance();
          final username = widget.username;
          // Mention format preference: how name is inserted into compose box.
          final prefix = switch (prefs.getString('mention_format') ?? '@name') {
            'name' => '$username ',
            'name,' => '$username, ',
            '@name,' => '@$username, ',
            _ => '@$username ',
          };
          final text = widget.messageController.text;
          widget.messageController.text = '$prefix$text';
          widget.messageController.selection = TextSelection.fromPosition(
            TextPosition(offset: widget.messageController.text.length),
          );
          widget.focusNode.requestFocus();
        },
      ),
      ListTile(
        dense: true,
        leading: const Icon(Icons.chat_bubble_outline),
        title: const Text('Whisper user'),
        onTap: () {
          widget.onClose();
          widget.onWhisperUser?.call();
        },
      ),
      ListTile(
        dense: true,
        leading: const Icon(Icons.block),
        title: const Text('Block'),
        onTap: () async {
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
          final ok = await widget.twitchApi.blockUser(
            widget.twitchAuth,
            userId,
          );
          if (!mounted) return;
          AppSnack.show(
            context,
            ok
                ? '${widget.displayName} blocked'
                : 'Block failed: ${widget.twitchApi.lastError ?? "unknown"}',
          );
          if (ok) widget.onUserBlocked?.call(widget.username);
          widget.onClose();
        },
      ),
      ListTile(
        dense: true,
        leading: const Icon(Icons.flag_outlined),
        title: const Text('Report'),
        onTap: () async {
          final url = Uri.parse('https://twitch.tv/${widget.username}/report');
          final ok = await launchUrl(url, mode: LaunchMode.externalApplication);
          if (!ok && mounted) {
            AppSnack.show(context, 'Could not open the report page');
          }
        },
      ),
    ];
  }
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
