import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import '../services/media_uploader.dart';
import '../util/prefs.dart';
import '../util/friendly_error.dart';
import '../util/log.dart';
import 'app_snack.dart';
import 'dialogs.dart';
import '../l10n/l10n.dart';

/// Notice sink for upload results. Home wires the inline notice bar;
/// detached uses fall back to the overlay snackbar.
typedef NoticeCallback =
    void Function(
      String message, {
      String? actionLabel,
      VoidCallback? onAction,
    });

class MediaUploadController {
  MediaUploadController({MediaUploader? uploader, this.onNotice, this.onPaste})
    : _uploader = uploader ?? MediaUploader();

  final MediaUploader _uploader;
  final NoticeCallback? onNotice;

  /// Inserts the just-copied link into the composer at the cursor. Wired by
  /// the screen that owns the composer so the upload notice can offer Paste.
  final VoidCallback? onPaste;

  /// The share of the running upload sent, from 0 to 1, or null when none
  /// runs. The composer draws it as a bar along its top edge.
  final progress = ValueNotifier<double?>(null);

  bool get _isUploading => progress.value != null;

  /// Releases the uploader's HTTP client. The owning screen calls this in its
  /// own dispose.
  void dispose() {
    _uploader.close();
    progress.dispose();
  }

  Future<void> pickAndUpload(BuildContext context) async {
    if (_isUploading) return;
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: Text(ctx.l10n.gallery),
              onTap: () => Navigator.pop(ctx, ImageSource.gallery),
            ),
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: Text(ctx.l10n.camera),
              onTap: () => Navigator.pop(ctx, ImageSource.camera),
            ),
          ],
        ),
      ),
    );
    if (source == null || !context.mounted) return;

    final picker = ImagePicker();
    final XFile? picked;
    try {
      // The gallery offers videos too; the camera takes photos.
      picked = source == ImageSource.gallery
          ? await picker.pickMedia()
          : await picker.pickImage(source: source);
    } catch (e) {
      if (context.mounted) {
        _showSnack(context, context.l10n.mediaPickerFailed('$e'));
      }
      return;
    }
    if (picked == null || !context.mounted) return;
    final file = File(picked.path);
    if (await file.length() > MediaUploader.maxBytes) {
      if (context.mounted) {
        _showSnack(
          context,
          context.l10n.uploadTooLarge(MediaUploader.maxBytes ~/ (1024 * 1024)),
        );
      }
      return;
    }
    if (!context.mounted) return;
    if (MediaUploader.isVideo(file) && !await _videoNoted(context)) return;
    if (!context.mounted) return;
    await _upload(context, file);
  }

  /// Asks once, on the first video, whether to upload it with its metadata.
  Future<bool> _videoNoted(BuildContext context) async {
    final prefs = await Prefs.load();
    if (prefs.videoUploadNoted) return true;
    if (!context.mounted) return false;
    final l = context.l10n;
    final ok = await confirmDialog(
      context,
      title: l.videoUploadTitle,
      message: l.videoUploadMessage,
      confirmLabel: l.videoUploadConfirm,
    );
    if (ok) await prefs.setVideoUploadNoted();
    return ok;
  }

  /// Image mime types the field accepts from keyboard content insertion.
  static const insertableMimeTypes = [
    'image/png',
    'image/jpeg',
    // Some keyboards report JPEG this way.
    'image/jpg',
    'image/gif',
    'image/webp',
  ];

  /// Uploads an image a keyboard inserted (clipboard, sticker, GIF) the same
  /// way as a picked one. Other content types are ignored.
  Future<void> uploadInserted(
    BuildContext context,
    KeyboardInsertedContent content,
  ) async {
    if (_isUploading || !insertableMimeTypes.contains(content.mimeType)) return;
    final bytes = content.data;
    if (bytes == null || bytes.isEmpty) return;
    final ext = content.mimeType.split('/').last.replaceAll('jpeg', 'jpg');
    final dir = await Directory.systemTemp.createTemp('ermchat_paste');
    try {
      final file = File('${dir.path}/image.$ext');
      await file.writeAsBytes(bytes);
      if (!context.mounted) return;
      await _upload(context, file);
    } finally {
      await dir.delete(recursive: true);
    }
  }

  Future<void> _upload(BuildContext context, File file) async {
    progress.value = 0;
    try {
      final result = await _uploader.uploadMedia(
        file,
        onProgress: (sent) => progress.value = sent,
      );
      if (!context.mounted) return;
      await _uploader.addRecent(result);
      if (!context.mounted) return;
      Clipboard.setData(ClipboardData(text: result.imageLink));
      _showSnack(
        context,
        context.l10n.uploadedLink(result.imageLink),
        actionLabel: onPaste == null ? null : context.l10n.paste,
        onAction: onPaste,
      );
    } catch (e) {
      logDebug('[Upload] failed: $e');
      if (context.mounted) {
        _showSnack(
          context,
          friendlyError(e, fallback: context.l10n.uploadFailedFallback),
        );
      }
    } finally {
      progress.value = null;
    }
  }

  void _showSnack(
    BuildContext context,
    String message, {
    String? actionLabel,
    VoidCallback? onAction,
  }) {
    final notice = onNotice;
    if (notice != null) {
      notice(message, actionLabel: actionLabel, onAction: onAction);
      return;
    }
    AppSnack.show(
      context,
      message,
      actionLabel: actionLabel,
      onAction: onAction,
    );
  }
}
