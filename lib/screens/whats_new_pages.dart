import 'dart:io' show Platform;

import '../l10n/app_localizations.dart';

/// One page of an update's showcase: a looping animation (an animated WebP
/// under assets/whats_new/) with a title and a line about the feature.
class ShowcasePage {
  const ShowcasePage({
    required this.asset,
    required this.title,
    required this.body,
    this.iosOnly = false,
  });

  final String asset;
  final String Function(AppLocalizations l) title;
  final String Function(AppLocalizations l) body;
  final bool iosOnly;
}

/// Showcases by minor version: updating into a new minor shows its pages
/// once, and patch releases only get the changelog.
final _showcases = <String, List<ShowcasePage>>{
  '0.10': [
    ShowcasePage(
      asset: 'assets/whats_new/0.10/history.webp',
      title: (l) => l.showcaseHistoryTitle,
      body: (l) => l.showcaseHistoryBody,
    ),
    ShowcasePage(
      asset: 'assets/whats_new/0.10/search.webp',
      title: (l) => l.showcaseSearchTitle,
      body: (l) => l.showcaseSearchBody,
    ),
    ShowcasePage(
      asset: 'assets/whats_new/0.10/vods.webp',
      title: (l) => l.showcaseVodsTitle,
      body: (l) => l.showcaseVodsBody,
    ),
    ShowcasePage(
      asset: 'assets/whats_new/0.10/island.webp',
      title: (l) => l.showcaseIslandTitle,
      body: (l) => l.showcaseIslandBody,
    ),
    ShowcasePage(
      asset: 'assets/whats_new/0.10/spam.webp',
      title: (l) => l.showcaseSpamTitle,
      body: (l) => l.showcaseSpamBody,
    ),
    ShowcasePage(
      asset: 'assets/whats_new/0.10/push.webp',
      title: (l) => l.showcasePushTitle,
      body: (l) => l.showcasePushBody,
      iosOnly: true,
    ),
  ],
};

String _minor(String version) => version.split('.').take(2).join('.');

/// The pages to show after updating from [from] to [current], or null for
/// none. [from] is empty when the dev arm fired, which replays the current
/// showcase.
List<ShowcasePage>? showcaseFor(String current, String from) {
  if (from.isNotEmpty && _minor(from) == _minor(current)) return null;
  final pages = [
    for (final p in _showcases[_minor(current)] ?? const <ShowcasePage>[])
      if (!p.iosOnly || Platform.isIOS) p,
  ];
  return pages.isEmpty ? null : pages;
}
