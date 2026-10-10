import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../l10n/l10n.dart';
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

/// Report outbox: drafts, reports waiting to send, and sent history with
/// each issue's status, checked again on open.
class ReportBugScreen extends ConsumerStatefulWidget {
  const ReportBugScreen({super.key});

  @override
  ConsumerState<ReportBugScreen> createState() => _ReportBugScreenState();
}

class _ReportBugScreenState extends ConsumerState<ReportBugScreen> {
  @override
  void initState() {
    super.initState();
    unawaited(ref.read(bugReportOutboxProvider).refreshStatus());
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(bugReportOutboxTickProvider);
    final outbox = ref.watch(bugReportOutboxProvider);
    final reports = outbox.reports;
    return SettingsPage(
      title: Text(context.l10n.sendFeedback),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _newReport(context, outbox),
        icon: const Icon(Icons.add),
        label: Text(context.l10n.newReport),
      ),
      body: reports.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  context.l10n.reportsEmpty,
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
                    onDelete: () => outbox.delete(r.id),
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
      unawaited(outbox.markSeen(r.id));
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
  const _ReportTile({
    required this.report,
    required this.onTap,
    required this.onDelete,
  });

  final BugReport report;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (IconData icon, Color color, String status) = switch (report.status) {
      BugReportStatus.draft => (
        Icons.edit_note,
        scheme.onSurfaceVariant,
        context.l10n.reportDraft,
      ),
      BugReportStatus.queued => (
        Icons.schedule_send,
        scheme.tertiary,
        report.lastError ?? context.l10n.reportWaiting,
      ),
      BugReportStatus.sent => (
        switch (report.issueStatus) {
          'planned' => Icons.event_note,
          'fixed' => Icons.task_alt,
          'wontfix' => Icons.do_not_disturb_on_outlined,
          _ => Icons.check_circle,
        },
        report.issueStatus == 'wontfix'
            ? scheme.onSurfaceVariant
            : scheme.primary,
        [
          report.issueNumber == null
              ? context.l10n.reportSent
              : context.l10n.reportSentAs(report.issueNumber!),
          ?_issueStatusLabel(context.l10n, report.issueStatus),
          if (report.replies > 0) context.l10n.reportReplies(report.replies),
        ].join(' · '),
      ),
      BugReportStatus.failed => (
        Icons.error,
        scheme.error,
        context.l10n.reportNotSent(
          report.lastError ?? context.l10n.reportRejected,
        ),
      ),
    };
    return ListTile(
      leading: Badge(
        isLabelVisible: report.hasNewReplies,
        child: Icon(icon, color: color),
      ),
      title: Text(
        report.title.isEmpty ? context.l10n.untitledReport : report.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text('$status · ${formatYmd(report.createdAt)}'),
      trailing: IconButton(
        icon: const Icon(Icons.delete_outline),
        tooltip: context.l10n.delete,
        onPressed: onDelete,
      ),
      onTap: onTap,
    );
  }
}

/// Report form: title, type, then optional description, and for bugs
/// steps, screenshots and diagnostics. Leaving the screen keeps a draft
/// whenever something was entered.
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
      if (mounted) _snack(context.l10n.couldNotOpenGallery);
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
      if (!mounted) return;
      _snack(friendlyError(e, fallback: context.l10n.uploadFailed));
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
      _snack(context.l10n.reportTooLong);
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
    final isBug = _kind == BugReportKind.bug;
    return PopScope(
      onPopInvokedWithResult: _onPop,
      child: SettingsPage(
        title: Text(context.l10n.sendFeedback),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            TextField(
              controller: _summary,
              maxLength: kBugReportMaxTitle,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(
                labelText: context.l10n.reportTitle,
                border: const OutlineInputBorder(),
              ),
            ),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final k in BugReportKind.values)
                  ChoiceChip(
                    label: Text(_kindLabel(context.l10n, k)),
                    selected: _kind == k,
                    onSelected: (_) => setState(() {
                      _kind = k;
                    }),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            _multiline(_what, context.l10n.reportDescription, minLines: 3),
            if (isBug) ...[
              const SizedBox(height: 16),
              _multiline(_steps, context.l10n.reportSteps),
              const SizedBox(height: 16),
              Text(
                context.l10n.reportScreenshots,
                style: theme.textTheme.titleSmall,
              ),
              const SizedBox(height: 4),
              Text(context.l10n.reportScreenshotsHint, style: caption),
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
                      label: Text(context.l10n.addScreenshot),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(context.l10n.includeDiagnostics),
                // The exact text that gets sent.
                subtitle: diagnostics.isEmpty
                    ? null
                    : Text(
                        diagnostics,
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 12,
                        ),
                      ),
                value: _includeDiagnostics,
                onChanged: diagnostics.isEmpty
                    ? null
                    : (v) => setState(() => _includeDiagnostics = v),
              ),
            ],
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: canSend ? _send : null,
              icon: const Icon(Icons.send),
              label: Text(context.l10n.send),
            ),
            const SizedBox(height: 8),
            Text(
              context.l10n.reportPublicNote,
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

/// Null for "open" (the plain sent state) and for values this build
/// does not know.
String? _issueStatusLabel(AppLocalizations l, String? status) =>
    switch (status) {
      'planned' => l.issuePlanned,
      'fixed' => l.issueFixed,
      'wontfix' => l.issueWontFix,
      _ => null,
    };

String _kindLabel(AppLocalizations l, BugReportKind k) => switch (k) {
  BugReportKind.bug => l.kindBug,
  BugReportKind.suggestion => l.kindSuggestion,
};

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
