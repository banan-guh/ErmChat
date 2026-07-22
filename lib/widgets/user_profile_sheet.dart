import 'package:flutter/material.dart';
import '../services/twitch_api.dart';
import '../services/twitch_auth.dart';

class UserProfileSheet extends StatefulWidget {
  final String username;
  final String? userId;
  final String displayName;
  final TwitchAuth twitchAuth;
  final TextEditingController messageController;
  final FocusNode focusNode;
  final VoidCallback onClose;

  const UserProfileSheet({
    super.key,
    required this.username,
    this.userId,
    required this.displayName,
    required this.twitchAuth,
    required this.messageController,
    required this.focusNode,
    required this.onClose,
  });

  @override
  State<UserProfileSheet> createState() => UserProfileSheetState();
}

class UserProfileSheetState extends State<UserProfileSheet> {
  Map<String, dynamic>? _profile;
  bool _loading = true;
  String? _error;

  String get _formattedDisplayName {
    final display = _profile?['display_name'] as String? ?? widget.displayName;
    if (display.toLowerCase() == widget.username.toLowerCase()) return display;
    return '${widget.username}($display)';
  }

  @override
  void initState() {
    super.initState();
    _fetchProfile();
  }

  Future<void> _fetchProfile() async {
    try {
      final profile = await TwitchApi.getUserProfile(
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
          _error = TwitchApi.lastError ?? 'User not found';
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
      return iso;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(
              width: 32,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.grey[400],
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 16),
          if (_loading) ...[
            const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: CircularProgressIndicator(),
              ),
            ),
          ] else if (_error != null) ...[
            Center(
              child: Text(_error!, style: const TextStyle(color: Colors.grey)),
            ),
          ] else if (_profile != null) ...[
            Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.network(
                    _profile!['profile_image_url'] as String? ?? '',
                    width: 64,
                    height: 64,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => Container(
                      width: 64,
                      height: 64,
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
            const SizedBox(height: 16),
            Divider(height: 1, color: theme.dividerColor),
            const SizedBox(height: 4),
            ListTile(
              dense: true,
              leading: const Icon(Icons.alternate_email),
              title: const Text('Mention user'),
              onTap: () {
                widget.onClose();
                final text = widget.messageController.text;
                final prefix = text.isEmpty
                    ? '@${widget.username} '
                    : '@${widget.username} ';
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
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Whisper not yet supported')),
                );
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
                    const SnackBar(
                      content: Text('Cannot block: user ID unknown'),
                    ),
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
                if (confirmed != true || !context.mounted) return;
                final ok = await TwitchApi.blockUser(widget.twitchAuth, userId);
                if (!context.mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                      ok
                          ? '${widget.displayName} blocked'
                          : 'Block failed: ${TwitchApi.lastError ?? "unknown"}',
                    ),
                  ),
                );
                widget.onClose();
              },
            ),
            ListTile(
              dense: true,
              leading: const Icon(Icons.flag_outlined),
              title: const Text('Report'),
              onTap: () async {
                final userId = widget.userId ?? _profile?['id'] as String?;
                if (userId == null) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Cannot report: user ID unknown'),
                    ),
                  );
                  return;
                }
                final reasonController = TextEditingController();
                final confirmed = await showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: const Text('Report user'),
                    content: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text('Report ${widget.displayName} for:'),
                        const SizedBox(height: 12),
                        TextField(
                          controller: reasonController,
                          decoration: const InputDecoration(
                            hintText: 'Reason (optional)',
                            border: OutlineInputBorder(),
                          ),
                          maxLines: 2,
                        ),
                      ],
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(ctx, false),
                        child: const Text('Cancel'),
                      ),
                      FilledButton(
                        onPressed: () => Navigator.pop(ctx, true),
                        child: const Text('Report'),
                      ),
                    ],
                  ),
                );
                if (confirmed != true || !context.mounted) return;
                final broadcasterId = _profile?['id'] as String? ?? userId;
                final ok = await TwitchApi.reportUser(
                  widget.twitchAuth,
                  userId: userId,
                  broadcasterId: broadcasterId,
                  reason: reasonController.text,
                );
                reasonController.dispose();
                if (!context.mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                      ok
                          ? 'Report submitted'
                          : 'Report failed: ${TwitchApi.lastError ?? "unknown"}',
                    ),
                  ),
                );
                widget.onClose();
              },
            ),
          ],
        ],
      ),
    );
  }
}
