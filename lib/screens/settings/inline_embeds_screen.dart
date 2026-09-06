import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../util/constants.dart';
import 'settings_page.dart';

class InlineEmbedsScreen extends StatefulWidget {
  final ValueChanged<bool>? onShowGifsChanged;
  final ValueChanged<double>? onGifHeightChanged;

  const InlineEmbedsScreen({
    super.key,
    this.onShowGifsChanged,
    this.onGifHeightChanged,
  });

  @override
  State<InlineEmbedsScreen> createState() => _InlineEmbedsScreenState();
}

class _InlineEmbedsScreenState extends State<InlineEmbedsScreen> {
  bool _showGifs = kGiphyInlineEnabledDefault;
  double _gifHeight = kGiphyInlineHeightDefault;

  @override
  void initState() {
    super.initState();
    _loadPrefs();
  }

  Future<void> _loadPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() {
        _showGifs =
            prefs.getBool(kGiphyInlineEnabledPrefKey) ??
            kGiphyInlineEnabledDefault;
        _gifHeight =
            (prefs.getDouble(kGiphyInlineHeightPrefKey) ??
                    kGiphyInlineHeightDefault)
                .clamp(kGiphyInlineHeightMin, kGiphyInlineHeightMax);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return SettingsPage(
      title: const Text('Inline embeds'),
      body: ListView(
        children: [
          _sectionHeader('Giphy'),
          SwitchListTile(
            secondary: const Icon(Icons.gif_box),
            title: const Text('Show Giphy inline'),
            subtitle: const Text('Render Giphy attachments as images in chat'),
            value: _showGifs,
            onChanged: (value) async {
              final prefs = await SharedPreferences.getInstance();
              await prefs.setBool(kGiphyInlineEnabledPrefKey, value);
              if (mounted) setState(() => _showGifs = value);
              widget.onShowGifsChanged?.call(value);
            },
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text(
              'Giphy height: ${_gifHeight.round()}dp',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: _showGifs
                    ? null
                    : Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Slider(
            value: _gifHeight.clamp(
              kGiphyInlineHeightMin,
              kGiphyInlineHeightMax,
            ),
            min: kGiphyInlineHeightMin,
            max: kGiphyInlineHeightMax,
            divisions: 12,
            label: '${_gifHeight.round()}dp',
            onChanged: _showGifs
                ? (value) {
                    setState(() => _gifHeight = value);
                    widget.onGifHeightChanged?.call(value);
                  }
                : null,
            onChangeEnd: _showGifs
                ? (value) {
                    SharedPreferences.getInstance().then(
                      (prefs) =>
                          prefs.setDouble(kGiphyInlineHeightPrefKey, value),
                    );
                  }
                : null,
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Text(
              'Animation follows Emotes > Animate GIFs.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _sectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(
        title,
        style: Theme.of(
          context,
        ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
      ),
    );
  }
}
