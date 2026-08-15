import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import '../services/media_uploader.dart';

/// Runs the "Upload media" flow for the chat input: lets the user pick an
/// image/video (gallery or camera), uploads it through the configured
/// uploader (kappa.lol by default), then inserts the returned link into
/// [input] and copies it to the clipboard. Successful uploads are recorded
/// in the recent uploads list (Settings > Tools).
///
/// Kept out of the home screen so the chat screen holds no upload logic; the
/// app bar menu just calls [pickAndUpload] with its own context.
class MediaUploadController {
  MediaUploadController({
    MediaUploader? uploader,
    required this.input,
    this.focusNode,
  }) : _uploader = uploader ?? MediaUploader();

  final MediaUploader _uploader;
  final TextEditingController input;
  final FocusNode? focusNode;

  bool _isUploading = false;

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
              title: const Text('Gallery'),
              onTap: () => Navigator.pop(ctx, ImageSource.gallery),
            ),
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('Camera'),
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
        _showSnack(context, 'Could not open media picker: $e');
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
      _insertIntoInput(result.imageLink);
      _showSnack(context, 'Uploaded ${result.imageLink}');
    } catch (e) {
      if (context.mounted) _showSnack(context, 'Upload failed: $e');
    } finally {
      _isUploading = false;
    }
  }

  void _insertIntoInput(String text) {
    final sel = input.selection;
    final start = sel.isValid ? sel.start : input.text.length;
    final end = sel.isValid ? sel.end : start;
    input.value = TextEditingValue(
      text: input.text.replaceRange(start, end, text),
      selection: TextSelection.collapsed(offset: start + text.length),
    );
    focusNode?.requestFocus();
  }

  void _showSnack(BuildContext context, String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }
}
