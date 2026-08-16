import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../util/constants.dart';
import '../util/log.dart';

/// Configuration for a Chatterino-style image uploader endpoint. The default
/// points at kappa.lol; every field mirrors the uploader settings used by
/// DankChat/Chatterino so users can point the app at any compatible host.
class UploaderConfig {
  final String uploadUrl;
  final String formField;
  final String? headers;
  final String? imageLinkPattern;
  final String? deletionLinkPattern;

  const UploaderConfig({
    required this.uploadUrl,
    required this.formField,
    this.headers,
    this.imageLinkPattern,
    this.deletionLinkPattern,
  });

  static const defaultConfig = UploaderConfig(
    uploadUrl: 'https://kappa.lol/api/upload',
    formField: 'file',
    imageLinkPattern: '{link}',
    deletionLinkPattern: '{delete}',
  );

  /// Extra request headers, stored as `Name: value` pairs separated by `;`,
  /// matching the DankChat uploader config format.
  List<({String name, String value})> get parsedHeaders {
    final raw = headers;
    if (raw == null || raw.isEmpty) return const [];
    final result = <({String name, String value})>[];
    for (final part in raw.split(';')) {
      final splits = part.split(':');
      if (splits.length != 2) continue;
      result.add((name: splits[0].trim(), value: splits[1].trim()));
    }
    return result;
  }

  Map<String, Object?> toJson() => {
    'upload_url': uploadUrl,
    'form_field': formField,
    'headers': headers,
    'image_link_pattern': imageLinkPattern,
    'deletion_link_pattern': deletionLinkPattern,
  };

  static UploaderConfig fromJson(Map<String, Object?> json) => UploaderConfig(
    uploadUrl: json['upload_url'] as String? ?? defaultConfig.uploadUrl,
    formField: json['form_field'] as String? ?? defaultConfig.formField,
    headers: json['headers'] as String?,
    imageLinkPattern: json['image_link_pattern'] as String?,
    deletionLinkPattern: json['deletion_link_pattern'] as String?,
  );
}

class UploadResult {
  final String imageLink;
  final String? deleteLink;

  const UploadResult({required this.imageLink, this.deleteLink});
}

class RecentUpload {
  final String imageLink;
  final String? deleteLink;
  final DateTime timestamp;

  const RecentUpload({
    required this.imageLink,
    this.deleteLink,
    required this.timestamp,
  });

  Map<String, Object?> toJson() => {
    'link': imageLink,
    'delete': deleteLink,
    'timestamp': timestamp.toIso8601String(),
  };

  static RecentUpload fromJson(Map<String, Object?> json) => RecentUpload(
    imageLink: json['link'] as String? ?? '',
    deleteLink: json['delete'] as String?,
    timestamp:
        DateTime.tryParse(json['timestamp'] as String? ?? '') ??
        DateTime.fromMillisecondsSinceEpoch(0),
  );
}

class MediaUploader {
  static const _configPrefKey = 'uploader_config';
  static const _recentsPrefKey = 'recent_uploads';

  final http.Client _client;

  MediaUploader({http.Client? client}) : _client = client ?? http.Client();

  Future<UploaderConfig> loadConfig() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_configPrefKey);
    if (raw == null) return UploaderConfig.defaultConfig;
    try {
      return UploaderConfig.fromJson(jsonDecode(raw) as Map<String, Object?>);
    } catch (e) {
      logDebug('MediaUploader: failed to parse uploader config: $e');
      return UploaderConfig.defaultConfig;
    }
  }

  Future<void> saveConfig(UploaderConfig config) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_configPrefKey, jsonEncode(config.toJson()));
  }

  Future<void> resetConfig() => saveConfig(UploaderConfig.defaultConfig);

  /// Uploads [file] to the configured endpoint via multipart/form-data and
  /// returns the resulting image link (and deletion link, when the endpoint
  /// provides one). When no link pattern is configured the raw response body
  /// is used as the link (DankChat-compatible behaviour).
  Future<UploadResult> uploadMedia(File file) async {
    final config = await loadConfig();
    final mimeType = _mimeTypeFor(file);
    final uri = Uri.parse(config.uploadUrl);
    final request = http.MultipartRequest('POST', uri)
      ..headers['User-Agent'] = 'ermchat'
      ..headers['Accept'] = '*/*'
      ..headers['Origin'] = uri.origin
      ..headers['Referer'] = '${uri.origin}/';
    for (final header in config.parsedHeaders) {
      request.headers[header.name] = header.value;
    }
    request.files.add(
      http.MultipartFile.fromBytes(
        config.formField,
        await file.readAsBytes(),
        filename: file.uri.pathSegments.isNotEmpty
            ? file.uri.pathSegments.last
            : 'upload',
        contentType: http.MediaType.parse(mimeType),
      ),
    );

    final response = await _client.send(request).timeout(httpTimeout);
    final body = await response.stream.bytesToString();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException(
        'Upload failed with HTTP ${response.statusCode}',
        uri: uri,
      );
    }

    final pattern = config.imageLinkPattern;
    if (pattern == null || pattern.trim().isEmpty) {
      return UploadResult(imageLink: body.trim());
    }
    final json = jsonDecode(body) as Map<String, dynamic>;
    return UploadResult(
      imageLink: _extractLink(json, pattern),
      deleteLink: _extractLinkOrNull(json, config.deletionLinkPattern),
    );
  }

  /// Substitutes `{path.to.json.value}` tokens in [pattern] with values from
  /// [json], e.g. `{link}` or `https://host/{id}.{ext}`.
  String _extractLink(Map<String, dynamic> json, String pattern) {
    var result = pattern;
    final regex = RegExp(r'\{([^}]+)\}');
    for (final match in regex.allMatches(pattern)) {
      final value = _jsonValue(json, match.group(1)!);
      if (value != null) {
        result = result.replaceAll(match.group(0)!, '$value');
      }
    }
    return result;
  }

  String? _extractLinkOrNull(Map<String, dynamic> json, String? pattern) {
    if (pattern == null || pattern.trim().isEmpty) return null;
    final value = _extractLink(json, pattern);
    // An unresolved token leaves the placeholder in place; treat that as "the
    // endpoint didn't provide a deletion link" rather than emitting a literal
    // "{delete}" string.
    if (value.isEmpty || RegExp(r'\{[^}]+\}').hasMatch(value)) return null;
    return value;
  }

  Object? _jsonValue(Map<String, dynamic> json, String dottedPath) {
    var current = json;
    final keys = dottedPath.split('.');
    for (var i = 0; i < keys.length; i++) {
      final key = keys[i];
      final value = current[key];
      if (value == null) return null;
      if (i == keys.length - 1) return value;
      if (value is Map<String, dynamic>) {
        current = value;
      } else {
        return null;
      }
    }
    return null;
  }

  String _mimeTypeFor(File file) {
    final name = file.path.toLowerCase();
    if (name.endsWith('.png')) return 'image/png';
    if (name.endsWith('.jpg') || name.endsWith('.jpeg')) {
      return 'image/jpeg';
    }
    if (name.endsWith('.gif')) return 'image/gif';
    if (name.endsWith('.webp')) return 'image/webp';
    if (name.endsWith('.mp4')) return 'video/mp4';
    if (name.endsWith('.mov')) return 'video/quicktime';
    return 'application/octet-stream';
  }

  Future<List<RecentUpload>> recentUploads() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_recentsPrefKey);
    if (raw == null) return [];
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      return list
          .map((e) => RecentUpload.fromJson(e as Map<String, Object?>))
          .toList();
    } catch (e) {
      logDebug('MediaUploader: failed to parse recent uploads: $e');
      return [];
    }
  }

  Future<void> addRecent(UploadResult result, {DateTime? timestamp}) async {
    final uploads = await recentUploads();
    uploads.insert(
      0,
      RecentUpload(
        imageLink: result.imageLink,
        deleteLink: result.deleteLink,
        timestamp: timestamp ?? DateTime.now(),
      ),
    );
    // Cap the persisted list to keep the pref small.
    final trimmed = uploads.take(50).toList();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _recentsPrefKey,
      jsonEncode(trimmed.map((e) => e.toJson()).toList()),
    );
  }

  Future<void> removeRecent(int index) async {
    final uploads = await recentUploads();
    if (index < 0 || index >= uploads.length) return;
    uploads.removeAt(index);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _recentsPrefKey,
      jsonEncode(uploads.map((e) => e.toJson()).toList()),
    );
  }

  Future<void> clearRecents() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_recentsPrefKey);
  }
}
