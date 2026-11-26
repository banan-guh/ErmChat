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
  late final TextEditingController _extraFields;
  late final TextEditingController _imageLinkPattern;
  late final TextEditingController _deletionLinkPattern;
  String? _presetId;
  int _presetFieldRevision = 0;

  @override
  void initState() {
    super.initState();
    _uploadUrl = TextEditingController();
    _formField = TextEditingController();
    _headers = TextEditingController();
    _extraFields = TextEditingController();
    _imageLinkPattern = TextEditingController();
    _deletionLinkPattern = TextEditingController();
    _loadConfig();
  }

  void _applyConfig(UploaderConfig config) {
    _uploadUrl.text = config.uploadUrl;
    _formField.text = config.formField;
    _headers.text = config.headers ?? '';
    _extraFields.text = config.extraFields ?? '';
    _imageLinkPattern.text = config.imageLinkPattern ?? '';
    _deletionLinkPattern.text = config.deletionLinkPattern ?? '';
  }

  Future<void> _loadConfig() async {
    final config = await _mediaUploader.loadConfig();
    if (!mounted) return;
    setState(() {
      _presetId = config.presetId;
      _applyConfig(config);
    });
  }

  String _presetLabel(BuildContext context, String? id) {
    final l10n = context.l10n;
    return switch (id) {
      'kappa' => l10n.uploaderPresetKappa,
      'femboy' => l10n.uploaderPresetFemboy,
      'segs' => l10n.uploaderPresetSegs,
      'nuuls' => l10n.uploaderPresetNuuls,
      'gachi' => l10n.uploaderPresetGachi,
      'olrite' => l10n.uploaderPresetOlrite,
      'catbox' => l10n.uploaderPresetCatbox,
      'litterbox' => l10n.uploaderPresetLitterbox,
      _ => l10n.uploaderPresetCustom,
    };
  }

  /// A preset overwrites the fields. A custom setup needs confirmation first
  /// because its headers and patterns would be lost.
  Future<void> _pickPreset(String? picked) async {
    if (picked == null || !mounted) return;
    if (_presetId == null) {
      final confirmed = await confirmDialog(
        context,
        title: context.l10n.replaceCustomUploaderTitle,
        message: context.l10n.replaceCustomUploaderMessage,
        confirmLabel: context.l10n.confirm,
        destructive: true,
      );
      if (!mounted) return;
      if (!confirmed) {
        // Rebuild the field to drop the pick it previewed.
        setState(() => _presetFieldRevision++);
        return;
      }
    }
    final preset = uploaderPresets.firstWhere((p) => p.id == picked);
    await _mediaUploader.saveConfig(preset.config);
    if (!mounted) return;
    setState(() {
      _presetId = preset.id;
      _applyConfig(preset.config);
    });
    AppSnack.show(context, context.l10n.uploaderSaved);
  }

  Future<void> _save() async {
    // Empty required fields fall back to the defaults.
    const defaults = UploaderConfig.defaultConfig;
    if (_uploadUrl.text.trim().isEmpty) _uploadUrl.text = defaults.uploadUrl;
    if (_formField.text.trim().isEmpty) _formField.text = defaults.formField;
    final config = UploaderConfig(
      uploadUrl: _uploadUrl.text.trim(),
      formField: _formField.text.trim(),
      headers: _headers.text.trim().isNotEmpty ? _headers.text.trim() : null,
      extraFields: _extraFields.text.trim().isNotEmpty
          ? _extraFields.text.trim()
          : null,
      imageLinkPattern: _imageLinkPattern.text.trim().isNotEmpty
          ? _imageLinkPattern.text.trim()
          : null,
      deletionLinkPattern: _deletionLinkPattern.text.trim().isNotEmpty
          ? _deletionLinkPattern.text.trim()
          : null,
    );
    await _mediaUploader.saveConfig(config);
    if (!mounted) return;
    setState(() => _presetId = config.presetId);
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
      _presetId = UploaderConfig.defaultConfig.presetId;
      _applyConfig(UploaderConfig.defaultConfig);
    });
  }

  @override
  void dispose() {
    _mediaUploader.close();
    _uploadUrl.dispose();
    _formField.dispose();
    _headers.dispose();
    _extraFields.dispose();
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
          DropdownButtonFormField<String>(
            key: ValueKey(_presetFieldRevision),
            initialValue: _presetId,
            decoration: InputDecoration(
              labelText: context.l10n.uploaderPresets,
              floatingLabelBehavior: FloatingLabelBehavior.always,
              border: OutlineInputBorder(),
            ),
            hint: Text(context.l10n.uploaderPresetCustom),
            items: [
              for (final preset in uploaderPresets)
                DropdownMenuItem<String>(
                  value: preset.id,
                  child: Text(_presetLabel(context, preset.id)),
                ),
            ],
            onChanged: _pickPreset,
          ),
          const Divider(height: 1),
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
            controller: _extraFields,
            autocorrect: false,
            decoration: InputDecoration(
              labelText: context.l10n.extraFormFields,
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
          SettingAnchor.row(
            SettingsRow.recentUploads,
            child: SettingsNavTile(
              icon: Icons.image,
              title: SettingsRow.recentUploads.titleOf(context.l10n),
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
