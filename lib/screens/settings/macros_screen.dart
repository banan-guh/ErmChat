import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../services/command_macros.dart';
import '../../services/twitch_auth.dart';
import 'settings_page.dart';

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
    final result = await showDialog<(String, String)>(
      context: context,
      builder: (ctx) => _MacroEditDialog(existing: existing),
    );

    if (result == null || !mounted) return;
    final (name, body) = result;
    setState(() {
      _macros.removeWhere((m) => m.name.toLowerCase() == name.toLowerCase());
      _macros.add(CommandMacro(name: name, body: body));
    });
    await _persist();
  }

  Future<void> _removeMacro(int index) async {
    setState(() => _macros.removeAt(index));
    await _persist();
  }

  @override
  Widget build(BuildContext context) {
    final anonymous = _login == null;
    return SettingsPage(
      title: Text(context.l10n.commandMacros),
      floatingActionButton: anonymous
          ? null
          : FloatingActionButton(
              onPressed: () => _editMacro(),
              child: const Icon(Icons.add),
            ),
      body: anonymous
          ? Center(child: Text(context.l10n.macrosNeedAccount))
          : _macros.isEmpty
          ? Center(
              child: Text(
                context.l10n.macrosEmpty('!so -> /shoutout {1}', '!so forsen'),
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

final _ws = RegExp(r'\s');

/// Owns its TextEditingControllers and disposes them in [dispose], which only
/// runs after the dialog route has fully exited; disposing right after
/// showDialog resolves would race the exit transition rebuilding the fields.
class _MacroEditDialog extends StatefulWidget {
  const _MacroEditDialog({required this.existing});

  final CommandMacro? existing;

  @override
  State<_MacroEditDialog> createState() => _MacroEditDialogState();
}

class _MacroEditDialogState extends State<_MacroEditDialog> {
  late final _nameCtrl = TextEditingController(text: widget.existing?.name);
  late final _bodyCtrl = TextEditingController(text: widget.existing?.body);

  @override
  void dispose() {
    _nameCtrl.dispose();
    _bodyCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(
        widget.existing == null
            ? context.l10n.addMacro
            : context.l10n.editMacro,
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _nameCtrl,
            autofocus: true,
            decoration: InputDecoration(
              hintText: '!so',
              label: Text(context.l10n.macroTrigger),
            ),
          ),
          TextField(
            controller: _bodyCtrl,
            decoration: InputDecoration(
              hintText: '/shoutout {1}',
              helperText: context.l10n.macroArgsHelp('{1}', '{2}', '{2+}'),
              label: Text(context.l10n.macroBody),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(context.l10n.cancel),
        ),
        TextButton(
          onPressed: () {
            final name = _nameCtrl.text.trim();
            final body = _bodyCtrl.text.trim();
            if (name.isEmpty || body.isEmpty || name.contains(_ws)) return;
            Navigator.pop(context, (name, body));
          },
          child: Text(context.l10n.save),
        ),
      ],
    );
  }
}
