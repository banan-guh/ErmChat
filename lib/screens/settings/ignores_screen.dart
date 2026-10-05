import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../services/ignore_manager.dart';
import 'settings_page.dart';

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
      child: SettingsPage(
        title: Text(context.l10n.ignoresTitle),
        bottom: TabBar(
          tabs: [
            Tab(text: context.l10n.tabUsers),
            Tab(text: context.l10n.tabKeywords),
          ],
        ),
        // The FAB needs the selected tab; look it up from a context INSIDE
        // the DefaultTabController. The state's own context sits above it,
        // where the scope is invisible (it would always read as Users).
        floatingActionButton: Builder(
          builder: (fabContext) => FloatingActionButton(
            onPressed: () => _edit(
              IgnoreEntry(id: '', pattern: ''),
              keyword: DefaultTabController.maybeOf(fabContext)?.index == 1,
              isNew: true,
            ),
            child: const Icon(Icons.add),
          ),
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

  Widget _list(List<IgnoreEntry> entries, {required bool keywords}) {
    if (entries.isEmpty) {
      return Center(
        child: Text(
          keywords
              ? context.l10n.ignoreKeywordsEmpty
              : context.l10n.ignoreUsersEmpty,
          textAlign: TextAlign.center,
        ),
      );
    }
    return ListView(
      children: [
        for (final entry in entries)
          ListTile(
            title: Text(
              entry.pattern.isEmpty ? context.l10n.noPattern : entry.pattern,
            ),
            subtitle: Text(
              [
                if (entry.isRegex) context.l10n.ignoreRegex,
                if (entry.caseSensitive) context.l10n.ignoreCaseSensitive,
                if (entry.wordBoundary) context.l10n.ignoreWholeWord,
                if (entry.block) context.l10n.ignoreBlocks,
                if (keywords && (entry.replacement ?? '').isNotEmpty)
                  context.l10n.ignoreReplacedWith(entry.replacement!),
              ].join(', '),
              style: const TextStyle(fontSize: 12),
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  icon: const Icon(Icons.edit_outlined),
                  tooltip: context.l10n.edit,
                  onPressed: () =>
                      _edit(entry, keyword: keywords, isNew: false),
                ),
                IconButton(
                  icon: const Icon(Icons.delete_outline),
                  tooltip: context.l10n.delete,
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
      builder: (ctx) =>
          _IgnoreEditDialog(entry: entry, keyword: keyword, isNew: isNew),
    );
    if (result == null) return;

    final updated = IgnoreEntry(
      id: isNew ? DateTime.now().microsecondsSinceEpoch.toString() : entry.id,
      pattern: result.pattern,
      isRegex: result.isRegex,
      caseSensitive: result.caseSensitive,
      wordBoundary: result.wordBoundary,
      block: result.block,
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
    required this.wordBoundary,
    required this.block,
    this.replacement,
  });

  final String pattern;
  final bool isRegex;
  final bool caseSensitive;
  final bool wordBoundary;
  final bool block;
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
  late bool _wholeWord = widget.entry.wordBoundary;
  late bool _block = widget.entry.block;

  @override
  void dispose() {
    _patternCtrl.dispose();
    _replacementCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(
        widget.isNew ? context.l10n.addIgnore : context.l10n.editIgnore,
      ),
      // Keyword rules stack six rows; on small screens (or with the keyboard
      // open) that exceeds the dialog bounds, so let the content scroll
      // instead of overflowing.
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _patternCtrl,
              autofocus: widget.isNew,
              decoration: InputDecoration(
                labelText: widget.keyword
                    ? context.l10n.keywordOrRegex
                    : context.l10n.usernameOrRegex,
              ),
            ),
            SwitchListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: Text(context.l10n.regularExpression),
              value: _isRegex,
              onChanged: (v) => setState(() => _isRegex = v),
            ),
            SwitchListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: Text(context.l10n.caseSensitive),
              value: _caseSensitive,
              onChanged: (v) => setState(() => _caseSensitive = v),
            ),
            if (widget.keyword)
              SwitchListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text(context.l10n.wholeWord),
                value: _wholeWord,
                onChanged: (v) => setState(() => _wholeWord = v),
              ),
            if (widget.keyword)
              SwitchListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text(context.l10n.blockMessage),
                subtitle: Text(context.l10n.blockMessageHint),
                value: _block,
                onChanged: (v) => setState(() => _block = v),
              ),
            if (widget.keyword && !_block)
              TextField(
                controller: _replacementCtrl,
                decoration: InputDecoration(
                  labelText: context.l10n.replaceWith,
                  helperText: context.l10n.replaceWithHint,
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(context.l10n.cancel),
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
                wordBoundary: widget.keyword && _wholeWord,
                block: widget.keyword && _block,
                // Block mode drops the message outright; no replacement.
                replacement: widget.keyword && !_block
                    ? _replacementCtrl.text.trim()
                    : null,
              ),
            );
          },
          child: Text(widget.isNew ? context.l10n.add : context.l10n.save),
        ),
      ],
    );
  }
}
