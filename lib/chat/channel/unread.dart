/// Per-channel unread state. A mention counts only for a mention-tier row
/// that is not history, not selected, and not the account's own.
class Unread {
  bool _hasUnread = false;
  bool _hasMention = false;
  int _mentionCount = 0;

  bool get hasUnread => _hasUnread;
  bool get hasMention => _hasMention;
  int get mentionCount => _mentionCount;

  /// Live ingest bookkeeping. Returns whether the unread dot turned on, so
  /// the root only notifies tab labels when one actually changes.
  bool note({
    required bool isMention,
    required bool isHistory,
    required bool isSystem,
    required bool isSelected,
    required bool isOwn,
  }) {
    if (isMention && !isOwn && !isHistory && !isSelected) {
      _hasMention = true;
      _mentionCount++;
    }
    if (!isSelected && !isHistory && !isSystem && !_hasUnread) {
      _hasUnread = true;
      return true;
    }
    return false;
  }

  /// Lowers the mention count to at most [keep] after a purge removed rows.
  /// Returns how many mentions dropped; the mention dot goes with the last one.
  int dropMentions(int keep) {
    if (keep >= _mentionCount) return 0;
    final dropped = _mentionCount - keep;
    _mentionCount = keep;
    if (keep == 0) _hasMention = false;
    return dropped;
  }

  /// Selecting the channel clears dots and mention counts.
  int clear() {
    final cleared = _mentionCount;
    if (!_hasUnread && !_hasMention && _mentionCount == 0) return 0;
    _hasUnread = false;
    _hasMention = false;
    _mentionCount = 0;
    return cleared;
  }

  void clearForAccountSwitch() {
    if (!_hasUnread && !_hasMention && _mentionCount == 0) return;
    _hasUnread = false;
    _hasMention = false;
    _mentionCount = 0;
  }

  void dispose() {
    _hasUnread = false;
    _hasMention = false;
    _mentionCount = 0;
  }
}
