import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/twitch_eventsub.dart';
import 'chat_widget_cutout.dart';

// Chat overlay widgets (hype train, poll, prediction) plus test fakes.
class BroadcastWidgets {
  BroadcastWidgets({required this.selectedChannel});

  final String? Function() selectedChannel;
  final notifier = ValueNotifier<int>(0);

  final hypeTrains = <String, HypeTrainEvent>{};
  final polls = <String, PollEvent>{};
  final predictions = <String, PredictionEvent>{};
  final widgetsMinimized = <String, bool>{};
  final pageCtrl = PageController();

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
    pageCtrl.dispose();
    notifier.dispose();
  }

  void onHypeTrain(HypeTrainEvent event) {
    if (!mounted) return;
    if (event.kind == 'end') {
      hypeTrains.remove(event.channel);
    } else {
      hypeTrains[event.channel] = event;
    }
    notifier.value++;
    clampPage();
  }

  void onPoll(PollEvent event) {
    if (!mounted) return;
    if (event.kind == 'end') {
      polls.remove(event.channel);
    } else {
      polls[event.channel] = event;
    }
    notifier.value++;
    clampPage();
  }

  void onPrediction(PredictionEvent event) {
    if (!mounted) return;
    if (event.kind == 'end') {
      predictions.remove(event.channel);
    } else {
      predictions[event.channel] = event;
    }
    notifier.value++;
    clampPage();
  }

  Future<void> loadTestWidgets() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    applyTestWidgets(prefs.getBool('test_chat_widgets') ?? false);
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
      kind: 'progress',
      level: _fakeLevel,
      progress: _fakeProgress,
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
      kind: 'progress',
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
      kind: 'progress',
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

  List<Widget> pagesFor(String channel) {
    final result = <Widget>[];
    final poll = polls[channel];
    if (poll != null) result.add(PollCard(event: poll));
    final prediction = predictions[channel];
    if (prediction != null) result.add(PredictionCard(event: prediction));
    final hypeTrain = hypeTrains[channel];
    if (hypeTrain != null) result.add(HypeTrainCard(event: hypeTrain));
    return result;
  }

  String labelsFor(String channel) {
    final labels = <String>[];
    if (polls.containsKey(channel)) labels.add('Poll');
    if (predictions.containsKey(channel)) labels.add('Prediction');
    if (hypeTrains.containsKey(channel)) labels.add('Hype Train');
    return labels.join(' / ');
  }

  Widget? buildOverlay(
    String channel, {
    required void Function(String, bool) onMinimizeChanged,
  }) {
    final pages = pagesFor(channel);
    if (pages.isEmpty) return null;
    if (widgetsMinimized[channel] ?? false) {
      return ChatWidgetMinimizedBar(
        labels: labelsFor(channel),
        onRestore: () => onMinimizeChanged(channel, false),
      );
    }
    return ChatWidgetCutout(
      pages: pages,
      controller: pageCtrl,
      onMinimize: () => onMinimizeChanged(channel, true),
    );
  }

  void clampPage() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !pageCtrl.hasClients) return;
      final channel = selectedChannel();
      if (channel == null) return;
      final pages = pagesFor(channel).length;
      if (pages == 0) return;
      final idx = pageCtrl.page?.round() ?? 0;
      if (idx >= pages) {
        pageCtrl.jumpToPage(pages - 1);
      }
    });
  }

  void resetPage() {
    if (pageCtrl.hasClients) pageCtrl.jumpToPage(0);
  }

  // Drop all state for a removed channel.
  void clearChannel(String channel) {
    hypeTrains.remove(channel);
    polls.remove(channel);
    predictions.remove(channel);
    widgetsMinimized.remove(channel);
  }

  void setMinimized(String channel, bool minimized) {
    widgetsMinimized[channel] = minimized;
    notifier.value++;
  }
}
