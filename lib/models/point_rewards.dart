// Channel Points shapes shared by the Helix layer and the chat kernel.
// Only rewards created by this app's client id are manageable through
// Helix; the rest are read-only.

/// One Channel Points custom reward.
class PointReward {
  final String id;
  final String title;
  final int cost;
  final bool isEnabled;
  final bool isPaused;

  const PointReward({
    required this.id,
    required this.title,
    required this.cost,
    required this.isEnabled,
    required this.isPaused,
  });

  factory PointReward.fromJson(Map<String, dynamic> json) => PointReward(
    id: json['id'] as String? ?? '',
    title: json['title'] as String? ?? '',
    cost: json['cost'] as int? ?? 0,
    isEnabled: json['is_enabled'] as bool? ?? true,
    isPaused: json['is_paused'] as bool? ?? false,
  );
}

/// One custom-reward redemption.
class PointRedemption {
  final String id;
  final String userLogin;
  final String rewardId;
  final String rewardTitle;
  final int cost;
  final String userInput;
  final String status;
  final String redeemedAt;

  const PointRedemption({
    required this.id,
    required this.userLogin,
    required this.rewardId,
    required this.rewardTitle,
    required this.cost,
    required this.userInput,
    required this.status,
    required this.redeemedAt,
  });

  factory PointRedemption.fromJson(Map<String, dynamic> json) {
    final reward = json['reward'] as Map<String, dynamic>?;
    return PointRedemption(
      id: json['id'] as String? ?? '',
      userLogin: json['user_login'] as String? ?? '',
      rewardId: reward?['id'] as String? ?? '',
      rewardTitle: reward?['title'] as String? ?? '',
      cost: reward?['cost'] as int? ?? 0,
      userInput: json['user_input'] as String? ?? '',
      status: json['status'] as String? ?? 'UNFULFILLED',
      redeemedAt: json['redeemed_at'] as String? ?? '',
    );
  }
}
