import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

// Shared metrics and builders for the liquid glass spike. The header block
// fuses the app bar and the channel tab strip, so both layers derive its
// height from the same formula and the chat list pads by the same amount.
const double kGlassAppBarHeight = 48.0;
const double kGlassTabStripHeight = 40.0;
const double kGlassComposerMargin = 6.0;
const double kGlassComposerRadius = 20.0;

// Full overlay header height: status bar plus app bar row plus tab strip.
double glassHeaderHeight(BuildContext context) =>
    MediaQuery.paddingOf(context).top +
    kGlassAppBarHeight +
    kGlassTabStripHeight;

// Welcome overlay header height: status bar plus app bar row only. With no
// channels there is no tab strip, so the glass card holds the app bar alone
// and the welcome list pads by this shorter amount.
double glassWelcomeHeaderHeight(BuildContext context) =>
    MediaQuery.paddingOf(context).top + kGlassAppBarHeight;

// Pill footprint the chat list must clear. The measured composer height
// already includes the pill outer padding (inputBarKey sits on it), so
// only a small breathing gap is added. Adding bottomPad again here double
// counts it and leaves a dead gap above the pill.
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
    required super.child,
  });

  final double bottomClearance;

  static GlassChromeScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<GlassChromeScope>();

  @override
  bool updateShouldNotify(GlassChromeScope oldWidget) =>
      bottomClearance != oldWidget.bottomClearance;
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
Widget glassBar({required Widget child, required bool dark}) => GlassContainer(
  quality: GlassQuality.premium,
  settings: _barSettings(dark),
  useOwnLayer: true,
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
Widget glassPill({required Widget child}) => GlassContainer(
  quality: GlassQuality.premium,
  settings: _pillSettings,
  useOwnLayer: true,
  shape: const LiquidRoundedSuperellipse(borderRadius: kGlassComposerRadius),
  child: child,
);

// Focus glow for the floating composer pill. The opaque field gets the
// framework focus ring, but the borderless glass field has no outline to
// tint, so the pill itself shows a soft primary halo while any inner field
// holds focus. Opaque chrome never builds this.
class PillFocusGlow extends StatefulWidget {
  const PillFocusGlow({super.key, required this.child});

  final Widget child;

  @override
  State<PillFocusGlow> createState() => _PillFocusGlowState();
}

class _PillFocusGlowState extends State<PillFocusGlow> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return Focus(
      // Observes the inner fields only; never a traversal stop itself.
      skipTraversal: true,
      onFocusChange: (v) {
        if (v != _focused) setState(() => _focused = v);
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(kGlassComposerRadius),
          border: Border.all(
            color: primary.withValues(alpha: _focused ? 0.45 : 0),
          ),
          boxShadow: _focused
              ? [
                  BoxShadow(
                    color: primary.withValues(alpha: 0.04),
                    blurRadius: 8,
                    spreadRadius: 1,
                  ),
                ]
              : const [],
        ),
        child: widget.child,
      ),
    );
  }
}
