import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

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
  bool _clearing = false;
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

  Future<void> _openDeleteLink(RecentUpload upload) async {
    final link = upload.deleteLink?.trim();
    if (link == null || link.isEmpty) return;
    final uri = Uri.tryParse(link);
    if (uri == null) return;
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok && mounted) {
      AppSnack.show(context, context.l10n.couldNotOpenUrl(link));
    }
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
    await _mediaUploader.clearRecents();
    if (!mounted) return;
    setState(() {
      _uploads = [];
      _clearing = false;
    });
    AppSnack.show(context, context.l10n.clearRecentUploadsDone);
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
            onPressed: _clearing ? null : _clearAll,
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
                final deleteLink = upload.deleteLink?.trim();
                final hasDeleteLink =
                    deleteLink != null && deleteLink.isNotEmpty;
                return ListTile(
                  dense: true,
                  leading: const Icon(Icons.link),
                  title: Text(
                    upload.imageLink,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        formatTimestamp(
                          upload.timestamp,
                          kDefaultTimestampFormat,
                        ),
                      ),
                      if (hasDeleteLink)
                        InkWell(
                          onTap: () => _openDeleteLink(upload),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 4),
                            child: Text(
                              context.l10n.recentUploadDeleteLink(deleteLink),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.primary,
                                decoration: TextDecoration.underline,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                  onTap: () => _copyLink(upload),
                  trailing: upload.imageLink.isEmpty
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.image_outlined),
                          tooltip: context.l10n.expandImage,
                          onPressed: () =>
                              showImageEmbedViewer(context, upload.imageLink),
                        ),
                );
              },
            ),
    );
  }
}
