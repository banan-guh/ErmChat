import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import '../../l10n/l10n.dart';
import '../../services/analytics_service.dart';
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
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _export(BuildContext context) async {
    final prefs = await Prefs.load();
    final info = await PackageInfo.fromPlatform();
    await Clipboard.setData(
      ClipboardData(text: prefs.exportSettings(info.version)),
    );
    if (!context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(context.l10n.exportSettingsDone)));
  }

  Future<void> _import(BuildContext context) async {
    final l = context.l10n;
    final messenger = ScaffoldMessenger.of(context);
    final prefs = await Prefs.load();
    final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text ?? '';
    final changes = prefs.settingsToImport(text);
    if (changes == null || changes.isEmpty) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            changes == null ? l.importSettingsInvalid : l.importSettingsNothing,
          ),
        ),
      );
      return;
    }
    if (!context.mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l.importSettingsTitle),
        content: Text(l.importSettingsMessage(changes.length)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(l.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(l.importSettingsConfirm),
          ),
        ],
      ),
    );
    if (ok != true) return;
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
            Setting.exportSettings,
            child: SettingsNavTile(
              icon: Icons.file_upload_outlined,
              title: Setting.exportSettings.titleOf(context.l10n),
              onTap: () => _export(context),
            ),
          ),
          SettingAnchor(
            Setting.importSettings,
            child: SettingsNavTile(
              icon: Icons.file_download_outlined,
              title: Setting.importSettings.titleOf(context.l10n),
              onTap: () => _import(context),
            ),
          ),
          if (Platform.isAndroid) ...[
            SettingsSectionHeader(context.l10n.sectionLivestreams),
            SettingAnchor(
              Setting.pip,
              child: PrefsSwitchTile(
                secondary: const Icon(Icons.picture_in_picture),
                title: Setting.pip.titleOf(context.l10n),
                defaultValue: false,
                read: (p) => p.streamPipEnabled,
                write: (p, v) => p.setStreamPipEnabled(v),
                onChanged: onPipEnabledChanged,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
