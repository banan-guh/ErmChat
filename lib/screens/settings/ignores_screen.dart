import 'package:flutter/material.dart';

import '../../services/ignore_manager.dart';

class IgnoresScreen extends StatefulWidget {
  const IgnoresScreen({super.key});

  @override
  State<IgnoresScreen> createState() => _IgnoresScreenState();
}

class _IgnoresScreenState extends State<IgnoresScreen> {
  IgnoreManager get _manager => IgnoreManager.instance;

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Ignores'),
          bottom: const TabBar(
            tabs: [
              Tab(text: 'Users'),
              Tab(text: 'Keywords'),
            ],
          ),
        ),
        floatingActionButton: FloatingActionButton(
          onPressed: () => _edit(
            IgnoreEntry(id: '', pattern: ''),
            keyword: _currentTabIsKeywords,
            isNew: true,
          ),
          child: const Icon(Icons.add),
        ),
        body: ListenableBuilder(
          listenable: _manager,
          builder: (context, _) {
            if (!_manager.loaded) {
              return const Center(child: CircularProgressIndicator());
            }
            return TabBarView(
              children: [
                _list(_manager.users, keywords: false),
                _list(_manager.keywords, keywords: true),
              ],
            );
          },
        ),
      ),
    );
  }

  bool get _currentTabIsKeywords {
    final controller = DefaultTabController.maybeOf(context);
    return controller?.index == 1;
  }

  Widget _list(List<IgnoreEntry> entries, {required bool keywords}) {
    if (entries.isEmpty) {
      return Center(
        child: Text(
          keywords
              ? 'Keyword rules rewrite matched text instead of deleting the '
                    'message. Tap + to add one.'
              : "Ignored users' messages are deleted outright, whispers "
                    'included. Tap + to add one.',
          textAlign: TextAlign.center,
        ),
      );
    }
    return ListView(
      children: [
        for (final entry in entries)
          ListTile(
            title: Text(entry.pattern.isEmpty ? '(no pattern)' : entry.pattern),
            subtitle: Text(
              [
                if (entry.isRegex) 'regex',
                if (entry.caseSensitive) 'case sensitive',
                if (keywords && (entry.replacement ?? '').isNotEmpty)
                  'replaced with "${entry.replacement}"',
              ].join(', '),
              style: const TextStyle(fontSize: 12),
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  icon: const Icon(Icons.edit_outlined),
                  tooltip: 'Edit',
                  onPressed: () =>
                      _edit(entry, keyword: keywords, isNew: false),
                ),
                IconButton(
                  icon: const Icon(Icons.delete_outline),
                  tooltip: 'Delete',
                  onPressed: () {
                    if (keywords) {
                      _manager.removeKeyword(entry.id);
                    } else {
                      _manager.removeUser(entry.id);
                    }
                    _manager.save();
                  },
                ),
              ],
            ),
            onTap: () => _edit(entry, keyword: keywords, isNew: false),
          ),
      ],
    );
  }

  Future<void> _edit(
    IgnoreEntry entry, {
    required bool keyword,
    required bool isNew,
  }) async {
    final result = await showDialog<_IgnoreEditResult>(
      context: context,
      builder: (ctx) => _IgnoreEditDialog(
        entry: entry,
        keyword: keyword,
        isNew: isNew,
      ),
    );
    if (result == null) return;

    final updated = IgnoreEntry(
      id: isNew ? DateTime.now().microsecondsSinceEpoch.toString() : entry.id,
      pattern: result.pattern,
      isRegex: result.isRegex,
      caseSensitive: result.caseSensitive,
      replacement: result.replacement,
    );
    if (keyword) {
      _manager.upsertKeyword(updated);
    } else {
      _manager.upsertUser(updated);
    }
    _manager.save();
  }
}

class _IgnoreEditResult {
  const _IgnoreEditResult({
    required this.pattern,
    required this.isRegex,
    required this.caseSensitive,
    this.replacement,
  });

  final String pattern;
  final bool isRegex;
  final bool caseSensitive;
  final String? replacement;
}

/// Owns its TextEditingControllers and disposes them in [dispose], which only
/// runs after the dialog route has fully exited; disposing right after
/// showDialog resolves would race the exit transition rebuilding the fields.
class _IgnoreEditDialog extends StatefulWidget {
  const _IgnoreEditDialog({
    required this.entry,
    required this.keyword,
    required this.isNew,
  });

  final IgnoreEntry entry;
  final bool keyword;
  final bool isNew;

  @override
  State<_IgnoreEditDialog> createState() => _IgnoreEditDialogState();
}

class _IgnoreEditDialogState extends State<_IgnoreEditDialog> {
  late final _patternCtrl = TextEditingController(text: widget.entry.pattern);
  late final _replacementCtrl = TextEditingController(
    text: widget.entry.replacement ?? '***',
  );
  late bool _isRegex = widget.entry.isRegex;
  late bool _caseSensitive = widget.entry.caseSensitive;

  @override
  void dispose() {
    _patternCtrl.dispose();
    _replacementCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.isNew ? 'Add ignore' : 'Edit ignore'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _patternCtrl,
            autofocus: widget.isNew,
            decoration: InputDecoration(
              labelText:
                  widget.keyword ? 'Keyword or regex' : 'Username or regex',
            ),
          ),
          SwitchListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: const Text('Regular expression'),
            value: _isRegex,
            onChanged: (v) => setState(() => _isRegex = v),
          ),
          SwitchListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: const Text('Case sensitive'),
            value: _caseSensitive,
            onChanged: (v) => setState(() => _caseSensitive = v),
          ),
          if (widget.keyword)
            TextField(
              controller: _replacementCtrl,
              decoration: const InputDecoration(
                labelText: 'Replace with',
                helperText: 'What matched text becomes (default ***)',
              ),
            ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () {
            final pattern = _patternCtrl.text.trim();
            if (pattern.isEmpty) return;
            Navigator.pop(
              context,
              _IgnoreEditResult(
                pattern: pattern,
                isRegex: _isRegex,
                caseSensitive: _caseSensitive,
                replacement: widget.keyword
                    ? _replacementCtrl.text.trim()
                    : null,
              ),
            );
          },
          child: Text(widget.isNew ? 'Add' : 'Save'),
        ),
      ],
    );
  }
}
