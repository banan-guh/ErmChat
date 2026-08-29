import 'log.dart';

/// Pluggable crash reporter. Null by default; wire a backend (Sentry,
/// Firebase, ...) here so errors surface in release builds instead of being
/// swallowed by Flutter's default handler.
void Function(Object error, StackTrace stack)? crashReporter;

void reportError(Object error, StackTrace? stack) {
  logDebug('[crash] $error\n$stack');
  crashReporter?.call(error, stack ?? StackTrace.current);
}
