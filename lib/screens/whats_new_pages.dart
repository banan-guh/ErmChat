import 'dart:io' show Platform;

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';

import '../services/app_updates.dart';

/// One page of an update's showcase: a title, a few lines and optional art.
/// English only: the screen shows once per minor version, so it skips the
/// translation pass.
class ShowcasePage {
  const ShowcasePage({
    required this.title,
    required this.body,
    this.art = const [],
    this.items = const [],
    this.aspect = 9 / 10,
    this.iosOnly = false,
  });

  final String title;
  final String body;

  /// Image URLs on the minor's GitHub release. Several stills crossfade in
  /// turn; one may be an animated WebP.
  final List<String> art;

  /// Smaller features listed under the body, one line each.
  final List<(IconData, String)> items;

  /// The art's width over its height.
  final double aspect;
  final bool iosOnly;
}

// Art lives on the minor's first release, beside the APKs, so it never
// weighs on the app or the repo.
List<String> _art(String minor, List<String> names) => [
  for (final n in names) AppUpdates.releaseAsset('v$minor.0', 'whatsnew-$n'),
];

/// Showcases by minor version: updating into a new minor shows its pages
/// once, and patch releases only get the changelog.
final _showcases = <String, List<ShowcasePage>>{
  '0.10': [
    ShowcasePage(
      title: 'Endless chat archive',
      body:
          'Every channel keeps 30 days of chat on your phone. Scroll back as '
          'far as you like, or open the calendar to jump to any day and keep '
          'the ones you want.',
      art: _art('0.10', ['history.webp']),
      aspect: 1080 / 1250,
    ),
    ShowcasePage(
      title: 'VODs with chat',
      body: 'Watch a past stream with live chat playback (if recorded).',
      art: _art('0.10', ['vods.webp']),
      aspect: 1080 / 700,
    ),
    ShowcasePage(
      title: 'Your layout',
      body: 'Pick a theme, or build your own.',
      art: _art('0.10', [
        'layout_ermchat.webp',
        'layout_dankchat3.webp',
        'layout_dankchat4.webp',
      ]),
    ),
    ShowcasePage(
      title: 'Also new',
      body: 'Smaller things in this update.',
      items: [
        (
          Icons.manage_search,
          'New "user:" keyword! Find messages from a user across the entire '
              'archive.',
        ),
        (Icons.import_export, 'Export and import your settings'),
        (Icons.image_outlined, 'Paste images from the keyboard to upload'),
        (Icons.delete_outline, 'Mods delete messages from the message menu'),
        (Icons.repeat, 'Spam send: hold send, then hold the spam button'),
        (Icons.restore, 'Reopen last active channel'),
      ],
    ),
  ],
};

/// When each showcase stops: a few days after its release, when its art
/// comes off the release. Later updaters get the changelog alone.
final _showcaseEnds = <String, DateTime>{'0.10': DateTime(2026, 10, 26)};

String _minor(String version) => version.split('.').take(2).join('.');

/// The pages to show after updating from [from] to [current], or null for
/// none. [from] is empty when the dev arm fired, which replays the current
/// showcase, or the newest one while its version is unreleased, past its
/// end date too.
List<ShowcasePage>? showcaseFor(String current, String from, {DateTime? now}) {
  if (from.isNotEmpty) {
    if (_minor(from) == _minor(current)) return null;
    final end = _showcaseEnds[_minor(current)];
    if (end != null && !(now ?? clock.now()).isBefore(end)) return null;
  }
  final source =
      _showcases[_minor(current)] ??
      (from.isEmpty ? _showcases.values.lastOrNull : null);
  final pages = [
    for (final p in source ?? const <ShowcasePage>[])
      if (!p.iosOnly || Platform.isIOS) p,
  ];
  return pages.isEmpty ? null : pages;
}
