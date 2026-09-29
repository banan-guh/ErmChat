import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../util/insets.dart';

// Shared metrics and builders for the liquid glass chrome. The header block
// fuses the app bar and the channel tab strip, so both layers derive its
// height from the same formula and the chat list pads by the same amount.
const double kGlassAppBarHeight = 48.0;
const double kGlassTabStripHeight = 40.0;
const double kGlassComposerMargin = 6.0;
const double kGlassComposerRadius = 20.0;

// Gap the list keeps above the in-flow composer when the glass pill is off.
const double kOpaqueComposerGap = 4.0;

// Full overlay header height: status bar plus app bar row plus tab strip.
double glassHeaderHeight(BuildContext context) =>
    statusBarHeight(context) + kGlassAppBarHeight + kGlassTabStripHeight;

// Welcome overlay header height: status bar plus app bar row only. With no
// channels there is no tab strip, so the glass card holds the app bar alone
// and the welcome list pads by this shorter amount.
double glassWelcomeHeaderHeight(BuildContext context) =>
    statusBarHeight(context) + kGlassAppBarHeight;

// Pill footprint the list clears; the caller includes the safe area, so this is just the gap.
double glassComposerOverlayHeight(double composerH) =>
    composerH + kGlassComposerMargin;

// How far the header glass bleeds past the screen on the top and sides.
// The rim follows the shape boundary, so pushing three boundaries
// off-screen leaves only the bottom rim visible across the chat.
const double kGlassEdgeBleed = 32.0;

// Glass stays off under high contrast; callers fall back to opaque chrome.
bool glassEnabled(BuildContext context, bool flag) =>
    flag && !MediaQuery.highContrastOf(context);

// Bottom clearance the scrolling lists keep above the composer pill.
// Provided by ChatBody around the body stack so every ChatView (main pages,
// welcome, panels) clears the pill without hand-threaded params. Zero when
// the pill is off, so the opaque theme renders exactly as before.
class GlassChromeScope extends InheritedWidget {
  const GlassChromeScope({
    super.key,
    required this.bottomClearance,
    this.listExtra = 0,
    this.freeze,
    required super.child,
  });

  final double bottomClearance;

  /// Non-null while the keyboard animates. Glass surfaces paint their crop
  /// of the snapshot instead of a live backdrop (see [GlassSurface]).
  final ValueListenable<GlassFreeze?>? freeze;

  /// Extra bottom padding the scrolling lists add on top of [bottomClearance]
  /// without moving the scroll-down button. Used for overlays that float above
  /// the composer, like the reply header.
  final double listExtra;

  static GlassChromeScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<GlassChromeScope>();

  /// The freeze signal, without subscribing to clearance changes.
  static ValueListenable<GlassFreeze?>? freezeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<GlassChromeScope>()?.freeze;

  @override
  bool updateShouldNotify(GlassChromeScope oldWidget) =>
      bottomClearance != oldWidget.bottomClearance ||
      listExtra != oldWidget.listExtra ||
      freeze != oldWidget.freeze;
}

/// Snapshot of the chrome's boundary, taken on the last live frame.
class GlassFreeze {
  const GlassFreeze(this.image, this.boundary, this.pixelRatio);

  final ui.Image image;
  final RenderBox boundary;
  final double pixelRatio;
}

/// Glass drawn as a background layer behind [child].
///
/// A live backdrop makes the GPU copy everything under it every frame, and
/// the keyboard animation moves the whole chat under the glass. While the
/// scope holds a [GlassFreeze], the surface paints its crop of that snapshot
/// instead, then fades it out over the live glass once the freeze lifts.
class GlassSurface extends StatefulWidget {
  const GlassSurface({
    super.key,
    required this.shape,
    this.settings,
    required this.child,
  });

  final LiquidShape shape;
  final LiquidGlassSettings? settings;
  final Widget child;

  @override
  State<GlassSurface> createState() => _GlassSurfaceState();
}

class _GlassSurfaceState extends State<GlassSurface>
    with SingleTickerProviderStateMixin {
  ValueListenable<GlassFreeze?>? _freeze;
  GlassFreeze? _shown;
  Rect? _src;
  late final _fade = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
  )..addStatusListener(_onFadeStatus);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final freeze = GlassChromeScope.freezeOf(context);
    if (freeze == _freeze) return;
    _freeze?.removeListener(_onFreeze);
    _freeze = freeze?..addListener(_onFreeze);
  }

  @override
  void dispose() {
    _freeze?.removeListener(_onFreeze);
    _fade.dispose();
    super.dispose();
  }

  // Runs before the next layout, so this box still sits where the snapshot
  // saw it.
  void _onFreeze() {
    final f = _freeze!.value;
    if (f == null) {
      if (_shown != null) _fade.reverse(from: 1);
      setState(() {});
      return;
    }
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize || !f.boundary.attached) return;
    _src = box.localToGlobal(Offset.zero, ancestor: f.boundary) & box.size;
    _shown = f;
    _fade.value = 1;
    setState(() {});
  }

  void _onFadeStatus(AnimationStatus status) {
    if (status == AnimationStatus.dismissed && mounted) {
      setState(() => _shown = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final shown = _shown;
    final frozen = shown != null && _freeze?.value == shown;
    return Stack(
      children: [
        Positioned.fill(
          child: Offstage(
            offstage: frozen,
            child: GlassContainer(
              quality: GlassQuality.premium,
              settings: widget.settings,
              useOwnLayer: true,
              shape: widget.shape,
              child: const SizedBox.expand(),
            ),
          ),
        ),
        Positioned.fill(
          child: IgnorePointer(
            child: CustomPaint(
              painter: shown == null
                  ? null
                  : _FrozenGlassPainter(shown, _src!, widget.shape, _fade),
            ),
          ),
        ),
        widget.child,
      ],
    );
  }
}

class _FrozenGlassPainter extends CustomPainter {
  _FrozenGlassPainter(this.freeze, this.src, this.shape, this.opacity)
    : super(repaint: opacity);

  final GlassFreeze freeze;
  final Rect src;
  final LiquidShape shape;
  final Animation<double> opacity;

  @override
  void paint(Canvas canvas, Size size) {
    final pr = freeze.pixelRatio;
    final image = freeze.image;
    final s = src.intersect(
      Rect.fromLTWH(0, 0, image.width / pr, image.height / pr),
    );
    if (s.isEmpty) return;
    canvas.save();
    canvas.clipPath(shape.getOuterPath(Offset.zero & size));
    canvas.drawImageRect(
      image,
      Rect.fromLTRB(s.left * pr, s.top * pr, s.right * pr, s.bottom * pr),
      s.shift(-src.topLeft),
      Paint()..color = Color.fromRGBO(0, 0, 0, opacity.value),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_FrozenGlassPainter old) =>
      freeze != old.freeze || src != old.src || shape != old.shape;
}

// Styled glass: thickness refracts rows scrolling underneath so light
// warps at the edges, fresnel plus specular draws the bright rim.
// Premium is the fidelity tier; both surfaces are fixed overlays (never
// list children), which is its sanctioned use.
/// Header glass, brightness-aware: a neutral tint whose alpha is the
/// opacity lever on the premium path. (standardOpacityMultiplier is
/// standard-path only and does nothing here, so it stays unset.)
LiquidGlassSettings _barSettings(bool dark) => LiquidGlassSettings(
  thickness: 28,
  blur: 12,
  lightIntensity: 0.1,
  fresnelStrength: 1.5,
  glassColor: dark ? const Color(0x59000000) : const Color(0x59FFFFFF),
);

const _pillSettings = LiquidGlassSettings(
  thickness: 22,
  blur: 10,
  lightIntensity: 0.1,
  fresnelStrength: 1.5,
  // Neutral background passthrough: the 1.5 default boosts whatever shines
  // through the middle. The rim stays untouched (fresnel + specular as is).
  saturation: 1.0,
);

// Full-bleed header fusing the app bar and the tab strip. The container
// extends past the screen on the top and sides (content is counter-padded
// by the same amount) so only the bottom rim draws across the chat.
Widget glassBar({required Widget child, required bool dark}) => GlassSurface(
  settings: _barSettings(dark),
  shape: const LiquidRoundedSuperellipse(borderRadius: 0),
  child: Padding(
    padding: const EdgeInsets.fromLTRB(
      kGlassEdgeBleed,
      kGlassEdgeBleed,
      kGlassEdgeBleed,
      0,
    ),
    child: child,
  ),
);

// Floating composer pill.
Widget glassPill({required Widget child}) => GlassSurface(
  settings: _pillSettings,
  shape: const LiquidRoundedSuperellipse(borderRadius: kGlassComposerRadius),
  child: child,
);

// Focus glow for the composer. The opaque field gets the framework focus
// ring, but the borderless glass field has no outline to tint, so this
// paints a primary outline while any inner field holds focus. It rides with
// the composer across the pill and docked paths, and paints as a foreground
// so it never changes the composer's size.
class ComposerFocusGlow extends StatefulWidget {
  const ComposerFocusGlow({
    super.key,
    required this.enabled,
    required this.radius,
    required this.child,
  });

  final bool enabled;
  final double radius;
  final Widget child;

  @override
  State<ComposerFocusGlow> createState() => _ComposerFocusGlowState();
}

class _ComposerFocusGlowState extends State<ComposerFocusGlow> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    final lit = widget.enabled && _focused;
    return Focus(
      // Observes the inner fields only; never a traversal stop itself.
      skipTraversal: true,
      onFocusChange: (v) {
        if (v != _focused) setState(() => _focused = v);
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
        foregroundDecoration: BoxDecoration(
          borderRadius: BorderRadius.circular(widget.radius),
          border: Border.all(color: primary.withValues(alpha: lit ? 0.45 : 0)),
        ),
        child: widget.child,
      ),
    );
  }
}
