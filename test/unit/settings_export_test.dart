import 'dart:convert';

import 'package:ermchat/util/prefs.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('export round trips, omits excluded keys, skips bad values', () async {
    SharedPreferences.setMockInitialValues({
      'themeMode': 'dark',
      'chat_font_size': 18.0,
      'max_messages_per_channel': 500,
      'tts_user_ignore_list': ['a', 'b'],
      'welcome_seen': true,
      'channels': ['x'],
      'uploader_config': 'secret',
      'macros_bob': ['hi'],
      'dev_arm_update': true,
    });
    final json = (await Prefs.load()).exportSettings('1.2.3');
    final doc = jsonDecode(json) as Map;
    final settings = doc['settings'] as Map;
    expect(doc['app'], '1.2.3');
    expect(
      settings.keys,
      unorderedEquals([
        'themeMode',
        'chat_font_size',
        'max_messages_per_channel',
        'tts_user_ignore_list',
      ]),
      reason: 'only allowlisted keys that are set are exported',
    );

    SharedPreferences.setMockInitialValues({'welcome_seen': true});
    final fresh = await Prefs.load();
    final changes = fresh.settingsToImport(json)!;
    expect(changes.length, 4);
    await fresh.applySettings(changes);
    expect(fresh.themeMode.name, 'dark');
    expect(fresh.chatFontSize, 18.0);
    expect(fresh.maxMessagesPerChannel, 500);
    expect(fresh.ttsUserIgnoreList, ['a', 'b']);
    expect(fresh.settingsToImport(json), isEmpty);

    final bad = jsonEncode({
      'format': 1,
      'settings': {
        'themeMode': 5,
        'max_messages_per_channel': 'many',
        'tts_user_ignore_list': [1],
        'channels': ['evil'],
        // The proxy gets the OAuth token: a file must not redirect it.
        'proxy_enabled': true,
        'proxy_url': 'wss://evil.example',
        'recent_messages_custom_url': 'https://evil.example',
        'unknown_key': true,
        'chat_font_size': 20,
      },
    });
    expect(fresh.settingsToImport(bad), {'chat_font_size': 20.0});
    expect(fresh.settingsToImport('not json'), isNull);
    expect(fresh.settingsToImport('[1]'), isNull);
  });
}
