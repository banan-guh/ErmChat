import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;

/// What to show a person when [error] stops an action: connection trouble
/// gets one plain sentence, anything else gets [fallback]. Raw exception
/// text belongs in logs, not in the UI.
String friendlyError(
  Object error, {
  String fallback = 'Something went wrong. Try again.',
}) {
  if (error is SocketException ||
      error is HandshakeException ||
      error is TimeoutException ||
      error is http.ClientException) {
    return "Can't reach the server. Check your connection.";
  }
  return fallback;
}

/// Plain-language reason for a failed HTTP status, or null when the status
/// says nothing a person can act on.
String? friendlyHttpStatus(int? status) => switch (status) {
  401 => 'Your Twitch login expired. Log in again in Settings > Account.',
  403 => "You don't have permission to do that.",
  404 => 'Not found.',
  429 => 'Too many requests. Try again in a moment.',
  final s? when s >= 500 => 'Twitch is having trouble. Try again later.',
  _ => null,
};
