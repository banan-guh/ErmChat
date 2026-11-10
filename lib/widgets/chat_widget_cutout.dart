import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import '../eventsub/decode/events.dart';
import '../l10n/l10n.dart';
import '../services/emote_manager.dart';
import 'chat_widget_cards.dart';
import 'chrome_menu_button.dart';
import 'seven_tv_paint_service.dart';
import 'tabbed_layout.dart';
import 'design_tokens.dart';

// The cutout the cards sit in: each card's controls land in its top-right
// corner, inset [TabbedLayout.cardInset]; see chat_widget_cards.dart.
const double _inset = TabbedLayout.cardInset;
const double _controlSize = kChromeMenuSize;

/// Card edge to the collapse control.
const double _controlRight = _inset;

/// Gap under the cards.
const double _bottomGap = 6;

final _controlStyle = IconButton.styleFrom(
  fixedSize: const Size.square(_controlSize),
  minimumSize: Size.zero,
  padding: EdgeInsets.zero,
  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
);

/// Cutout for chat widget cards (pin, poll, prediction, hype train). Each
/// card sizes to its content up to [maxHeight], then scrolls. Several cards
/// share a pager whose height follows the swipe between them.
class ChatWidgetCutout extends StatefulWidget {
  const ChatWidgetCutout({
    super.key,
    required this.pages,
    required this.ids,
    required this.heights,
    required this.controller,
    required this.onMinimize,
    this.room = double.infinity,
    this.carryInk = false,
  });

  static const double maxHeight = 220;

  /// Height left below the cards' top; they never run past it.
  final double room;

  final List<Widget> pages;

  /// Identity per page, parallel to [pages], keying [heights].
  final List<Object> ids;

  /// Each card's natural height, kept by the caller so a rebuilt cutout
  /// (restore, channel swipe) opens at the right size.
  final Map<Object, double> heights;
  final PageController controller;
  final VoidCallback onMinimize;

  /// A tap on the bar opened these cards; they carry its ink.
  final bool carryInk;

  @override
  State<ChatWidgetCutout> createState() => _ChatWidgetCutoutState();
}

class _ChatWidgetCutoutState extends State<ChatWidgetCutout> {
  double get _cap => (widget.room - _bottomGap)
      .clamp(0.0, ChatWidgetCutout.maxHeight)
      .toDouble();

  double? _heightAt(int index) {
    final ids = widget.ids;
    return index >= 0 && index < ids.length ? widget.heights[ids[index]] : null;
  }

  void _report(int index, double height) {
    if (_heightAt(index) == height) return;
    final id = widget.ids[index];
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.heights[id] != height) {
        setState(() => widget.heights[id] = height);
      }
    });
  }

  /// The pager's position; its initial page until one view is attached.
  double get _page {
    final c = widget.controller;
    if (c.positions.length != 1) return c.initialPage.toDouble();
    return c.page ?? c.initialPage.toDouble();
  }

  // Blends the two visible pages' heights by swipe progress. A page not
  // measured yet borrows its neighbor's height.
  double? _pagerHeight() {
    final page = _page;
    final i = page.floor();
    final a = _heightAt(i) ?? _heightAt(i + 1);
    final b = _heightAt(i + 1) ?? a;
    if (a == null || b == null) return null;
    final h = a + (b - a) * (page - i);
    return h.clamp(0, _cap).toDouble();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final pages = widget.pages;
    // A tap anywhere collapses the cards to the minimized bar.
    Widget surface(Widget child) => _cardSurface(
      context,
      carryInk: widget.carryInk,
      child: InkWell(onTap: widget.onMinimize, child: child),
    );
    final minimize = Positioned(
      top: _inset,
      right: _controlRight,
      child: IconButton(
        icon: const Icon(Icons.keyboard_arrow_down, size: 20),
        tooltip: context.l10n.minimize,
        style: _controlStyle,
        onPressed: widget.onMinimize,
      ),
    );
    if (pages.length == 1) {
      return Padding(
        padding: const EdgeInsets.only(bottom: _bottomGap),
        child: surface(
          Stack(
            children: [
              ConstrainedBox(
                constraints: BoxConstraints(maxHeight: _cap),
                child: _fadeIfClipped(
                  (_heightAt(0) ?? 0) > _cap,
                  SingleChildScrollView(
                    child: _MeasureSize(
                      onSize: (size) => _report(0, size.height),
                      child: pages.single,
                    ),
                  ),
                ),
              ),
              minimize,
            ],
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: _bottomGap),
      child: AnimatedBuilder(
        animation: widget.controller,
        builder: (context, child) {
          final height = _pagerHeight();
          // Unmeasured, the cards lay out hidden for one frame rather than
          // opening at a guess and snapping to size.
          return height == null
              ? Opacity(
                  opacity: 0,
                  child: SizedBox(height: _cap, child: child),
                )
              : SizedBox(height: height, child: child);
        },
        child: surface(
          Stack(
            children: [
              PageView.builder(
                controller: widget.controller,
                itemCount: pages.length,
                itemBuilder: (context, index) => _fadeIfClipped(
                  (_heightAt(index) ?? 0) > _cap,
                  SingleChildScrollView(
                    child: _MeasureSize(
                      onSize: (size) => _report(index, size.height),
                      child: pages[index],
                    ),
                  ),
                ),
              ),
              minimize,
              Positioned(
                left: 0,
                right: 0,
                bottom: 4,
                child: AnimatedBuilder(
                  animation: widget.controller,
                  builder: (context, _) {
                    final current = _page.round();
                    return Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        for (var i = 0; i < pages.length; i++)
                          AnimatedContainer(
                            duration: Motion.fast,
                            width: i == current ? 14 : 6,
                            height: 6,
                            margin: const EdgeInsets.symmetric(horizontal: 2),
                            decoration: BoxDecoration(
                              color: i == current
                                  ? theme.colorScheme.primary
                                  : theme.colorScheme.outlineVariant,
                              borderRadius: BorderRadius.circular(Radii.small),
                            ),
                          ),
                      ],
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Fades the bottom of a card cut off by its cap, so content running just
/// past it reads as scrollable rather than as a card missing its padding.
Widget _fadeIfClipped(bool clipped, Widget child) {
  if (!clipped) return child;
  return ShaderMask(
    blendMode: BlendMode.dstIn,
    shaderCallback: (rect) => LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: const [Colors.black, Colors.black, Colors.transparent],
      stops: [0, 1 - 28 / rect.height.clamp(28, double.infinity), 1],
    ).createShader(rect),
    child: child,
  );
}

/// Reports its child's laid-out size.
class _MeasureSize extends SingleChildRenderObjectWidget {
  const _MeasureSize({required this.onSize, required super.child});

  final ValueChanged<Size> onSize;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderMeasureSize(onSize);

  @override
  void updateRenderObject(BuildContext context, _RenderMeasureSize render) =>
      render.onSize = onSize;
}

class _RenderMeasureSize extends RenderProxyBox {
  _RenderMeasureSize(this.onSize);

  ValueChanged<Size> onSize;

  @override
  void performLayout() {
    super.performLayout();
    onSize(size);
  }
}

/// The cards' opaque rounded backing in the chrome's tone, without an
/// outline like the island.
Widget _cardSurface(
  BuildContext context, {
  required bool carryInk,
  required Widget child,
}) {
  final theme = Theme.of(context);
  child = Stack(
    children: [
      child,
      Positioned.fill(
        child: IgnorePointer(child: _CarriedInk(active: carryInk)),
      ),
    ],
  );
  return Material(
    // The top bar's color, so the cards read as part of the chrome.
    color: theme.colorScheme.surfaceContainer,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(Radii.medium),
    ),
    clipBehavior: Clip.antiAlias,
    child: child,
  );
}

/// The tap that swapped this card in: the tapped card's ripple dies with
/// it, so the new card picks the press up as a fading splash.
class _CarriedInk extends StatefulWidget {
  const _CarriedInk({required this.active});

  /// Read once, on mount.
  final bool active;

  @override
  State<_CarriedInk> createState() => _CarriedInkState();
}

class _CarriedInkState extends State<_CarriedInk>
    with SingleTickerProviderStateMixin {
  late final _fade = AnimationController(
    vsync: this,
    duration: Motion.slow,
    value: widget.active ? 1 : 0,
  );

  @override
  void initState() {
    super.initState();
    if (widget.active) _fade.animateTo(0, curve: Motion.enter);
  }

  @override
  void dispose() {
    _fade.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
    opacity: _fade,
    child: ColoredBox(color: Theme.of(context).splashColor),
  );
}

/// Collapsed cutout: one row previewing the card that was showing (the
/// pin's message, or [icon] and [label]) and a restore button. A tap
/// anywhere restores.
class ChatWidgetMinimizedBar extends StatelessWidget {
  const ChatWidgetMinimizedBar({
    super.key,
    required this.label,
    required this.icon,
    required this.onRestore,
    this.pin,
    this.emotes,
    this.paints,
    this.carryInk = false,
  });

  /// A tap on the cards folded them into this bar; it carries their ink.
  final bool carryInk;

  /// Paints the pin sender's name; null leaves it plain.
  final SevenTvPaintService? paints;

  /// The trigger plus its inset above and below, so it sits centered.
  static const double height = _inset + _controlSize + _inset;

  final String Function(AppLocalizations) label;
  final IconData icon;
  final VoidCallback onRestore;
  final PinnedMessageEvent? pin;
  final EmoteLookupSource? emotes;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: _bottomGap),
      child: SizedBox(
        height: height,
        child: _cardSurface(
          context,
          carryInk: carryInk,
          child: InkWell(
            onTap: onRestore,
            child: SizedBox(
              height: height,
              child: Row(
                children: [
                  const SizedBox(width: 12),
                  Icon(
                    pin == null ? icon : Icons.push_pin_outlined,
                    size: 16,
                    color: pin == null
                        ? theme.colorScheme.primary
                        : theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: switch (pin) {
                      final pin? => PinnedMessageText(
                        event: pin,
                        emotes: emotes,
                        paints: paints,
                        style: theme.textTheme.bodyMedium,
                        maxLines: 1,
                      ),
                      null => Text(
                        label(context.l10n),
                        style: theme.textTheme.labelMedium,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    },
                  ),
                  IconButton(
                    icon: const Icon(Icons.keyboard_arrow_up, size: 20),
                    tooltip: context.l10n.restore,
                    style: _controlStyle,
                    onPressed: onRestore,
                  ),
                  const SizedBox(width: _controlRight),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
