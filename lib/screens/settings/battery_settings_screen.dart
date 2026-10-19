import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import 'chat_settings_screen.dart';
import 'customization_screen.dart';
import 'emotes_settings_screen.dart';
import 'settings_page.dart';

/// Every setting that changes how hard ermchat works the screen, the GPU
/// and the radio, gathered from their home pages.
class BatterySettingsScreen extends StatelessWidget {
  const BatterySettingsScreen({super.key, this.onBackgroundServiceChanged});

  final ValueChanged<bool>? onBackgroundServiceChanged;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return SettingsPage(
      title: Text(l.pageBattery),
      body: ListView(
        children: [
          SettingsPageIntro(l.batteryPageIntro),
          SettingsSectionHeader(l.sectionDisplay),
          const KeepScreenOnTile(),
          const TrueDarkTile(),
          const LiquidGlassTile(),
          const EmoteAnimationSection(),
          if (!kIsWeb && Platform.isAndroid) ...[
            SettingsSectionHeader(l.sectionConnection),
            StayConnectedTile(onChanged: onBackgroundServiceChanged),
          ],
          const SizedBox(height: 16),
        ],
      ),
    );
  }
}
