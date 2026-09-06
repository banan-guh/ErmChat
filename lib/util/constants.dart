import 'dart:io';
import 'dart:math';

const httpTimeout = Duration(seconds: 10);

/// User-whitelisted link suffixes for rejoining fractured (spaced) domains like "kappa .lol".
const String kLinkWhitelistPrefKey = 'link_whitelist_v1';

/// Log-scaled max-messages-per-channel options: 100-500 by 100, 1000-5000 by 1000.
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

/// Default max-messages-per-channel. Must be in [kMaxMessagesPerChannelValues].
const kMaxMessagesPerChannelDefault = 500;

/// Max joined channels. Restore path is exempt so existing users keep theirs.
const kMaxChannels = 100;

/// Default recent-messages fetch count, shared across boot, HomeScreen, and settings.
const kRecentMessagesLimitDefault = 100;

/// Giphy inline embeds: off by default, height slider in dp at textScale 1.0.
const String kGiphyInlineEnabledPrefKey = 'giphy_inline_enabled';
const String kGiphyInlineHeightPrefKey = 'giphy_inline_height';
const bool kGiphyInlineEnabledDefault = false;
const double kGiphyInlineHeightDefault = 120.0;
const double kGiphyInlineHeightMin = 60.0;
const double kGiphyInlineHeightMax = 240.0;

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

/// Throws on transient HTTP errors (429/5xx) so callers can retry and keep stale cache.
void throwOnTransientHttpError(int statusCode, Uri uri) {
  if (statusCode == 429 || statusCode >= 500) {
    throw HttpException('HTTP $statusCode', uri: uri);
  }
}

Duration applyReconnectJitter(Duration base) {
  final jitter = 0.75 + Random().nextDouble() * 0.5;
  return Duration(milliseconds: (base.inMilliseconds * jitter).toInt());
}
