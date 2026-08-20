import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../services/tts_controller.dart';

class TtsUserIgnoreListScreen extends StatefulWidget {
  final TtsController? ttsController;

  const TtsUserIgnoreListScreen({super.key, this.ttsController});

  @override
  State<TtsUserIgnoreListScreen> createState() =>
      _TtsUserIgnoreListScreenState();
}

class _TtsUserIgnoreListScreenState extends State<TtsUserIgnoreListScreen> {
  final _controller = TextEditingController();
  late List<String> _users;

  @override
  void initState() {
    super.initState();
    _users = [...?widget.ttsController?.userIgnoreList];
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(kTtsUserIgnoreListKey, _users);
  }

  void _addUser(String raw) {
    final name = raw.trim();
    if (name.isEmpty) return;
    if (_users.any((u) => u.toLowerCase() == name.toLowerCase())) return;
    setState(() => _users.add(name));
    widget.ttsController?.setUserIgnoreList(_users);
    unawaited(_persist());
    _controller.clear();
  }

  void _removeUser(int index) {
    setState(() => _users.removeAt(index));
    widget.ttsController?.setUserIgnoreList(_users);
    unawaited(_persist());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('TTS user ignore list')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _controller,
                    decoration: const InputDecoration(
                      labelText: 'Add username',
                      hintText: 'e.g. forsen',
                    ),
                    onSubmitted: _addUser,
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  icon: const Icon(Icons.add),
                  tooltip: 'Add',
                  onPressed: () => _addUser(_controller.text),
                ),
              ],
            ),
          ),
          Expanded(
            child: _users.isEmpty
                ? const Center(child: Text('No ignored users'))
                : ListView.builder(
                    itemCount: _users.length,
                    itemBuilder: (context, index) {
                      final user = _users[index];
                      return Dismissible(
                        key: ValueKey(user),
                        direction: DismissDirection.endToStart,
                        background: Container(
                          color: Theme.of(context).colorScheme.error,
                          alignment: Alignment.centerRight,
                          padding: const EdgeInsets.only(right: 16),
                          child: const Icon(Icons.delete),
                        ),
                        onDismissed: (_) => _removeUser(index),
                        child: ListTile(
                          leading: const Icon(Icons.person_off),
                          title: Text(user),
                          trailing: IconButton(
                            icon: const Icon(Icons.delete),
                            tooltip: 'Remove',
                            onPressed: () => _removeUser(index),
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }
}
