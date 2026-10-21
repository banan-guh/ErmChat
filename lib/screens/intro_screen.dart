import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../services/twitch_auth.dart';
import 'settings/account_screen.dart';
import 'settings/language_screen.dart';
import 'whats_new_pages.dart';
import '../widgets/design_tokens.dart';

/// First-install introduction: full-screen pages that showcase features.
/// Each page carries its control, untouched unless the user taps it; nothing
/// turns on by itself.
class IntroScreen extends StatefulWidget {
  const IntroScreen({
    super.key,
    required this.twitchAuth,
    required this.onJoinChannel,
    required this.mentionPush,
    required this.onMentionPushChanged,
  });

  final TwitchAuth twitchAuth;
  final ValueChanged<String> onJoinChannel;
  final bool mentionPush;
  final ValueChanged<bool> onMentionPushChanged;

  @override
  State<IntroScreen> createState() => _IntroScreenState();
}

class _IntroScreenState extends State<IntroScreen> {
  static const _pageCount = 4;
  final _pages = PageController();
  final _channel = TextEditingController();
  final _joined = <String>[];
  int _page = 0;
  late bool _mentionPush = widget.mentionPush;

  @override
  void dispose() {
    _pages.dispose();
    _channel.dispose();
    super.dispose();
  }

  void _next() {
    if (_page == _pageCount - 1) {
      Navigator.pop(context);
      return;
    }
    _pages.nextPage(duration: Motion.slow, curve: Motion.enter);
  }

  Future<void> _logIn() async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => AccountScreen(twitchAuth: widget.twitchAuth),
      ),
    );
    if (mounted) setState(() {});
  }

  void _join() {
    final name = _channel.text.trim().replaceFirst('#', '').toLowerCase();
    if (name.isEmpty || _joined.contains(name)) return;
    widget.onJoinChannel(name);
    setState(() => _joined.add(name));
    _channel.clear();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final last = _page == _pageCount - 1;
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 4, 8, 0),
              child: Row(
                children: [
                  // A symbol, so anyone stuck in a language they cannot
                  // read finds it.
                  IconButton(
                    icon: const Icon(Icons.translate),
                    tooltip: l10n.settingLanguage,
                    onPressed: () => Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => const LanguageScreen()),
                    ),
                  ),
                  const Spacer(),
                  if (!last)
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: Text(l10n.introSkip),
                    ),
                ],
              ),
            ),
            Expanded(
              child: PageView(
                controller: _pages,
                onPageChanged: (i) => setState(() => _page = i),
                children: [
                  _IntroPage(
                    title: l10n.introWelcomeTitle,
                    body: l10n.introLoginBody,
                    child: widget.twitchAuth.isConfigured
                        ? Text(
                            l10n.introLoggedIn(widget.twitchAuth.login ?? ''),
                            style: theme.textTheme.titleMedium,
                          )
                        : FilledButton.icon(
                            icon: const Icon(Icons.login),
                            label: Text(l10n.introLogIn),
                            onPressed: _logIn,
                          ),
                  ),
                  _IntroPage(
                    title: l10n.introChannelsTitle,
                    body: l10n.introChannelsBody,
                    child: Column(
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: TextField(
                                controller: _channel,
                                autocorrect: false,
                                textInputAction: TextInputAction.go,
                                onSubmitted: (_) => _join(),
                                decoration: InputDecoration(
                                  hintText: l10n.channelNameHint,
                                  prefixText: '#',
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            FilledButton.tonal(
                              onPressed: _join,
                              child: Text(l10n.join),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            for (final name in _joined)
                              Chip(
                                avatar: const Icon(Icons.check, size: 18),
                                label: Text('#$name'),
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  _IntroPage(
                    title: l10n.introMentionsTitle,
                    body: l10n.introMentionsBody,
                    child: SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(l10n.introMentionPings),
                      value: _mentionPush,
                      onChanged: (v) {
                        setState(() => _mentionPush = v);
                        widget.onMentionPushChanged(v);
                      },
                    ),
                  ),
                  _IntroPage(
                    title: l10n.introEmotesTitle,
                    body: l10n.introEmotesBody,
                    child: const _EmoteTour(),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
              child: Row(
                children: [
                  _PageDots(count: _pageCount, page: _page),
                  const Spacer(),
                  FilledButton(
                    onPressed: _next,
                    child: Text(last ? l10n.introStart : l10n.introNext),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// An update's showcase: one page per new feature, a title and a few lines
/// over its art. Shown once after updating into a new minor version, never
/// on a first install.
class WhatsNewScreen extends StatefulWidget {
  const WhatsNewScreen({super.key, required this.pages, required this.art});

  final List<ShowcasePage> pages;

  /// Art URLs that finished loading. A page missing any of its art shows
  /// only its text.
  final Set<String> art;

  static const _artWait = Duration(seconds: 4);

  /// Loads the pages' art for a few seconds, then opens the screen. Returns
  /// true when the user asks for the full changelog.
  static Future<bool> show(
    BuildContext context,
    List<ShowcasePage> pages,
  ) async {
    final loaded = <String>{}, failed = <String>{};
    await Future.wait([
      for (final url in {for (final p in pages) ...p.art})
        precacheImage(
          NetworkImage(url),
          context,
          onError: (_, _) => failed.add(url),
        ).then((_) {
          if (!failed.contains(url)) loaded.add(url);
        }),
    ]).timeout(_artWait, onTimeout: () => const []);
    if (!context.mounted) return false;
    // Art still loading at the timeout counts as missing.
    final art = {...loaded};
    return await Navigator.push<bool>(
          context,
          MaterialPageRoute(
            fullscreenDialog: true,
            builder: (_) => WhatsNewScreen(pages: pages, art: art),
          ),
        ) ??
        false;
  }

  @override
  State<WhatsNewScreen> createState() => _WhatsNewScreenState();
}

class _WhatsNewScreenState extends State<WhatsNewScreen> {
  // Room a page's title and body take above the animation.
  static const _textRoom = 240.0;

  final _pages = PageController();
  int _page = 0;

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final last = _page == widget.pages.length - 1;
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 4, 8, 0),
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.translate),
                    tooltip: l10n.settingLanguage,
                    onPressed: () => Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => const LanguageScreen()),
                    ),
                  ),
                  const Spacer(),
                  TextButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: Text(l10n.showcaseAllChanges),
                  ),
                ],
              ),
            ),
            Expanded(
              child: PageView(
                controller: _pages,
                onPageChanged: (i) => setState(() => _page = i),
                children: [
                  for (final p in widget.pages)
                    LayoutBuilder(
                      builder: (context, box) {
                        // The art grows with the page up to a cap and leaves
                        // the text its room. Too small to read, it drops and
                        // the page keeps the text.
                        final width = math.min(
                          math.min(box.maxWidth - 48, _Showcase.maxWidth),
                          (box.maxHeight - _textRoom) * p.aspect,
                        );
                        final hasArt =
                            p.art.isNotEmpty && widget.art.containsAll(p.art);
                        return _IntroPage(
                          title: p.title,
                          body: p.body,
                          child: p.items.isNotEmpty
                              ? _FeatureList(items: p.items)
                              : !hasArt || width < _Showcase.minWidth
                              ? const SizedBox.shrink()
                              : Center(
                                  child: _Showcase(
                                    art: p.art,
                                    width: width,
                                    aspect: p.aspect,
                                  ),
                                ),
                        );
                      },
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
              child: Row(
                children: [
                  _PageDots(count: widget.pages.length, page: _page),
                  const Spacer(),
                  FilledButton(
                    onPressed: last
                        ? () => Navigator.pop(context)
                        : () => _pages.nextPage(
                            duration: Motion.slow,
                            curve: Motion.enter,
                          ),
                    child: Text(last ? l10n.showcaseDone : l10n.introNext),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A feature's art: one image, or stills that crossfade in turn.
class _Showcase extends StatefulWidget {
  const _Showcase({
    required this.art,
    required this.width,
    required this.aspect,
  });

  final List<String> art;
  final double width;
  final double aspect;

  static const minWidth = 200.0;
  static const maxWidth = 480.0;

  @override
  State<_Showcase> createState() => _ShowcaseState();
}

class _ShowcaseState extends State<_Showcase> {
  static const _hold = Duration(milliseconds: 2200);
  static const _fade = Duration(milliseconds: 500);

  Timer? _cycle;
  int _shown = 0;

  @override
  void initState() {
    super.initState();
    if (widget.art.length > 1) {
      _cycle = Timer.periodic(_hold, (_) {
        setState(() => _shown = (_shown + 1) % widget.art.length);
      });
    }
  }

  @override
  void dispose() {
    _cycle?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final url = widget.art[_shown];
    return ClipRRect(
      borderRadius: BorderRadius.circular(Radii.large),
      child: SizedBox(
        width: widget.width,
        height: widget.width / widget.aspect,
        child: AnimatedSwitcher(
          duration: _fade,
          switchInCurve: Motion.move,
          switchOutCurve: Motion.move,
          child: Image.network(
            url,
            key: ValueKey(url),
            fit: BoxFit.cover,
            width: widget.width,
            height: widget.width / widget.aspect,
            gaplessPlayback: true,
          ),
        ),
      ),
    );
  }
}

/// A page's smaller features, an icon beside each line.
class _FeatureList extends StatelessWidget {
  const _FeatureList({required this.items});

  final List<(IconData, String)> items;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final (icon, text) in items)
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(icon, size: 22, color: theme.colorScheme.primary),
                const SizedBox(width: 16),
                Expanded(child: Text(text, style: theme.textTheme.bodyLarge)),
              ],
            ),
          ),
      ],
    );
  }
}

class _PageDots extends StatelessWidget {
  const _PageDots({required this.count, required this.page});

  final int count;
  final int page;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < count; i++)
          AnimatedContainer(
            duration: Motion.normal,
            margin: const EdgeInsets.only(right: 6),
            width: i == page ? 20 : 8,
            height: 8,
            decoration: BoxDecoration(
              color: i == page ? scheme.primary : scheme.outlineVariant,
              borderRadius: BorderRadius.circular(Radii.small),
            ),
          ),
      ],
    );
  }
}

class _IntroPage extends StatelessWidget {
  const _IntroPage({
    required this.title,
    required this.body,
    required this.child,
  });

  final String title;
  final String body;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 24),
      children: [
        Text(title, style: theme.textTheme.headlineMedium),
        const SizedBox(height: 12),
        Text(
          body,
          style: theme.textTheme.bodyLarge?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 32),
        Align(alignment: Alignment.centerLeft, child: child),
      ],
    );
  }
}

/// A guided tour of the emote settings screenshot: the frame pans to each
/// section in turn, outlines it, and captions what it does.
class _EmoteTour extends StatefulWidget {
  const _EmoteTour();

  @override
  State<_EmoteTour> createState() => _EmoteTourState();
}

class _EmoteTourState extends State<_EmoteTour> {
  static const _shot = 'assets/intro/emote_settings.webp';
  static const _shotAspect = 1080 / 2207;
  static const _frameWidth = 260.0;
  static const _frameHeight = 300.0;
  static const _step = Duration(milliseconds: 3200);

  /// Each section's top and bottom as fractions of the screenshot height.
  /// Animation is left out: the screenshot cuts off mid-section.
  static const _sections = [(0.08, 0.30), (0.32, 0.48), (0.50, 0.76)];

  Timer? _timer;
  int _index = 0;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(
      _step,
      (_) => setState(() => _index = (_index + 1) % _sections.length),
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final captions = [
      l10n.introEmoteFetching,
      l10n.introEmoteDataSaver,
      l10n.introEmoteCache,
    ];
    const shotHeight = _frameWidth / _shotAspect;
    final (top, bottom) = _sections[_index];
    // Centres the section in the frame, clamped to the screenshot's edges.
    final centre = (top + bottom) / 2 * shotHeight;
    final offset = (centre - _frameHeight / 2).clamp(
      0.0,
      shotHeight - _frameHeight,
    );
    const duration = Duration(milliseconds: 500);
    const curve = Motion.move;
    return Column(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(Radii.large),
          child: SizedBox(
            width: _frameWidth,
            height: _frameHeight,
            child: Stack(
              clipBehavior: Clip.hardEdge,
              children: [
                AnimatedPositioned(
                  duration: duration,
                  curve: curve,
                  top: -offset,
                  left: 0,
                  width: _frameWidth,
                  height: shotHeight,
                  child: Image.asset(_shot, fit: BoxFit.fill),
                ),
                AnimatedPositioned(
                  duration: duration,
                  curve: curve,
                  top: top * shotHeight - offset,
                  left: 4,
                  width: _frameWidth - 8,
                  height: (bottom - top) * shotHeight,
                  child: IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: theme.colorScheme.primary.withValues(
                          alpha: 0.08,
                        ),
                        border: Border.all(
                          color: theme.colorScheme.primary,
                          width: 2,
                        ),
                        borderRadius: BorderRadius.circular(Radii.medium),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        SizedBox(
          width: _frameWidth,
          height: 48,
          child: AnimatedSwitcher(
            duration: Motion.slow,
            child: Text(
              captions[_index],
              key: ValueKey(_index),
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium,
            ),
          ),
        ),
      ],
    );
  }
}
