import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/twitch_message.dart';

const kTtsEnabledKey = 'tts_enabled';
const kTtsQueueModeKey = 'tts_queue_mode';
const kTtsFormatModeKey = 'tts_format_mode';
const kTtsIgnoreUrlsKey = 'tts_ignore_urls';
const kTtsIgnoreEmotesKey = 'tts_ignore_emotes';
const kTtsForceEnglishKey = 'tts_force_english';
const kTtsUserIgnoreListKey = 'tts_user_ignore_list';
const kTtsVoiceIdKey = 'tts_voice_id';
const kTtsVoiceRawKey = 'tts_voice_raw';

enum TtsQueueMode { queue, newest }

enum TtsFormatMode { messageOnly, userAndMessage }

/// A selectable TTS engine (Android) or voice (iOS), unified behind id + label.
class TtsOption {
  final String id;
  final String label;
  final Map<String, String> raw;

  const TtsOption({required this.id, required this.label, required this.raw});

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TtsOption && other.id == id && other.label == label;

  @override
  int get hashCode => Object.hash(id, label);
}

/// Reads chat messages aloud. Only the active channel is spoken;
/// emotes/URLs can be stripped. Engine selection delegated to system settings
/// (Android) or in-app (iOS).
class TtsController {
  final FlutterTts _tts;
  static const MethodChannel _channel = MethodChannel('ermchat/tts');

  bool _enabled = false;
  bool _available = false;
  TtsQueueMode _queueMode = TtsQueueMode.queue;
  TtsFormatMode _formatMode = TtsFormatMode.userAndMessage;
  bool _ignoreUrls = true;
  bool _ignoreEmotes = true;
  bool _forceEnglish = false;
  final Set<String> _userIgnoreList = {};
  TtsOption? _selectedOption;
  String? _previousUser;

  // Test hook: forces the Android platform branch regardless of host OS.
  bool? overrideIsAndroid;

  TtsController({FlutterTts? tts}) : _tts = tts ?? FlutterTts();

  bool get isAvailable => _available;
  bool get enabled => _enabled;
  TtsQueueMode get queueMode => _queueMode;
  TtsFormatMode get formatMode => _formatMode;
  bool get ignoreUrls => _ignoreUrls;
  bool get ignoreEmotes => _ignoreEmotes;
  bool get forceEnglish => _forceEnglish;
  TtsOption? get selectedOption => _selectedOption;
  List<String> get userIgnoreList => List.unmodifiable(_userIgnoreList);

  /// Android only: opens system TTS engine picker. No-op on iOS.
  bool get canOpenSystemSettings => Platform.isAndroid;

  String get _defaultLocale {
    if (_forceEnglish) return 'en-US';
    final locale = Platform.localeName;
    if (locale.isEmpty) return 'en-US';
    return locale.replaceAll('_', '-');
  }

  /// Loads settings and checks availability. Re-applies a previously chosen
  /// option if any.
  Future<void> init() async {
    await loadFromPrefs();
    _available = await _checkLanguage();
    if (!_available) return;
    if (_selectedOption != null) await applyOption(_selectedOption!);
  }

  /// Enables TTS. Blocked only when no language support is available.
  Future<bool> checkAndPrepare() async {
    if (!_available) _available = await _checkLanguage();
    if (!_available) return false;
    if (_selectedOption != null) await applyOption(_selectedOption!);
    return true;
  }

  /// Opens system TTS settings (Android only).
  Future<void> openSystemTtsSettings() async {
    try {
      await _channel.invokeMethod('openTtsSettings');
    } catch (_) {}
  }

  /// Sentinel: "use system default". Returned when engine enumeration is
  /// blocked.
  static const defaultEngineId = '__default__';

  /// Lists installed engines (Android) or voices (iOS). Falls back to default
  /// when enumeration is blocked.
  Future<List<TtsOption>> fetchOptions() async {
    final useEngines = overrideIsAndroid ?? Platform.isAndroid;
    final useVoices =
        !useEngines &&
        (overrideIsAndroid != null || Platform.isIOS || Platform.isMacOS);
    try {
      if (useEngines) {
        for (var attempt = 0; attempt < 2; attempt++) {
          try {
            final engines = await _tts.getEngines as List<dynamic>?;
            if (engines != null && engines.isNotEmpty) {
              return _parseAndroidEngines(engines);
            }
          } catch (_) {}
          // Retry after delay: getEngines can be empty before init completes.
          if (attempt == 0) {
            await Future<void>.delayed(const Duration(milliseconds: 400));
          }
        }
        // Enumeration blocked/empty: fall back to the default engine.
        try {
          final def = await _tts.getDefaultEngine as String?;
          if (def != null && def.isNotEmpty) {
            return [
              TtsOption(id: def, label: def, raw: {'name': def}),
            ];
          }
        } catch (_) {}
        // No way to enumerate: offer "use device default" so TTS still works.
        return [
          const TtsOption(
            id: defaultEngineId,
            label: 'Device default',
            raw: {},
          ),
        ];
      } else if (useVoices) {
        final voices = await _tts.getVoices as List<dynamic>?;
        if (voices == null) return [];
        return _parseIosVoices(voices);
      }
    } catch (_) {}
    return [];
  }

  List<TtsOption> _parseAndroidEngines(List<dynamic> engines) {
    final options = <TtsOption>[];
    for (final e in engines) {
      if (e is! Map) continue;
      final map = <String, dynamic>{};
      e.forEach((k, v) => map[k.toString()] = v);
      final id = (map['name'] ?? map['label'] ?? '').toString();
      if (id.isEmpty) continue;
      final label = (map['label'] ?? map['name'] ?? id).toString();
      options.add(TtsOption(id: id, label: label, raw: _stringMap(map)));
    }
    return options;
  }

  List<TtsOption> _parseIosVoices(List<dynamic> voices) {
    final options = <TtsOption>[];
    for (final v in voices) {
      if (v is! Map) continue;
      final map = <String, dynamic>{};
      v.forEach((k, vv) => map[k.toString()] = vv);
      final name = (map['name'] ?? '').toString();
      final locale = (map['locale'] ?? '').toString();
      final id = (map['identifier']?.toString().isNotEmpty == true)
          ? map['identifier'].toString()
          : '$name-$locale';
      if (id.isEmpty) continue;
      final label = name.isEmpty ? locale : '$name ($locale)';
      options.add(TtsOption(id: id, label: label, raw: _stringMap(map)));
    }
    return options;
  }

  Map<String, String> _stringMap(Map map) {
    final out = <String, String>{};
    map.forEach((k, v) => out[k.toString()] = v?.toString() ?? '');
    return out;
  }

  /// Applies and persists the selected engine/voice.
  Future<void> applyOption(TtsOption option) async {
    try {
      if (overrideIsAndroid ?? Platform.isAndroid) {
        await _applyToEngine(option);
      } else {
        await _applyToVoice(option);
      }
      _selectedOption = option;
      await _persistOption(option);
    } catch (_) {}
  }

  Future<void> _applyToEngine(TtsOption option) async {
    if (option.id == defaultEngineId) return;
    await _tts.setEngine(option.id);
  }

  Future<void> _applyToVoice(TtsOption option) async =>
      _tts.setVoice(option.raw);

  Future<bool> _checkLanguage() async {
    try {
      final result = await _tts.isLanguageAvailable(_defaultLocale);
      return result == true;
    } catch (_) {
      return false;
    }
  }

  /// Seeds the in-memory settings from persisted preferences.
  Future<void> loadFromPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    _enabled = prefs.getBool(kTtsEnabledKey) ?? false;
    _queueMode = TtsQueueMode.values.byName(
      prefs.getString(kTtsQueueModeKey) ?? 'queue',
    );
    _formatMode = TtsFormatMode.values.byName(
      prefs.getString(kTtsFormatModeKey) ?? 'userAndMessage',
    );
    _ignoreUrls = prefs.getBool(kTtsIgnoreUrlsKey) ?? true;
    _ignoreEmotes = prefs.getBool(kTtsIgnoreEmotesKey) ?? true;
    _forceEnglish = prefs.getBool(kTtsForceEnglishKey) ?? false;
    _userIgnoreList.clear();
    _userIgnoreList.addAll(prefs.getStringList(kTtsUserIgnoreListKey) ?? []);
    final voiceId = prefs.getString(kTtsVoiceIdKey);
    final voiceRaw = prefs.getString(kTtsVoiceRawKey);
    if (voiceId != null && voiceRaw != null) {
      try {
        _selectedOption = TtsOption(
          id: voiceId,
          label: voiceId == defaultEngineId ? 'Device default' : '',
          raw: Map<String, String>.from(
            jsonDecode(voiceRaw) as Map<dynamic, dynamic>,
          ),
        );
      } catch (_) {
        _selectedOption = null;
      }
    }
  }

  Future<void> _persistOption(TtsOption option) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(kTtsVoiceIdKey, option.id);
    await prefs.setString(kTtsVoiceRawKey, jsonEncode(option.raw));
  }

  Future<void> shutdown() async {
    try {
      await _tts.stop();
    } catch (_) {}
  }

  void setEnabled(bool value) {
    _enabled = value;
    if (!value) stop();
  }

  void setQueueMode(TtsQueueMode value) => _queueMode = value;

  void setFormatMode(TtsFormatMode value) => _formatMode = value;

  void setIgnoreUrls(bool value) => _ignoreUrls = value;

  void setIgnoreEmotes(bool value) => _ignoreEmotes = value;

  void setForceEnglish(bool value) {
    _forceEnglish = value;
    if (value) _applyLanguage();
  }

  void setUserIgnoreList(List<String> value) {
    _userIgnoreList.clear();
    _userIgnoreList.addAll(value);
  }

  /// Speaks [msg] if it belongs to the active [selectedChannel].
  void handleMessage(
    String channel,
    TwitchMessage msg,
    String? selectedChannel,
  ) {
    if (!_enabled || !_available) return;
    if (channel != selectedChannel) return;
    if (msg.isHistory || msg.isBackfill) return;
    final login = msg.login.toLowerCase();
    final display = msg.displayName.toLowerCase();
    for (final ignored in _userIgnoreList) {
      final lower = ignored.toLowerCase();
      if (lower == login || lower == display) return;
    }
    final utterance = _buildUtterance(msg);
    if (utterance == null || utterance.trim().isEmpty) return;
    _speak(utterance);
  }

  Future<void> stop() async {
    try {
      await _tts.stop();
    } catch (_) {}
  }

  String? _buildUtterance(TwitchMessage msg) {
    var text = msg.text;
    if (_ignoreEmotes) text = _stripEmotes(msg, text);
    if (_ignoreUrls) text = _stripUrls(text);
    // Emoji/symbols are intentionally kept: TTS should not skip over them.
    if (text.trim().isEmpty) return null;

    if (_formatMode == TtsFormatMode.messageOnly) return text.trim();

    final name = msg.displayName.isNotEmpty ? msg.displayName : msg.login;
    final sameUser =
        _previousUser != null && _previousUser == name.toLowerCase();
    _previousUser = name.toLowerCase();
    if (sameUser) return text.trim();
    return _forceEnglish
        ? '$name said ${text.trim()}'
        : '$name. ${text.trim()}';
  }

  String _stripEmotes(TwitchMessage msg, String text) {
    final positions = msg.emotePositions;
    if (positions == null || positions.isEmpty) return text;
    var result = text;
    final sorted = [...positions]
      ..sort((a, b) => b.startIndex.compareTo(a.startIndex));
    for (final p in sorted) {
      if (p.startIndex < 0 || p.endIndex > result.length) continue;
      if (p.startIndex > p.endIndex) continue;
      result = result.replaceRange(p.startIndex, p.endIndex, '');
    }
    return result;
  }

  static final RegExp _urlRegex = RegExp(r'https?://[^\s]+|www\.[^\s]+');

  String _stripUrls(String text) => text.replaceAll(_urlRegex, '');

  Future<void> _applyLanguage() async {
    try {
      if (_forceEnglish) await _tts.setLanguage('en-US');
    } catch (_) {}
  }

  Future<void> _speak(String text) async {
    try {
      // QUEUE_ADD (1) vs QUEUE_FLUSH (0); flutter_tts defaults to FLUSH.
      await _tts.setQueueMode(_queueMode == TtsQueueMode.queue ? 1 : 0);
      await _tts.speak(text);
    } catch (_) {}
  }
}
