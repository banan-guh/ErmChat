import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:http/http.dart' as http;

import '../util/constants.dart' show httpTimeout;
import '../util/log.dart';
import '../util/prefs.dart';

/// Where an install gets its updates, read from its installer.
enum UpdateSource { github, fdroid, play, testflight }

/// The source to check for [installer] (`PackageInfo.installerStore`); null
/// means no check. GitHub APKs, Obtainium and sideloads report other or no
/// installers, so Android falls back to GitHub. iOS outside TestFlight has
/// nothing to check yet.
UpdateSource? updateSourceFor(String? installer, {required bool ios}) {
  if (ios) {
    return installer == 'com.apple.testflight' ? UpdateSource.testflight : null;
  }
  return switch (installer) {
    'com.android.vending' => UpdateSource.play,
    'org.fdroid.fdroid' ||
    'org.fdroid.basic' ||
    'com.looker.droidify' ||
    'com.machiav3lli.fdroid' => UpdateSource.fdroid,
    _ => UpdateSource.github,
  };
}

/// Compares dotted versions like `0.9.7`; a `v` prefix and `+build` suffix
/// are ignored, so build-only bumps never count as updates.
int compareVersions(String a, String b) {
  List<int> parts(String v) => [
    for (final p in v.replaceFirst('v', '').split('+').first.split('.'))
      int.tryParse(p) ?? 0,
  ];
  final x = parts(a), y = parts(b);
  for (var i = 0; i < x.length || i < y.length; i++) {
    final d = (i < x.length ? x[i] : 0) - (i < y.length ? y[i] : 0);
    if (d != 0) return d.sign;
  }
  return 0;
}

/// The `- ` bullets of a CHANGELOG.md.
List<String> parseChangelog(String text) => [
  for (final line in text.split('\n'))
    if (line.trimLeft().startsWith('- ')) line.trimLeft().substring(2).trim(),
];

/// One version's changelog bullets.
class VersionNotes {
  const VersionNotes(this.version, this.items);

  final String version;
  final List<String> items;
}

/// A newer version found by [AppUpdates.checkForUpdate]. [armed] marks the
/// dev fake, which has no tag to read notes from.
class AvailableUpdate {
  const AvailableUpdate(this.version, {this.armed = false});

  final String version;
  final bool armed;
}

/// What's new after an update and the once-a-day store version check. State
/// lives in [Prefs]; the clock and HTTP client are injectable for tests.
class AppUpdates {
  AppUpdates({http.Client? client, DateTime Function()? now})
    : _client = client ?? http.Client(),
      _now = now ?? clock.now;

  final http.Client _client;
  final DateTime Function() _now;

  static const _repo = 'banan-guh/ermchat';
  static const _appId = 'io.github.bananguh.ErmChat';
  static const _testFlightAppId = '6805456131';

  /// ermchatbot (the bug report host) serves the newest live version per
  /// store, for Play and TestFlight, which have no public version API.
  static const _botLatest = 'https://erm-machine-1.tail834800.ts.net/latest';

  static const checkInterval = Duration(hours: 24);

  /// Records [current] as seen and returns the previous version when What's
  /// new should show, '' when the dev arm fired, or null to stay quiet. The
  /// first launch with no saved version shows nothing.
  Future<String?> takeWhatsNew(String current) async {
    final prefs = await Prefs.load();
    final last = prefs.lastSeenVersion;
    await prefs.setLastSeenVersion(current);
    if (prefs.armWhatsNew) {
      await prefs.setArmWhatsNew(false);
      return last ?? '';
    }
    if (last == null || compareVersions(current, last) <= 0) return null;
    return prefs.whatsNewEnabled ? last : null;
  }

  /// Notes for released versions after [from] and before [current], newest
  /// first, read from CHANGELOG.md at each tag. Tags without one are skipped;
  /// a failed fetch returns what it has.
  Future<List<VersionNotes>> missedNotes(String from, String current) async {
    final versions = <String>[];
    try {
      final res = await _client
          .get(
            Uri.parse(
              'https://api.github.com/repos/$_repo/releases?per_page=30',
            ),
          )
          .timeout(httpTimeout);
      if (res.statusCode != 200) return const [];
      for (final r in jsonDecode(res.body) as List<dynamic>) {
        if (r['draft'] == true || r['prerelease'] == true) continue;
        final v = (r['tag_name'] as String? ?? '').replaceFirst('v', '');
        if (compareVersions(v, from) > 0 && compareVersions(v, current) < 0) {
          versions.add(v);
        }
      }
    } catch (e) {
      logDebug('[Updates] release list failed: $e');
      return const [];
    }
    versions.sort((a, b) => compareVersions(b, a));
    final out = <VersionNotes>[];
    for (final v in versions) {
      final notes = await notesFor(v);
      if (notes != null) out.add(notes);
    }
    return out;
  }

  /// CHANGELOG.md bullets at [version]'s tag; null when missing or offline.
  Future<VersionNotes?> notesFor(String version) async {
    try {
      final res = await _client
          .get(
            Uri.parse(
              'https://raw.githubusercontent.com/$_repo/v$version/CHANGELOG.md',
            ),
          )
          .timeout(httpTimeout);
      if (res.statusCode != 200) return null;
      final items = parseChangelog(res.body);
      return items.isEmpty ? null : VersionNotes(version, items);
    } catch (e) {
      logDebug('[Updates] notes for $version failed: $e');
      return null;
    }
  }

  /// Asks [source] for its newest version at most once per [checkInterval].
  /// Returns a version newer than [current] the first time it is seen; a
  /// failed check waits for the next interval. The dev arm skips all of it.
  Future<AvailableUpdate?> checkForUpdate(
    String current,
    UpdateSource? source,
  ) async {
    final prefs = await Prefs.load();
    if (prefs.armUpdate) {
      await prefs.setArmUpdate(false);
      final fake = _nextPatch(current);
      await prefs.setAvailableUpdate(fake);
      return AvailableUpdate(fake, armed: true);
    }
    final available = prefs.availableUpdate;
    if (available != null && compareVersions(available, current) <= 0) {
      await prefs.setAvailableUpdate(null);
    }
    if (source == null || !prefs.updateCheckEnabled) return null;
    final now = _now();
    final last = prefs.lastUpdateCheck;
    if (last != null &&
        now.difference(DateTime.fromMillisecondsSinceEpoch(last)) <
            checkInterval) {
      return null;
    }
    await prefs.setLastUpdateCheck(now.millisecondsSinceEpoch);
    final latest = await _latest(source);
    if (latest == null) return null;
    if (compareVersions(latest, current) <= 0) {
      // Clears the banner, including a dev fake, once the store catches up.
      await prefs.setAvailableUpdate(null);
      return null;
    }
    await prefs.setAvailableUpdate(latest);
    if (prefs.notifiedUpdate == latest) return null;
    await prefs.setNotifiedUpdate(latest);
    return AvailableUpdate(latest);
  }

  Future<String?> _latest(UpdateSource source) async {
    try {
      final url = switch (source) {
        UpdateSource.github =>
          'https://api.github.com/repos/$_repo/releases/latest',
        UpdateSource.fdroid => 'https://f-droid.org/api/v1/packages/$_appId',
        UpdateSource.play || UpdateSource.testflight => _botLatest,
      };
      final res = await _client.get(Uri.parse(url)).timeout(httpTimeout);
      if (res.statusCode != 200) return null;
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      return switch (source) {
        UpdateSource.github => (data['tag_name'] as String?)?.replaceFirst(
          'v',
          '',
        ),
        UpdateSource.fdroid => _fdroidSuggested(data),
        UpdateSource.play ||
        UpdateSource.testflight => data[source.name] as String?,
      };
    } catch (e) {
      logDebug('[Updates] ${source.name} check failed: $e');
      return null;
    }
  }

  // F-Droid lists one entry per ABI build; the suggested code names the
  // version it serves.
  static String? _fdroidSuggested(Map<String, dynamic> data) {
    final code = data['suggestedVersionCode'];
    for (final p in data['packages'] as List<dynamic>? ?? const []) {
      if (p['versionCode'] == code) return p['versionName'] as String?;
    }
    return null;
  }

  static String _nextPatch(String version) {
    final parts = version.split('+').first.split('.');
    final last = int.tryParse(parts.last) ?? 0;
    return [...parts.take(parts.length - 1), '${last + 1}'].join('.');
  }

  /// Where [source] installs [version] from.
  static Uri storeLink(UpdateSource? source, String version) =>
      Uri.parse(switch (source) {
        UpdateSource.fdroid => 'https://f-droid.org/packages/$_appId/',
        UpdateSource.play =>
          'https://play.google.com/store/apps/details?id=$_appId',
        UpdateSource.testflight =>
          'itms-beta://beta.itunes.apple.com/v1/app/$_testFlightAppId',
        UpdateSource.github ||
        null => 'https://github.com/$_repo/releases/tag/v$version',
      });

  void dispose() => _client.close();
}
