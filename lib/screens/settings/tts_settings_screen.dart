import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../services/tts_controller.dart';
import 'tts_user_ignore_list_screen.dart';

class TtsSettingsScreen extends StatefulWidget {
  final TtsController? ttsController;

  const TtsSettingsScreen({super.key, this.ttsController});

  @override
  State<TtsSettingsScreen> createState() => _TtsSettingsScreenState();
}

class _TtsSettingsScreenState extends State<TtsSettingsScreen> {
  late bool _enabled;
  late TtsQueueMode _queueMode;
  late TtsFormatMode _formatMode;
  late bool _ignoreUrls;
  late bool _ignoreEmotes;
  late bool _forceEnglish;
  bool _available = false;
  TtsOption? _selectedOption;

  @override
  void initState() {
    super.initState();
    final c = widget.ttsController;
    _enabled = c?.enabled ?? false;
    _queueMode = c?.queueMode ?? TtsQueueMode.queue;
    _formatMode = c?.formatMode ?? TtsFormatMode.userAndMessage;
    _ignoreUrls = c?.ignoreUrls ?? true;
    _ignoreEmotes = c?.ignoreEmotes ?? true;
    _forceEnglish = c?.forceEnglish ?? false;
    _selectedOption = c?.selectedOption;
    _availability();
  }

  Future<void> _availability() async {
    final c = widget.ttsController;
    if (c == null) return;
    await c.init();
    if (mounted) {
      setState(() {
        _available = c.isAvailable;
        _selectedOption = c.selectedOption;
      });
    }
  }

  Future<void> _persist(String key, Object value) async {
    final prefs = await SharedPreferences.getInstance();
    if (value is bool) {
      await prefs.setBool(key, value);
    } else if (value is String) {
      await prefs.setString(key, value);
    }
  }

  Future<void> _setEnabled(bool value) async {
    if (value) {
      final c = widget.ttsController;
      if (c != null) {
        final ready = await c.checkAndPrepare();
        if (!ready) {
          if (mounted) {
            final messenger = ScaffoldMessenger.of(context);
            messenger.removeCurrentSnackBar();
            messenger.showSnackBar(
              const SnackBar(
                content: Text(
                  'No TTS engine available. Install or enable one in your '
                  'device\'s Text-to-speech settings, then enable again.',
                ),
              ),
            );
            setState(() => _enabled = false);
          }
          return;
        }
      }
    }
    setState(() => _enabled = value);
    widget.ttsController?.setEnabled(value);
    unawaited(_persist(kTtsEnabledKey, value));
  }

  void _setIgnoreUrls(bool value) {
    setState(() => _ignoreUrls = value);
    widget.ttsController?.setIgnoreUrls(value);
    unawaited(_persist(kTtsIgnoreUrlsKey, value));
  }

  void _setIgnoreEmotes(bool value) {
    setState(() => _ignoreEmotes = value);
    widget.ttsController?.setIgnoreEmotes(value);
    unawaited(_persist(kTtsIgnoreEmotesKey, value));
  }

  void _setForceEnglish(bool value) {
    setState(() => _forceEnglish = value);
    widget.ttsController?.setForceEnglish(value);
    unawaited(_persist(kTtsForceEnglishKey, value));
  }

  Future<void> _pickQueueMode() async {
    final chosen = await showDialog<TtsQueueMode>(
      context: context,
      builder: (ctx) => _ChoiceDialog<TtsQueueMode>(
        title: 'Message queue mode',
        value: _queueMode,
        options: const [
          (TtsQueueMode.queue, 'Queue', 'Plays every message using a queue'),
          (TtsQueueMode.newest, 'Newest', 'Plays only the newest message'),
        ],
      ),
    );
    if (chosen == null || chosen == _queueMode) return;
    setState(() => _queueMode = chosen);
    widget.ttsController?.setQueueMode(chosen);
    unawaited(_persist(kTtsQueueModeKey, chosen.name));
  }

  Future<void> _pickFormatMode() async {
    final chosen = await showDialog<TtsFormatMode>(
      context: context,
      builder: (ctx) => _ChoiceDialog<TtsFormatMode>(
        title: 'Message format',
        value: _formatMode,
        options: const [
          (
            TtsFormatMode.messageOnly,
            'Message only',
            'Reads out just the message',
          ),
          (
            TtsFormatMode.userAndMessage,
            'User and message',
            'Reads out the user then the message',
          ),
        ],
      ),
    );
    if (chosen == null || chosen == _formatMode) return;
    setState(() => _formatMode = chosen);
    widget.ttsController?.setFormatMode(chosen);
    unawaited(_persist(kTtsFormatModeKey, chosen.name));
  }

  Future<void> _pickVoice() async {
    final c = widget.ttsController;
    if (c == null) return;
    final options = await c.fetchOptions();
    if (!mounted) return;
    if (options.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('No TTS engines available')));
      return;
    }
    final chosen = await showDialog<TtsOption>(
      context: context,
      builder: (ctx) => _ChoiceDialog<TtsOption>(
        title: 'TTS engine',
        value: _selectedOption,
        options: [for (final o in options) (o, o.label, o.id)],
      ),
    );
    if (chosen == null) return;
    await c.applyOption(chosen);
    if (mounted) setState(() => _selectedOption = chosen);
  }

  Future<void> _openEngineSettings() async {
    final c = widget.ttsController;
    if (c == null) return;
    // Android: engine selection lives in the system TTS screen (dankchat's
    // flow). iOS: single engine, so offer the in-app voice list instead.
    if (c.canOpenSystemSettings) {
      await c.openSystemTtsSettings();
    } else {
      await _pickVoice();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Text-to-speech')),
      body: ListView(
        children: [
          SwitchListTile(
            secondary: const Icon(Icons.record_voice_over),
            title: const Text('Enable TTS'),
            value: _enabled,
            onChanged: (value) => unawaited(_setEnabled(value)),
          ),
          ListTile(
            leading: const Icon(Icons.audio_file),
            title: const Text('TTS engine'),
            subtitle: Text(
              _selectedOption?.label ??
                  (widget.ttsController?.canOpenSystemSettings == true
                      ? 'Change in system settings'
                      : 'Device default'),
            ),
            trailing: const Icon(Icons.chevron_right),
            enabled: _enabled,
            onTap: _openEngineSettings,
          ),
          ListTile(
            leading: const Icon(Icons.queue),
            title: const Text('Message queue mode'),
            subtitle: Text(
              _queueMode == TtsQueueMode.queue ? 'Queue' : 'Newest',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: _pickQueueMode,
          ),
          ListTile(
            leading: const Icon(Icons.format_quote),
            title: const Text('Message format'),
            subtitle: Text(
              _formatMode == TtsFormatMode.messageOnly
                  ? 'Message only'
                  : 'User and message',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: _pickFormatMode,
          ),
          SwitchListTile(
            secondary: const Icon(Icons.language),
            title: const Text('Force language to English'),
            value: _forceEnglish,
            onChanged: _setForceEnglish,
          ),
          SwitchListTile(
            secondary: const Icon(Icons.link_off),
            title: const Text('Ignore URLs'),
            value: _ignoreUrls,
            onChanged: _setIgnoreUrls,
          ),
          SwitchListTile(
            secondary: const Icon(Icons.emoji_emotions),
            title: const Text('Ignore emotes'),
            value: _ignoreEmotes,
            onChanged: _setIgnoreEmotes,
          ),
          ListTile(
            leading: const Icon(Icons.person_off),
            title: const Text('User ignore list'),
            subtitle: const Text('Skip messages from specific users'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => TtsUserIgnoreListScreen(
                  ttsController: widget.ttsController,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ChoiceDialog<T> extends StatelessWidget {
  final String title;
  final T? value;
  final List<(T, String, String)> options;

  const _ChoiceDialog({
    required this.title,
    required this.value,
    required this.options,
  });

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(title),
      contentPadding: const EdgeInsets.symmetric(vertical: 8),
      content: SizedBox(
        width: 360,
        child: RadioGroup<T>(
          groupValue: value,
          onChanged: (v) {
            if (v != null) Navigator.pop(context, v);
          },
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final (val, label, sub) in options)
                RadioListTile<T>(
                  value: val,
                  title: Text(label),
                  subtitle: Text(sub),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
