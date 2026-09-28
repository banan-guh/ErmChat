/// In-app bug reports go to the ermchatbot `POST /report` endpoint. Both
/// values come from `--dart-define`; an empty endpoint hides the feature.
class ReportConfig {
  /// Full URL, e.g. `https://<service>.onrender.com/report`.
  static const String endpoint = String.fromEnvironment('ERMCHAT_REPORT_URL');

  /// Optional `X-Report-Secret` gate. It ships in the binary, so it only
  /// filters casual traffic; the server's Twitch token check is the auth.
  static const String secret = String.fromEnvironment('ERMCHAT_REPORT_SECRET');

  static bool get isConfigured => endpoint.isNotEmpty;
}
