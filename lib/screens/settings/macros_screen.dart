import 'package:flutter/material.dart';

import '../../services/command_macros.dart';
import '../../services/twitch_auth.dart';

/// Per-account command macros: trigger word + body, expanded on send.
class MacrosScreen extends StatefulWidget {
  final TwitchAuth twitchAuth;

  const MacrosScreen({super.key, required this.twitchAuth});

  @override
  State<MacrosScreen> createState() => _MacrosScreenState();
}

class _MacrosScreenState extends State<MacrosScreen> {
  List<CommandMacro> _macros = [];

  String? get _login => widget.twitchAuth.login?.toLowerCase();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final login = _login;
    if (login == null) return;
    final macros = await loadMacros(login);
    if (mounted) setState(() => _macros = macros);
  }

  Future<void> _persist() async {
    final login = _login;
    if (login == null) return;
    await saveMacros(login, _macros);
  }

  /// Add/edit dialog. Returns the edited macro list entry or null when
  /// cancelled/invalid.
  Future<void> _editMacro([CommandMacro? existing]) async {
    final nameController = TextEditingController(text: existing?.name);
    final bodyController = TextEditingController(text: existing?.body);

    Future<(String, String)?> showDialog2() => showDialog<(String, String)>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(existing == null ? 'Add macro' : 'Edit macro'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameController,
              autofocus: true,
              decoration: const InputDecoration(
                hintText: '!so',
                label: Text('Trigger'),
              ),
            ),
            TextField(
              controller: bodyController,
              decoration: InputDecoration(
                hintText: '/shoutout {1}',
                helperText: '{1}, {2} = args; {2+} = args 2 onward',
                label: const Text('Body'),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              final name = nameController.text.trim();
              final body = bodyController.text.trim();
              if (name.isEmpty || body.isEmpty || name.contains(_ws)) return;
              Navigator.pop(ctx, (name, body));
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );

    final result = await showDialog2();

    if (result == null || !mounted) return;
    final (name, body) = result;
    setState(() {
      _macros.removeWhere((m) => m.name.toLowerCase() == name.toLowerCase());
      _macros.add(CommandMacro(name: name, body: body));
    });
    await _persist();
  }

  static final _ws = RegExp(r'\s');

  Future<void> _removeMacro(int index) async {
    setState(() => _macros.removeAt(index));
    await _persist();
  }

  @override
  Widget build(BuildContext context) {
    final anonymous = _login == null;
    return Scaffold(
      appBar: AppBar(title: const Text('Command macros')),
      floatingActionButton: anonymous
          ? null
          : FloatingActionButton(
              onPressed: () => _editMacro(),
              child: const Icon(Icons.add),
            ),
      body: anonymous
          ? const Center(child: Text('Connect an account to use macros.'))
          : _macros.isEmpty
          ? const Center(
              child: Text(
                'No macros yet. Tap + to add one.\n\n'
                'Example:\n!so -> /shoutout {1}\n'
                'Typing "!so forsen" sends the shoutout.',
                textAlign: TextAlign.center,
              ),
            )
          : ListView.builder(
              itemCount: _macros.length,
              itemBuilder: (_, i) => ListTile(
                title: Text(_macros[i].name),
                subtitle: Text(_macros[i].body),
                onTap: () => _editMacro(_macros[i]),
                trailing: IconButton(
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () => _removeMacro(i),
                ),
              ),
            ),
    );
  }
}
