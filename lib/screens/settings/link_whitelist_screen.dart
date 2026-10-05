import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../services/link_whitelist.dart';
import '../../widgets/dialogs.dart';
import 'settings_page.dart';

/// Lets the user manage the link-whitelist used to linkify bare/short domains
/// (e.g. `kappa.lol`) that stock linkify skips. Entries are auto-classified as
/// a TLD (`lol` -> any `*.lol`) or a full domain (`kappa.lol` -> that domain
/// plus subdomains); the type is shown as a badge so the behavior is obvious.
class LinkWhitelistSettingsScreen extends StatefulWidget {
  const LinkWhitelistSettingsScreen({super.key});

  @override
  State<LinkWhitelistSettingsScreen> createState() =>
      _LinkWhitelistSettingsScreenState();
}

class _LinkWhitelistSettingsScreenState
    extends State<LinkWhitelistSettingsScreen> {
  static const List<String> _examples = [
    'lol',
    'gg',
    'tv',
    'kappa.lol',
    'gachi.gay',
    'youtu.be',
  ];

  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _add(BuildContext context) async {
    final value = _controller.text.trim();
    if (value.isEmpty) return;
    LinkWhitelist.instance.add(value);
    _controller.clear();
    if (context.mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SettingsPage(
      title: Text(context.l10n.splitLinkWhitelist),
      actions: [
        IconButton(
          icon: const Icon(Icons.restore),
          tooltip: context.l10n.restoreDefaults,
          onPressed: () => _confirmRestore(context),
        ),
      ],
      floatingActionButton: FloatingActionButton(
        onPressed: LinkWhitelist.instance.enabled
            ? () => showDialog(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: Text(ctx.l10n.addLink),
                  content: TextField(
                    controller: _controller,
                    autofocus: true,
                    decoration: InputDecoration(
                      labelText: ctx.l10n.domainOrTld,
                      helperText: ctx.l10n.domainOrTldHint,
                    ),
                    onSubmitted: (_) => _add(ctx),
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: Text(ctx.l10n.cancel),
                    ),
                    TextButton(
                      onPressed: () => _add(ctx),
                      child: Text(ctx.l10n.add),
                    ),
                  ],
                ),
              )
            : null,
        child: const Icon(Icons.add),
      ),
      body: ListenableBuilder(
        listenable: LinkWhitelist.instance,
        builder: (context, _) {
          final entries = LinkWhitelist.instance.entries;
          final enabled = LinkWhitelist.instance.enabled;
          return ListView(
            padding: const EdgeInsets.only(bottom: 80),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                child: Text(context.l10n.splitLinksHint),
              ),
              SwitchListTile(
                title: Text(context.l10n.enableSplitLinks),
                value: enabled,
                onChanged: (v) => LinkWhitelist.instance.setEnabled(v),
              ),
              IgnorePointer(
                ignoring: !enabled,
                child: Opacity(
                  opacity: enabled ? 1.0 : 0.38,
                  child: Column(
                    children: [
                      for (final entry in entries)
                        ListTile(
                          title: Text(entry),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              _TypeBadge(LinkWhitelist.classify(entry)),
                              IconButton(
                                icon: const Icon(Icons.delete_outline),
                                tooltip: context.l10n.remove,
                                onPressed: () =>
                                    LinkWhitelist.instance.remove(entry),
                              ),
                            ],
                          ),
                        ),
                      if (entries.isEmpty)
                        Padding(
                          padding: const EdgeInsets.all(16),
                          child: Text(context.l10n.noEntriesYet),
                        ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
                        child: Text(
                          context.l10n.examplesTapToAdd,
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            for (final ex in _examples)
                              if (!entries.contains(
                                LinkWhitelist.normalize(ex),
                              ))
                                InputChip(
                                  label: Text(ex),
                                  avatar: _TypeBadge(
                                    LinkWhitelist.classify(ex),
                                  ),
                                  onPressed: () =>
                                      LinkWhitelist.instance.add(ex),
                                ),
                          ],
                        ),
                      ),
                      SizedBox(height: theme.visualDensity.vertical * 2),
                    ],
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _confirmRestore(BuildContext context) async {
    final confirmed = await confirmDialog(
      context,
      title: context.l10n.restoreDefaultsTitle,
      message: context.l10n.restoreDefaultsMessage,
      confirmLabel: context.l10n.restore,
    );
    if (confirmed) LinkWhitelist.instance.restoreDefaults();
  }
}

class _TypeBadge extends StatelessWidget {
  const _TypeBadge(this.type);

  final LinkType type;

  @override
  Widget build(BuildContext context) {
    final isTld = type == LinkType.tld;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: isTld
            ? Colors.orange.withValues(alpha: 0.18)
            : Colors.green.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        isTld ? context.l10n.linkTypeTld : context.l10n.linkTypeDomain,
        style: TextStyle(
          fontSize: 11,
          color: isTld ? Colors.orange : Colors.green,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
