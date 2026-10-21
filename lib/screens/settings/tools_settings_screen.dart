import 'dart:convert' show utf8;
import 'dart:io' show Platform;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import '../../l10n/l10n.dart';
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
    final prefs = await Prefs.load();
    final info = await PackageInfo.fromPlatform();
    final source = updateSourceFor(info.installerStore, ios: Platform.isIOS);
    if (!context.mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, setState) => SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CheckboxListTile(
                title: Text(sheetContext.l10n.whatsNewToggle),
                value: prefs.whatsNewEnabled,
                onChanged: (v) async {
                  await prefs.setWhatsNewEnabled(v ?? true);
                  if (sheetContext.mounted) setState(() {});
                },
              ),
              CheckboxListTile(
                title: Text(sheetContext.l10n.settingCheckForUpdates),
                value: prefs.updateCheckEnabled,
                onChanged: (v) async {
                  await prefs.setUpdateCheckEnabled(v ?? true);
                  if (sheetContext.mounted) setState(() {});
                },
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
  /// carries the few thousand characters where a paste gets cut or refused.
  Future<void> _showBackupOptions(BuildContext context) async {
    final l = context.l10n;
    Widget option(IconData icon, String title, Future<void> Function() run) =>
        Builder(
          builder: (sheetContext) => ListTile(
            leading: Icon(icon),
            title: Text(title),
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
            ),
            option(Icons.file_open, l.importFile, () => _importFile(context)),
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
    final path = await FilePicker.saveFile(
      fileName: 'ermchat-settings.txt',
      bytes: bytes,
    );
    if (path == null || !context.mounted) return;
    AppSnack.show(context, context.l10n.exportSettingsSaved);
  }

  Future<void> _importClipboard(BuildContext context) async {
    final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text ?? '';
    if (context.mounted) await _import(context, text);
  }

  Future<void> _importFile(BuildContext context) async {
    // Any type: a shared .txt often arrives renamed or with another MIME.
    final picked = await FilePicker.pickFiles(withData: true);
    final bytes = picked?.files.singleOrNull?.bytes;
    if (bytes == null || !context.mounted) return;
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
