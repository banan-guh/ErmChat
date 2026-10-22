import 'dart:convert' show utf8;
import 'dart:io' show File, Platform;

import 'package:flutter/material.dart';
import 'package:flutter_file_dialog/flutter_file_dialog.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../l10n/l10n.dart';
import '../../util/constants.dart' show httpTimeout;
import '../../services/analytics_service.dart';
import '../../services/app_updates.dart';
import '../../services/emote_images.dart';
import '../../services/tts_controller.dart';
import '../../util/prefs.dart';
import '../../util/prefs_store.dart';
import 'analytics_screen.dart';
import 'prefs_tiles.dart';
import 'report_bug_screen.dart';
import 'settings_page.dart';
import 'settings_search.dart';
import 'tts_settings_screen.dart';
import 'uploader_settings_screen.dart';
import '../../widgets/app_snack.dart';
import '../../widgets/dialogs.dart';
import '../../widgets/whats_new_sheet.dart';
import '../../util/settings.dart';

/// Features too small for a top-level entry: TTS, uploads, analytics,
/// feedback, and the stream player toggles.
class ToolsSettingsScreen extends StatelessWidget {
  final AnalyticsService? analyticsService;
  final List<String>? channels;
  final TtsController? ttsController;
  final EmoteImages? images;
  final ValueChanged<bool>? onPipEnabledChanged;

  /// Whether Send feedback shows. It needs a signed-in account.
  final bool showFeedback;

  const ToolsSettingsScreen({
    super.key,
    this.analyticsService,
    this.channels,
    this.ttsController,
    this.images,
    this.onPipEnabledChanged,
    this.showFeedback = false,
  });

  /// Both update toggles in one sheet; each saves as it flips.
  Future<void> _showUpdateOptions(BuildContext context) async {
    final info = await PackageInfo.fromPlatform();
    final source = updateSourceFor(info.installerStore, ios: Platform.isIOS);
    if (!context.mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      builder: (sheetContext) => SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ValueListenableBuilder<bool>(
              valueListenable: Settings.whatsNewEnabled,
              builder: (context, value, _) => CheckboxListTile(
                title: Text(context.l10n.whatsNewToggle),
                value: value,
                onChanged: (v) => Settings.whatsNewEnabled.set(v ?? true),
              ),
            ),
            ValueListenableBuilder<bool>(
              valueListenable: Settings.updateCheckEnabled,
              builder: (context, value, _) => CheckboxListTile(
                title: Text(context.l10n.settingCheckForUpdates),
                value: value,
                onChanged: (v) => Settings.updateCheckEnabled.set(v ?? true),
              ),
            ),
            if (source != null)
              ListTile(
                leading: const Icon(Icons.refresh),
                title: Text(sheetContext.l10n.checkUpdatesNow),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _checkNow(context, info.version, source);
                },
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _checkNow(
    BuildContext context,
    String current,
    UpdateSource source,
  ) async {
    final l = context.l10n;
    final updates = AppUpdates();
    final latest = await updates.checkNow(current, source);
    if (!context.mounted) return;
    if (latest == null) {
      AppSnack.show(context, l.updateCheckFailed);
    } else if (compareVersions(latest, current) <= 0) {
      AppSnack.show(context, l.updateUpToDate);
    } else {
      AppSnack.show(
        context,
        l.updateAvailableSnack(latest),
        actionLabel: l.whatsNewAction,
        onAction: () => showUpdateSheet(
          context,
          updates,
          AvailableUpdate(latest),
          source,
          currentVersion: current,
        ),
      );
    }
  }

  /// Settings out and in, through the clipboard or a .txt file. A file
  /// carries the few thousand characters where a paste gets cut or refused,
  /// and so does a Pastebin link, which the clipboard import fetches.
  Future<void> _showBackupOptions(BuildContext context) async {
    final l = context.l10n;
    Widget option(
      IconData icon,
      String title,
      Future<void> Function() run, {
      String? subtitle,
    }) => Builder(
      builder: (sheetContext) => ListTile(
        leading: Icon(icon),
        title: Text(title),
        subtitle: subtitle == null ? null : Text(subtitle),
        onTap: () {
          Navigator.pop(sheetContext);
          run();
        },
      ),
    );
    await showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      builder: (_) => SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            option(
              Icons.copy,
              l.exportClipboard,
              () => _exportClipboard(context),
            ),
            option(Icons.save_alt, l.exportFile, () => _exportFile(context)),
            option(
              Icons.content_paste,
              l.importClipboard,
              () => _importClipboard(context),
              subtitle: l.importClipboardHint,
            ),
            option(Icons.file_open, l.importFile, () => _importFile(context)),
            _PastebinHint(onOpen: () => _openPastebin(context)),
          ],
        ),
      ),
    );
  }

  Future<String> _exportText() async {
    final prefs = await Prefs.load();
    final info = await PackageInfo.fromPlatform();
    return prefs.exportSettings(info.version);
  }

  Future<void> _exportClipboard(BuildContext context) async {
    await Clipboard.setData(ClipboardData(text: await _exportText()));
    if (!context.mounted) return;
    AppSnack.show(context, context.l10n.exportSettingsDone);
  }

  Future<void> _exportFile(BuildContext context) async {
    final bytes = utf8.encode(await _exportText());
    final path = await FlutterFileDialog.saveFile(
      params: SaveFileDialogParams(
        data: bytes,
        fileName: 'ermchat-settings.txt',
      ),
    );
    if (path == null || !context.mounted) return;
    AppSnack.show(context, context.l10n.exportSettingsSaved);
  }

  Future<void> _openPastebin(BuildContext context) async {
    final ok = await launchUrl(_pastebin, mode: LaunchMode.externalApplication);
    if (!ok && context.mounted) {
      AppSnack.show(context, context.l10n.couldNotOpenUrl('$_pastebin'));
    }
  }

  static final _pastebin = Uri.parse('https://pastebin.com');

  /// A pastebin.com link to a paste, as the address of its raw text.
  static final _pasteLink = RegExp(
    r'^https?://(?:www\.)?pastebin\.com/(?:raw/)?([A-Za-z0-9]+)/?$',
  );

  Future<void> _importClipboard(BuildContext context) async {
    var text = (await Clipboard.getData(Clipboard.kTextPlain))?.text ?? '';
    final paste = _pasteLink.firstMatch(text.trim())?.group(1);
    if (paste != null) {
      final raw = Uri.https('pastebin.com', '/raw/$paste');
      http.Response? res;
      try {
        res = await http.get(raw).timeout(httpTimeout);
      } catch (_) {}
      if (res == null || res.statusCode != 200) {
        if (context.mounted) {
          AppSnack.show(context, context.l10n.importLinkFailed);
        }
        return;
      }
      text = utf8.decode(res.bodyBytes, allowMalformed: true);
    }
    if (context.mounted) await _import(context, text);
  }

  Future<void> _importFile(BuildContext context) async {
    // Any type: a shared .txt often arrives renamed or with another MIME.
    final path = await FlutterFileDialog.pickFile();
    if (path == null) return;
    final bytes = await File(path).readAsBytes();
    if (!context.mounted) return;
    await _import(context, utf8.decode(bytes, allowMalformed: true));
  }

  Future<void> _import(BuildContext context, String text) async {
    final l = context.l10n;
    final prefs = await Prefs.load();
    final changes = prefs.settingsToImport(text);
    if (changes == null || changes.isEmpty) {
      if (context.mounted) {
        AppSnack.show(
          context,
          changes == null ? l.importSettingsInvalid : l.importSettingsNothing,
        );
      }
      return;
    }
    if (!context.mounted) return;
    final ok = await confirmDialog(
      context,
      title: l.importSettingsTitle,
      message: l.importSettingsMessage(changes.length),
      confirmLabel: l.importSettingsConfirm,
    );
    if (!ok) return;
    await prefs.applySettings(changes);
    PrefsStore.instance.notifyChanged();
  }

  @override
  Widget build(BuildContext context) {
    return SettingsPage(
      title: Text(context.l10n.pageTools),
      body: ListView(
        children: [
          SettingAnchor(
            Setting.tts,
            child: SettingsNavTile(
              icon: Icons.record_voice_over,
              title: Setting.tts.titleOf(context.l10n),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) =>
                      TtsSettingsScreen(ttsController: ttsController),
                ),
              ),
            ),
          ),
          SettingAnchor(
            Setting.uploader,
            child: SettingsNavTile(
              icon: Icons.upload,
              title: Setting.uploader.titleOf(context.l10n),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => const UploaderSettingsScreen(),
                ),
              ),
            ),
          ),
          if (analyticsService != null && channels != null && images != null)
            SettingAnchor(
              Setting.analytics,
              child: SettingsNavTile(
                icon: Icons.insights,
                title: Setting.analytics.titleOf(context.l10n),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => AnalyticsScreen(
                      analyticsService: analyticsService!,
                      channels: channels!,
                      images: images!,
                    ),
                  ),
                ),
              ),
            ),
          // Reports carry the signed-in Twitch identity, so the entry only
          // shows for a real account.
          if (showFeedback)
            SettingsNavTile(
              icon: Icons.bug_report,
              title: context.l10n.sendFeedback,
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const ReportBugScreen()),
              ),
            ),
          SettingAnchor(
            Setting.updates,
            child: SettingsNavTile(
              icon: Icons.system_update,
              title: Setting.updates.titleOf(context.l10n),
              onTap: () => _showUpdateOptions(context),
            ),
          ),
          SettingAnchor(
            Setting.settingsBackup,
            child: SettingsNavTile(
              icon: Icons.import_export,
              title: Setting.settingsBackup.titleOf(context.l10n),
              onTap: () => _showBackupOptions(context),
            ),
          ),
          if (Platform.isAndroid) ...[
            SettingsSectionHeader(context.l10n.sectionLivestreams),
            SettingAnchor(
              Setting.pip,
              child: PrefsSwitchTile(
                secondary: const Icon(Icons.picture_in_picture),
                title: Setting.pip.titleOf(context.l10n),
                pref: Settings.streamPipEnabled,
                onChanged: onPipEnabledChanged,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// "Too long to send?" with pastebin.com as a plain link in the sentence.
class _PastebinHint extends StatelessWidget {
  const _PastebinHint({required this.onOpen});

  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    const site = 'pastebin.com';
    // The sentence is translated whole; the site name marks where the link
    // goes.
    final parts = context.l10n.exportPastebinHint(site).split(site);
    final style = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      child: Text.rich(
        TextSpan(
          style: style,
          children: [
            TextSpan(text: parts.first),
            WidgetSpan(
              alignment: PlaceholderAlignment.baseline,
              baseline: TextBaseline.alphabetic,
              child: GestureDetector(
                onTap: onOpen,
                child: Text(
                  site,
                  style: style?.copyWith(
                    color: theme.colorScheme.primary,
                    decoration: TextDecoration.underline,
                    decorationColor: theme.colorScheme.primary,
                  ),
                ),
              ),
            ),
            TextSpan(text: parts.skip(1).join(site)),
          ],
        ),
      ),
    );
  }
}
