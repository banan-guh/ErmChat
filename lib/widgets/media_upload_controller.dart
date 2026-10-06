import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import '../services/media_uploader.dart';
import '../util/friendly_error.dart';
import '../util/log.dart';
import 'app_snack.dart';
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
  MediaUploadController({MediaUploader? uploader, this.onNotice})
    : _uploader = uploader ?? MediaUploader();

  final MediaUploader _uploader;
  final NoticeCallback? onNotice;

  bool _isUploading = false;

  /// Releases the uploader's HTTP client. The owning screen calls this in its
  /// own dispose.
  void dispose() => _uploader.close();

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
      picked = await picker.pickImage(source: source);
    } catch (e) {
      if (context.mounted) {
        _showSnack(context, context.l10n.mediaPickerFailed('$e'));
      }
      return;
    }
    if (picked == null || !context.mounted) return;

    final file = File(picked.path);
    _isUploading = true;
    try {
      final result = await _uploader.uploadMedia(file);
      if (!context.mounted) return;
      await _uploader.addRecent(result);
      if (!context.mounted) return;
      Clipboard.setData(ClipboardData(text: result.imageLink));
      _showSnack(context, context.l10n.uploadedLink(result.imageLink));
    } catch (e) {
      logDebug('[Upload] failed: $e');
      if (context.mounted) {
        _showSnack(
          context,
          friendlyError(e, fallback: context.l10n.uploadFailedFallback),
        );
      }
    } finally {
      _isUploading = false;
    }
  }

  void _showSnack(BuildContext context, String message) {
    final notice = onNotice;
    if (notice != null) {
      notice(message);
      return;
    }
    AppSnack.show(context, message);
  }
}
