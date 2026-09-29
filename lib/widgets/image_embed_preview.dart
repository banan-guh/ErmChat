import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:http/http.dart' as http;

import '../util/log.dart';
import 'image_embed_viewer.dart';

/// Inline preview for an image link. Streams the bytes itself so it can
/// count progress and drop anything that is not an image (a video, a web
/// page) on the first response instead of downloading all of it. Finished
/// bytes go into the shared image cache, so the full-screen viewer opens
/// without a second fetch.
class ImageEmbedPreview extends StatefulWidget {
  const ImageEmbedPreview({
    super.key,
    required this.url,
    required this.maxWidth,
    required this.maxHeight,
    this.client,
    this.cache,
  });

  final String url;
  final double maxWidth;
  final double maxHeight;

  /// Test seams; default to a fresh client and the app-wide image cache.
  final http.Client? client;
  final BaseCacheManager? cache;

  /// Forgets the in-memory recent embeds. Exposed for tests.
  @visibleForTesting
  static void debugClearRecent() => _ImageEmbedPreviewState._clearRecent();

  @override
  State<ImageEmbedPreview> createState() => _ImageEmbedPreviewState();
}

class _ImageEmbedPreviewState extends State<ImageEmbedPreview> {
  /// Recently shown embeds, newest last, so reopening one paints on the
  /// first frame instead of flashing the loading box over a disk read.
  static final _recent = <String, Uint8List>{};
  static int _recentBytes = 0;
  static const _maxRecentBytes = 24 << 20;

  static void _remember(String url, Uint8List bytes) {
    final old = _recent.remove(url);
    if (old != null) _recentBytes -= old.length;
    _recent[url] = bytes;
    _recentBytes += bytes.length;
    while (_recentBytes > _maxRecentBytes && _recent.length > 1) {
      final oldest = _recent.keys.first;
      _recentBytes -= _recent.remove(oldest)!.length;
    }
  }

  static void _clearRecent() {
    _recent.clear();
    _recentBytes = 0;
  }

  Uint8List? _bytes;

  /// A network fetch is running; until then the box stays blank, so a
  /// disk cache hit never flashes the spinner.
  bool _fetching = false;

  /// Why the link cannot show, once known.
  String? _rejected;
  bool _failed = false;
  int _received = 0;
  int? _total;

  http.Client? _ownClient;
  StreamSubscription<List<int>>? _sub;

  BaseCacheManager get _cache => widget.cache ?? DefaultCacheManager();

  @override
  void initState() {
    super.initState();
    final recent = _recent[widget.url];
    if (recent != null) {
      _bytes = recent;
      _remember(widget.url, recent);
      return;
    }
    unawaited(_load());
  }

  @override
  void dispose() {
    _sub?.cancel();
    _ownClient?.close();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final cached = await _cache.getFileFromCache(widget.url);
      if (cached != null) {
        final bytes = await cached.file.readAsBytes();
        if (!mounted) return;
        if (sniffEmbedImage(bytes) == true) {
          _remember(widget.url, bytes);
          setState(() => _bytes = bytes);
          return;
        }
      }
    } on Object {
      // No cache (tests, storage errors): fetch instead.
    }
    if (!mounted) return;
    setState(() => _fetching = true);
    final client = widget.client ?? (_ownClient = http.Client());
    final http.StreamedResponse response;
    try {
      response = await client.send(http.Request('GET', Uri.parse(widget.url)));
    } on Object catch (e) {
      _fail(e);
      return;
    }
    if (!mounted) return;
    if (response.statusCode != 200) {
      _fail('HTTP ${response.statusCode}');
      unawaited(response.stream.listen(null).cancel());
      return;
    }
    final type = response.headers['content-type'] ?? '';
    if (!embedTypeMayBeImage(type)) {
      unawaited(response.stream.listen(null).cancel());
      _reject(type);
      return;
    }
    _total = response.contentLength;
    final builder = BytesBuilder(copy: false);
    var sniffed = false;
    _sub = response.stream.listen(
      (chunk) {
        builder.add(chunk);
        if (!sniffed) {
          final verdict = sniffEmbedImage(builder.toBytes());
          if (verdict == false) {
            _sub?.cancel();
            _reject(type);
            return;
          }
          sniffed = verdict == true;
        }
        _onProgress(builder.length);
      },
      onDone: () {
        final bytes = builder.takeBytes();
        if (!sniffed && sniffEmbedImage(bytes) != true) {
          _reject(type);
          return;
        }
        _remember(widget.url, bytes);
        if (!mounted) return;
        setState(() => _bytes = bytes);
        _cache.putFile(widget.url, bytes).ignore();
      },
      onError: _fail,
      cancelOnError: true,
    );
  }

  /// Repaints only when the shown figure changes: a whole percent, or
  /// 64 KB steps when the size is unknown.
  void _onProgress(int received) {
    final total = _total;
    final changed = total != null && total > 0
        ? received * 100 ~/ total != _received * 100 ~/ total
        : received >> 16 != _received >> 16;
    _received = received;
    if (changed && mounted) setState(() {});
  }

  void _reject(String type) {
    final kind = type.split(';').first.trim();
    logDebug('Image embed rejected: ${widget.url} ($kind)');
    if (mounted) {
      setState(() => _rejected = kind.isEmpty ? 'not an image' : kind);
    }
  }

  void _fail(Object error) {
    logDebug('Image embed load failed: ${widget.url} - $error');
    if (mounted) setState(() => _failed = true);
  }

  @override
  Widget build(BuildContext context) {
    final rejected = _rejected;
    if (rejected != null) return _Notice('Can\'t preview ($rejected)');
    if (_failed) return const _Notice('Image failed to load');
    final bytes = _bytes;
    if (bytes == null) {
      if (!_fetching) {
        return SizedBox.square(dimension: widget.maxHeight);
      }
      return _EmbedProgress(
        size: widget.maxHeight,
        received: _received,
        total: _total,
      );
    }
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxWidth: widget.maxWidth,
        maxHeight: widget.maxHeight,
      ),
      child: GestureDetector(
        onTap: () => showImageEmbedViewer(context, widget.url),
        child: Image.memory(
          bytes,
          fit: BoxFit.contain,
          alignment: Alignment.centerLeft,
          gaplessPlayback: true,
          errorBuilder: (_, error, _) {
            logDebug('Image embed decode failed: ${widget.url} - $error');
            return const _Notice('Image failed to load');
          },
        ),
      ),
    );
  }
}

/// Whether a Content-Type can still turn out to be an image. Missing and
/// generic binary types pass to the byte sniff; video, audio, text and
/// other typed payloads stop at once.
bool embedTypeMayBeImage(String contentType) {
  final type = contentType.split(';').first.trim().toLowerCase();
  return type.isEmpty ||
      type.startsWith('image/') ||
      type == 'application/octet-stream' ||
      type == 'binary/octet-stream';
}

/// Image formats the engine decodes, by magic bytes: true for PNG, JPEG,
/// GIF, WebP or BMP, false for anything else, null while under 12 bytes.
bool? sniffEmbedImage(Uint8List bytes) {
  if (bytes.length < 12) return null;
  bool at(int offset, List<int> magic) {
    for (var i = 0; i < magic.length; i++) {
      if (bytes[offset + i] != magic[i]) return false;
    }
    return true;
  }

  return at(0, const [0x89, 0x50, 0x4E, 0x47]) ||
      at(0, const [0xFF, 0xD8, 0xFF]) ||
      at(0, 'GIF8'.codeUnits) ||
      (at(0, 'RIFF'.codeUnits) && at(8, 'WEBP'.codeUnits)) ||
      at(0, 'BM'.codeUnits);
}

/// Square box with a spinner and a counter while an embed downloads.
class _EmbedProgress extends StatelessWidget {
  const _EmbedProgress({
    required this.size,
    required this.received,
    required this.total,
  });

  final double size;
  final int received;
  final int? total;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final total = this.total;
    final fraction = total != null && total > 0
        ? (received / total).clamp(0.0, 1.0)
        : null;
    final label = fraction != null
        ? '${(fraction * 100).floor()}%'
        : received > 0
        ? _formatBytes(received)
        : null;
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox.square(
            dimension: 20,
            child: CircularProgressIndicator(strokeWidth: 2, value: fraction),
          ),
          if (label != null) ...[
            const SizedBox(height: 6),
            Text(label, style: theme.textTheme.labelSmall),
          ],
        ],
      ),
    );
  }
}

String _formatBytes(int bytes) {
  if (bytes < 1024 * 1024) return '${(bytes / 1024).ceil()} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

/// One-line status in place of a preview that cannot show.
class _Notice extends StatelessWidget {
  const _Notice(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.onSurfaceVariant;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.hide_image_outlined, size: 16, color: color),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            text,
            style: TextStyle(fontSize: 12, color: color),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}
