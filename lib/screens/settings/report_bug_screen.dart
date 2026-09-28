import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../models/bug_report.dart';
import '../../models/emote_fetch_tier.dart';
import '../../providers/feature_providers.dart';
import '../../services/bug_report_outbox.dart';
import '../../util/date_format.dart';
import '../../util/diagnostics_scrub.dart';
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
      title: const Text('Report a bug'),
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
                  'Reports go to the ermchat issue tracker. Drafts stay on '
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

/// Split-field report form. Fields assemble into one markdown issue body;
/// leaving the screen keeps a draft whenever something was typed.
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
  late final _expected = TextEditingController(text: widget.report.expected);
  late BugReportKind _kind = widget.report.kind;
  late bool _includeDiagnostics = widget.report.includeDiagnostics;
  bool _sent = false;

  @override
  void initState() {
    super.initState();
    for (final c in [_summary, _what]) {
      c.addListener(() => setState(() {}));
    }
  }

  @override
  void dispose() {
    for (final c in [_summary, _what, _steps, _expected]) {
      c.dispose();
    }
    super.dispose();
  }

  BugReport _apply() => widget.report
    ..summary = _summary.text
    ..whatHappened = _what.text
    ..steps = _steps.text
    ..expected = _expected.text
    ..kind = _kind
    ..includeDiagnostics = _includeDiagnostics;

  bool get _hasContent =>
      _summary.text.trim().isNotEmpty ||
      _what.text.trim().isNotEmpty ||
      _expected.text.trim().isNotEmpty ||
      _steps.text.trim() != kBugReportStepsTemplate.trim();

  Future<void> _send() async {
    final report = _apply();
    if (!report.isSendable) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Report is too long; trim some text')),
      );
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
    final diagnostics = widget.report.diagnostics.trim();
    final canSend =
        _summary.text.trim().isNotEmpty && _what.text.trim().isNotEmpty;
    return PopScope(
      onPopInvokedWithResult: _onPop,
      child: SettingsPage(
        title: const Text('Report a bug'),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            TextField(
              controller: _summary,
              maxLength: kBugReportMaxTitle,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                labelText: 'Summary *',
                hintText: 'One line describing the problem',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            DropdownButtonFormField<BugReportKind>(
              initialValue: _kind,
              decoration: const InputDecoration(
                labelText: 'Type',
                border: OutlineInputBorder(),
              ),
              items: [
                for (final k in BugReportKind.values)
                  DropdownMenuItem(value: k, child: Text(k.label)),
              ],
              onChanged: (k) => setState(() => _kind = k ?? _kind),
            ),
            const SizedBox(height: 16),
            _multiline(_what, 'What happened *', minLines: 3),
            const SizedBox(height: 16),
            _multiline(_steps, 'Steps to reproduce'),
            const SizedBox(height: 16),
            _multiline(_expected, 'What you expected'),
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Include diagnostics'),
              subtitle: const Text(
                'App version, device, settings, recent performance log',
              ),
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
              'Sent with your Twitch name so we can follow up. Offline? It '
              'sends automatically once you are back online.',
              style: Theme.of(context).textTheme.bodySmall,
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
  final perf = PerfLog.I.entries();
  if (perf.isNotEmpty) {
    lines
      ..add('')
      ..add('Recent performance log:')
      ..addAll(perf.skip(perf.length > 30 ? perf.length - 30 : 0));
  }
  return scrubDiagnostics(lines.join('\n'));
}
