import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Enforces the mechanical import-direction subset of docs/ARCHITECTURE_RULES.md.
///
/// The test scans `.dart` sources under `lib/` and asserts that each layer only
/// imports downward. Every assertion names the rule it checks, and a failure
/// lists each offending importer, import string, and resolved target.
void main() {
  final directives = _scanLib();

  test('transport and decode leaves import nothing upward', () {
    const importers = [
      'irc/transport/',
      'irc/decode/',
      'eventsub/transport/',
      'eventsub/decode/',
    ];
    const forbidden = [
      'services/',
      'chat/',
      'channels/',
      'widgets/',
      'screens/',
      'panels/',
      'composer/',
      'chrome/',
      'sheets/',
    ];
    _expectClean(
      rule: 'transport and decode leaves import nothing upward',
      violations: directives.where(
        (d) => _isUnder(d.importer, importers) && _isUnder(d.target, forbidden),
      ),
    );
  });

  test('the kernel imports nothing upward', () {
    const forbidden = [
      'services/',
      'channels/',
      'widgets/',
      'screens/',
      'panels/',
      'composer/',
      'chrome/',
      'sheets/',
      'irc/transport/',
      'eventsub/transport/',
    ];
    _expectClean(
      rule: 'the kernel imports nothing upward',
      violations: directives.where(
        (d) =>
            _isUnder(d.importer, const ['chat/']) &&
            (_isUnder(d.target, forbidden) ||
                d.raw.startsWith('package:flutter_riverpod')),
      ),
    );
  });

  test('the pipeline does not depend on UI', () {
    const forbidden = [
      'widgets/',
      'screens/',
      'panels/',
      'composer/',
      'chrome/',
      'sheets/',
    ];
    _expectClean(
      rule: 'the pipeline does not depend on UI',
      violations: directives.where(
        (d) =>
            _isUnder(d.importer, const ['services/']) &&
            _isUnder(d.target, forbidden),
      ),
    );
  });

  test('UI does not import transports', () {
    const importers = [
      'widgets/',
      'screens/',
      'panels/',
      'composer/',
      'chrome/',
      'sheets/',
    ];
    const transports = ['irc/transport/', 'eventsub/transport/'];
    _expectClean(
      rule: 'UI does not import transports',
      violations: directives.where(
        (d) =>
            _isUnder(d.importer, importers) && _isUnder(d.target, transports),
      ),
    );
  });

  test('the pipeline layer does not import providers', () {
    _expectClean(
      rule: 'the pipeline layer does not import providers',
      violations: directives.where(
        (d) =>
            _isUnder(d.importer, const ['services/']) &&
            _isUnder(d.target, const ['providers/']),
      ),
    );
  });

  test('the UI does not construct app objects', () {
    final lines = _scanUiConstructions()
        .map(
          (v) =>
              '  the UI does not construct app objects: lib/${v.importer}:'
              '${v.line} constructs ${v.type}',
        )
        .toList();
    if (lines.isNotEmpty) {
      fail(
        'the UI does not construct app objects failed:\n${lines.join('\n')}',
      );
    }
  });
}

final _directiveRe = RegExp(r'''^\s*(?:import|export)\s+['"]([^'"]+)['"]''');

class _Directive {
  _Directive(this.importer, this.line, this.raw, this.target);

  final String importer;
  final int line;
  final String raw;
  final String target;
}

List<_Directive> _scanLib() {
  final libDir = Directory('lib');
  final result = <_Directive>[];
  for (final entity in libDir.listSync(recursive: true)) {
    if (entity is! File || !entity.path.endsWith('.dart')) {
      continue;
    }
    final importer = _libRelative(entity.path);
    final lines = entity.readAsLinesSync();
    for (var i = 0; i < lines.length; i++) {
      final match = _directiveRe.firstMatch(lines[i]);
      if (match == null) {
        continue;
      }
      final raw = match.group(1)!;
      final target = _resolve(importer, raw);
      if (target == null) {
        continue;
      }
      result.add(_Directive(importer, i + 1, raw, target));
    }
  }
  return result;
}

/// Strips the leading `lib/` (and any platform separators) from [path].
String _libRelative(String path) {
  final normalized = path.replaceAll(r'\', '/');
  final marker = 'lib/';
  final index = normalized.indexOf(marker);
  return index == -1 ? normalized : normalized.substring(index + marker.length);
}

/// Maps a directive to a normalized lib-relative target, or null for imports
/// the rules ignore such as `dart:` and non-ermchat `package:` imports.
String? _resolve(String importer, String raw) {
  if (raw.startsWith('dart:')) {
    return null;
  }
  if (raw.startsWith('package:')) {
    const prefix = 'package:ermchat/';
    if (!raw.startsWith(prefix)) {
      return null;
    }
    return _normalize(raw.substring(prefix.length).split('/'));
  }
  final base = importer.split('/')..removeLast();
  return _normalize([...base, ...raw.split('/')]);
}

/// Collapses `.` and `..` segments into a clean lib-relative path.
String _normalize(List<String> segments) {
  final out = <String>[];
  for (final segment in segments) {
    if (segment.isEmpty || segment == '.') {
      continue;
    }
    if (segment == '..') {
      if (out.isNotEmpty) {
        out.removeLast();
      }
      continue;
    }
    out.add(segment);
  }
  return out.join('/');
}

/// True when [path] is inside any of the lib-relative directory [prefixes].
bool _isUnder(String path, List<String> prefixes) =>
    prefixes.any((prefix) => path.startsWith(prefix));

void _expectClean({
  required String rule,
  required Iterable<_Directive> violations,
}) {
  final lines = violations
      .map(
        (v) =>
            "  $rule: lib/${v.importer}:${v.line} imports "
            "'${v.raw}' -> '${v.target}'",
      )
      .toList();
  if (lines.isNotEmpty) {
    fail('$rule failed:\n${lines.join('\n')}');
  }
}

/// Provider-owned types the UI must obtain through a provider, never `new`.
const _providerOwnedTypes = <String>[
  'ChatConnectionManager',
  'Chat',
  'Session',
  'EmoteManager',
  'TwitchAuth',
  'AnalyticsService',
  'NotificationService',
  'TtsController',
  'ModActions',
  'ChatNoticeController',
  'ConnectivityService',
  'EventSubService',
  'IrcService',
  'IrcReadService',
  'SevenTvEventClient',
  'TwitchApi',
  'TwitchBadgeService',
  'UserStore',
  'JoinRateLimiter',
  'RecentMessagesService',
  'PipService',
  'BroadcastWidgets',
  'CommandHandler',
];

/// Constructor declarations and test seams that are not UI constructions,
/// keyed `lib-relative path:type`. Keep this list narrow; fix the source first.
const _constructionAllowlist = <String>{
  // BroadcastWidgets declares its own constructor in this file.
  'widgets/broadcast_widgets.dart:BroadcastWidgets',
  // Test seam: AccountScreen accepts an optional TwitchApi and falls back to
  // constructing one when the caller does not supply it.
  'screens/settings/account_screen.dart:TwitchApi',
};

class _Construction {
  _Construction(this.importer, this.line, this.type);

  final String importer;
  final int line;
  final String type;
}

/// Scans screens and widgets for constructor calls of provider-owned types.
List<_Construction> _scanUiConstructions() {
  const dirs = ['screens/', 'widgets/'];
  final result = <_Construction>[];
  for (final entity in Directory('lib').listSync(recursive: true)) {
    if (entity is! File || !entity.path.endsWith('.dart')) {
      continue;
    }
    final importer = _libRelative(entity.path);
    if (!_isUnder(importer, dirs)) {
      continue;
    }
    final lines = _stripCommentsAndStrings(
      entity.readAsStringSync(),
    ).split('\n');
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      for (final type in _providerOwnedTypes) {
        final re = RegExp('(?<![\\w\$])${RegExp.escape(type)}\\s*\\(');
        if (!re.hasMatch(line)) {
          continue;
        }
        if (_constructionAllowlist.contains('$importer:$type')) {
          continue;
        }
        result.add(_Construction(importer, i + 1, type));
      }
    }
  }
  return result;
}

/// Replaces comment and string-literal contents with spaces, preserving
/// newlines and offsets, so a source-line scan only sees code.
String _stripCommentsAndStrings(String source) {
  final out = StringBuffer();
  var i = 0;
  final n = source.length;
  while (i < n) {
    final c = source[i];
    if (c == '/' && i + 1 < n && source[i + 1] == '/') {
      while (i < n && source[i] != '\n') {
        out.write(' ');
        i++;
      }
      continue;
    }
    if (c == '/' && i + 1 < n && source[i + 1] == '*') {
      out.write('  ');
      i += 2;
      while (i < n &&
          !(source[i] == '*' && i + 1 < n && source[i + 1] == '/')) {
        out.write(source[i] == '\n' ? '\n' : ' ');
        i++;
      }
      if (i < n) {
        out.write('  ');
        i += 2;
      }
      continue;
    }
    if (c == "'" || c == '"') {
      final triple = i + 2 < n && source[i + 1] == c && source[i + 2] == c;
      if (triple) {
        out.write('   ');
        i += 3;
        while (i < n) {
          if (source[i] == c &&
              i + 2 < n &&
              source[i + 1] == c &&
              source[i + 2] == c) {
            out.write('   ');
            i += 3;
            break;
          }
          out.write(source[i] == '\n' ? '\n' : ' ');
          i++;
        }
      } else {
        out.write(' ');
        i++;
        while (i < n && source[i] != c) {
          if (source[i] == '\\') {
            out.write('  ');
            i += 2;
            continue;
          }
          out.write(source[i] == '\n' ? '\n' : ' ');
          i++;
        }
        if (i < n) {
          out.write(' ');
          i++;
        }
      }
      continue;
    }
    out.write(c);
    i++;
  }
  return out.toString();
}
