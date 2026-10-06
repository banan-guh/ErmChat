import 'dart:async';
import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import '../../l10n/l10n.dart';
import '../../util/log.dart';
import '../../util/prefs.dart';
import '../../services/app_updates.dart';
import '../../services/fake_chat_feed.dart';
import '../../widgets/whats_new_sheet.dart';
import 'dev_settings_screen.dart';
import 'settings_page.dart';

class AboutScreen extends StatefulWidget {
  final ValueChanged<bool>? onTestWidgetsChanged;
  final FakeChatFeed? fakeChat;
  final int Function()? fakeFillCount;

  const AboutScreen({
    super.key,
    this.onTestWidgetsChanged,
    this.fakeChat,
    this.fakeFillCount,
  });

  @override
  State<AboutScreen> createState() => _AboutScreenState();
}

class _AboutScreenState extends State<AboutScreen> {
  String _version = 'Loading...';
  int _tapCount = 0;

  /// Newer version the store serves, from the last update check.
  String? _update;
  UpdateSource? _source;
  String _current = '';
  AppUpdates? _updates;

  @override
  void initState() {
    super.initState();
    _loadVersion();
  }

  Future<void> _loadVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      final available = (await Prefs.load()).availableUpdate;
      if (mounted) {
        setState(() {
          _version = '${info.version}+${info.buildNumber}';
          _current = info.version;
          _source = updateSourceFor(info.installerStore, ios: Platform.isIOS);
          if (available != null &&
              compareVersions(available, info.version) > 0) {
            _update = available;
          }
        });
      }
    } catch (_) {
      logDebug('[AboutScreen] failed to load package info');
      if (mounted) setState(() => _version = 'unknown');
    }
  }

  @override
  void dispose() {
    _updates?.dispose();
    super.dispose();
  }

  void _handleTap() {
    _tapCount++;
    if (_tapCount >= 7) {
      _tapCount = 0;
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => DevSettingsScreen(
            onTestWidgetsChanged: widget.onTestWidgetsChanged,
            fakeChat: widget.fakeChat,
            fakeFillCount: widget.fakeFillCount,
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return SettingsPage(
      title: Text(context.l10n.pageAbout),
      body: Column(
        children: [
          Expanded(
            child: InkWell(
              onTap: _handleTap,
              child: SizedBox.expand(
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'ErmChat',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        context.l10n.versionValue(_version),
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          if (_update case final version?)
            ListTile(
              leading: Icon(
                Icons.system_update,
                color: Theme.of(context).colorScheme.primary,
              ),
              title: Text(context.l10n.updateBanner),
              subtitle: Text(version),
              onTap: () => showUpdateSheet(
                context,
                _updates ??= AppUpdates(),
                AvailableUpdate(version),
                _source,
                currentVersion: _current,
              ),
            ),
          ListTile(
            leading: const Icon(Icons.description_outlined),
            title: Text(context.l10n.openSourceLicenses),
            onTap: () => showLicensePage(
              context: context,
              applicationName: 'ErmChat',
              applicationVersion:
                  _version == 'Loading...' || _version == 'unknown'
                  ? null
                  : _version,
            ),
          ),
        ],
      ),
    );
  }
}
