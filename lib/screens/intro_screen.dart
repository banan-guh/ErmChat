import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../services/twitch_auth.dart';
import 'settings/account_screen.dart';
import 'settings/language_screen.dart';

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
    _pages.nextPage(
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOutCubic,
    );
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
                  for (var i = 0; i < _pageCount; i++)
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      margin: const EdgeInsets.only(right: 6),
                      width: i == _page ? 20 : 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: i == _page
                            ? theme.colorScheme.primary
                            : theme.colorScheme.outlineVariant,
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
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
    const curve = Curves.easeInOutCubic;
    return Column(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(20),
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
                        borderRadius: BorderRadius.circular(12),
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
            duration: const Duration(milliseconds: 300),
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
