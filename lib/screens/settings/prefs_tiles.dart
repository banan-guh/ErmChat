import 'package:flutter/material.dart';

import '../../util/prefs.dart';
import '../../util/prefs_store.dart';
import '../../util/settings.dart';
import 'settings_page.dart';

/// Settings rows bound directly to one stored value.
///
/// A change writes through, announces it on [PrefsStore] for owners that
/// re-read everything, then optionally forwards to [onChanged] for callers
/// that need an inline action.

/// Switch row for one [Settings] flag. It shows the live value, so a write
/// from anywhere else moves it too.
class PrefsSwitchTile extends StatelessWidget {
  const PrefsSwitchTile({
    super.key,
    required this.title,
    this.subtitle,
    this.secondary,
    this.titleTrailing,
    this.info,
    required this.pref,
    this.onChanged,
    this.enabled = true,
  });

  final String title;
  final String? subtitle;
  final Widget? secondary;

  /// Sits at the end of the title row, before the switch.
  final Widget? titleTrailing;

  /// Sits right after the title text, such as an info button.
  final Widget? info;
  final Pref<bool> pref;
  final ValueChanged<bool>? onChanged;
  final bool enabled;

  Future<void> _onChanged(bool value) async {
    await pref.set(value);
    PrefsStore.instance.notifyChanged();
    onChanged?.call(value);
  }

  @override
  Widget build(BuildContext context) {
    final trailing = titleTrailing;
    final subtitle = this.subtitle;
    final title = TextWithTrailing(this.title, trailing: info);
    return ValueListenableBuilder(
      valueListenable: pref,
      builder: (context, value, _) => SwitchListTile(
        secondary: secondary,
        // With a title trailing, the subtitle joins the title slot so the
        // trailing centers on both lines, not on the title alone.
        title: trailing == null
            ? title
            : Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        title,
                        if (subtitle != null)
                          Text(subtitle, style: _subtitleStyle(context)),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  trailing,
                ],
              ),
        subtitle: subtitle == null || trailing != null ? null : Text(subtitle),
        value: value,
        onChanged: enabled ? _onChanged : null,
      ),
    );
  }

  /// The list tile's own subtitle look, dimmed when disabled.
  TextStyle? _subtitleStyle(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return theme.textTheme.bodyMedium?.copyWith(
      color: enabled
          ? scheme.onSurfaceVariant
          : scheme.onSurface.withValues(alpha: 0.38),
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
    this.labelTrailing,
    this.tint,
  });

  /// Colors the caption and track for a value, such as a warning red.
  final Color? Function(double value)? tint;

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

  /// Sits right after the caption, such as an info button.
  final Widget? labelTrailing;

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
    PrefsStore.instance.notifyChanged();
  }

  @override
  Widget build(BuildContext context) {
    final value = _value ?? widget.defaultValue;
    final enabled = widget.enabled;
    final tint = enabled ? widget.tint?.call(value) : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: TextWithTrailing(
            widget.label(value),
            trailing: widget.labelTrailing,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: enabled
                  ? tint
                  : Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        Slider(
          value: value,
          min: widget.min,
          max: widget.max,
          divisions: widget.divisions,
          activeColor: tint,
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
