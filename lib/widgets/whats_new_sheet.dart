import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:url_launcher/url_launcher.dart';

import '../l10n/l10n.dart';
import '../services/app_updates.dart';

/// The bundled CHANGELOG.md as [version]'s notes; empty when it has none.
Future<List<VersionNotes>> bundledNotes(String version) async {
  final items = parseChangelog(await rootBundle.loadString('CHANGELOG.md'));
  return items.isEmpty ? const [] : [VersionNotes(version, items)];
}

/// What's new for an update not yet installed, with a button to [source]'s
/// store. The dev fake has no tag, so it shows the bundled notes instead.
Future<void> showUpdateSheet(
  BuildContext context,
  AppUpdates updates,
  AvailableUpdate update,
  UpdateSource? source, {
  required String currentVersion,
}) {
  final more = update.armed
      ? bundledNotes(currentVersion)
      : updates
            .notesFor(update.version)
            .then((n) => n == null ? const <VersionNotes>[] : [n]);
  return showWhatsNewSheet(
    context,
    title: context.l10n.whatsNewIn(update.version),
    notes: const [],
    more: more,
    onGetUpdate: () => launchUrl(
      AppUpdates.storeLink(source, update.version),
      mode: LaunchMode.externalApplication,
    ),
  );
}

/// What's new as a peeking bottom sheet: about 40% tall over chat, dragged up
/// to scroll every version. [more] appends versions that load later (missed
/// releases fetched from GitHub). [onGetUpdate] adds the store button when
/// the notes describe an update not yet installed.
Future<void> showWhatsNewSheet(
  BuildContext context, {
  required String title,
  required List<VersionNotes> notes,
  Future<List<VersionNotes>>? more,
  VoidCallback? onGetUpdate,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (sheetContext) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.4,
      minChildSize: 0.25,
      maxChildSize: 1,
      builder: (context, controller) {
        final theme = Theme.of(context);
        Widget version(VersionNotes v) => Padding(
          padding: const EdgeInsets.fromLTRB(24, 12, 24, 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(v.version, style: theme.textTheme.labelLarge),
              const SizedBox(height: 4),
              for (final item in v.items)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Text('• $item', style: theme.textTheme.bodyMedium),
                ),
            ],
          ),
        );
        return ListView(
          controller: controller,
          padding: const EdgeInsets.only(bottom: 24),
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Text(title, style: theme.textTheme.titleLarge),
            ),
            for (final v in notes) version(v),
            if (more != null)
              FutureBuilder<List<VersionNotes>>(
                future: more,
                builder: (context, snap) => Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [for (final v in snap.data ?? const []) version(v)],
                ),
              ),
            if (onGetUpdate != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
                child: FilledButton(
                  onPressed: onGetUpdate,
                  child: Text(context.l10n.getUpdate),
                ),
              ),
          ],
        );
      },
    ),
  );
}
