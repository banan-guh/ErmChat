import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../l10n/l10n.dart';
import 'glass_chrome.dart';

/// Side of the dropdown trigger, and its corner radius. The chat widget
/// cards sit concentric around it: their corner is this radius plus their
/// inset.
const double kChromeMenuSize = 28;
const double kChromeMenuRadius = 8;

/// The trigger's gap from the top and right of the chat pages.
const double kChromeMenuMargin = 8;

// Dropdown for search, mod view, and fullscreen, input, stream toggles.
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

  /// Glass tile trigger to match the floating glass header.
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
    final theme = Theme.of(context);
    final arrow = AnimatedRotation(
      turns: _open ? 0.5 : 0.0,
      duration: const Duration(milliseconds: 175),
      child: Icon(
        Icons.expand_more,
        size: 20,
        color: theme.colorScheme.onSurfaceVariant,
      ),
    );
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
            ChromeMenuEntry(
              Icons.shield_outlined,
              l10n.modView,
              () => widget.onShowModView?.call(),
            ),
          ChromeMenuEntry(
            Icons.search,
            l10n.search,
            () => widget.onToggleSearch?.call(),
          ),
          if (widget.onCalendar case final onCalendar?)
            ChromeMenuEntry(
              Icons.calendar_month_outlined,
              l10n.historyCalendar,
              onCalendar,
            ),
          ChromeMenuEntry(
            Icons.fullscreen,
            l10n.toggleFullscreen,
            widget.onToggleFullscreen,
          ),
          ChromeMenuEntry(
            Icons.keyboard_outlined,
            l10n.toggleInput,
            widget.onToggleInput,
          ),
          if (showStream)
            ChromeMenuEntry(
              Icons.live_tv_outlined,
              active ? l10n.hideStream : l10n.showStream,
              () => widget.onToggleStream?.call(),
            ),
        ];
      },
      // Fixed size in both styles; a border would otherwise grow the box.
      trigger: widget.glass
          ? GlassSurface(
              shape: const LiquidRoundedSuperellipse(
                borderRadius: kChromeMenuRadius,
              ),
              settings: kGlassPillSettings,
              child: SizedBox.square(
                dimension: kChromeMenuSize,
                child: Center(child: arrow),
              ),
            )
          : Container(
              width: kChromeMenuSize,
              height: kChromeMenuSize,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(kChromeMenuRadius),
                border: Border.all(color: theme.colorScheme.outlineVariant),
              ),
              child: arrow,
            ),
    );
  }
}

/// One row of a [ChromeMenu]; [ChromeMenuEntry.divider] draws a line.
class ChromeMenuEntry {
  const ChromeMenuEntry(this.icon, this.label, this.onTap);
  const ChromeMenuEntry.divider() : icon = null, label = null, onTap = null;

  final IconData? icon;
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
  });

  final Widget trigger;
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
      return GlassMenu(
        menuAlignment: GlassMenuAlignment.topRight,
        autoAdjustToScreen: true,
        menuPadding: const EdgeInsets.all(8),
        menuWidth: 220,
        // A quick, plain open: no rubber-band stretch or press scaling.
        morphSpeed: MorphSpeed.fast,
        stretch: 0,
        interactionScale: 1,
        settings: kGlassPillSettings,
        onClose: () => widget.onOpenChanged?.call(false),
        triggerBuilder: (context, toggle) => GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {
            setState(() => _entries = widget.entries());
            widget.onOpenChanged?.call(true);
            toggle();
          },
          child: widget.trigger,
        ),
        items: [
          for (final e in _entries)
            if (e.label case final label?)
              GlassMenuItem(title: label, icon: Icon(e.icon), onTap: e.onTap!)
            else
              const GlassMenuDivider(),
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
                child: Row(
                  children: [
                    Icon(_entries[i].icon, size: 20),
                    const SizedBox(width: 12),
                    Flexible(
                      child: Text(label, overflow: TextOverflow.ellipsis),
                    ),
                  ],
                ),
              )
            else
              const PopupMenuDivider(),
        ];
      },
      child: widget.trigger,
    );
  }
}
