import 'dart:async';

import 'package:flutter/material.dart';

import '../eventsub/decode/events.dart';
import '../l10n/l10n.dart';
import '../services/emote_manager.dart';
import '../services/mod_actions.dart' show ModResult;
import '../util/prefs.dart';
import 'chat_widget_cutout.dart';

// Chat overlay widgets (hype train, poll, prediction, pin) plus test fakes.
class BroadcastWidgets {
  BroadcastWidgets({required this.selectedChannel, this.emotes});

  /// Renders emotes in pinned messages; null shows plain text.
  final EmoteLookupSource? emotes;

  final String? Function() selectedChannel;
  final notifier = ValueNotifier<int>(0);

  final hypeTrains = <String, HypeTrainEvent>{};
  final polls = <String, PollEvent>{};
  final predictions = <String, PredictionEvent>{};
  final pins = <String, PinnedMessageEvent>{};

  // Lapses timed pins, which get no unpin event.
  final _pinExpiry = <String, Timer>{};
  final widgetsMinimized = <String, bool>{};
  // One card pager per channel: two channels' cards show mid-swipe.
  final _pageCtrls = <String, PageController>{};

  PageController pageCtrlFor(String channel) =>
      _pageCtrls.putIfAbsent(channel, PageController.new);

  Timer? _testWidgetsTimer;
  int _fakeLevel = 1;
  int _fakeProgress = 0;
  int _fakeGoal = 100;
  int _fakePollA = 120;
  int _fakePollB = 80;
  int _fakePollC = 40;
  int _fakePredYes = 900;
  int _fakePredNo = 450;
  DateTime? _fakeTrainEndsAt;

  bool mounted = true;

  void dispose() {
    mounted = false;
    _testWidgetsTimer?.cancel();
    for (final t in _pinExpiry.values) {
      t.cancel();
    }
    for (final c in _pageCtrls.values) {
      c.dispose();
    }
    notifier.dispose();
  }

  // Live polls, predictions and hype trains are a dev opt-in until their
  // cards are verified against real streams; pins always show.
  static bool get _liveWidgets => Prefs.loaded?.liveChatWidgets ?? true;

  void onHypeTrain(HypeTrainEvent event) {
    if (!mounted || !_liveWidgets) return;
    if (event.kind == HypeTrainKind.end) {
      hypeTrains.remove(event.channel);
    } else {
      hypeTrains[event.channel] = event;
    }
    notifier.value++;
    clampPage();
  }

  void onPoll(PollEvent event) {
    if (!mounted || !_liveWidgets) return;
    if (event.kind == PollKind.end) {
      polls.remove(event.channel);
    } else {
      polls[event.channel] = event;
    }
    notifier.value++;
    clampPage();
  }

  void onPrediction(PredictionEvent event) {
    if (!mounted || !_liveWidgets) return;
    if (event.kind == PredictionKind.end) {
      predictions.remove(event.channel);
    } else {
      predictions[event.channel] = event;
    }
    notifier.value++;
    clampPage();
  }

  void onPinned(PinnedMessageEvent event) {
    if (!mounted) return;
    final channel = event.channel;
    if (event.removed) {
      if (pins[channel]?.id != event.id) return;
      _dropPin(channel);
    } else {
      if (_dismissedPins.contains(event.id)) return;
      _pinExpiry.remove(channel)?.cancel();
      pins[channel] = event;
      final left = event.endsAt?.difference(DateTime.now());
      if (left != null) {
        _pinExpiry[channel] = Timer(
          left.isNegative ? Duration.zero : left,
          () => _dropPin(channel),
        );
      }
    }
    notifier.value++;
    clampPage();
  }

  /// Pins the user closed; a repeat push of the same pin stays hidden.
  final _dismissedPins = <String>{};

  /// Hides [channel]'s current pin on this device; a new pin still shows.
  void dismissPin(String channel) {
    final pin = pins[channel];
    if (pin == null) return;
    _dismissedPins.add(pin.id);
    _dropPin(channel);
  }

  void _dropPin(String channel) {
    _pinExpiry.remove(channel)?.cancel();
    if (pins.remove(channel) == null || !mounted) return;
    notifier.value++;
    clampPage();
  }

  Future<void> loadTestWidgets() async {
    final prefs = await Prefs.load();
    if (!mounted) return;
    applyTestWidgets(prefs.testChatWidgets);
  }

  void setTestWidgets(bool value) {
    if (!mounted) return;
    applyTestWidgets(value);
  }

  void applyTestWidgets(bool value) {
    if (value) {
      _startTestWidgets();
    } else {
      _stopTestWidgets();
    }
  }

  void _startTestWidgets() {
    _fakeTrainEndsAt = DateTime.now().add(const Duration(minutes: 5));
    _testWidgetsTimer?.cancel();
    _testWidgetsTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => _tickTestWidgets(),
    );
    _tickTestWidgets();
  }

  void _stopTestWidgets() {
    _testWidgetsTimer?.cancel();
    _testWidgetsTimer = null;
    if (!mounted) return;
    hypeTrains.clear();
    polls.clear();
    predictions.clear();
    widgetsMinimized.clear();
    notifier.value++;
  }

  void _tickTestWidgets() {
    if (!mounted) return;
    final channel = selectedChannel();
    if (channel == null) return;
    hypeTrains.clear();
    polls.clear();
    predictions.clear();

    _fakeProgress += 9;
    if (_fakeProgress >= _fakeGoal) {
      _fakeLevel++;
      _fakeGoal += 100;
      _fakeProgress = 0;
    }
    hypeTrains[channel] = HypeTrainEvent(
      channel: channel,
      kind: HypeTrainKind.progress,
      rawKind: 'progress',
      level: _fakeLevel,
      progress: _fakeProgress,
      goal: _fakeGoal,
      total: _fakeGoal,
      expiresAt: _fakeTrainEndsAt,
      topContributions: [
        HypeTrainContribution(userName: 'fakebits', type: 'BITS', total: 5000),
        HypeTrainContribution(userName: 'fakesub', type: 'SUBS', total: 12),
      ],
    );

    _fakePollA += 3;
    _fakePollB += 2;
    _fakePollC += 1;
    polls[channel] = PollEvent(
      channel: channel,
      kind: PollKind.progress,
      rawKind: 'progress',
      title: 'Fake poll: what should we play?',
      choices: [
        PollChoice(title: 'Minecraft', votes: _fakePollA),
        PollChoice(title: 'Terraria', votes: _fakePollB),
        PollChoice(title: 'Stardew', votes: _fakePollC),
      ],
      status: 'ACTIVE',
    );

    _fakePredYes += 12;
    _fakePredNo += 5;
    predictions[channel] = PredictionEvent(
      channel: channel,
      kind: PredictionKind.progress,
      rawKind: 'progress',
      title: 'Fake prediction: will we win?',
      outcomes: [
        PredictionOutcome(
          title: 'Yes',
          users: _fakePredYes,
          channelPoints: 9000,
        ),
        PredictionOutcome(title: 'No', users: _fakePredNo, channelPoints: 4500),
      ],
      status: 'ACTIVE',
    );
    notifier.value++;
    clampPage();
  }

  /// [unpin], when the user moderates [channel], offers Unpin on its pin.
  List<Widget> pagesFor(
    String channel, {
    Future<ModResult> Function(PinnedMessageEvent pin)? unpin,
  }) {
    final result = <Widget>[];
    final pin = pins[channel];
    if (pin != null) {
      result.add(
        PinnedMessageCard(
          key: ValueKey(pin.id),
          event: pin,
          emotes: emotes,
          onDismiss: () => dismissPin(channel),
          onUnpin: unpin != null && pin.messageId.isNotEmpty
              ? () => unpin(pin)
              : null,
        ),
      );
    }
    final poll = polls[channel];
    if (poll != null) result.add(PollCard(event: poll));
    final prediction = predictions[channel];
    if (prediction != null) result.add(PredictionCard(event: prediction));
    final hypeTrain = hypeTrains[channel];
    if (hypeTrain != null) result.add(HypeTrainCard(event: hypeTrain));
    return result;
  }

  List<_Card> _cardsFor(String channel) => [
    if (pins.containsKey(channel)) _Card.pin,
    if (polls.containsKey(channel)) _Card.poll,
    if (predictions.containsKey(channel)) _Card.prediction,
    if (hypeTrains.containsKey(channel)) _Card.hypeTrain,
  ];

  /// The card showing when each channel's cutout was minimized; the bar
  /// previews it and restore returns to it.
  final _focused = <String, _Card>{};

  // Measured card heights per channel; outlive the cutout so a restore
  // opens at size.
  final _cardHeights = <String, Map<Object, double>>{};

  Widget? buildOverlay(
    String channel, {
    required void Function(String, bool) onMinimizeChanged,
    bool glass = false,
    Future<ModResult> Function(PinnedMessageEvent pin)? unpin,
  }) {
    final pages = pagesFor(channel, unpin: unpin);
    if (pages.isEmpty) return null;
    final cards = _cardsFor(channel);
    final ctrl = pageCtrlFor(channel);
    if (widgetsMinimized[channel] ?? false) {
      final focus = cards.contains(_focused[channel])
          ? _focused[channel]!
          : cards.first;
      return ChatWidgetMinimizedBar(
        label: _labelFor(channel, focus),
        icon: _iconFor(focus),
        onRestore: () {
          // A fresh pager opens on the focused card instead of jumping there.
          final old = _pageCtrls[channel];
          _pageCtrls[channel] = PageController(
            initialPage: cards.indexOf(focus),
          );
          onMinimizeChanged(channel, false);
          WidgetsBinding.instance.addPostFrameCallback((_) => old?.dispose());
        },
        pin: focus == _Card.pin ? pins[channel] : null,
        emotes: emotes,
        glass: glass,
      );
    }
    return ChatWidgetCutout(
      pages: pages,
      ids: cards,
      heights: _cardHeights.putIfAbsent(channel, () => {}),
      controller: ctrl,
      onMinimize: () {
        final now = _cardsFor(channel);
        final page = ctrl.positions.length == 1 ? ctrl.page ?? 0 : 0.0;
        if (now.isNotEmpty) {
          _focused[channel] = now[page.round().clamp(0, now.length - 1)];
        }
        onMinimizeChanged(channel, true);
      },
      glass: glass,
    );
  }

  String Function(AppLocalizations) _labelFor(String channel, _Card card) =>
      switch (card) {
        _Card.pin => (l) => l.pinned,
        _Card.poll => (_) => polls[channel]?.title ?? '',
        _Card.prediction => (_) => predictions[channel]?.title ?? '',
        _Card.hypeTrain => (l) {
          final train = hypeTrains[channel];
          if (train == null) return l.hypeTrain;
          return '${l.hypeTrain} ${l.hypeTrainLevel(train.level)} · '
              '${hypeTrainPercent(train)}%';
        },
      };

  static IconData _iconFor(_Card card) => switch (card) {
    _Card.pin => Icons.push_pin_outlined,
    _Card.poll => Icons.poll_outlined,
    _Card.prediction => Icons.emoji_events_outlined,
    _Card.hypeTrain => Icons.train_outlined,
  };

  void clampPage() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final channel = selectedChannel();
      if (!mounted || channel == null) return;
      final pageCtrl = pageCtrlFor(channel);
      if (pageCtrl.positions.length != 1) return;
      final pages = pagesFor(channel).length;
      if (pages == 0) return;
      final idx = pageCtrl.page?.round() ?? 0;
      if (idx >= pages) {
        pageCtrl.jumpToPage(pages - 1);
      }
    });
  }

  // Drop all state for a removed channel.
  void clearChannel(String channel) {
    hypeTrains.remove(channel);
    polls.remove(channel);
    predictions.remove(channel);
    _pinExpiry.remove(channel)?.cancel();
    pins.remove(channel);
    widgetsMinimized.remove(channel);
    _focused.remove(channel);
    _cardHeights.remove(channel);
    _pageCtrls.remove(channel)?.dispose();
  }

  void setMinimized(String channel, bool minimized) {
    widgetsMinimized[channel] = minimized;
    notifier.value++;
  }
}

enum _Card { pin, poll, prediction, hypeTrain }
