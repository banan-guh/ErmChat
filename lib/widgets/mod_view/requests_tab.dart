import 'package:flutter/material.dart';

import '../../services/twitch_api.dart';
import '../../l10n/l10n.dart';
import '../../util/date_format.dart';
import 'scope.dart';
import 'widgets.dart';
import '../glass_chrome.dart';

/// Unban requests, filtered by status.
class RequestsTab extends ModTabWidget {
  const RequestsTab({super.key, required super.mod});

  @override
  State<RequestsTab> createState() => _RequestsTabState();
}

class _RequestsTabState extends State<RequestsTab>
    with ModTabState<RequestsTab> {
  List<(String, String)> get _statuses => [
    (mod.l10n.requestPending, 'pending'),
    (mod.l10n.requestApproved, 'approved'),
    (mod.l10n.requestDenied, 'denied'),
  ];

  String _statusLabel(String status) => switch (status) {
    'approved' => mod.l10n.requestApproved,
    'denied' => mod.l10n.requestDenied,
    'pending' => mod.l10n.requestPending,
    _ => status,
  };

  String _status = 'pending';
  late final ModLoader<List<UnbanRequest>> _requests;

  @override
  void initState() {
    super.initState();
    _requests = loader(
      (mod) =>
          mod.actions.getUnbanRequests(mod.auth, mod.channel, status: _status),
      failure: mod.l10n.loadUnbanRequestsFailed,
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
        title: Text(mod.l10n.requestFrom(request.userLogin)),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('"${request.text}"'),
              const SizedBox(height: 8),
              Text(
                mod.l10n.requestStatus(
                  _statusLabel(request.status),
                  formatAgoIso(request.createdAt, l: context.l10n),
                ),
              ),
              if (request.resolutionText?.isNotEmpty ?? false)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    mod.l10n.requestResolution(request.resolutionText!),
                  ),
                ),
              if (pending) ...[
                const SizedBox(height: 12),
                TextField(
                  controller: resolution,
                  maxLength: 500,
                  maxLines: 2,
                  decoration: InputDecoration(
                    labelText: mod.l10n.resolutionMessage,
                    border: const OutlineInputBorder(),
                  ),
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(mod.l10n.close),
          ),
          if (pending) ...[
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(mod.l10n.deny),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(mod.l10n.approve),
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
      done: decision
          ? mod.l10n.requestApprovedDone
          : mod.l10n.requestDeniedDone,
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
              title: switch (_status) {
                'approved' => mod.l10n.noApprovedRequests,
                'denied' => mod.l10n.noDeniedRequests,
                _ => mod.l10n.noPendingRequests,
              },
              subtitle: _status == 'pending' ? mod.l10n.newRequestsHint : null,
            ),
            builder: (context, requests) => ListView.builder(
              padding: glassListPadding(
                context,
                const EdgeInsets.fromLTRB(8, 4, 8, 16),
              ),
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
                      '"${request.text}" · ${formatAgoIso(request.createdAt, l: context.l10n)}',
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
