import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// A locally-defined chat macro: a trigger word plus a body that replaces it
/// on send. The body may reference positional args with {1}, {2} ... and
/// {2+} ("arg 2 and everything after").
class CommandMacro {
  final String name;
  final String body;

  const CommandMacro({required this.name, required this.body});

  Map<String, dynamic> toJson() => {'name': name, 'body': body};

  factory CommandMacro.fromJson(Map<String, dynamic> json) =>
      CommandMacro(name: json['name'] as String, body: json['body'] as String);
}

final _whitespaceRe = RegExp(r'\s+');
final _placeholderRe = RegExp(r'\{(\d+\+?)\}');

String _prefsKey(String login) => 'macros_${login.toLowerCase()}';

// Per-account in-memory mirror of what is on disk. Populated by [loadMacros]
// and kept fresh by [saveMacros], so send-path reads never need to await I/O.
final _cache = <String, List<CommandMacro>>{};

/// Loads this account's macros from SharedPreferences (cached after first
/// load).
Future<List<CommandMacro>> loadMacros(String login) async {
  final key = login.toLowerCase();
  final cached = _cache[key];
  if (cached != null) return List.of(cached);
  final prefs = await SharedPreferences.getInstance();
  final raw = prefs.getStringList(_prefsKey(login)) ?? const [];
  final macros = raw
      .map((entry) {
        try {
          return CommandMacro.fromJson(
            jsonDecode(entry) as Map<String, dynamic>,
          );
        } catch (_) {
          return null;
        }
      })
      .whereType<CommandMacro>()
      .toList();
  _cache[key] = macros;
  return List.of(macros);
}

/// Persists this account's macros and refreshes the in-memory mirror.
Future<void> saveMacros(String login, List<CommandMacro> macros) async {
  final key = login.toLowerCase();
  final prefs = await SharedPreferences.getInstance();
  await prefs.setStringList(_prefsKey(login), [
    for (final m in macros) jsonEncode(m.toJson()),
  ]);
  _cache[key] = List.of(macros);
}

/// Synchronous lookup for the send path; null when nothing has been loaded
/// for this account yet (no macros configured).
Map<String, String>? cachedMacroLookup(String login) {
  final cached = _cache[login.toLowerCase()];
  if (cached == null || cached.isEmpty) return null;
  return macroLookup(cached);
}

/// Trigger -> body lookup, names matched case-insensitively.
Map<String, String> macroLookup(List<CommandMacro> macros) => {
  for (final m in macros) m.name.toLowerCase(): m.body,
};

/// Expands a macro trigger at the start of [text]. Returns null when no
/// trigger matches, so callers can fall through to the normal send path.
///
/// The first whitespace-separated token is matched against the lookup
/// case-insensitively; everything after it becomes positional args for the
/// body's placeholders. {n} substitutes arg n ({0} and unknown specs stay
/// literal); {n+} joins args n onward. Missing args expand to the empty
/// string. Single pass: expanded output is never re-expanded.
String? expandMacro(String text, Map<String, String> macros) {
  if (text.isEmpty || macros.isEmpty) return null;
  final trimmed = text.trim();
  if (trimmed.isEmpty) return null;

  final parts = trimmed.split(_whitespaceRe);
  final body = macros[parts.first.toLowerCase()];
  if (body == null) return null;
  final args = parts.sublist(1);

  return body.replaceAllMapped(_placeholderRe, (m) {
    final spec = m.group(1)!;
    final isTail = spec.endsWith('+');
    final n = int.tryParse(isTail ? spec.substring(0, spec.length - 1) : spec);
    if (n == null || n < 1) return m.group(0)!;
    if (isTail) {
      return args.length >= n ? args.sublist(n - 1).join(' ') : '';
    }
    return n <= args.length ? args[n - 1] : '';
  });
}
