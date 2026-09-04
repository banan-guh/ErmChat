import 'dart:math';
import 'package:flutter/material.dart';

const officialColors = [
  '#FF0000',
  '#0000FF',
  '#008000',
  '#B22222',
  '#FF7F50',
  '#9ACD32',
  '#FF4500',
  '#2E8B57',
  '#DAA520',
  '#D2691E',
  '#5F9EA0',
  '#1E90FF',
  '#FF69B4',
  '#8A2BE2',
  '#00FF7F',
];

/// Announcement banner colors mapped from msg-param-color tag values.
/// PRIMARY/PURPLE is muted toward dankchat sub purple (S~0.47): same hue
/// at 60% saturation so row tints stay calm after contrast equalization.
const announcementColors = <String, Color>{
  'PRIMARY': Color(0xFF7C47D1),
  'BLUE': Color(0xFF1F69FF),
  'GREEN': Color(0xFF00C853),
  'ORANGE': Color(0xFFFF6F00),
  'PURPLE': Color(0xFF7C47D1),
};

/// Banner color for a msg-param-color value, or null if unknown.
Color? announcementColorFor(String? value) {
  if (value == null) return null;
  return announcementColors[value.toUpperCase()];
}

String pickColor(String username) {
  final hash = username.codeUnits.fold(0, (h, c) => h * 31 + c);
  return officialColors[hash.abs() % officialColors.length];
}

Color? parseColor(String? color, {Color? background}) {
  if (color == null || color.length != 7 || !color.startsWith('#')) return null;
  final value = int.tryParse(color.replaceFirst('#', '0xff'));
  if (value == null) return null;
  final c = Color(value);
  if (background == null) return c;
  return normalizeColor(c, background);
}

double luminance(Color c) {
  double r = c.r;
  double g = c.g;
  double b = c.b;
  r = r <= 0.03928 ? r / 12.92 : (pow((r + 0.055) / 1.055, 2.4) as double);
  g = g <= 0.03928 ? g / 12.92 : (pow((g + 0.055) / 1.055, 2.4) as double);
  b = b <= 0.03928 ? b / 12.92 : (pow((b + 0.055) / 1.055, 2.4) as double);
  return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}

Color normalizeColor(Color color, Color background) {
  final hsl = HSLColor.fromColor(color);
  final hue = hsl.hue;
  final saturation = hsl.saturation;
  double lightness = hsl.lightness;

  final isLight = luminance(background) > 0.5;
  final huePercentage = hue / 360.0;

  if (isLight) {
    if (lightness > 0.5) {
      lightness = 0.5;
    }
    if (lightness > 0.4 && huePercentage >= 0.1 && huePercentage <= 0.33333) {
      lightness -=
          sin((huePercentage - 0.1) / (0.33333 - 0.1) * pi) * saturation * 0.4;
    }
  } else {
    if (lightness < 0.5) {
      lightness = 0.5;
    }
    if (lightness < 0.6 &&
        huePercentage >= 0.54444 &&
        huePercentage <= 0.83333) {
      lightness +=
          sin((huePercentage - 0.54444) / (0.83333 - 0.54444) * pi) *
          saturation *
          0.4;
    }
  }

  lightness = lightness.clamp(0.0, 1.0);
  return HSLColor.fromAHSL(1, hue, saturation, lightness).toColor();
}

/// Shift [color]'s HSL lightness so its blended luminance distance from
/// [surface] matches [anchor]'s. Equalizes perceived contrast across hues
/// (the highlight-tint analogue of [normalizeColor] for text). Hue and
/// saturation are preserved; only lightness moves.
/// Perceptual brightness of [c] in 0..1. Unlike linear [luminance] (which
/// over-weights green and makes reds/purples look brighter than they measure),
/// this sqrt-weighted metric tracks how bright a hue actually reads, so a
/// saturated red or purple is scored as bright as it looks.
double brightness(Color c) {
  final r = c.r;
  final g = c.g;
  final b = c.b;
  return sqrt(0.299 * r * r + 0.587 * g * g + 0.114 * b * b);
}

/// Global strength of equalized highlight tints. The anchor hue is lifted to
/// this fraction of its natural contrast so highlights read evenly without
/// blowing out at high opacity.
const highlightStrength = 0.8;

Color matchTintContrast(
  Color color,
  Color surface,
  Color anchor, {
  double strength = highlightStrength,
}) {
  assert(strength > 0 && strength <= 1, 'strength must be in (0, 1]');
  final bgLum = brightness(surface);
  final target = (brightness(anchor) - bgLum).abs() * strength;
  if (target <= 1e-4) return color;

  final hsl = HSLColor.fromColor(color);
  final hue = hsl.hue;
  final saturation = hsl.saturation;
  // On a light background, more contrast means a darker tint; on a dark
  // background, a lighter tint.
  final lightenForContrast = bgLum < 0.5;

  double lo = 0.0;
  double hi = 1.0;
  Color best = color;
  for (var i = 0; i < 16; i++) {
    final mid = (lo + hi) / 2;
    final candidate = HSLColor.fromAHSL(1, hue, saturation, mid).toColor();
    final delta = (brightness(candidate) - bgLum).abs();
    best = candidate;
    if ((delta - target).abs() < 1e-4) break;
    if (delta < target) {
      // Need more contrast: move lightness toward the contrast-increasing end.
      if (lightenForContrast) {
        lo = mid;
      } else {
        hi = mid;
      }
    } else {
      if (lightenForContrast) {
        hi = mid;
      } else {
        lo = mid;
      }
    }
  }
  return best;
}

/// Built-in highlight palette, dark then light themes. Order:
/// mention/red, redemption/teal, elevated/gold, first-message/green.
const highlightPaletteDark = <Color>[
  Color(0xFF8C3A3B),
  Color(0xFF00606B),
  Color(0xFF6B5800),
  Color(0xFF3A6600),
];
const highlightPaletteLight = <Color>[
  Color(0xFFCF5050),
  Color(0xFF458B93),
  Color(0xFFB08D2A),
  Color(0xFF558B2F),
];

/// Built-in highlight color with the strongest perceived contrast against
/// [surface]. Used as the contrast anchor when equalizing so no highlight is
/// dulled below its natural vividness (everything else is lifted up to it).
Color highlightAnchor(Color surface) {
  final bg = brightness(surface);
  final palette = bg < 0.5 ? highlightPaletteDark : highlightPaletteLight;
  Color best = palette.first;
  var bestDist = (brightness(best) - bg).abs();
  for (final c in palette.skip(1)) {
    final d = (brightness(c) - bg).abs();
    if (d > bestDist) {
      bestDist = d;
      best = c;
    }
  }
  return best;
}
