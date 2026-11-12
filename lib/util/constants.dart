import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

const httpTimeout = Duration(seconds: 10);

/// Twitch's limit on one chat message, in characters.
const kTwitchMessageMaxChars = 500;

/// The one emote loading look app-wide: neutral gray (unthemed, cached
/// spans outlive theme switches), shared by chat spans, Giphy previews,
/// menu, sheet, and panel placeholders.
const Color kEmotePlaceholderGray = Color(0x33808080);

/// Corner radius for emote loading boxes.
const double kEmotePlaceholderRadius = 3.0;

/// Pseudo-channel whisper rows render under. Whispers carry no channel, so
/// ingest stamps them against the global mix under this key and the whisper
/// tile renders with the same string.
const kWhispersChannel = '@whispers';

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

/// Rows each channel's live buffer keeps. Fixed: history past it reads from
/// the archive. Covers
/// robotty's 800-row fetch, which dedups against the buffer.
const kLiveBufferMessages = 1000;

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
const String kImageEmbedHostsPrefKey = 'image_embed_hosts_v1';
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
bool isImageEmbedCandidate(String url, {List<String>? hosts}) {
  final uri = Uri.tryParse(url);
  if (uri == null || uri.host.isEmpty) return false;
  if (uri.scheme != 'https' && uri.scheme != 'http') return false;
  final host = uri.host.toLowerCase();
  final knownHost = (hosts ?? kImageEmbedHosts).any(
    (d) => host == d || host.endsWith('.$d'),
  );
  final path = uri.path.toLowerCase();
  final dot = path.lastIndexOf('.');
  final ext = dot < 0 ? null : path.substring(dot + 1);
  // A known host serves anything: its bare ids pass, a video extension not.
  if (knownHost) {
    if (uri.pathSegments.isEmpty) return false;
    return ext == null || ext.contains('/') || _kImageExtensions.contains(ext);
  }
  if (ext == null || ext.contains('/')) return false;
  return _kImageExtensions.contains(ext);
}

/// The URL to fetch for an embed preview. Most hosts serve the raw image at
/// the shared link; olrite.lol shares a viewer page and keeps the file under
/// `/api/files/<id>`.
String imageEmbedFetchUrl(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null) return url;
  final host = uri.host.toLowerCase();
  if (host != 'olrite.lol' && host != 'www.olrite.lol') return url;
  final segments = uri.pathSegments;
  if (segments.length != 1 || segments.single.isEmpty) return url;
  return 'https://olrite.lol/api/files/${segments.single}';
}

/// Throws on transient HTTP errors (429/5xx) so callers can retry and keep stale cache.
void throwOnTransientHttpError(int statusCode, Uri uri) {
  if (statusCode == 429 || statusCode >= 500) {
    throw HttpException('HTTP $statusCode', uri: uri);
  }
}

/// Whether [error] is worth another attempt: a timeout, a socket or TLS
/// failure, or a transient HTTP status.
bool isTransientHttpError(Object error) =>
    error is TimeoutException ||
    error is SocketException ||
    error is HandshakeException ||
    error is HttpException ||
    error is http.ClientException;

/// Runs [action] up to [attempts] times, backing off between transient
/// failures. Non-transient errors fail at once.
Future<T> retryTransient<T>(
  Future<T> Function() action, {
  int attempts = 3,
  Duration base = const Duration(milliseconds: 500),
}) async {
  for (var attempt = 1; ; attempt++) {
    try {
      return await action();
    } catch (error) {
      if (attempt >= attempts || !isTransientHttpError(error)) rethrow;
      await Future<void>.delayed(applyReconnectJitter(base * attempt));
    }
  }
}

Duration applyReconnectJitter(Duration base) {
  final jitter = 0.75 + Random().nextDouble() * 0.5;
  return Duration(milliseconds: (base.inMilliseconds * jitter).toInt());
}
