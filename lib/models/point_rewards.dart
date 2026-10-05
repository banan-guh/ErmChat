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
  final String userDisplayName;
  final String rewardId;
  final String rewardTitle;
  final int cost;
  final String userInput;
  final String status;
  final String redeemedAt;

  /// True when the reward asks the viewer for text (highlight message, TTS,
  /// ...). The chat line arrives over IRC; the banner arrives here.
  final bool requiresUserInput;

  /// Large reward image URL when the source carried one (PubSub only).
  final String? imageUrl;

  /// Twitch's own reward (gigantified emote, message effects ...), set only
  /// for PubSub `automatic-reward-redeemed`. Never posts on its own.
  final bool isAutomatic;

  /// [cost] is in bits rather than channel points.
  final bool costInBits;

  const PointRedemption({
    required this.id,
    required this.userLogin,
    this.userDisplayName = '',
    required this.rewardId,
    required this.rewardTitle,
    required this.cost,
    required this.userInput,
    required this.status,
    required this.redeemedAt,
    this.requiresUserInput = false,
    this.imageUrl,
    this.isAutomatic = false,
    this.costInBits = false,
  });

  factory PointRedemption.fromJson(Map<String, dynamic> json) {
    final reward = json['reward'] as Map<String, dynamic>?;
    return PointRedemption(
      id: json['id'] as String? ?? '',
      userLogin: json['user_login'] as String? ?? '',
      rewardId: reward?['id'] as String? ?? '',
      rewardTitle: reward?['title'] as String? ?? '',
      cost: (reward?['cost'] as num?)?.toInt() ?? 0,
      userInput: json['user_input'] as String? ?? '',
      status: json['status'] as String? ?? 'UNFULFILLED',
      redeemedAt: json['redeemed_at'] as String? ?? '',
    );
  }

  /// Parses a PubSub `reward-redeemed` or `automatic-reward-redeemed`
  /// redemption plus its envelope timestamp. PubSub carries no fulfillment
  /// status or user input text, so those stay empty; the reward id keys the
  /// IRC correlation.
  factory PointRedemption.fromPubSub(
    Map<String, dynamic> redemption,
    String timestamp,
  ) {
    final user = redemption['user'] as Map<String, dynamic>?;
    final reward = redemption['reward'] as Map<String, dynamic>?;
    final type = reward?['reward_type'] as String?;
    // Automatic rewards pair with their chat line by its IRC msg-id.
    final (pairId, fallbackTitle) = switch (type) {
      'SEND_GIGANTIFIED_EMOTE' => (
        'gigantified-emote-message',
        'Gigantify an Emote',
      ),
      'SEND_ANIMATED_MESSAGE' => ('animated-message', 'Message Effects'),
      _ => (null, ''),
    };
    final title = reward?['title'] as String? ?? '';
    int intOf(String key) => (reward?[key] as num?)?.toInt() ?? 0;
    final points = intOf('cost');
    final bits = intOf('bits_cost') > 0
        ? intOf('bits_cost')
        : intOf('default_bits_cost');
    return PointRedemption(
      id: redemption['id'] as String? ?? '',
      userLogin: user?['login'] as String? ?? '',
      userDisplayName: user?['display_name'] as String? ?? '',
      rewardId: pairId ?? reward?['id'] as String? ?? '',
      rewardTitle: title.isEmpty ? fallbackTitle : title,
      cost: points > 0 ? points : bits,
      costInBits: points <= 0 && bits > 0,
      isAutomatic: type != null,
      userInput: '',
      status: 'UNFULFILLED',
      redeemedAt: timestamp,
      requiresUserInput: reward?['is_user_input_required'] as bool? ?? false,
      imageUrl: _pubSubImage(reward),
    );
  }

  /// Large custom image, falling back to the default set (DankChat picks the
  /// 4x variant the same way).
  static String? _pubSubImage(Map<String, dynamic>? reward) {
    String? pick(Map<String, dynamic>? images) {
      if (images == null) return null;
      for (final key in const ['url_4x', 'url_2x', 'url_1x']) {
        final url = images[key] as String?;
        if (url != null && url.isNotEmpty) return url;
      }
      return null;
    }

    return pick(reward?['image'] as Map<String, dynamic>?) ??
        pick(reward?['default_image'] as Map<String, dynamic>?);
  }
}
