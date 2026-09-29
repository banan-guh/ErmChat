import 'package:flutter/material.dart';

import '../../services/twitch_api.dart';
import '../../util/date_format.dart';
import 'scope.dart';
import 'widgets.dart';

/// Unban requests, filtered by status.
class RequestsTab extends ModTabWidget {
  const RequestsTab({super.key, required super.mod});

  @override
  State<RequestsTab> createState() => _RequestsTabState();
}

class _RequestsTabState extends State<RequestsTab>
    with ModTabState<RequestsTab> {
  static const _statuses = [
    ('Pending', 'pending'),
    ('Approved', 'approved'),
    ('Denied', 'denied'),
  ];

  String _status = 'pending';
  late final ModLoader<List<UnbanRequest>> _requests;

  @override
  void initState() {
    super.initState();
    _requests = loader(
      (mod) =>
          mod.actions.getUnbanRequests(mod.auth, mod.channel, status: _status),
      failure: 'Could not load unban requests.',
    );
    watch((mod) => mod.moderation?.modInboxVersion, _requests.load);
  }

  @override
  void didChangeChannel() => _status = 'pending';

  void _setStatus(String status) {
    if (_status == status) return;
    setState(() => _status = status);
    _requests.reset();
  }

  Future<void> _showDetail(UnbanRequest request) async {
    final pending = request.status == 'pending';
    final resolution = TextEditingController();
    final decision = await showDialog<bool>(
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
                'Status: ${request.status} · ${formatAgoIso(request.createdAt)}',
              ),
              if (request.resolutionText?.isNotEmpty ?? false)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text('Resolution: "${request.resolutionText}"'),
                ),
              if (pending) ...[
                const SizedBox(height: 12),
                TextField(
                  controller: resolution,
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
          if (pending) ...[
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
    final message = resolution.text.trim();
    resolution.dispose();
    if (decision == null) return;
    final ok = await mod.report(
      mod.actions.resolveUnbanRequest(
        mod.auth,
        mod.channel,
        requestId: request.id,
        approved: decision,
        resolutionText: message.isEmpty ? null : message,
      ),
      done: decision ? 'Request approved.' : 'Request denied.',
    );
    if (ok) _requests.load();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        ModChoiceChips(
          options: _statuses,
          selected: _status,
          onSelected: _setStatus,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        ),
        Expanded(
          child: ModLoadView(
            loader: _requests,
            isEmpty: (requests) => requests.isEmpty,
            empty: ModEmpty(
              icon: Icons.mark_email_read_outlined,
              title: 'No $_status requests.',
              subtitle: _status == 'pending'
                  ? 'New unban requests will appear here.'
                  : null,
            ),
            builder: (context, requests) => ListView.builder(
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 16),
              itemCount: requests.length,
              itemBuilder: (_, i) {
                final request = requests[i];
                return Card(
                  margin: const EdgeInsets.symmetric(
                    horizontal: 4,
                    vertical: 6,
                  ),
                  child: ListTile(
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    title: Text(request.userLogin),
                    subtitle: Text(
                      '"${request.text}" · ${formatAgoIso(request.createdAt)}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    onTap: () => _showDetail(request),
                  ),
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}
