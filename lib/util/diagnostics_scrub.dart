final _oauthRe = RegExp(r'oauth:\S+', caseSensitive: false);
final _bearerRe = RegExp(r'(Bearer|OAuth)\s+\S+');
final _tokenParamRe = RegExp(
  r'((?:access_token|refresh_token|token|code|client_secret)=)[^&\s#]+',
  caseSensitive: false,
);
final _queryRe = RegExp(r'(https?://[^\s?#]+)[?#]\S*');

/// Removes credentials from diagnostics text before it leaves the device:
/// IRC `oauth:` passwords, auth headers, token query params, and the query
/// part of any URL (which is where tokens and ids tend to ride).
String scrubDiagnostics(String text) => text
    .replaceAll(_oauthRe, 'oauth:[redacted]')
    .replaceAllMapped(_bearerRe, (m) => '${m[1]} [redacted]')
    .replaceAllMapped(_tokenParamRe, (m) => '${m[1]}[redacted]')
    .replaceAllMapped(_queryRe, (m) => '${m[1]}?[redacted]');
