import 'dart:io';
import 'dart:math';

const httpTimeout = Duration(seconds: 10);

/// Persisted list of user-whitelisted link suffixes used to rejoin and
/// linkify fractured (spaced) domains such as `kappa .lol` that would
/// otherwise evade a "no links" filter.
const String kLinkWhitelistPrefKey = 'link_whitelist_v1';

/// Discrete max-messages-per-channel options, log-scaled so small buffers can
/// be fine-tuned while large buffers stay reachable: 100-500 in 100s, then
/// 1000-5000 in 1000s. The settings slider indexes into this list; stored
/// values that fall between steps snap to the nearest one.
const kMaxMessagesPerChannelValues = <int>[
  100,
  200,
  300,
  400,
  500,
  1000,
  2000,
  3000,
  4000,
  5000,
];

/// Default max-messages-per-channel when nothing is persisted. Must be a
/// member of [kMaxMessagesPerChannelValues].
const kMaxMessagesPerChannelDefault = 500;

/// Hard ceiling on simultaneously joined channels. The join path checks this
/// before adding; the restore path (loading saved channels) is intentionally
/// exempt so existing users with more keep them.
const kMaxChannels = 50;

/// Default recent-messages history fetch count when nothing is persisted.
/// Shared by the boot warm-up, HomeScreen's limit loader, and the settings
/// screen so all three agree.
const kRecentMessagesLimitDefault = 100;

/// Snaps a raw (possibly legacy) value to the nearest log-scale step.
int snapToMaxMessagesStep(int value) {
  var best = kMaxMessagesPerChannelValues.first;
  var bestDistance = (value - best).abs();
  for (final step in kMaxMessagesPerChannelValues) {
    final distance = (value - step).abs();
    if (distance < bestDistance) {
      best = step;
      bestDistance = distance;
    }
  }
  return best;
}

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
