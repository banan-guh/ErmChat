import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../l10n/l10n.dart';
import '../services/app_updates.dart';
import '../util/log.dart';
import '../util/prefs.dart';
import 'whats_new_sheet.dart';

/// "New update available!" from the last update check, until the user
/// installs it or dismisses that version. Tapping opens [showUpdateSheet].
class UpdateBanner extends StatefulWidget {
  const UpdateBanner({super.key});

  @override
  State<UpdateBanner> createState() => _UpdateBannerState();
}

class _UpdateBannerState extends State<UpdateBanner> {
  String? _update;
  UpdateSource? _source;
  String _current = '';
  AppUpdates? _updates;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final info = await PackageInfo.fromPlatform();
      final prefs = await Prefs.load();
      final available = prefs.availableUpdate;
      if (!mounted ||
          available == null ||
          available == prefs.dismissedUpdate ||
          compareVersions(available, info.version) <= 0) {
        return;
      }
      setState(() {
        _update = available;
        _current = info.version;
        _source = updateSourceFor(info.installerStore, ios: Platform.isIOS);
      });
    } catch (_) {
      logDebug('[UpdateBanner] failed to load package info');
    }
  }

  @override
  void dispose() {
    _updates?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final version = _update;
    if (version == null) return const SizedBox.shrink();
    return ListTile(
      leading: Icon(
        Icons.system_update,
        color: Theme.of(context).colorScheme.primary,
      ),
      title: Text(context.l10n.updateBanner),
      subtitle: Text(version),
      trailing: IconButton(
        icon: const Icon(Icons.close),
        tooltip: context.l10n.dismiss,
        onPressed: () async {
          setState(() => _update = null);
          await (await Prefs.load()).setDismissedUpdate(version);
        },
      ),
      onTap: () => showUpdateSheet(
        context,
        _updates ??= AppUpdates(),
        AvailableUpdate(version),
        _source,
        currentVersion: _current,
      ),
    );
  }
}
