import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../services/media_uploader.dart';
import '../../util/timestamp_formatter.dart';

class RecentUploadsScreen extends StatefulWidget {
  const RecentUploadsScreen({super.key});

  @override
  State<RecentUploadsScreen> createState() => _RecentUploadsScreenState();
}

class _RecentUploadsScreenState extends State<RecentUploadsScreen> {
  final _mediaUploader = MediaUploader();
  List<RecentUpload> _uploads = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final uploads = await _mediaUploader.recentUploads();
    if (!mounted) return;
    setState(() {
      _uploads = uploads;
      _loading = false;
    });
  }

  Future<void> _copyLink(RecentUpload upload) async {
    Clipboard.setData(ClipboardData(text: upload.imageLink)).ignore();
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('Copied ${upload.imageLink}')));
  }

  Future<void> _delete(int index) async {
    await _mediaUploader.removeRecent(index);
    if (!mounted) return;
    setState(() => _uploads.removeAt(index));
  }

  Future<void> _clearAll() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Clear recent uploads'),
        content: const Text('This only clears the local history of uploads.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _mediaUploader.clearRecents();
    if (!mounted) return;
    setState(() => _uploads = []);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Recent uploads'),
        actions: [
          if (_uploads.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.delete_sweep),
              tooltip: 'Clear all',
              onPressed: _clearAll,
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _uploads.isEmpty
          ? const Center(child: Text('No uploads yet'))
          : ListView.builder(
              itemCount: _uploads.length,
              itemBuilder: (context, index) {
                final upload = _uploads[index];
                return ListTile(
                  dense: true,
                  leading: const Icon(Icons.link),
                  title: Text(
                    upload.imageLink,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    formatTimestamp(upload.timestamp, kDefaultTimestampFormat),
                  ),
                  onTap: () => _copyLink(upload),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete_outline),
                    tooltip: 'Remove',
                    onPressed: () => _delete(index),
                  ),
                );
              },
            ),
    );
  }
}
