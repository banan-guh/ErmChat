import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../services/image_embed_hosts.dart';
import '../../widgets/dialogs.dart';
import 'settings_page.dart';

/// Lets the user manage the hosts whose extensionless links count as raw
/// image serves, e.g. `kappa.lol/abc`.
class ImageHostSettingsScreen extends StatefulWidget {
  const ImageHostSettingsScreen({super.key});

  @override
  State<ImageHostSettingsScreen> createState() =>
      _ImageHostSettingsScreenState();
}

class _ImageHostSettingsScreenState extends State<ImageHostSettingsScreen> {
  Future<void> _add(BuildContext context) async {
    final l = context.l10n;
    final value = await showTextDialog(
      context,
      title: l.addImageHost,
      label: l.imageHosts,
      helper: l.imageHostHint,
      confirmLabel: l.add,
      validate: (v) =>
          ImageEmbedHosts.normalize(v).isEmpty ? l.imageHostHint : null,
    );
    if (value != null) ImageEmbedHosts.instance.add(value);
  }

  @override
  Widget build(BuildContext context) {
    return SettingsPage(
      title: Text(context.l10n.imageHosts),
      actions: [
        IconButton(
          icon: const Icon(Icons.restore),
          tooltip: context.l10n.restoreDefaults,
          onPressed: () => _confirmRestore(context),
        ),
      ],
      floatingActionButton: FloatingActionButton(
        onPressed: () => _add(context),
        child: const Icon(Icons.add),
      ),
      body: ListenableBuilder(
        listenable: ImageEmbedHosts.instance,
        builder: (context, _) {
          final entries = ImageEmbedHosts.instance.entries;
          return ListView(
            padding: const EdgeInsets.only(bottom: 80),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                child: Text(context.l10n.imageHostsHint),
              ),
              for (final entry in entries)
                ListTile(
                  title: Text(entry),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete_outline),
                    tooltip: context.l10n.remove,
                    onPressed: () => ImageEmbedHosts.instance.remove(entry),
                  ),
                ),
              if (entries.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(context.l10n.noEntriesYet),
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
      message: context.l10n.restoreImageHostsMessage,
      confirmLabel: context.l10n.restore,
    );
    if (confirmed) ImageEmbedHosts.instance.restoreDefaults();
  }
}
