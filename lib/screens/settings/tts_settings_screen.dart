import 'dart:async';

import 'package:flutter/material.dart';
import '../../l10n/l10n.dart';
import '../../services/tts_controller.dart';
import '../../util/prefs.dart';
import '../../widgets/app_snack.dart';
import '../../widgets/dialogs.dart';
import 'settings_page.dart';
import 'settings_search.dart';
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
            AppSnack.showError(context, context.l10n.ttsNoEngine);
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
      title: context.l10n.ttsQueueModeTitle,
      value: _queueMode,
      options: [
        (TtsQueueMode.queue, context.l10n.ttsQueue, context.l10n.ttsQueueHint),
        (
          TtsQueueMode.newest,
          context.l10n.ttsNewest,
          context.l10n.ttsNewestHint,
        ),
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
      title: context.l10n.ttsFormatTitle,
      value: _formatMode,
      options: [
        (
          TtsFormatMode.messageOnly,
          context.l10n.ttsMessageOnly,
          context.l10n.ttsMessageOnlyHint,
        ),
        (
          TtsFormatMode.userAndMessage,
          context.l10n.ttsUserAndMessage,
          context.l10n.ttsUserAndMessageHint,
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
      AppSnack.showError(context, context.l10n.ttsNoEngines);
      return;
    }
    final chosen = await showChoiceDialog<TtsOption>(
      context,
      title: context.l10n.ttsEngineTitle,
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
      title: Text(context.l10n.ttsTitle),
      body: ListView(
        children: [
          SettingAnchor(
            Setting.enableTts,
            child: SwitchListTile(
              secondary: const Icon(Icons.record_voice_over),
              title: Text(Setting.enableTts.titleOf(context.l10n)),
              value: _enabled,
              onChanged: (value) => unawaited(_setEnabled(value)),
            ),
          ),
          SettingAnchor(
            Setting.ttsEngine,
            child: SettingsNavTile(
              icon: Icons.audio_file,
              title: Setting.ttsEngine.titleOf(context.l10n),
              subtitle:
                  _selectedOption?.label ??
                  (widget.ttsController?.canOpenSystemSettings == true
                      ? context.l10n.ttsChangeInSystem
                      : context.l10n.ttsDeviceDefault),
              enabled: _enabled,
              onTap: _openEngineSettings,
            ),
          ),
          SettingAnchor(
            Setting.ttsQueueMode,
            child: SettingsNavTile(
              icon: Icons.queue,
              title: Setting.ttsQueueMode.titleOf(context.l10n),
              subtitle: _queueMode == TtsQueueMode.queue
                  ? context.l10n.ttsQueue
                  : context.l10n.ttsNewest,
              onTap: _pickQueueMode,
            ),
          ),
          SettingAnchor(
            Setting.ttsFormat,
            child: SettingsNavTile(
              icon: Icons.format_quote,
              title: Setting.ttsFormat.titleOf(context.l10n),
              subtitle: _formatMode == TtsFormatMode.messageOnly
                  ? context.l10n.ttsMessageOnly
                  : context.l10n.ttsUserAndMessage,
              onTap: _pickFormatMode,
            ),
          ),
          SettingAnchor(
            Setting.ttsForceEnglish,
            child: SwitchListTile(
              secondary: const Icon(Icons.language),
              title: Text(Setting.ttsForceEnglish.titleOf(context.l10n)),
              value: _forceEnglish,
              onChanged: _setForceEnglish,
            ),
          ),
          SettingAnchor(
            Setting.ttsIgnoreUrls,
            child: SwitchListTile(
              secondary: const Icon(Icons.link_off),
              title: Text(Setting.ttsIgnoreUrls.titleOf(context.l10n)),
              value: _ignoreUrls,
              onChanged: _setIgnoreUrls,
            ),
          ),
          SettingAnchor(
            Setting.ttsIgnoreEmotes,
            child: SwitchListTile(
              secondary: const Icon(Icons.emoji_emotions),
              title: Text(Setting.ttsIgnoreEmotes.titleOf(context.l10n)),
              value: _ignoreEmotes,
              onChanged: _setIgnoreEmotes,
            ),
          ),
          SettingAnchor(
            Setting.ttsIgnoredUsers,
            child: SettingsNavTile(
              icon: Icons.person_off,
              title: Setting.ttsIgnoredUsers.titleOf(context.l10n),
              subtitle: context.l10n.userCount(
                widget.ttsController?.userIgnoreList.length ?? 0,
              ),
              // The list screen edits the controller directly; recount on return.
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => TtsUserIgnoreListScreen(
                    ttsController: widget.ttsController,
                  ),
                ),
              ).then((_) => mounted ? setState(() {}) : null),
            ),
          ),
        ],
      ),
    );
  }
}
