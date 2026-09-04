import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import '../models/twitch_message.dart';
import '../services/mod_actions.dart';
import '../services/twitch_api.dart';
import '../services/twitch_auth.dart';
import '../util/log.dart';
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

  /// Scroll controller from the wrapping DraggableScrollableSheet. A local
  /// one is used when null (e.g. tests embedding the sheet directly).
  final ScrollController? scrollController;

  /// Sheet controller for the wrapping DraggableScrollableSheet. Drives the
  /// expand arrow (tap jumps to full, arrow hides once revealed). Null in
  /// tests, where the arrow is shown but inert.
  final DraggableScrollableController? sheetController;

  /// Sheet extent the card opens at. The arrow shows while the sheet is at
  /// or below this size and the history is unscrolled.
  final double sheetCollapsedExtent;

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
    this.sheetCollapsedExtent = 0.5,
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
  bool _arrowVisible = true;
  bool _arrowUp = false;
  ScrollController? _fallbackController;

  ScrollController get _scrollController =>
      widget.scrollController ?? (_fallbackController ??= ScrollController());

  bool get _hasHistory =>
      widget.messageRowBuilder != null && widget.userMessages.isNotEmpty;

  @override
  void initState() {
    super.initState();
    widget.sheetController?.addListener(_refreshArrow);
    _fetchProfile();
  }

  @override
  void dispose() {
    widget.sheetController?.removeListener(_refreshArrow);
    _fallbackController?.dispose();
    super.dispose();
  }

  // The floating arrow hints at below-fold history. Scrolled, it flips up
  // and glides back to the top. It hides once the sheet grows past opening.
  void _onScrollPixels(double pixels) {
    final up = pixels > 4;
    if (up != _arrowUp && mounted) setState(() => _arrowUp = up);
    _refreshArrow();
  }

  void _refreshArrow() {
    if (!mounted) return;
    final controller = widget.sheetController;
    final extent = controller != null && controller.isAttached
        ? controller.size
        : null;
    final visible =
        _hasHistory &&
        (_arrowUp ||
            extent == null ||
            extent <= widget.sheetCollapsedExtent + 0.05);
    if (visible != _arrowVisible) setState(() => _arrowVisible = visible);
  }

  void _onArrowTap() {
    // Scrolled: glide back to the top instead of fighting the sheet.
    if (_arrowUp) {
      _scrollController.animateTo(
        0,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
      return;
    }
    _expandSheet();
  }

  void _expandSheet() {
    final controller = widget.sheetController;
    if (controller == null || !controller.isAttached) return;
    // Clamps to maxChildSize automatically.
    controller.animateTo(
      1,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
    );
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final actions = _profile != null ? _buildActionTiles() : const <Widget>[];

    return Stack(
      children: [
        NotificationListener<ScrollUpdateNotification>(
          onNotification: (notification) {
            _onScrollPixels(notification.metrics.pixels);
            return false;
          },
          child: CustomScrollView(
            controller: _scrollController,
            slivers: [
              SliverToBoxAdapter(
                child: Padding(
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
              ),
              const SliverToBoxAdapter(child: SizedBox(height: 16)),
              if (_loading) ...[
                const SliverToBoxAdapter(
                  child: Center(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: CircularProgressIndicator(),
                    ),
                  ),
                ),
              ] else if (_error != null) ...[
                SliverToBoxAdapter(
                  child: Center(
                    child: Text(
                      _error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
              ] else ...[
                SliverPadding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  sliver: SliverToBoxAdapter(child: _buildProfileHeader(theme)),
                ),
                if (_profile != null)
                  SliverList.builder(
                    itemCount: actions.length,
                    itemBuilder: (context, i) => actions[i],
                  ),
                // History is buffer-local, so it shows for anonymous too.
                // Rows live below the fold; the floating arrow hints at them.
                if (widget.messageRowBuilder != null) ...[
                  const SliverToBoxAdapter(
                    child: Padding(
                      padding: EdgeInsets.only(bottom: 12),
                      child: Divider(height: 1),
                    ),
                  ),
                  if (widget.userMessages.isEmpty)
                    SliverToBoxAdapter(child: _buildHistoryEmpty(theme))
                  else
                    SliverList.builder(
                      itemCount: widget.userMessages.length,
                      itemBuilder: (context, i) => widget.messageRowBuilder!(
                        context,
                        widget.userMessages[i],
                      ),
                    ),
                ],
              ],
              const SliverToBoxAdapter(child: SizedBox(height: 24)),
            ],
          ),
        ),
        if (_hasHistory)
          Positioned(
            bottom: 16 + MediaQuery.paddingOf(context).bottom,
            left: 0,
            right: 0,
            child: Center(
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
          ),
      ],
    );
  }

  Widget _buildHistoryArrow(ThemeData theme) {
    return Material(
      shape: const CircleBorder(),
      elevation: 3,
      color: theme.colorScheme.surfaceContainerHighest,
      child: IconButton(
        tooltip: _arrowUp ? 'Back to top' : 'Show recent messages',
        icon: Icon(
          _arrowUp ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down,
        ),
        color: theme.colorScheme.onSurfaceVariant,
        onPressed: _onArrowTap,
      ),
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
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
      ],
    );
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
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Cannot block: user ID unknown')),
            );
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
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                ok
                    ? '${widget.displayName} blocked'
                    : 'Block failed: ${widget.twitchApi.lastError ?? "unknown"}',
              ),
            ),
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
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Could not open the report page')),
            );
          }
        },
      ),
    ];
  }
}
