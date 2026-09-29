import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../../chat/chat.dart';
import '../../services/mod_actions.dart';
import '../../services/twitch_api.dart';
import '../../services/twitch_auth.dart';
import 'common.dart';

class TermsTab extends StatefulWidget {
  const TermsTab({
    super.key,
    required this.channel,
    required this.chat,
    required this.modActions,
    required this.auth,
    required this.termsVersion,
    required this.onNotice,
  });

  final String channel;
  final Chat chat;
  final ModActions modActions;
  final TwitchAuth auth;
  final ValueListenable<int> termsVersion;
  final ValueChanged<String> onNotice;

  @override
  State<TermsTab> createState() => _TermsTabState();
}

class _TermsTabState extends State<TermsTab> with ModTabLoad<TermsTab> {
  @override
  ModActions get modActions => widget.modActions;
  @override
  ValueChanged<String> get onNotice => widget.onNotice;

  List<BlockedTerm>? _terms;
  String? _error;
  int _loadGen = 0;
  final _removing = <String>{};
  ValueNotifier<int>? _termsVersion;

  @override
  void initState() {
    super.initState();
    _subscribeTerms();
    widget.termsVersion.addListener(_onTermsChanged);
    _load();
  }

  void _subscribeTerms() {
    _termsVersion = widget.chat
        .channelFor(widget.channel)
        ?.moderation
        .modTermsVersion;
    _termsVersion?.addListener(_onTermsChanged);
  }

  void _unsubscribeTerms() {
    _termsVersion?.removeListener(_onTermsChanged);
    _termsVersion = null;
  }

  @override
  void didUpdateWidget(covariant TermsTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.channel != widget.channel) {
      _unsubscribeTerms();
      _subscribeTerms();
      setState(() {
        _terms = null;
        _error = null;
      });
      _load();
    }
  }

  @override
  void dispose() {
    _unsubscribeTerms();
    widget.termsVersion.removeListener(_onTermsChanged);
    super.dispose();
  }

  void _onTermsChanged() => _load();

  Future<void> _load() async {
    final gen = ++_loadGen;
    final outcome = await guardedLoad<List<BlockedTerm>>(
      gen: gen,
      currentGen: () => _loadGen,
      background: _terms != null,
      request: () =>
          widget.modActions.getBlockedTerms(widget.auth, widget.channel),
      fallbackError: 'Could not load blocked terms.',
    );
    if (outcome == null) return;
    setState(() {
      _error = outcome.error;
      if (outcome.error == null) _terms = outcome.value;
    });
  }

  Future<void> _remove(BlockedTerm term) async {
    if (!_removing.add(term.id)) return;
    setState(() {});
    final result = await widget.modActions.removeBlockedTerm(
      widget.auth,
      widget.channel,
      term.id,
    );
    if (!mounted) return;
    _removing.remove(term.id);
    if (result.ok) {
      _load();
    } else {
      setState(() {});
      widget.onNotice(modErrorText(result));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Text(
            'Only moderators can see this list. Public terms only; '
            'private terms live in the dashboard. '
            'Type in the chat box below to add one.',
            style: TextStyle(
              fontSize: 12,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        Expanded(child: _body()),
      ],
    );
  }

  Widget _body() {
    if (_error != null && _terms == null) {
      return ModError(message: _error!, onRetry: _load);
    }
    final terms = _terms;
    if (terms == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (terms.isEmpty) {
      return const ModEmpty(
        icon: Icons.block_outlined,
        title: 'No blocked terms yet.',
        subtitle: 'A * wildcard is allowed at the start or the end.',
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 16),
      itemCount: terms.length,
      itemBuilder: (_, i) {
        final term = terms[i];
        return ListTile(
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 4,
          ),
          title: Text(term.text),
          subtitle: Text('Added ${modRelativeShortDate(term.createdAt)}'),
          trailing: _removing.contains(term.id)
              ? const SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : IconButton(
                  icon: const Icon(Icons.delete_outline),
                  tooltip: 'Remove',
                  onPressed: () => _remove(term),
                ),
        );
      },
    );
  }
}
