/// What kind of problem a report describes. Rendered into the issue body.
enum BugReportKind {
  bug('Bug'),
  crash('Crash'),
  visual('Visual glitch'),
  performance('Performance'),
  other('Other');

  const BugReportKind(this.label);

  final String label;
}

/// Where a report is in the outbox. Drafts stay local; queued reports send
/// whenever the app can reach the report server; failed ones need an edit.
enum BugReportStatus { draft, queued, sent, failed }

/// Placeholder steps the editor pre-fills; untouched, they are not sent.
const kBugReportStepsTemplate = '1. \n2. \n3. ';

/// Server caps (ermchatbot `maxReportTitle` / `maxReportBody`).
const kBugReportMaxTitle = 200;
const kBugReportMaxBody = 20000;

/// One in-app bug report. [id] is generated once and doubles as the
/// server's idempotency key, so a resend after a timeout never duplicates.
class BugReport {
  BugReport({
    required this.id,
    required this.createdAt,
    this.kind = BugReportKind.bug,
    this.summary = '',
    this.whatHappened = '',
    this.steps = kBugReportStepsTemplate,
    this.expected = '',
    this.includeDiagnostics = true,
    this.diagnostics = '',
    this.status = BugReportStatus.draft,
    this.issueNumber,
    this.issueUrl,
    this.lastError,
    this.attempts = 0,
  });

  final String id;
  final DateTime createdAt;
  BugReportKind kind;
  String summary;
  String whatHappened;
  String steps;
  String expected;
  bool includeDiagnostics;

  /// Captured when the editor opens so the preview matches what is sent.
  String diagnostics;
  BugReportStatus status;
  int? issueNumber;
  String? issueUrl;

  /// Why the last send attempt did not go through, for the outbox list.
  String? lastError;

  /// Consecutive retryable failures, driving the retry backoff.
  int attempts;

  String get title => summary.trim();

  /// Required fields filled and within the server caps.
  bool get isSendable =>
      title.isNotEmpty &&
      title.length <= kBugReportMaxTitle &&
      whatHappened.trim().isNotEmpty &&
      buildBody().length <= kBugReportMaxBody;

  /// Markdown issue body assembled from the separate fields. Empty optional
  /// sections are left out, and so are the untouched template steps.
  String buildBody() {
    final b = StringBuffer('**Type:** ${kind.label}\n');
    void section(String heading, String text) {
      final t = text.trim();
      if (t.isEmpty) return;
      b.write('\n### $heading\n\n$t\n');
    }

    section('What happened', whatHappened);
    if (steps.trim() != kBugReportStepsTemplate.trim()) {
      section('Steps to reproduce', steps);
    }
    section('Expected', expected);
    final diag = diagnostics.trim();
    if (includeDiagnostics && diag.isNotEmpty) {
      b.write(
        '\n<details><summary>Diagnostics</summary>\n\n'
        '```\n$diag\n```\n\n</details>\n',
      );
    }
    return b.toString();
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'createdAt': createdAt.toIso8601String(),
    'kind': kind.name,
    'summary': summary,
    'whatHappened': whatHappened,
    'steps': steps,
    'expected': expected,
    'includeDiagnostics': includeDiagnostics,
    'diagnostics': diagnostics,
    'status': status.name,
    'issueNumber': issueNumber,
    'issueUrl': issueUrl,
    'lastError': lastError,
    'attempts': attempts,
  };

  /// Null when [json] is not a report (corrupt file entries are skipped).
  static BugReport? fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final created = DateTime.tryParse(json['createdAt'] as String? ?? '');
    if (id is! String || id.isEmpty || created == null) return null;
    T byName<T extends Enum>(List<T> values, Object? name, T fallback) {
      for (final v in values) {
        if (v.name == name) return v;
      }
      return fallback;
    }

    return BugReport(
      id: id,
      createdAt: created,
      kind: byName(BugReportKind.values, json['kind'], BugReportKind.bug),
      summary: json['summary'] as String? ?? '',
      whatHappened: json['whatHappened'] as String? ?? '',
      steps: json['steps'] as String? ?? kBugReportStepsTemplate,
      expected: json['expected'] as String? ?? '',
      includeDiagnostics: json['includeDiagnostics'] as bool? ?? true,
      diagnostics: json['diagnostics'] as String? ?? '',
      status: byName(
        BugReportStatus.values,
        json['status'],
        BugReportStatus.draft,
      ),
      issueNumber: json['issueNumber'] as int?,
      issueUrl: json['issueUrl'] as String?,
      lastError: json['lastError'] as String?,
      attempts: json['attempts'] as int? ?? 0,
    );
  }
}
