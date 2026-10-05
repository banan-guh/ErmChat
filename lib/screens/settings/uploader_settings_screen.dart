import 'package:flutter/material.dart';
import '../../l10n/l10n.dart';
import '../../services/media_uploader.dart';
import '../../widgets/app_snack.dart';
import '../../widgets/dialogs.dart';
import 'recent_uploads_screen.dart';
import 'settings_page.dart';
import 'settings_search.dart';

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
    AppSnack.show(context, context.l10n.uploaderSaved);
  }

  Future<void> _reset() async {
    final confirmed = await confirmDialog(
      context,
      title: context.l10n.resetUploaderTitle,
      confirmLabel: context.l10n.reset,
    );
    if (!confirmed) return;
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
    _mediaUploader.close();
    _uploadUrl.dispose();
    _formField.dispose();
    _headers.dispose();
    _imageLinkPattern.dispose();
    _deletionLinkPattern.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SettingsPage(
      title: Text(context.l10n.imageUploaderTitle),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(context.l10n.uploaderHint, style: const TextStyle(height: 1.4)),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: _reset,
              icon: const Icon(Icons.restore),
              label: Text(context.l10n.reset),
            ),
          ),
          TextField(
            controller: _uploadUrl,
            keyboardType: TextInputType.url,
            autocorrect: false,
            decoration: InputDecoration(
              labelText: context.l10n.uploadUrl,
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _formField,
            autocorrect: false,
            decoration: InputDecoration(
              labelText: context.l10n.formField,
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _headers,
            autocorrect: false,
            decoration: InputDecoration(
              labelText: context.l10n.headers,
              hintText: context.l10n.headersHint,
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _imageLinkPattern,
            autocorrect: false,
            decoration: InputDecoration(
              labelText: context.l10n.imageLinkPattern,
              hintText: '{link}',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _deletionLinkPattern,
            autocorrect: false,
            decoration: InputDecoration(
              labelText: context.l10n.deletionLinkPattern,
              hintText: '{delete}',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: _save,
            icon: const Icon(Icons.save),
            label: Text(context.l10n.save),
          ),
          const SizedBox(height: 8),
          SettingAnchor(
            Setting.recentUploads,
            child: SettingsNavTile(
              icon: Icons.image,
              title: Setting.recentUploads.titleOf(context.l10n),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const RecentUploadsScreen()),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
