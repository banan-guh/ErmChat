import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class PingsScreen extends StatefulWidget {
  const PingsScreen({super.key});

  @override
  State<PingsScreen> createState() => _PingsScreenState();
}

class _PingsScreenState extends State<PingsScreen> {
  List<String> _pings = [];

  @override
  void initState() {
    super.initState();
    _loadPings();
  }

  Future<void> _loadPings() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() => _pings = prefs.getStringList('alt_pings') ?? []);
    }
  }

  Future<void> _addPing() async {
    final controller = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Add ping'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Text to highlight'),
          onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('Add'),
          ),
        ],
      ),
    );

    if (result == null || result.isEmpty || _pings.contains(result)) return;

    final prefs = await SharedPreferences.getInstance();
    _pings.add(result);
    await prefs.setStringList('alt_pings', _pings);
    if (mounted) setState(() {});
  }

  Future<void> _removePing(int index) async {
    final prefs = await SharedPreferences.getInstance();
    _pings.removeAt(index);
    await prefs.setStringList('alt_pings', _pings);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Pings')),
      floatingActionButton: FloatingActionButton(
        onPressed: _addPing,
        child: const Icon(Icons.add),
      ),
      body: _pings.isEmpty
          ? const Center(child: Text('No pings yet. Tap + to add one.'))
          : ListView.builder(
              itemCount: _pings.length,
              itemBuilder: (_, i) => ListTile(
                title: Text(_pings[i]),
                trailing: IconButton(
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () => _removePing(i),
                ),
              ),
            ),
    );
  }
}
