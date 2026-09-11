import 'dart:async';

import 'package:flutter/material.dart';
import '../../services/tts_controller.dart';
import '../../util/prefs.dart';
import '../../widgets/app_snack.dart';
import '../../widgets/dialogs.dart';
import 'settings_page.dart';
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
  //bool _available = false;
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
        //_available = c.isAvailable;
        _selectedOption = c.selectedOption;
      });
    }
  }

  Future<void> _persist(Future<void> Function(Prefs) write) async {
    final prefs = await Prefs.load();
    await write(prefs);
  }

  Future<void> _setEnabled(bool value) async {
    if (value) {
      final c = widget.ttsController;
      if (c != null) {
        final ready = await c.checkAndPrepare();
        if (!ready) {
          if (mounted) {
            AppSnack.showError(
              context,
              'No TTS engine available. Install or enable one in your '
              'device\'s Text-to-speech settings, then enable again.',
            );
            setState(() => _enabled = false);
          }
          return;
        }
      }
    }
    setState(() => _enabled = value);
    widget.ttsController?.setEnabled(value);
    unawaited(_persist((p) => p.setTtsEnabled(value)));
  }

  void _setIgnoreUrls(bool value) {
    setState(() => _ignoreUrls = value);
    widget.ttsController?.setIgnoreUrls(value);
    unawaited(_persist((p) => p.setTtsIgnoreUrls(value)));
  }

  void _setIgnoreEmotes(bool value) {
    setState(() => _ignoreEmotes = value);
    widget.ttsController?.setIgnoreEmotes(value);
    unawaited(_persist((p) => p.setTtsIgnoreEmotes(value)));
  }

  void _setForceEnglish(bool value) {
    setState(() => _forceEnglish = value);
    widget.ttsController?.setForceEnglish(value);
    unawaited(_persist((p) => p.setTtsForceEnglish(value)));
  }

  Future<void> _pickQueueMode() async {
    final chosen = await showChoiceDialog<TtsQueueMode>(
      context,
      title: 'Message queue mode',
      value: _queueMode,
      options: const [
        (TtsQueueMode.queue, 'Queue', 'Plays every message using a queue'),
        (TtsQueueMode.newest, 'Newest', 'Plays only the newest message'),
      ],
    );
    if (chosen == null || chosen == _queueMode) return;
    setState(() => _queueMode = chosen);
    widget.ttsController?.setQueueMode(chosen);
    unawaited(_persist((p) => p.setTtsQueueMode(chosen.name)));
  }

  Future<void> _pickFormatMode() async {
    final chosen = await showChoiceDialog<TtsFormatMode>(
      context,
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
    );
    if (chosen == null || chosen == _formatMode) return;
    setState(() => _formatMode = chosen);
    widget.ttsController?.setFormatMode(chosen);
    unawaited(_persist((p) => p.setTtsFormatMode(chosen.name)));
  }

  Future<void> _pickVoice() async {
    final c = widget.ttsController;
    if (c == null) return;
    final options = await c.fetchOptions();
    if (!mounted) return;
    if (options.isEmpty) {
      AppSnack.showError(context, 'No TTS engines available');
      return;
    }
    final chosen = await showChoiceDialog<TtsOption>(
      context,
      title: 'TTS engine',
      value: _selectedOption,
      options: [for (final o in options) (o, o.label, o.id)],
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
    return SettingsPage(
      title: const Text('Text-to-speech'),
      body: ListView(
        children: [
          SwitchListTile(
            secondary: const Icon(Icons.record_voice_over),
            title: const Text('Enable TTS'),
            value: _enabled,
            onChanged: (value) => unawaited(_setEnabled(value)),
          ),
          SettingsNavTile(
            icon: Icons.audio_file,
            title: 'TTS engine',
            subtitle:
                _selectedOption?.label ??
                (widget.ttsController?.canOpenSystemSettings == true
                    ? 'Change in system settings'
                    : 'Device default'),
            enabled: _enabled,
            onTap: _openEngineSettings,
          ),
          SettingsNavTile(
            icon: Icons.queue,
            title: 'Message queue mode',
            subtitle: _queueMode == TtsQueueMode.queue ? 'Queue' : 'Newest',
            onTap: _pickQueueMode,
          ),
          SettingsNavTile(
            icon: Icons.format_quote,
            title: 'Message format',
            subtitle: _formatMode == TtsFormatMode.messageOnly
                ? 'Message only'
                : 'User and message',
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
          SettingsNavTile(
            icon: Icons.person_off,
            title: 'User ignore list',
            subtitle: 'Skip messages from specific users',
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
