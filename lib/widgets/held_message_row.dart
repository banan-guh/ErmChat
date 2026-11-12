import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../models/twitch_message.dart';
import 'design_tokens.dart';

/// An AutoMod-held message in the chat list. Allow and Deny resolve it; the
/// row leaves the list when the resolution lands.
class HeldMessageRow extends StatefulWidget {
  const HeldMessageRow({
    super.key,
    required this.message,
    required this.onDecide,
    this.timestamp,
  });

  final TwitchMessage message;
  final Future<void> Function(bool allow) onDecide;
  final String? timestamp;

  @override
  State<HeldMessageRow> createState() => _HeldMessageRowState();
}

class _HeldMessageRowState extends State<HeldMessageRow> {
  bool _busy = false;

  Future<void> _decide(bool allow) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await widget.onDecide(allow);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final msg = widget.message;
    final category = msg.heldCategory;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 3, 8, 3),
      child: Semantics(
        label: '${l.automodHeldInChat}: ${msg.login}: ${msg.text}',
        child: Container(
          decoration: BoxDecoration(
            color: scheme.errorContainer.withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(Radii.small),
            border: Border(left: BorderSide(color: scheme.error, width: 3)),
          ),
          padding: const EdgeInsets.fromLTRB(10, 6, 6, 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.shield_outlined,
                    size: 16,
                    color: scheme.onErrorContainer,
                  ),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      [
                        l.automodHeldInChat,
                        if (category != null && category.isNotEmpty) category,
                      ].join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: scheme.onErrorContainer,
                      ),
                    ),
                  ),
                  if (widget.timestamp case final time?) ...[
                    const SizedBox(width: 8),
                    Text(
                      time,
                      style: TextStyle(
                        fontSize: 11,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 2),
              Text.rich(
                TextSpan(
                  children: [
                    TextSpan(
                      text: '${msg.login}: ',
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    TextSpan(text: msg.text),
                  ],
                ),
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  if (_busy)
                    const Padding(
                      padding: EdgeInsets.all(12),
                      child: SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  else ...[
                    TextButton.icon(
                      onPressed: () => _decide(false),
                      icon: const Icon(Icons.close, size: 18),
                      label: Text(l.deny),
                    ),
                    const SizedBox(width: 4),
                    TextButton.icon(
                      onPressed: () => _decide(true),
                      icon: const Icon(Icons.check, size: 18),
                      label: Text(l.allow),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
