/// What a report is about. Sent by name; the server turns it into the
/// issue label and forum tag. Only bugs take steps, screenshots and
/// diagnostics.
enum BugReportKind { bug, suggestion }

/// Where a report is in the outbox. Drafts stay local; queued reports send
/// whenever the app can reach the report server; failed ones need an edit.
enum BugReportStatus { draft, queued, sent, failed }

/// Steps template older drafts were saved with; it counts as empty.
const _legacyStepsTemplate = '1. \n2. \n3. ';

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
    this.steps = '',
    List<String>? screenshots,
    this.includeDiagnostics = true,
    this.diagnostics = '',
    this.status = BugReportStatus.draft,
    this.issueNumber,
    this.issueUrl,
    this.lastError,
    this.attempts = 0,
    this.issueStatus,
    this.replies = 0,
    this.seenReplies = 0,
  }) : screenshots = screenshots ?? [];

  final String id;
  final DateTime createdAt;
  BugReportKind kind;
  String summary;
  String whatHappened;
  String steps;

  /// Uploaded image links, shown under the description.
  final List<String> screenshots;
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

  /// The sent issue's status as the server last reported it (open,
  /// planned, fixed, wontfix); null until the first status check.
  String? issueStatus;

  /// Comments on the sent issue, and how many of them the user has seen.
  int replies;
  int seenReplies;

  bool get hasNewReplies => replies > seenReplies;

  String get title => summary.trim();

  /// Title filled and everything within the server caps.
  bool get isSendable =>
      title.isNotEmpty &&
      title.length <= kBugReportMaxTitle &&
      buildBody().length <= kBugReportMaxBody;

  /// Markdown issue body assembled from the separate fields. Empty optional
  /// sections are left out, and the bug-only fields only go with bugs.
  String buildBody() {
    final b = StringBuffer();
    void section(String heading, String text) {
      final t = text.trim();
      if (t.isEmpty) return;
      b.write('\n### $heading\n\n$t\n');
    }

    section('Description', whatHappened);
    if (kind != BugReportKind.bug) return b.toString();
    section('Steps to reproduce', steps);
    section(
      'Screenshots',
      [for (final url in screenshots) '![]($url)'].join('\n'),
    );
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
    'screenshots': screenshots,
    'includeDiagnostics': includeDiagnostics,
    'diagnostics': diagnostics,
    'status': status.name,
    'issueNumber': issueNumber,
    'issueUrl': issueUrl,
    'lastError': lastError,
    'attempts': attempts,
    'issueStatus': issueStatus,
    'replies': replies,
    'seenReplies': seenReplies,
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
      // Older drafts had finer kinds; "idea" became a suggestion and the
      // rest were all problems.
      kind: json['kind'] == 'idea'
          ? BugReportKind.suggestion
          : byName(BugReportKind.values, json['kind'], BugReportKind.bug),
      summary: json['summary'] as String? ?? '',
      whatHappened: _withLegacyExpected(
        json['whatHappened'] as String? ?? '',
        json['expected'] as String? ?? '',
      ),
      steps: switch (json['steps']) {
        _legacyStepsTemplate => '',
        final String s => s,
        _ => '',
      },
      screenshots: [
        for (final url in json['screenshots'] as List<dynamic>? ?? const [])
          if (url is String) url,
      ],
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
      issueStatus: json['issueStatus'] as String?,
      replies: json['replies'] as int? ?? 0,
      seenReplies: json['seenReplies'] as int? ?? 0,
    );
  }

  // Older drafts had a separate "expected" field; keep its text.
  static String _withLegacyExpected(String what, String expected) {
    final e = expected.trim();
    if (e.isEmpty) return what;
    return what.trim().isEmpty
        ? 'Expected: $e'
        : '${what.trimRight()}\n\nExpected: $e';
  }
}
