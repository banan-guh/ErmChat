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
    var pattern = entry.pattern;
    var isRegex = entry.isRegex;
    var caseSensitive = entry.caseSensitive;
    final replacementCtrl = TextEditingController(
      text: entry.replacement ?? '***',
    );
    final controller = TextEditingController(text: pattern);

    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Text(isNew ? 'Add ignore' : 'Edit ignore'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: controller,
                autofocus: isNew,
                decoration: InputDecoration(
                  labelText: keyword ? 'Keyword or regex' : 'Username or regex',
                ),
                onChanged: (v) => pattern = v.trim(),
              ),
              SwitchListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: const Text('Regular expression'),
                value: isRegex,
                onChanged: (v) => setDialogState(() => isRegex = v),
              ),
              SwitchListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: const Text('Case sensitive'),
                value: caseSensitive,
                onChanged: (v) => setDialogState(() => caseSensitive = v),
              ),
              if (keyword)
                TextField(
                  controller: replacementCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Replace with',
                    helperText: 'What matched text becomes (default ***)',
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
                if (pattern.isEmpty) return;
                Navigator.pop(ctx, true);
              },
              child: Text(isNew ? 'Add' : 'Save'),
            ),
          ],
        ),
      ),
    );

    controller.dispose();
    replacementCtrl.dispose();
    if (saved != true) return;

    final updated = IgnoreEntry(
      id: isNew ? DateTime.now().microsecondsSinceEpoch.toString() : entry.id,
      pattern: pattern,
      isRegex: isRegex,
      caseSensitive: caseSensitive,
      replacement: keyword ? replacementCtrl.text.trim() : null,
    );
    if (keyword) {
      _manager.upsertKeyword(updated);
    } else {
      _manager.upsertUser(updated);
    }
    _manager.save();
  }
}
