import 'package:flutter/material.dart';

import '../../util/prefs.dart';

/// Settings rows bound directly to one [Prefs] value.
///
/// Each tile loads [Prefs] once, shows its default until the store arrives,
/// then rebuilds from the persisted value. A change writes through and
/// forwards to [onChanged] so the owning screen can mirror the value. This
/// removes the per-setting field, load line, and setter method a screen would
/// otherwise keep.

class PrefsSwitchTile extends StatefulWidget {
  const PrefsSwitchTile({
    super.key,
    required this.title,
    this.subtitle,
    this.secondary,
    this.defaultValue = false,
    required this.read,
    required this.write,
    this.onChanged,
    this.enabled = true,
  });

  final String title;
  final String? subtitle;
  final Widget? secondary;
  final bool defaultValue;
  final bool Function(Prefs prefs) read;
  final Future<void> Function(Prefs prefs, bool value) write;
  final ValueChanged<bool>? onChanged;
  final bool enabled;

  @override
  State<PrefsSwitchTile> createState() => _PrefsSwitchTileState();
}

class _PrefsSwitchTileState extends State<PrefsSwitchTile> {
  Prefs? _prefs;
  bool? _value;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await Prefs.load();
    if (!mounted) return;
    setState(() {
      _prefs = prefs;
      _value = widget.read(prefs);
    });
  }

  Future<void> _onChanged(bool value) async {
    setState(() => _value = value);
    final prefs = _prefs ?? await Prefs.load();
    await widget.write(prefs, value);
    widget.onChanged?.call(value);
  }

  @override
  Widget build(BuildContext context) {
    return SwitchListTile(
      secondary: widget.secondary,
      title: Text(widget.title),
      subtitle: widget.subtitle == null ? null : Text(widget.subtitle!),
      value: _value ?? widget.defaultValue,
      onChanged: widget.enabled ? _onChanged : null,
    );
  }
}

/// Slider settings row. Keeps a local drag value and persists on release,
/// matching the app's existing slider behavior.
class PrefsSliderTile extends StatefulWidget {
  const PrefsSliderTile({
    super.key,
    required this.label,
    this.sliderLabel,
    required this.min,
    required this.max,
    this.divisions,
    required this.defaultValue,
    required this.read,
    required this.write,
    this.onChanged,
    this.enabled = true,
  });

  /// Renders the caption from the current slider value.
  final String Function(double value) label;

  /// Renders the drag tooltip; defaults to [label].
  final String Function(double value)? sliderLabel;
  final double min;
  final double max;
  final int? divisions;
  final double defaultValue;
  final double Function(Prefs prefs) read;
  final Future<void> Function(Prefs prefs, double value) write;
  final ValueChanged<double>? onChanged;

  /// When false, the slider is inert and the caption is dimmed.
  final bool enabled;

  @override
  State<PrefsSliderTile> createState() => _PrefsSliderTileState();
}

class _PrefsSliderTileState extends State<PrefsSliderTile> {
  Prefs? _prefs;
  double? _value;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await Prefs.load();
    if (!mounted) return;
    setState(() {
      _prefs = prefs;
      _value = widget.read(prefs);
    });
  }

  Future<void> _commit(double value) async {
    final prefs = _prefs ?? await Prefs.load();
    await widget.write(prefs, value);
  }

  @override
  Widget build(BuildContext context) {
    final value = _value ?? widget.defaultValue;
    final enabled = widget.enabled;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Text(
            widget.label(value),
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: enabled
                  ? null
                  : Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        Slider(
          value: value,
          min: widget.min,
          max: widget.max,
          divisions: widget.divisions,
          label: (widget.sliderLabel ?? widget.label)(value),
          onChanged: enabled
              ? (v) {
                  setState(() => _value = v);
                  widget.onChanged?.call(v);
                }
              : null,
          onChangeEnd: enabled ? _commit : null,
        ),
      ],
    );
  }
}
