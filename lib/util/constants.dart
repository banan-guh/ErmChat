import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';

const httpTimeout = Duration(seconds: 10);

/// The one emote loading look app-wide: neutral gray (unthemed, cached
/// spans outlive theme switches), shared by chat spans, Giphy previews,
/// menu, sheet, and panel placeholders.
const Color kEmotePlaceholderGray = Color(0x33808080);

/// Corner radius for emote loading boxes.
const double kEmotePlaceholderRadius = 3.0;

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

/// Image link embeds: extension match anywhere, or extensionless links on
/// these raw-image hosts (subdomains included). Kept separate from the
/// split-link whitelist: youtu.be links but never serves raw images.
const String kImageEmbedEnabledPrefKey = 'image_embeds_enabled';
const String kImageEmbedHeightPrefKey = 'image_embeds_height';
const bool kImageEmbedEnabledDefault = false;
const double kImageEmbedHeightDefault = 120.0;
const double kImageEmbedHeightMin = 60.0;
const double kImageEmbedHeightMax = 240.0;

/// Raw-image hosts whose short links carry no extension (kappa.lol/abc).
const kImageEmbedHosts = <String>[
  'kappa.lol',
  'segs.lol',
  'i.nuuls.com',
  'gachi.gay',
  'olrite.lol',
];

/// At most this many expandable previews render under one message.
const kMaxImageEmbedsPerMessage = 4;

const _kImageExtensions = <String>{'png', 'jpg', 'jpeg', 'gif', 'webp'};

/// Best-effort sync check for raw image serves: image extension in the path
/// (query/fragment stripped by Uri), or a known host with a real path.
/// Bare host roots (upload homepages) never count.
bool isImageEmbedCandidate(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null || uri.host.isEmpty) return false;
  if (uri.scheme != 'https' && uri.scheme != 'http') return false;
  final host = uri.host.toLowerCase();
  final knownHost = kImageEmbedHosts.any(
    (d) => host == d || host.endsWith('.$d'),
  );
  if (knownHost) return uri.pathSegments.isNotEmpty;
  final path = uri.path.toLowerCase();
  final dot = path.lastIndexOf('.');
  if (dot < 0) return false;
  final ext = path.substring(dot + 1);
  if (ext.contains('/')) return false;
  return _kImageExtensions.contains(ext);
}

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
