import 'dart:io';
import 'dart:math';

const httpTimeout = Duration(seconds: 10);

/// Throws on transient HTTP failures (rate-limit and server errors) so emote
/// providers can distinguish a flaky response (retryable, caller should keep
/// stale cached data) from a genuine "no emotes" response (other non-2xx like
/// 404).
void throwOnTransientHttpError(int statusCode, Uri uri) {
  if (statusCode == 429 || statusCode >= 500) {
    throw HttpException('HTTP $statusCode', uri: uri);
  }
}

Duration applyReconnectJitter(Duration base) {
  final jitter = 0.75 + Random().nextDouble() * 0.5;
  return Duration(milliseconds: (base.inMilliseconds * jitter).toInt());
}
