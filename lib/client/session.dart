import 'package:flutter/foundation.dart';

/// The account the pipeline currently acts as. Identity only: chat state
/// lives in lib/chat. [version] ticks when [apply] resolves an account so the
/// app can refresh account-scoped data; [seed] and [clear] stay silent.
class Session {
  String? _login;
  String? _userId;

  final ValueNotifier<int> version = ValueNotifier(0);

  String? get login => _login;
  String? get userId => _userId;

  /// Pipeline-path write: resolves or re-resolves identity and announces it.
  void apply(String? login, {String? userId, bool keepUserId = false}) {
    _login = login;
    if (!keepUserId) _userId = userId;
    version.value++;
  }

  /// Init seed: assigns the cached account before the pipeline exists, with
  /// no announcement. The connect that follows resolves through [apply].
  void seed(String? login, {String? userId}) {
    _login = login;
    _userId = userId;
  }

  /// Drops identity without announcing; the app clears its own account state.
  void clear() {
    _login = null;
    _userId = null;
  }

  void dispose() {
    version.dispose();
  }
}
