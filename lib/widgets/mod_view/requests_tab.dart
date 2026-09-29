import 'dart:async';

import 'package:flutter/material.dart';
import '../../chat/chat.dart';
import '../../services/mod_actions.dart';
import '../../services/twitch_api.dart';
import '../../services/twitch_auth.dart';
import 'common.dart';

class RequestsTab extends StatefulWidget {
  const RequestsTab({
    super.key,
    required this.channel,
    required this.chat,
    required this.modActions,
    required this.auth,
    required this.onNotice,
  });

  final String channel;
  final Chat chat;
  final ModActions modActions;
  final TwitchAuth auth;
  final ValueChanged<String> onNotice;

  @override
  State<RequestsTab> createState() => _RequestsTabState();
}

class _RequestsTabState extends State<RequestsTab>
    with ModTabLoad<RequestsTab> {
  static const _statuses = ['pending', 'approved', 'denied'];

  @override
  ModActions get modActions => widget.modActions;
  @override
  ValueChanged<String> get onNotice => widget.onNotice;

  String _status = 'pending';
  List<UnbanRequest>? _requests;
  String? _error;
  int _loadGen = 0;
  ValueNotifier<int>? _inboxVersion;

  @override
  void initState() {
    super.initState();
    _subscribeInbox();
    _load();
  }

  void _subscribeInbox() {
    _inboxVersion = widget.chat
        .channelFor(widget.channel)
        ?.moderation
        .modInboxVersion;
    _inboxVersion?.addListener(_onInboxChanged);
  }

  void _unsubscribeInbox() {
    _inboxVersion?.removeListener(_onInboxChanged);
    _inboxVersion = null;
  }

  @override
  void didUpdateWidget(covariant RequestsTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.channel != widget.channel) {
      _unsubscribeInbox();
      _subscribeInbox();
      setState(() {
        _status = 'pending';
        _requests = null;
        _error = null;
      });
      _load();
    }
  }

  @override
  void dispose() {
    _unsubscribeInbox();
    super.dispose();
  }

  void _onInboxChanged() => _load();

  void _setStatus(String status) {
    if (_status == status) return;
    setState(() {
      _status = status;
      _requests = null;
      _error = null;
    });
    _load();
  }

  Future<void> _load() async {
    final gen = ++_loadGen;
    final outcome = await guardedLoad<List<UnbanRequest>>(
      gen: gen,
      currentGen: () => _loadGen,
      background: _requests != null,
      request: () => widget.modActions.getUnbanRequests(
        widget.auth,
        widget.channel,
        status: _status,
      ),
      fallbackError: 'Could not load unban requests.',
    );
    if (outcome == null) return;
    setState(() {
      _error = outcome.error;
      if (outcome.error == null) _requests = outcome.value;
    });
  }

  Future<void> _showDetail(UnbanRequest request) async {
    final resolutionCtrl = TextEditingController();
    final pending = showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Request from ${request.userLogin}'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('"${request.text}"'),
              const SizedBox(height: 8),
              Text(
                'Status: ${request.status} · ${modRelativeShortDate(request.createdAt)}',
              ),
              if (request.resolutionText != null &&
                  request.resolutionText!.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text('Resolution: "${request.resolutionText}"'),
                ),
              if (request.status == 'pending') ...[
                const SizedBox(height: 12),
                TextField(
                  controller: resolutionCtrl,
                  maxLength: 500,
                  maxLines: 2,
                  decoration: const InputDecoration(
                    labelText: 'Resolution message (optional)',
                    border: OutlineInputBorder(),
                  ),
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
          if (request.status == 'pending') ...[
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Deny'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Approve'),
            ),
          ],
        ],
      ),
    );
    final decision = await pending;
    final trimmed = resolutionCtrl.text.trim();
    resolutionCtrl.dispose();
    if (decision == null || !mounted) return;
    final result = await widget.modActions.resolveUnbanRequest(
      widget.auth,
      widget.channel,
      requestId: request.id,
      approved: decision,
      resolutionText: trimmed.isEmpty ? null : trimmed,
    );
    if (!mounted) return;
    if (result.ok) {
      widget.onNotice(decision ? 'Request approved.' : 'Request denied.');
      _load();
    } else {
      widget.onNotice(modErrorText(result));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              for (final s in _statuses)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 4,
                        vertical: 4,
                      ),
                      child: Text(s[0].toUpperCase() + s.substring(1)),
                    ),
                    selected: _status == s,
                    onSelected: (_) => _setStatus(s),
                  ),
                ),
            ],
          ),
        ),
        Expanded(child: _body()),
      ],
    );
  }

  Widget _body() {
    if (_error != null && _requests == null) {
      return ModError(message: _error!, onRetry: _load);
    }
    final requests = _requests;
    if (requests == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (requests.isEmpty) {
      return ModEmpty(
        icon: Icons.mark_email_read_outlined,
        title: 'No $_status requests.',
        subtitle: _status == 'pending'
            ? 'New unban requests will appear here.'
            : null,
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 16),
      itemCount: requests.length,
      itemBuilder: (_, i) {
        final request = requests[i];
        return Card(
          margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
          child: ListTile(
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 8,
            ),
            title: Text(request.userLogin),
            subtitle: Text(
              '"${request.text}" · ${modRelativeShortDate(request.createdAt)}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            onTap: () => _showDetail(request),
          ),
        );
      },
    );
  }
}
