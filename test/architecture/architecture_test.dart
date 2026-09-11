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
