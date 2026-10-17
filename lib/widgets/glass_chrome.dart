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

// Compact header height: status bar plus the merged tab strip, which
// carries the app bar actions, so there is no app bar row.
double glassCompactHeaderHeight(BuildContext context) =>
    statusBarHeight(context) + kGlassTabStripHeight;

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
    required super.child,
  });

  final double bottomClearance;

  /// Extra bottom padding the scrolling lists add on top of [bottomClearance]
  /// without moving the scroll-down button. Used for overlays that float above
  /// the composer, like the reply header.
  final double listExtra;

  static GlassChromeScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<GlassChromeScope>();

  @override
  bool updateShouldNotify(GlassChromeScope oldWidget) =>
      bottomClearance != oldWidget.bottomClearance ||
      listExtra != oldWidget.listExtra;
}

/// [base] plus the pill clearance, for plain lists in the chat body (panels,
/// mod view) so their last rows scroll clear of the composer like ChatView's.
EdgeInsets glassListPadding(
  BuildContext context, [
  EdgeInsets base = EdgeInsets.zero,
]) {
  final scope = GlassChromeScope.maybeOf(context);
  final extra = (scope?.bottomClearance ?? 0) + (scope?.listExtra ?? 0);
  return base.copyWith(bottom: base.bottom + extra);
}

/// Glass drawn as a background layer behind [child].
class GlassSurface extends StatelessWidget {
  const GlassSurface({
    super.key,
    required this.shape,
    this.settings,
    this.quality = GlassQuality.premium,
    required this.child,
  });

  final LiquidShape shape;
  final LiquidGlassSettings? settings;

  /// Minimal is a plain frosted blur; it needs no own layer.
  final GlassQuality quality;
  final Widget child;

  @override
  Widget build(BuildContext context) => Stack(
    children: [
      Positioned.fill(
        child: GlassContainer(
          quality: quality,
          settings: settings,
          useOwnLayer: quality != GlassQuality.minimal,
          shape: shape,
          child: const SizedBox.expand(),
        ),
      ),
      child,
    ],
  );
}

// Styled glass: thickness refracts rows scrolling underneath so light
// warps at the edges, fresnel plus specular draws the bright rim.
// Premium is the fidelity tier; both surfaces are fixed overlays (never
// list children), which is its sanctioned use.
/// Header glass, brightness-aware: a neutral tint whose alpha is the
/// opacity lever on the premium path. (standardOpacityMultiplier is
/// standard-path only and does nothing here, so it stays unset.)
LiquidGlassSettings _barSettings(bool dark, double visibility) =>
    LiquidGlassSettings(
      thickness: 34,
      // Low blur and a light tint keep the rows under the rim legible as
      // bent rows, the refraction real glass shows.
      blur: 4,
      refractiveIndex: 1.5,
      chromaticAberration: 0.02,
      lightIntensity: 0.6,
      fresnelStrength: 1.5,
      glassColor: dark ? const Color(0x40000000) : const Color(0x40FFFFFF),
      visibility: visibility,
    );

/// The pill's material, shared by the small chrome tiles.
const kGlassPillSettings = LiquidGlassSettings(
  thickness: 26,
  blur: 3,
  refractiveIndex: 1.5,
  chromaticAberration: 0.02,
  lightIntensity: 0.6,
  fresnelStrength: 1.5,
  // Neutral background passthrough: the 1.5 default boosts whatever shines
  // through the middle. The rim stays untouched (fresnel + specular as is).
  saturation: 1.0,
);

/// Full-bleed header fusing the app bar and the tab strip. The glass
/// extends past the screen on the top and sides (content is counter-padded
/// by the same amount) so only the bottom rim draws across the chat.
///
/// While [hidden] (fullscreen) it slides up and fades out, then goes
/// offstage so it captures no backdrop. The fade runs through the glass's
/// visibility and the content's own opacity, never an opacity above the
/// glass, which would keep it out of a [GlassBackdropGroup].
Widget glassHeaderBar({
  required bool hidden,
  required bool dark,
  required Widget child,
}) => IgnorePointer(
  ignoring: hidden,
  child: TweenAnimationBuilder<double>(
    tween: Tween(end: hidden ? 0 : 1),
    duration: const Duration(milliseconds: 200),
    curve: Curves.easeInOut,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(
        kGlassEdgeBleed,
        kGlassEdgeBleed,
        kGlassEdgeBleed,
        0,
      ),
      child: child,
    ),
    builder: (context, shown, child) => Offstage(
      offstage: shown == 0,
      child: FractionalTranslation(
        translation: Offset(0, shown - 1),
        child: GlassSurface(
          settings: _barSettings(dark, shown),
          shape: const LiquidRoundedSuperellipse(borderRadius: 0),
          child: Opacity(opacity: shown, child: child),
        ),
      ),
    ),
  ),
);

// Floating composer pill.
Widget glassPill({required Widget child}) => GlassSurface(
  settings: kGlassPillSettings,
  shape: const LiquidRoundedSuperellipse(borderRadius: kGlassComposerRadius),
  child: child,
);

// Floating broadcast cards (pins, polls, predictions) over the chat.
Widget glassCard({required Widget child}) => GlassSurface(
  settings: kGlassPillSettings,
  shape: const LiquidRoundedSuperellipse(borderRadius: 12),
  child: child,
);

// Focus glow for the composer. The opaque field gets the framework focus
// ring, but the borderless glass field has no outline to tint, so this
// rings the shell (the pill, or the docked bar) in primary with a soft halo
// while any inner field holds focus. Disabled, it adds nothing to layout.
class ComposerFocusGlow extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return Focus(
      // Observes the inner fields only; never a traversal stop itself.
      skipTraversal: true,
      // Reads focus on build rather than on change, so a field that arrives
      // already focused (the pill hand-off) lights the new shell at once.
      child: Builder(
        builder: (context) {
          final lit = enabled && Focus.of(context).hasFocus;
          return AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
            // The border stays while enabled so focus never shifts layout.
            decoration: enabled
                ? BoxDecoration(
                    borderRadius: BorderRadius.circular(radius),
                    border: Border.all(
                      color: primary.withValues(alpha: lit ? 0.45 : 0),
                    ),
                    boxShadow: lit
                        ? [
                            BoxShadow(
                              color: primary.withValues(alpha: 0.04),
                              blurRadius: 8,
                              spreadRadius: 1,
                            ),
                          ]
                        : const [],
                  )
                : null,
            child: child,
          );
        },
      ),
    );
  }
}
