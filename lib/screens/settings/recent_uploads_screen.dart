import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../l10n/l10n.dart';
import '../../services/media_uploader.dart';
import '../../util/timestamp_formatter.dart';
import '../../widgets/app_snack.dart';
import '../../widgets/dialogs.dart';
import '../../widgets/image_embed_viewer.dart';
import 'settings_page.dart';

class RecentUploadsScreen extends StatefulWidget {
  const RecentUploadsScreen({super.key});

  @override
  State<RecentUploadsScreen> createState() => _RecentUploadsScreenState();
}

class _RecentUploadsScreenState extends State<RecentUploadsScreen> {
  final _mediaUploader = MediaUploader();
  List<RecentUpload> _uploads = [];
  final _deleting = <String>{};
  bool _clearing = false;
  bool _loading = true;

  static String _key(RecentUpload upload) =>
      '${upload.imageLink}|${upload.timestamp.toIso8601String()}';

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

  Future<void> _delete(RecentUpload upload) async {
    final confirmed = await confirmDialog(
      context,
      title: context.l10n.deleteUploadTitle,
      message: context.l10n.deleteUploadMessage,
      confirmLabel: context.l10n.delete,
      destructive: true,
    );
    if (!confirmed || !mounted) return;
    final key = _key(upload);
    setState(() => _deleting.add(key));
    final deleted = await _mediaUploader.deleteUpload(upload);
    if (!mounted) return;
    if (!deleted) {
      setState(() => _deleting.remove(key));
      AppSnack.show(context, context.l10n.deleteUploadFailed);
      return;
    }
    // The host dropped the image, so the row and its key can go too.
    await _mediaUploader.removeRecent(upload);
    if (!mounted) return;
    setState(() {
      _deleting.remove(key);
      _uploads.removeWhere((u) => _key(u) == key);
    });
  }

  Future<void> _clearAll() async {
    final confirmed = await confirmDialog(
      context,
      title: context.l10n.clearRecentUploadsTitle,
      message: context.l10n.clearRecentUploadsMessage,
      confirmLabel: context.l10n.clear,
      destructive: true,
    );
    if (!confirmed || !mounted) return;
    setState(() => _clearing = true);
    final deleted = <RecentUpload>[];
    final kept = <RecentUpload>[];
    for (final upload in List.of(_uploads)) {
      final ok = await _mediaUploader.deleteUpload(upload);
      if (!mounted) return;
      (ok ? deleted : kept).add(upload);
    }
    if (deleted.isNotEmpty) await _mediaUploader.removeRecents(deleted);
    if (!mounted) return;
    setState(() {
      _uploads = kept;
      _clearing = false;
    });
    AppSnack.show(
      context,
      kept.isEmpty
          ? context.l10n.clearRecentUploadsDone
          : context.l10n.clearRecentUploadsKept(kept.length),
    );
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
        if (_clearing)
          const Padding(
            padding: EdgeInsets.all(14),
            child: SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          )
        else if (_uploads.isNotEmpty)
          IconButton(
            icon: const Icon(Icons.delete_sweep),
            tooltip: context.l10n.clearAll,
            onPressed: _deleting.isEmpty ? _clearAll : null,
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
                final key = _key(upload);
                final deleting = _deleting.contains(key);
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
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (upload.imageLink.isNotEmpty)
                        IconButton(
                          icon: const Icon(Icons.image_outlined),
                          tooltip: context.l10n.expandImage,
                          onPressed: _clearing || deleting
                              ? null
                              : () => showImageEmbedViewer(
                                  context,
                                  upload.imageLink,
                                ),
                        ),
                      IconButton(
                        icon: deleting
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.delete_outline),
                        tooltip: context.l10n.delete,
                        onPressed: _clearing || deleting
                            ? null
                            : () => _delete(upload),
                      ),
                    ],
                  ),
                );
              },
            ),
    );
  }
}
