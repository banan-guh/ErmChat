import 'dart:convert';

import 'package:ermchat/services/app_updates.dart';
import 'package:ermchat/util/prefs.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('versions compare numerically, ignoring v and build', () {
    for (final (a, b, want) in [
      ('0.9.10', '0.9.9', 1),
      ('v0.9.7', '0.9.7', 0),
      ('0.9.7+412', '0.9.7+413', 0),
      ('1.0', '0.9.9', 1),
      ('0.9.7', '0.9.7.1', -1),
    ]) {
      expect(compareVersions(a, b), want, reason: '$a vs $b');
    }
  });

  test('each installer checks its own store', () {
    for (final (installer, ios, want) in [
      ('com.android.vending', false, UpdateSource.play),
      ('org.fdroid.fdroid', false, UpdateSource.fdroid),
      ('com.looker.droidify', false, UpdateSource.fdroid),
      ('dev.imranr.obtainium', false, UpdateSource.github),
      (null, false, UpdateSource.github),
      ('com.apple.testflight', true, UpdateSource.testflight),
      ('com.apple', true, null),
    ]) {
      expect(updateSourceFor(installer, ios: ios), want, reason: '$installer');
    }
  });

  test(
    "What's new: quiet on first launch, once per upgrade, never down",
    () async {
      final updates = AppUpdates(
        client: MockClient((_) async => http.Response('', 404)),
      );
      expect(
        await updates.takeWhatsNew('0.9.7'),
        isNull,
        reason: 'first launch',
      );
      expect(
        await updates.takeWhatsNew('0.9.7'),
        isNull,
        reason: 'same version',
      );
      expect(await updates.takeWhatsNew('0.9.9'), '0.9.7', reason: 'upgrade');
      expect(await updates.takeWhatsNew('0.9.9'), isNull, reason: 'shown once');
      expect(await updates.takeWhatsNew('0.9.8'), isNull, reason: 'downgrade');
      expect(await updates.takeWhatsNew('0.9.9'), '0.9.8');

      final prefs = await Prefs.load();
      await prefs.setWhatsNewEnabled(false);
      expect(await updates.takeWhatsNew('1.0.0'), isNull, reason: 'toggle off');
      await prefs.setWhatsNewEnabled(true);
      expect(
        await updates.takeWhatsNew('1.0.0'),
        isNull,
        reason: 'turning it back on does not replay a skipped version',
      );

      await prefs.setArmWhatsNew(true);
      expect(await updates.takeWhatsNew('1.0.0'), '1.0.0', reason: 'armed');
      expect(prefs.armWhatsNew, isFalse, reason: 'the arm fires once');
    },
  );

  test('missed notes: released versions in between, newest first', () async {
    final updates = AppUpdates(
      client: MockClient((req) async {
        if (req.url.host == 'api.github.com') {
          return http.Response(
            jsonEncode([
              {'tag_name': 'v0.9.10'},
              {'tag_name': 'v0.9.9'},
              {'tag_name': 'v0.9.8', 'prerelease': true},
              {'tag_name': 'v0.9.7'},
              {'tag_name': 'v0.9.6', 'draft': true},
              {'tag_name': 'v0.9.5'},
              {'tag_name': 'v0.9.4'},
            ]),
            200,
          );
        }
        // v0.9.5 predates CHANGELOG.md.
        if (req.url.path.contains('v0.9.5')) return http.Response('', 404);
        final tag = req.url.pathSegments[2];
        return http.Response('- notes for $tag\n', 200);
      }),
    );
    final notes = await updates.missedNotes('0.9.4', '0.9.10');
    expect(
      [for (final n in notes) '${n.version}: ${n.items.single}'],
      ['0.9.9: notes for v0.9.9', '0.9.7: notes for v0.9.7'],
    );
  });

  group('update check', () {
    var now = DateTime(2026, 10, 6, 12);
    var latest = '0.9.8';
    var fail = false;
    late AppUpdates updates;

    setUp(() {
      now = DateTime(2026, 10, 6, 12);
      latest = '0.9.8';
      fail = false;
      updates = AppUpdates(
        now: () => now,
        client: MockClient((req) async {
          if (fail) throw http.ClientException('offline');
          return http.Response(jsonEncode({'tag_name': 'v$latest'}), 200);
        }),
      );
    });

    Future<String?> check() async =>
        (await updates.checkForUpdate('0.9.7', UpdateSource.github))?.version;
    void nextDay() => now = now.add(const Duration(hours: 25));

    test('once a day, once per version, banner tracks the store', () async {
      final prefs = await Prefs.load();
      expect(await check(), '0.9.8');
      expect(prefs.availableUpdate, '0.9.8');
      latest = '0.9.9';
      expect(await check(), isNull, reason: 'within 24h');
      nextDay();
      latest = '0.9.8';
      expect(await check(), isNull, reason: '0.9.8 was already announced');
      nextDay();
      latest = '0.9.9';
      expect(await check(), '0.9.9');
      nextDay();
      fail = true;
      expect(await check(), isNull, reason: 'offline');
      expect(prefs.availableUpdate, '0.9.9', reason: 'a failure keeps it');
      fail = false;
      expect(await check(), isNull, reason: 'a failure still waits a day');
      nextDay();
      latest = '0.9.7';
      expect(await check(), isNull);
      expect(prefs.availableUpdate, isNull, reason: 'store caught up');

      nextDay();
      latest = '0.9.9';
      await prefs.setUpdateCheckEnabled(false);
      expect(await check(), isNull, reason: 'toggle off');
      expect(
        await updates.checkForUpdate('0.9.7', null),
        isNull,
        reason: 'no source',
      );
    });

    test('the dev arm fakes the next patch, offline, once', () async {
      final prefs = await Prefs.load();
      await prefs.setArmUpdate(true);
      await prefs.setDismissedUpdate('0.9.8');
      fail = true;
      final fake = await updates.checkForUpdate('0.9.7', null);
      expect(fake?.version, '0.9.8');
      expect(fake?.armed, isTrue);
      expect(prefs.armUpdate, isFalse);
      expect(prefs.availableUpdate, '0.9.8', reason: 'banner shows it too');
      expect(prefs.dismissedUpdate, isNull, reason: 'even after an X');
    });
  });

  test('each store answers in its own shape', () async {
    for (final (source, body, want) in [
      (UpdateSource.github, {'tag_name': 'v0.9.8'}, '0.9.8'),
      (
        UpdateSource.fdroid,
        {
          'suggestedVersionCode': 4113,
          'packages': [
            {'versionName': '0.9.7', 'versionCode': 4123},
            {'versionName': '0.9.6', 'versionCode': 4113},
          ],
        },
        null,
      ),
      (UpdateSource.play, {'play': '0.9.8', 'github': '0.9.9'}, '0.9.8'),
      (UpdateSource.testflight, {'play': '0.9.9'}, null),
    ]) {
      SharedPreferences.setMockInitialValues({});
      final updates = AppUpdates(
        client: MockClient((_) async => http.Response(jsonEncode(body), 200)),
      );
      expect(
        (await updates.checkForUpdate('0.9.6', source))?.version,
        want,
        reason: '$source',
      );
    }
  });
}
