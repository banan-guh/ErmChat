import 'package:ermchat/util/prefs.dart';
import 'package:ermchat/util/settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('a legacy name copy bool maps to the matching gesture', () async {
    for (final (saved, expected) in [
      (true, NameCopyGesture.doubleTap),
      (false, NameCopyGesture.off),
    ]) {
      SharedPreferences.setMockInitialValues({'double_tap_name_copy': saved});
      await Prefs.load();
      expect(
        Settings.copyUsernameGesture.value,
        expected,
        reason: 'legacy $saved',
      );
    }
  });
}
