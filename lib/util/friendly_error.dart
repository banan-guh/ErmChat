import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../l10n/l10n.dart';

/// What to show a person when [error] stops an action: connection trouble
/// gets one plain sentence, anything else gets [fallback]. Raw exception
/// text belongs in logs, not in the UI.
String friendlyError(Object error, {String? fallback, AppLocalizations? l}) {
  l ??= englishStrings();
  if (error is SocketException ||
      error is HandshakeException ||
      error is TimeoutException ||
      error is http.ClientException) {
    return l.errorNetwork;
  }
  return fallback ?? l.errorGeneric;
}

/// Plain-language reason for a failed HTTP status, or null when the status
/// says nothing a person can act on.
String? friendlyHttpStatus(int? status, [AppLocalizations? l]) {
  l ??= englishStrings();
  return switch (status) {
    401 => l.errorLoginExpired,
    403 => l.errorNoPermission,
    404 => l.errorNotFound,
    429 => l.errorRateLimited,
    final s? when s >= 500 => l.errorTwitchTrouble,
    _ => null,
  };
}
