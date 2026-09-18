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

// Styled glass: thickness refracts rows scrolling underneath so light
// warps at the edges, fresnel plus specular draws the bright rim.
// Premium is the fidelity tier; both surfaces are fixed overlays (never
// list children), which is its sanctioned use.
const _barSettings = LiquidGlassSettings(
  thickness: 28,
  blur: 8,
  lightIntensity: 0.7,
  fresnelStrength: 1.5,
);

const _pillSettings = LiquidGlassSettings(
  thickness: 30,
  blur: 10,
  lightIntensity: 0.8,
  fresnelStrength: 1.5,
);

// Full-bleed header fusing the app bar and the tab strip. The container
// extends past the screen on the top and sides (content is counter-padded
// by the same amount) so only the bottom rim draws across the chat.
Widget glassBar({required Widget child}) => GlassContainer(
  quality: GlassQuality.premium,
  settings: _barSettings,
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
