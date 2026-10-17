import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../l10n/l10n.dart';
import 'glass_chrome.dart';

/// Side of the chat widget cards' header controls.
const double kChromeMenuSize = 28;

/// The chat widget cards' gap from the top and sides of the chat pages.
const double kChromeMenuMargin = 8;

// The view menu in the island's button row: search, mod view, calendar,
// and the fullscreen, input and stream toggles. Its chevron points up, the
// way the menu opens, and flips while open.
class ChromeMenuButton extends StatefulWidget {
  final VoidCallback onToggleFullscreen;
  final VoidCallback onToggleInput;
  final VoidCallback? onToggleStream;
  final bool Function()? showStreamToggle;
  final bool Function()? streamActive;
  final VoidCallback? onShowModView;
  final bool Function()? showModView;
  final VoidCallback? onToggleSearch;

  /// Opens the channel page's days.
  final VoidCallback? onCalendar;

  /// Liquid glass menu to match the glass island.
  final bool glass;

  const ChromeMenuButton({
    super.key,
    required this.onToggleFullscreen,
    required this.onToggleInput,
    this.onToggleStream,
    this.showStreamToggle,
    this.streamActive,
    this.onShowModView,
    this.showModView,
    this.onToggleSearch,
    this.onCalendar,
    this.glass = false,
  });

  @override
  State<ChromeMenuButton> createState() => ChromeMenuButtonState();
}

class ChromeMenuButtonState extends State<ChromeMenuButton> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    return ChromeMenu(
      glass: widget.glass,
      onOpenChanged: (open) => setState(() => _open = open),
      entries: () {
        final l10n = context.l10n;
        final showMod = widget.showModView?.call() ?? false;
        final showStream = widget.showStreamToggle?.call() ?? false;
        final active = widget.streamActive?.call() ?? false;
        return [
          if (showMod)
            ChromeMenuEntry(l10n.modView, () => widget.onShowModView?.call()),
          ChromeMenuEntry(l10n.search, () => widget.onToggleSearch?.call()),
          if (widget.onCalendar case final onCalendar?)
            ChromeMenuEntry(l10n.historyCalendar, onCalendar),
          ChromeMenuEntry(l10n.toggleFullscreen, widget.onToggleFullscreen),
          ChromeMenuEntry(l10n.toggleInput, widget.onToggleInput),
          if (showStream)
            ChromeMenuEntry(
              active ? l10n.hideStream : l10n.showStream,
              () => widget.onToggleStream?.call(),
            ),
        ];
      },
      buttonStyle: const ButtonStyle(),
      trigger: AnimatedRotation(
        turns: _open ? 0.0 : 0.5,
        duration: const Duration(milliseconds: 175),
        child: const Icon(Icons.expand_more),
      ),
    );
  }
}

/// One row of a [ChromeMenu]; [ChromeMenuEntry.divider] draws a line.
class ChromeMenuEntry {
  const ChromeMenuEntry(this.label, this.onTap);
  const ChromeMenuEntry.divider() : label = null, onTap = null;

  final String? label;
  final VoidCallback? onTap;
}

/// A chrome dropdown: with [glass], a liquid glass menu that morphs out of
/// [trigger]; otherwise a Material popup under it. [entries] is read on
/// each open, so rows that depend on state stay current.
class ChromeMenu extends StatefulWidget {
  const ChromeMenu({
    super.key,
    required this.trigger,
    required this.entries,
    this.glass = false,
    this.onOpenChanged,
    this.buttonStyle,
  });

  /// The tap target; with [buttonStyle], the icon of an [IconButton] in that
  /// style, which draws its own ink.
  final Widget trigger;
  final ButtonStyle? buttonStyle;
  final List<ChromeMenuEntry> Function() entries;
  final bool glass;
  final ValueChanged<bool>? onOpenChanged;

  @override
  State<ChromeMenu> createState() => _ChromeMenuState();
}

class _ChromeMenuState extends State<ChromeMenu> {
  List<ChromeMenuEntry> _entries = const [];

  @override
  Widget build(BuildContext context) {
    if (widget.glass) {
      // Rows sized like the Material popup, not the library's iOS 17pt.
      final title = TextStyle(
        fontSize: 14,
        color: Theme.of(context).colorScheme.onSurface,
      );
      return GlassMenu(
        menuAlignment: GlassMenuAlignment.topRight,
        autoAdjustToScreen: true,
        menuPadding: const EdgeInsets.all(4),
        menuWidth: 200,
        // A short, calm open: the stiffest spring (about 170 ms, barely any
        // overshoot), no rubber-band stretch or press scaling.
        morphSpeed: MorphSpeed.instant,
        stretch: 0,
        interactionScale: 1,
        settings: kGlassPillSettings,
        onClose: () => widget.onOpenChanged?.call(false),
        triggerBuilder: (context, toggle) {
          void open() {
            setState(() => _entries = widget.entries());
            widget.onOpenChanged?.call(true);
            toggle();
          }

          if (widget.buttonStyle case final style?) {
            return IconButton(
              style: style,
              icon: widget.trigger,
              tooltip: MaterialLocalizations.of(context).showMenuTooltip,
              onPressed: open,
            );
          }
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: open,
            child: widget.trigger,
          );
        },
        items: [
          for (final e in _entries)
            if (e.label case final label?)
              GlassMenuItem(
                title: label,
                titleStyle: title,
                height: 40,
                onTap: e.onTap!,
              )
            else
              const GlassMenuDivider(height: 8),
        ],
      );
    }
    return PopupMenuButton<int>(
      position: PopupMenuPosition.under,
      popUpAnimationStyle: const AnimationStyle(
        duration: Duration(milliseconds: 175),
      ),
      onOpened: () => widget.onOpenChanged?.call(true),
      onCanceled: () => widget.onOpenChanged?.call(false),
      onSelected: (i) {
        widget.onOpenChanged?.call(false);
        _entries[i].onTap?.call();
      },
      itemBuilder: (_) {
        _entries = widget.entries();
        return [
          for (var i = 0; i < _entries.length; i++)
            if (_entries[i].label case final label?)
              PopupMenuItem(
                value: i,
                child: Text(label, overflow: TextOverflow.ellipsis),
              )
            else
              const PopupMenuDivider(),
        ];
      },
      style: widget.buttonStyle,
      icon: widget.buttonStyle == null ? null : widget.trigger,
      child: widget.buttonStyle == null ? widget.trigger : null,
    );
  }
}
