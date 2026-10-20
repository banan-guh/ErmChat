import 'package:ermchat/util/prefs.dart';
import 'package:ermchat/util/prefs_store.dart';
import 'package:ermchat/util/settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('each setting notifies only for its own changes', () async {
    SharedPreferences.setMockInitialValues({'haptics': true});
    final prefs = await Prefs.load();
    var haptics = 0;
    var fontSize = 0;
    void onHaptics() => haptics++;
    void onFontSize() => fontSize++;
    Settings.haptics.addListener(onHaptics);
    Settings.chatFontSize.addListener(onFontSize);
    addTearDown(() {
      Settings.haptics.removeListener(onHaptics);
      Settings.chatFontSize.removeListener(onFontSize);
    });

    await Settings.haptics.set(false);
    await prefs.setHaptics(false);
    expect((haptics, fontSize), (1, 0), reason: 'a same-value write is quiet');

    // An import writes the raw store; the bulk signal finds what changed.
    await prefs.applySettings({'chat_font_size': 20.0});
    PrefsStore.instance.notifyChanged();
    expect((haptics, fontSize), (1, 1), reason: 'bulk refresh skips haptics');
    expect(Settings.chatFontSize.value, 20.0);

    PrefsStore.instance.notifyChanged();
    expect((haptics, fontSize), (1, 1), reason: 'nothing changed since');
  });
}
