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

double contrast(Color a, Color b) {
  final l1 = luminance(a);
  final l2 = luminance(b);
  return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05);
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
    if (lightness > 0.4 &&
        huePercentage >= 0.1 &&
        huePercentage <= 0.33333) {
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
