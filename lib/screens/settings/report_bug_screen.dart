import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../models/bug_report.dart';
import '../../models/emote_fetch_tier.dart';
import '../../providers/feature_providers.dart';
import '../../services/bug_report_outbox.dart';
import '../../services/media_uploader.dart';
import '../../util/date_format.dart';
import '../../util/diagnostics_scrub.dart';
import '../../util/friendly_error.dart';
import '../../util/log.dart';
import '../../util/prefs.dart';
import 'settings_page.dart';

/// Report outbox: drafts, reports waiting to send, and sent history.
class ReportBugScreen extends ConsumerWidget {
  const ReportBugScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(bugReportOutboxTickProvider);
    final outbox = ref.watch(bugReportOutboxProvider);
    final reports = outbox.reports;
    return SettingsPage(
      title: const Text('Send feedback'),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _newReport(context, outbox),
        icon: const Icon(Icons.add),
        label: const Text('New report'),
      ),
      body: reports.isEmpty
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'Reports are public on the ermchat GitHub. Drafts stay on '
                  'this device, and sent reports wait here until the app '
                  'can reach the server.',
                  textAlign: TextAlign.center,
                ),
              ),
            )
          : ListView(
              padding: const EdgeInsets.only(bottom: 88),
              children: [
                for (final r in reports)
                  _ReportTile(
                    report: r,
                    onTap: () => _open(context, outbox, r),
                    onDelete: r.status == BugReportStatus.sent
                        ? null
                        : () => outbox.delete(r.id),
                  ),
              ],
            ),
    );
  }

  Future<void> _newReport(BuildContext context, BugReportOutbox outbox) async {
    final diagnostics = await collectDiagnostics(context);
    if (!context.mounted) return;
    final draft = outbox.newDraft(diagnostics: diagnostics);
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => ReportEditorScreen(report: draft)),
    );
  }

  void _open(BuildContext context, BugReportOutbox outbox, BugReport r) {
    if (r.status == BugReportStatus.sent) {
      final url = r.issueUrl;
      if (url != null) {
        launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
      }
      return;
    }
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => ReportEditorScreen(report: r)),
    );
  }
}

class _ReportTile extends StatelessWidget {
  const _ReportTile({required this.report, required this.onTap, this.onDelete});

  final BugReport report;
  final VoidCallback onTap;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (IconData icon, Color color, String status) = switch (report.status) {
      BugReportStatus.draft => (
        Icons.edit_note,
        scheme.onSurfaceVariant,
        'Draft',
      ),
      BugReportStatus.queued => (
        Icons.schedule_send,
        scheme.tertiary,
        report.lastError ?? 'Waiting to send',
      ),
      BugReportStatus.sent => (
        Icons.check_circle,
        scheme.primary,
        report.issueNumber == null ? 'Sent' : 'Sent as #${report.issueNumber}',
      ),
      BugReportStatus.failed => (
        Icons.error,
        scheme.error,
        'Not sent: ${report.lastError ?? 'rejected'}',
      ),
    };
    return ListTile(
      leading: Icon(icon, color: color),
      title: Text(
        report.title.isEmpty ? 'Untitled report' : report.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text('$status · ${formatYmd(report.createdAt)}'),
      trailing: onDelete == null
          ? null
          : IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: 'Delete',
              onPressed: onDelete,
            ),
      onTap: onTap,
    );
  }
}

/// Report form: title, type, then optional description, steps (problem
/// kinds only) and screenshots. Leaving the screen keeps a draft whenever
/// something was entered.
class ReportEditorScreen extends ConsumerStatefulWidget {
  const ReportEditorScreen({super.key, required this.report});

  final BugReport report;

  @override
  ConsumerState<ReportEditorScreen> createState() => _ReportEditorScreenState();
}

class _ReportEditorScreenState extends ConsumerState<ReportEditorScreen> {
  late final _summary = TextEditingController(text: widget.report.summary);
  late final _what = TextEditingController(text: widget.report.whatHappened);
  late final _steps = TextEditingController(text: widget.report.steps);
  late BugReportKind _kind = widget.report.kind;
  late bool _includeDiagnostics = widget.report.includeDiagnostics;
  late final _screenshots = [...widget.report.screenshots];
  final _uploader = MediaUploader();
  bool _uploading = false;
  bool _sent = false;

  @override
  void initState() {
    super.initState();
    _summary.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    for (final c in [_summary, _what, _steps]) {
      c.dispose();
    }
    _uploader.close();
    super.dispose();
  }

  BugReport _apply() {
    final r = widget.report
      ..summary = _summary.text
      ..whatHappened = _what.text
      ..steps = _steps.text
      ..kind = _kind
      ..includeDiagnostics = _includeDiagnostics;
    r.screenshots
      ..clear()
      ..addAll(_screenshots);
    return r;
  }

  bool get _hasContent =>
      _summary.text.trim().isNotEmpty ||
      _what.text.trim().isNotEmpty ||
      _steps.text.trim().isNotEmpty ||
      _screenshots.isNotEmpty;

  Future<void> _addScreenshot() async {
    final XFile? picked;
    try {
      picked = await ImagePicker().pickImage(source: ImageSource.gallery);
    } catch (e) {
      _snack('Could not open the gallery');
      return;
    }
    if (picked == null || !mounted) return;
    setState(() => _uploading = true);
    try {
      final result = await _uploader.uploadMedia(File(picked.path));
      await _uploader.addRecent(result);
      if (mounted) setState(() => _screenshots.add(result.imageLink));
    } catch (e) {
      logDebug('[Report] screenshot upload failed: $e');
      _snack(friendlyError(e, fallback: 'Upload failed'));
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _send() async {
    final report = _apply();
    if (!report.isSendable) {
      _snack('Report is too long; trim some text');
      return;
    }
    _sent = true;
    final outbox = ref.read(bugReportOutboxProvider);
    Navigator.pop(context);
    await outbox.submit(report);
  }

  void _onPop(bool didPop, Object? _) {
    if (!didPop || _sent || !_hasContent) return;
    ref.read(bugReportOutboxProvider).saveDraft(_apply());
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final caption = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final diagnostics = widget.report.diagnostics.trim();
    final canSend = _summary.text.trim().isNotEmpty && !_uploading;
    return PopScope(
      onPopInvokedWithResult: _onPop,
      child: SettingsPage(
        title: const Text('Send feedback'),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            TextField(
              controller: _summary,
              maxLength: kBugReportMaxTitle,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                labelText: 'Title',
                border: OutlineInputBorder(),
              ),
            ),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final k in BugReportKind.values)
                  ChoiceChip(
                    label: Text(k.label),
                    selected: _kind == k,
                    onSelected: (_) => setState(() => _kind = k),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            _multiline(_what, 'Description (optional)', minLines: 3),
            if (_kind.hasSteps) ...[
              const SizedBox(height: 16),
              _multiline(_steps, 'Steps to reproduce (optional)'),
            ],
            const SizedBox(height: 16),
            Text('Screenshots (optional)', style: theme.textTheme.titleSmall),
            const SizedBox(height: 4),
            Text(
              'Totally optional, most reports have none. kappa.lol links '
              'in the description work too.',
              style: caption,
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                for (final url in _screenshots)
                  InputChip(
                    avatar: const Icon(Icons.image_outlined),
                    label: Text(
                      Uri.tryParse(url)?.pathSegments.lastOrNull ?? url,
                    ),
                    onDeleted: () => setState(() => _screenshots.remove(url)),
                  ),
                if (_uploading)
                  const SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else
                  OutlinedButton.icon(
                    onPressed: _addScreenshot,
                    icon: const Icon(Icons.add_photo_alternate_outlined),
                    label: const Text('Add screenshot'),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Include diagnostics'),
              subtitle: const Text('App version, phone model and settings'),
              value: _includeDiagnostics,
              onChanged: diagnostics.isEmpty
                  ? null
                  : (v) => setState(() => _includeDiagnostics = v),
            ),
            if (_includeDiagnostics && diagnostics.isNotEmpty)
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: const Text('Preview diagnostics'),
                children: [
                  Align(
                    alignment: Alignment.centerLeft,
                    child: SelectableText(
                      diagnostics,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 12,
                      ),
                    ),
                  ),
                ],
              ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: canSend ? _send : null,
              icon: const Icon(Icons.send),
              label: const Text('Send'),
            ),
            const SizedBox(height: 8),
            Text(
              "Posted publicly on GitHub with your Twitch name. Offline? It "
              "sends once you're back online.",
              style: theme.textTheme.bodySmall,
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _multiline(
    TextEditingController c,
    String label, {
    int minLines = 2,
  }) => TextField(
    controller: c,
    minLines: minLines,
    maxLines: null,
    keyboardType: TextInputType.multiline,
    textCapitalization: TextCapitalization.sentences,
    decoration: InputDecoration(
      labelText: label,
      alignLabelWithHint: true,
      border: const OutlineInputBorder(),
    ),
  );
}

const _deviceChannel = MethodChannel('ermchat/device');

/// Snapshot of app, device, and settings state for a new report. Scrubbed
/// of credentials; the editor previews exactly this text.
Future<String> collectDiagnostics(BuildContext context) async {
  final media = MediaQuery.of(context);
  final locale = Localizations.maybeLocaleOf(context)?.toString() ?? '?';
  final lines = <String>[];
  try {
    final info = await PackageInfo.fromPlatform();
    final mode = kReleaseMode
        ? 'release'
        : kProfileMode
        ? 'profile'
        : 'debug';
    lines.add('App: ${info.version}+${info.buildNumber} ($mode)');
  } catch (_) {
    lines.add('App: unknown version');
  }
  lines.add(
    'OS: ${Platform.operatingSystem} ${Platform.operatingSystemVersion}',
  );
  if (Platform.isAndroid) {
    try {
      final model = await _deviceChannel.invokeMethod<String>('deviceModel');
      final mem = await _deviceChannel.invokeMethod<int>('totalMemBytes');
      final gib = mem == null ? '?' : (mem / (1 << 30)).toStringAsFixed(1);
      lines.add('Device: ${model ?? '?'}, $gib GiB RAM');
    } catch (_) {}
  }
  final size = media.size;
  lines.add(
    'Screen: ${size.width.round()}x${size.height.round()} dp '
    '@ ${media.devicePixelRatio.toStringAsFixed(2)}x, '
    'text scale ${media.textScaler.scale(1).toStringAsFixed(2)}',
  );
  lines.add('Locale: $locale');
  final prefs = Prefs.loaded;
  if (prefs != null) {
    final tiers = EmoteFetchTier.values;
    final tier = prefs.emoteFetchTier;
    String onOff(bool v) => v ? 'on' : 'off';
    lines
      ..add('Channels: ${prefs.channels.length}')
      ..add(
        'Settings: glass ${onOff(prefs.liquidGlass)}, '
        'emote tier ${tier >= 0 && tier < tiers.length ? tiers[tier].label : '?'}, '
        'animate emotes ${onOff(prefs.animateGifs)}, '
        '7TV paints ${onOff(prefs.seventvNamePaints)}, '
        'font ${prefs.chatFontSize}, '
        'max messages ${prefs.maxMessagesPerChannel}',
      );
  }
  return scrubDiagnostics(lines.join('\n'));
}
