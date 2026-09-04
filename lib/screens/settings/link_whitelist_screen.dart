import 'package:flutter/material.dart';

import '../../services/link_whitelist.dart';

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
    return Scaffold(
      appBar: AppBar(
        title: const Text('Split link whitelist'),
        actions: [
          IconButton(
            icon: const Icon(Icons.restore),
            tooltip: 'Restore defaults',
            onPressed: () => _confirmRestore(context),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: LinkWhitelist.instance.enabled
            ? () => showDialog(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: const Text('Add link'),
                  content: TextField(
                    controller: _controller,
                    autofocus: true,
                    decoration: const InputDecoration(
                      labelText: 'Domain or TLD',
                      helperText:
                          'e.g. "lol" (any *.lol) or "kappa.lol" (+subs)',
                    ),
                    onSubmitted: (_) => _add(ctx),
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Cancel'),
                    ),
                    TextButton(
                      onPressed: () => _add(ctx),
                      child: const Text('Add'),
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
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
                child: Text(
                  'Split domains can be linked here so you can open them without hassle. \n'
                  'Example of split domains: kappa .lol/ABCDE',
                ),
              ),
              SwitchListTile(
                title: const Text('Enable split links'),
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
                                tooltip: 'Remove',
                                onPressed: () =>
                                    LinkWhitelist.instance.remove(entry),
                              ),
                            ],
                          ),
                        ),
                      if (entries.isEmpty)
                        const Padding(
                          padding: EdgeInsets.all(16),
                          child: Text(
                            'No entries yet. Add one or tap an example.',
                          ),
                        ),
                      const Padding(
                        padding: EdgeInsets.fromLTRB(16, 24, 16, 8),
                        child: Text(
                          'Examples (tap to add):',
                          style: TextStyle(fontWeight: FontWeight.bold),
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
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Restore defaults?'),
        content: const Text(
          'This replaces your whitelist with the built-in defaults, '
          'and removes any entries you added.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context, true);
            },
            child: const Text('Restore'),
          ),
        ],
      ),
    );
    if (confirmed == true) LinkWhitelist.instance.restoreDefaults();
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
        isTld ? 'TLD' : 'DOMAIN',
        style: TextStyle(
          fontSize: 11,
          color: isTld ? Colors.orange : Colors.green,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
