import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/twitch_api.dart';
import '../services/twitch_auth.dart';
import '../util/log.dart';

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
  });

  @override
  State<UserProfileSheet> createState() => UserProfileSheetState();
}

class UserProfileSheetState extends State<UserProfileSheet> {
  Map<String, dynamic>? _profile;
  bool _loading = true;
  String? _error;
  bool _anonymous = false;

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
              child: Text(
                _error!,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ] else if (_anonymous) ...[
            Row(
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
            ),
          ] else if (_profile != null) ...[
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
            ..._buildActionTiles(),
          ],
        ],
      ),
    );
  }

  List<Widget> _buildActionTiles() {
    return [
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
