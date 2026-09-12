import 'dart:collection';

import 'package:flutter/foundation.dart';

import '../../models/point_rewards.dart';

/// Per-channel Channel Points state: Helix-sourced rewards plus unfulfilled
/// redemptions oldest-first.
class Points {
  final ValueNotifier<int> version = ValueNotifier(0);

  List<PointReward> _rewards = const [];
  final List<PointRedemption> _redemptions = [];

  UnmodifiableListView<PointReward> get rewards =>
      UnmodifiableListView(_rewards);
  UnmodifiableListView<PointRedemption> get redemptions =>
      UnmodifiableListView(_redemptions);

  void setRewards(List<PointReward> rewards) {
    _rewards = List.of(rewards);
    version.value++;
  }

  void upsertRedemption(PointRedemption redemption) {
    _redemptions.removeWhere((r) => r.id == redemption.id);
    _redemptions.add(redemption);
    _redemptions.sort((a, b) => a.redeemedAt.compareTo(b.redeemedAt));
    version.value++;
  }

  bool resolveRedemption(String redemptionId) {
    final before = _redemptions.length;
    _redemptions.removeWhere((r) => r.id == redemptionId);
    if (_redemptions.length == before) return false;
    version.value++;
    return true;
  }

  void clear() {
    var touched = false;
    if (_rewards.isNotEmpty) {
      _rewards = const [];
      touched = true;
    }
    if (_redemptions.isNotEmpty) {
      _redemptions.clear();
      touched = true;
    }
    if (touched) version.value++;
  }

  void clearForAccountSwitch() => clear();

  void dispose() {
    version.dispose();
    _rewards = const [];
    _redemptions.clear();
  }
}
