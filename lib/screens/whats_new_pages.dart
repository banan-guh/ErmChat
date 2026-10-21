import 'dart:io' show Platform;

import '../services/app_updates.dart';

/// One page of an update's showcase: a title, a few lines and optional art.
/// English only: the screen shows once per minor version, so it skips the
/// translation pass.
class ShowcasePage {
  const ShowcasePage({
    required this.title,
    required this.body,
    this.art = const [],
    this.aspect = 9 / 10,
    this.iosOnly = false,
  });

  final String title;
  final String body;

  /// Image URLs on the minor's GitHub release. Several stills crossfade in
  /// turn; one may be an animated WebP.
  final List<String> art;

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
      title: 'A month of chat',
      body:
          'Every channel keeps 30 days of chat on your phone. Scroll back as '
          'far as you like, or open the calendar to jump to any day and keep '
          'the ones you want.',
      art: _art('0.10', ['history.webp']),
      aspect: 1080 / 1250,
    ),
    ShowcasePage(
      title: 'VODs with chat',
      body:
          'Watch a past stream with its chat replaying as it happened, and '
          'switch back to live chat any time.',
      art: _art('0.10', ['vods.webp']),
      aspect: 1080 / 700,
    ),
    ShowcasePage(
      title: 'Your layout',
      body:
          'Pick a chrome theme, move any button where you want it, or build '
          'your own. Edit the layout in place from the ⋮ menu.',
      art: _art('0.10', [
        'layout_ermchat.webp',
        'layout_dankchat3.webp',
        'layout_dankchat4.webp',
      ]),
    ),
    ShowcasePage(
      title: 'Spam send',
      body:
          'Hold send, then hold the spam button to repeat your message. Turn '
          'it on in Chat settings.',
    ),
    ShowcasePage(
      title: 'Mentions while closed',
      body: 'Get notified when someone mentions you, even with the app closed.',
      iosOnly: true,
    ),
    ShowcasePage(
      title: 'Also new',
      body:
          '• Search reaches a channel\'s whole history. user:name finds '
          'someone\'s messages and mod actions\n'
          '• Drag highlight rules to set their priority\n'
          '• Pause notifications from the moon button\n'
          '• Export and import your settings\n'
          '• Paste images from the keyboard to upload them\n'
          '• Personal 7TV emotes and BTTV badges\n'
          '• Mods delete messages from the message menu\n'
          '• A characters-left counter near the limit\n'
          '• Chat font weight and a haptics toggle\n'
          '• Reopen the last channel on launch',
    ),
  ],
};

String _minor(String version) => version.split('.').take(2).join('.');

/// The pages to show after updating from [from] to [current], or null for
/// none. [from] is empty when the dev arm fired, which replays the current
/// showcase, or the newest one while its version is unreleased.
List<ShowcasePage>? showcaseFor(String current, String from) {
  if (from.isNotEmpty && _minor(from) == _minor(current)) return null;
  final source =
      _showcases[_minor(current)] ??
      (from.isEmpty ? _showcases.values.lastOrNull : null);
  final pages = [
    for (final p in source ?? const <ShowcasePage>[])
      if (!p.iosOnly || Platform.isIOS) p,
  ];
  return pages.isEmpty ? null : pages;
}
