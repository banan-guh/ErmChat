import 'package:flutter/material.dart';

import '../../services/twitch_api.dart';
import '../../util/date_format.dart';
import 'scope.dart';
import 'widgets.dart';

/// Public blocked terms. New terms are typed into the borrowed composer.
class TermsTab extends ModTabWidget {
  const TermsTab({super.key, required super.mod, required this.termsVersion});

  /// Bumped when the composer adds a term.
  final Listenable termsVersion;

  @override
  State<TermsTab> createState() => _TermsTabState();
}

class _TermsTabState extends State<TermsTab> with ModTabState<TermsTab> {
  late final ModLoader<List<BlockedTerm>> _terms;

  @override
  void initState() {
    super.initState();
    _terms = loader(
      (mod) => mod.actions.getBlockedTerms(mod.auth, mod.channel),
      failure: mod.l10n.loadTermsFailed,
    );
    watch((mod) => mod.moderation?.modTermsVersion, _terms.load);
    watch((_) => widget.termsVersion, _terms.load);
  }

  Future<void> _remove(BlockedTerm term) => busy(term.id, () async {
    final ok = await mod.report(
      mod.actions.removeBlockedTerm(mod.auth, mod.channel, term.id),
    );
    if (ok) await _terms.load();
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        ModHint(
          mod.l10n.termsHint,
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
        ),
        Expanded(
          child: ModLoadView(
            loader: _terms,
            isEmpty: (terms) => terms.isEmpty,
            empty: ModEmpty(
              icon: Icons.block_outlined,
              title: mod.l10n.noBlockedTerms,
              subtitle: mod.l10n.wildcardHint,
            ),
            builder: (context, terms) => ListView.builder(
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
                  subtitle: Text(
                    mod.l10n.addedAgo(formatAgoIso(term.createdAt)),
                  ),
                  trailing: isBusy(term.id)
                      ? const ModSpinner()
                      : IconButton(
                          icon: const Icon(Icons.delete_outline),
                          tooltip: mod.l10n.remove,
                          onPressed: () => _remove(term),
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
