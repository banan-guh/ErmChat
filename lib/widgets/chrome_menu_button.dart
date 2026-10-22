import 'dart:math';
import 'dart:ui' show ImageFilter, lerpDouble;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../l10n/l10n.dart';
import 'glass_chrome.dart';
import 'design_tokens.dart';

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
            ChromeMenuEntry(
              l10n.modView,
              () => widget.onShowModView?.call(),
              icon: Icons.shield_outlined,
            ),
          ChromeMenuEntry(
            l10n.search,
            () => widget.onToggleSearch?.call(),
            icon: Icons.search,
          ),
          if (widget.onCalendar case final onCalendar?)
            ChromeMenuEntry(
              l10n.historyCalendar,
              onCalendar,
              icon: Icons.calendar_month_outlined,
            ),
          ChromeMenuEntry(
            l10n.toggleFullscreen,
            widget.onToggleFullscreen,
            icon: Icons.fullscreen,
          ),
          ChromeMenuEntry(
            l10n.toggleInput,
            widget.onToggleInput,
            icon: Icons.keyboard_outlined,
          ),
          if (showStream)
            ChromeMenuEntry(
              active ? l10n.hideStream : l10n.showStream,
              () => widget.onToggleStream?.call(),
              icon: Icons.live_tv_outlined,
            ),
        ];
      },
      buttonStyle: const ButtonStyle(),
      trigger: AnimatedRotation(
        turns: _open ? 0.0 : 0.5,
        duration: Motion.fast,
        child: const Icon(Icons.expand_more),
      ),
    );
  }
}

/// The view menu's pill while fullscreen floats it over the pages. Its
/// width matches a small FAB's tap target, so a floating button under it
/// at the same right edge shares its center.
class FloatingMenuShell extends StatelessWidget {
  const FloatingMenuShell({super.key, required this.child});

  final Widget child;

  static const double width = 48;
  static const double height = 40;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      height: height,
      child: DecoratedBox(
        decoration: ShapeDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHigh,
          shape: const StadiumBorder(),
        ),
        child: Center(child: child),
      ),
    );
  }
}

/// One row of a [ChromeMenu]; [ChromeMenuEntry.divider] draws a line.
class ChromeMenuEntry {
  const ChromeMenuEntry(this.label, this.onTap, {this.icon});
  const ChromeMenuEntry.divider() : label = null, onTap = null, icon = null;

  final String? label;
  final VoidCallback? onTap;

  /// Leading icon.
  final IconData? icon;
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
      return _BloomMenu(
        trigger: widget.trigger,
        buttonStyle: widget.buttonStyle,
        entries: widget.entries,
        onOpenChanged: widget.onOpenChanged,
      );
    }
    return PopupMenuButton<int>(
      position: PopupMenuPosition.under,
      popUpAnimationStyle: const AnimationStyle(duration: Motion.fast),
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
                    if (_entries[i].icon case final icon?) ...[
                      Icon(icon, size: 20),
                      const SizedBox(width: 12),
                    ],
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
      style: widget.buttonStyle,
      icon: widget.buttonStyle == null ? null : widget.trigger,
      child: widget.buttonStyle == null ? widget.trigger : null,
    );
  }
}

const double _kMenuWidth = 200;
const double _kMenuPad = 4;
const double _kRowHeight = 40;
const double _kDividerHeight = 8;
const double _kMenuRadius = 16;
const double _kEdgeGap = 8;

/// A liquid glass menu that blooms out of its trigger: a circle grows from
/// the button, then squares off into the menu while its rows sharpen out of
/// a blur. It covers the trigger's corner and opens toward the roomier side.
/// Opening closes the keyboard, and the menu follows the trigger as the
/// keyboard slides away.
class _BloomMenu extends StatefulWidget {
  const _BloomMenu({
    required this.trigger,
    required this.entries,
    this.buttonStyle,
    this.onOpenChanged,
  });

  final Widget trigger;
  final ButtonStyle? buttonStyle;
  final List<ChromeMenuEntry> Function() entries;
  final ValueChanged<bool>? onOpenChanged;

  @override
  State<_BloomMenu> createState() => _BloomMenuState();
}

class _BloomMenuState extends State<_BloomMenu>
    with SingleTickerProviderStateMixin {
  // About the system menu's spring: settles in ~350 ms with a slight overshoot.
  static const _spring = SpringDescription(
    mass: 1,
    stiffness: 121,
    damping: 16,
  );

  final _link = LayerLink();
  final _portal = OverlayPortalController();
  late final _morph = AnimationController.unbounded(vsync: this);
  List<ChromeMenuEntry> _entries = const [];
  Size _trigger = Size.zero;
  Alignment _corner = Alignment.topRight;
  // Shift that keeps the menu clear of the screen edges.
  Offset _shift = Offset.zero;
  bool _closing = false;

  @override
  void dispose() {
    _morph.dispose();
    super.dispose();
  }

  void _open() {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    FocusManager.instance.primaryFocus?.unfocus();
    final screen = MediaQuery.sizeOf(context);
    final safe = MediaQuery.paddingOf(context);
    final at = box.localToGlobal(Offset.zero) & box.size;
    final center = at.center;
    final right = center.dx > screen.width / 2;
    final up = center.dy > screen.height / 2;
    setState(() {
      _entries = widget.entries();
      _trigger = box.size;
      _corner = Alignment(right ? 1 : -1, up ? 1 : -1);
      _shift = Offset(
        right
            ? min(0, screen.width - _kEdgeGap - at.right)
            : max(0, _kEdgeGap - at.left),
        up
            ? min(0, screen.height - safe.bottom - _kEdgeGap - at.bottom)
            : max(0, safe.top + _kEdgeGap - at.top),
      );
      _closing = false;
    });
    widget.onOpenChanged?.call(true);
    _portal.show();
    if (MediaQuery.disableAnimationsOf(context)) {
      _morph.value = 1;
    } else {
      _morph.animateWith(SpringSimulation(_spring, _morph.value, 1, 0));
    }
  }

  Future<void> _close() async {
    if (!_portal.isShowing || _closing) return;
    // Closing mid-open turns straight back instead of easing in from a stop.
    final opening = _morph.isAnimating;
    setState(() => _closing = true);
    widget.onOpenChanged?.call(false);
    if (!MediaQuery.disableAnimationsOf(context)) {
      try {
        await _morph
            .animateTo(
              0,
              duration: Motion.normal,
              curve: opening ? Motion.enter : Motion.exit,
            )
            .orCancel;
      } on TickerCanceled {
        return; // Reopened mid-close.
      }
    }
    if (mounted && _closing) setState(_portal.hide);
  }

  void _select(ChromeMenuEntry entry) {
    _close();
    entry.onTap?.call();
  }

  @override
  Widget build(BuildContext context) {
    final style = widget.buttonStyle;
    final trigger = style != null
        ? IconButton(
            style: style,
            icon: widget.trigger,
            tooltip: MaterialLocalizations.of(context).showMenuTooltip,
            onPressed: _open,
          )
        : GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _open,
            child: widget.trigger,
          );
    // The menu grows out of the button, so the button gives way to it.
    return CompositedTransformTarget(
      link: _link,
      child: OverlayPortal(
        controller: _portal,
        overlayChildBuilder: _overlay,
        child: AnimatedOpacity(
          opacity: _portal.isShowing && !_closing ? 0 : 1,
          duration: Motion.fast,
          child: trigger,
        ),
      ),
    );
  }

  Widget _overlay(BuildContext context) {
    var height = _kMenuPad * 2;
    for (final e in _entries) {
      height += e.label == null ? _kDividerHeight : _kRowHeight;
    }
    final size = Size(_kMenuWidth, height);
    final rows = _rows(context);
    return SizedBox.expand(
      child: Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _close,
            ),
          ),
          CompositedTransformFollower(
            link: _link,
            targetAnchor: _corner,
            followerAnchor: _corner,
            offset: _shift,
            child: PopScope(
              canPop: false,
              onPopInvokedWithResult: (didPop, _) {
                if (!didPop) _close();
              },
              child: SizedBox.fromSize(
                size: size,
                child: AnimatedBuilder(
                  animation: _morph,
                  builder: (context, _) => _bloom(size, rows),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// The menu at the morph's current value: a circle over the trigger that
  /// grows to the menu's width, then squares off into the full menu.
  Widget _bloom(Size size, Widget rows) {
    final p = _morph.value;
    final t = p.clamp(0.0, 1.0);
    // Center of a box of [s] tucked into the anchored corner.
    Offset tucked(Size s) =>
        _corner.alongSize(size) - _corner.alongSize(s) + s.center(Offset.zero);
    // The trigger sits off the corner by the edge shift.
    final from = tucked(_trigger) - _shift;
    final grow = Motion.enter.transform((t / 0.45).clamp(0.0, 1.0));
    final square = Motion.move.transform(((t - 0.3) / 0.7).clamp(0.0, 1.0));
    final full = min(size.width, size.height);
    final d = lerpDouble(_trigger.shortestSide, full, grow)!;
    final circle = Rect.fromCenter(
      center: Offset.lerp(from, tucked(Size.square(full)), grow)!,
      width: d,
      height: d,
    );
    // The spring's overshoot swells the settled menu a touch.
    final rect = Rect.lerp(
      circle,
      Offset.zero & size,
      square,
    )!.inflate(max(0.0, p - 1) * 40);
    final radius = lerpDouble(d / 2, _kMenuRadius, square)!;
    final blur = (1 - square) * 12;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Positioned.fromRect(
          rect: rect,
          child: GlassSurface(
            settings: kGlassPillSettings.copyWith(
              visibility: (t / 0.15).clamp(0.0, 1.0),
            ),
            shape: LiquidRoundedRectangle(borderRadius: radius),
            child: const SizedBox.expand(),
          ),
        ),
        Positioned.fill(
          child: IgnorePointer(
            ignoring: _closing || t < 0.8,
            child: ClipRRect(
              clipper: _RRectClip(
                RRect.fromRectAndRadius(rect, Radius.circular(radius)),
              ),
              child: Opacity(
                opacity: ((t - 0.2) / 0.4).clamp(0.0, 1.0),
                child: blur < 0.1
                    ? rows
                    : ImageFiltered(
                        imageFilter: ImageFilter.blur(
                          sigmaX: blur,
                          sigmaY: blur,
                        ),
                        child: rows,
                      ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _rows(BuildContext context) {
    // The Material popup's text and icon styles, so both menus read alike.
    final theme = Theme.of(context);
    final color = theme.colorScheme.onSurface;
    final style = theme.textTheme.labelLarge?.copyWith(color: color);
    return Material(
      type: MaterialType.transparency,
      child: Padding(
        padding: const EdgeInsets.all(_kMenuPad),
        child: Column(
          children: [
            for (final e in _entries)
              if (e.label case final label?)
                SizedBox(
                  height: _kRowHeight,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(
                      _kMenuRadius - _kMenuPad,
                    ),
                    onTap: () => _select(e),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: Row(
                        children: [
                          if (e.icon case final icon?) ...[
                            Icon(
                              icon,
                              size: 20,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                            const SizedBox(width: 12),
                          ],
                          Expanded(
                            child: Text(
                              label,
                              style: style,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                )
              else
                Divider(
                  height: _kDividerHeight,
                  thickness: 0.5,
                  color: color.withValues(alpha: 0.15),
                ),
          ],
        ),
      ),
    );
  }
}

class _RRectClip extends CustomClipper<RRect> {
  const _RRectClip(this.rrect);

  final RRect rrect;

  @override
  RRect getClip(Size size) => rrect;

  @override
  bool shouldReclip(_RRectClip old) => old.rrect != rrect;
}
