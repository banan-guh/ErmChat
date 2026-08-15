import 'package:flutter/material.dart';
import '../../services/media_uploader.dart';

class UploaderSettingsScreen extends StatefulWidget {
  const UploaderSettingsScreen({super.key});

  @override
  State<UploaderSettingsScreen> createState() => _UploaderSettingsScreenState();
}

class _UploaderSettingsScreenState extends State<UploaderSettingsScreen> {
  final _mediaUploader = MediaUploader();

  late final TextEditingController _uploadUrl;
  late final TextEditingController _formField;
  late final TextEditingController _headers;
  late final TextEditingController _imageLinkPattern;
  late final TextEditingController _deletionLinkPattern;

  @override
  void initState() {
    super.initState();
    _uploadUrl = TextEditingController();
    _formField = TextEditingController();
    _headers = TextEditingController();
    _imageLinkPattern = TextEditingController();
    _deletionLinkPattern = TextEditingController();
    _loadConfig();
  }

  Future<void> _loadConfig() async {
    final config = await _mediaUploader.loadConfig();
    if (!mounted) return;
    setState(() {
      _uploadUrl.text = config.uploadUrl;
      _formField.text = config.formField;
      _headers.text = config.headers ?? '';
      _imageLinkPattern.text = config.imageLinkPattern ?? '';
      _deletionLinkPattern.text = config.deletionLinkPattern ?? '';
    });
  }

  Future<void> _save() async {
    await _mediaUploader.saveConfig(
      UploaderConfig(
        uploadUrl: _uploadUrl.text.trim(),
        formField: _formField.text.trim(),
        headers: _headers.text.trim().isNotEmpty ? _headers.text.trim() : null,
        imageLinkPattern: _imageLinkPattern.text.trim().isNotEmpty
            ? _imageLinkPattern.text.trim()
            : null,
        deletionLinkPattern: _deletionLinkPattern.text.trim().isNotEmpty
            ? _deletionLinkPattern.text.trim()
            : null,
      ),
    );
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Uploader settings saved')));
  }

  Future<void> _reset() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Reset media uploader'),
        content: const Text('Restore the default kappa.lol uploader settings?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Reset'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _mediaUploader.resetConfig();
    if (!mounted) return;
    setState(() {
      _uploadUrl.text = UploaderConfig.defaultConfig.uploadUrl;
      _formField.text = UploaderConfig.defaultConfig.formField;
      _headers.text = '';
      _imageLinkPattern.text =
          UploaderConfig.defaultConfig.imageLinkPattern ?? '';
      _deletionLinkPattern.text =
          UploaderConfig.defaultConfig.deletionLinkPattern ?? '';
    });
  }

  @override
  void dispose() {
    _uploadUrl.dispose();
    _formField.dispose();
    _headers.dispose();
    _imageLinkPattern.dispose();
    _deletionLinkPattern.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Image uploader')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'Images and videos picked from chat are uploaded to this endpoint '
            'and the returned link is pasted into the input box. The default '
            'points at kappa.lol.',
            style: TextStyle(height: 1.4),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: _reset,
              icon: const Icon(Icons.restore),
              label: const Text('Reset'),
            ),
          ),
          TextField(
            controller: _uploadUrl,
            keyboardType: TextInputType.url,
            autocorrect: false,
            decoration: const InputDecoration(
              labelText: 'Upload URL',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _formField,
            autocorrect: false,
            decoration: const InputDecoration(
              labelText: 'Form field',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _headers,
            autocorrect: false,
            decoration: const InputDecoration(
              labelText: 'Headers',
              hintText: 'Name: value; Name: value',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _imageLinkPattern,
            autocorrect: false,
            decoration: const InputDecoration(
              labelText: 'Image link pattern',
              hintText: '{link}',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _deletionLinkPattern,
            autocorrect: false,
            decoration: const InputDecoration(
              labelText: 'Deletion link pattern',
              hintText: '{delete}',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: _save,
            icon: const Icon(Icons.save),
            label: const Text('Save'),
          ),
        ],
      ),
    );
  }
}
