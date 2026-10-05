import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../l10n/l10n.dart';
import '../../services/media_uploader.dart';
import '../../util/timestamp_formatter.dart';
import '../../widgets/app_snack.dart';
import '../../widgets/dialogs.dart';
import 'settings_page.dart';

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
    AppSnack.show(context, context.l10n.copiedValue(upload.imageLink));
  }

  Future<void> _delete(int index) async {
    await _mediaUploader.removeRecent(index);
    if (!mounted) return;
    setState(() => _uploads.removeAt(index));
  }

  Future<void> _clearAll() async {
    final confirmed = await confirmDialog(
      context,
      title: context.l10n.clearRecentUploadsTitle,
      message: context.l10n.clearRecentUploadsMessage,
      confirmLabel: context.l10n.clear,
    );
    if (!confirmed) return;
    await _mediaUploader.clearRecents();
    if (!mounted) return;
    setState(() => _uploads = []);
  }

  @override
  void dispose() {
    _mediaUploader.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SettingsPage(
      title: Text(context.l10n.recentUploadsTitle),
      actions: [
        if (_uploads.isNotEmpty)
          IconButton(
            icon: const Icon(Icons.delete_sweep),
            tooltip: context.l10n.clearAll,
            onPressed: _clearAll,
          ),
      ],
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _uploads.isEmpty
          ? Center(child: Text(context.l10n.noUploadsYet))
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
                    tooltip: context.l10n.remove,
                    onPressed: () => _delete(index),
                  ),
                );
              },
            ),
    );
  }
}
