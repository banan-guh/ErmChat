/// In-app bug reports go to the ermchatbot `POST /report` endpoint.
class ReportConfig {
  static const String endpoint =
      'https://erm-machine-1.tail834800.ts.net/report';

  /// Optional `X-Report-Secret` gate. It ships in the binary, so it only
  /// filters casual traffic; the server's Twitch token check is the auth.
  static const String secret = String.fromEnvironment('ERMCHAT_REPORT_SECRET');
}
