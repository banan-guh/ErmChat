import 'package:flutter/material.dart';

import '../../chat/channel/moderation.dart';
import '../../chat/channel/points.dart';
import '../../chat/chat.dart';
import '../../l10n/l10n.dart';
import '../../services/mod_actions.dart';
import '../../services/twitch_auth.dart';
import 'dialogs.dart';

/// What every Mod View tab works with: the channel, the owners it acts
/// through, and where results are reported.
class ModContext {
  const ModContext({
    required this.channel,
    required this.chat,
    required this.actions,
    required this.auth,
    required this.notify,
    this.showUser,
    this.isBroadcaster = false,
    this._l10n,
  });

  final String channel;
  final Chat chat;
  final ModActions actions;
  final TwitchAuth auth;

  /// Notice sink; the shell routes it to the inline bar.
  final ValueChanged<String> notify;

  /// Opens a user card.
  final ValueChanged<String>? showUser;

  /// Whether the session user owns the channel.
  final bool isBroadcaster;

  /// Strings in the app language, readable where no context is (loader
  /// failures built in initState). English without one.
  AppLocalizations get l10n =>
      _l10n ?? lookupAppLocalizations(const Locale('en'));
  final AppLocalizations? _l10n;

  Moderation? get moderation => chat.channelFor(channel)?.moderation;
  Points? get points => chat.channelFor(channel)?.points;

  /// Awaits a mod action and reports it: [done] on success, the failure
  /// text otherwise. Returns whether it worked.
  Future<bool> report(Future<ModResult> action, {String? done}) async {
    final result = await action;
    if (!result.ok) {
      notify(modErrorText(result, l10n));
    } else if (done != null) {
      notify(done);
    }
    return result.ok;
  }
}

/// One Helix read under the Mod View load rules: the newest load wins,
/// failures are read from this request alone, and a failed refresh of data
/// already on screen becomes a notice instead of an error state.
class ModLoader<T extends Object> extends ChangeNotifier {
  ModLoader(
    this.mod,
    this._request, {
    required this.failure,
    this.statusFailure,
  });

  /// Swapped by the owning tab when the context changes.
  ModContext mod;
  final Future<T?> Function(ModContext mod) _request;

  /// Copy for a thrown or empty-handed request.
  final String failure;

  /// Copy for a specific HTTP status; null falls back to the Helix reason.
  final String? Function(int status)? statusFailure;

  T? _value;
  String? _error;
  int _gen = 0;
  bool _disposed = false;

  T? get value => _value;
  String? get error => _error;

  /// Replaces the shown value without a request (optimistic edits).
  set value(T? next) {
    _value = next;
    notifyListeners();
  }

  /// Drops what is shown (channel or filter change) and loads again.
  Future<void> reset() {
    _gen++;
    _value = null;
    _error = null;
    notifyListeners();
    return load();
  }

  Future<void> load() async {
    final gen = ++_gen;
    final mod = this.mod;
    final api = mod.actions.twitchApi;
    final (value, error) = await api.isolateErrors<(T?, String?)>(() async {
      try {
        final value = await _request(mod);
        final status = api.lastErrorStatus;
        if (status != null) {
          return (
            null,
            statusFailure?.call(status) ?? mod.actions.failureReason(),
          );
        }
        return value == null ? (null, failure) : (value, null);
      } catch (_) {
        return (null, failure);
      }
    });
    if (_disposed || gen != _gen) return;
    if (error != null && _value != null) {
      mod.notify(error);
      return;
    }
    _value = value;
    _error = error;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

/// A Mod View tab or section: everything it needs arrives in [mod].
abstract class ModTabWidget extends StatefulWidget {
  const ModTabWidget({super.key, required this.mod});

  final ModContext mod;
}

/// Channel plumbing for [ModTabWidget] states. Loaders and kernel listeners
/// follow the context: a channel switch calls [didChangeChannel], rebinds
/// listeners, and reloads. Also tracks in-flight actions per key.
mixin ModTabState<W extends ModTabWidget> on State<W> {
  ModContext get mod => widget.mod;

  final _loaders = <ModLoader>[];
  final _watches = <(Listenable? Function(ModContext), VoidCallback)>[];
  final _bound = <(Listenable, VoidCallback)>[];
  final _busy = <String>{};

  /// Creates a loader owned by this state and starts its first load.
  ModLoader<T> loader<T extends Object>(
    Future<T?> Function(ModContext mod) request, {
    required String failure,
    String? Function(int status)? statusFailure,
  }) {
    final loader = ModLoader<T>(
      mod,
      request,
      failure: failure,
      statusFailure: statusFailure,
    );
    _loaders.add(loader);
    loader.load();
    return loader;
  }

  /// Calls [onChange] whenever the listenable [select] picks for the
  /// current channel fires.
  void watch(
    Listenable? Function(ModContext mod) select,
    VoidCallback onChange,
  ) {
    _watches.add((select, onChange));
    final target = select(mod);
    if (target == null) return;
    target.addListener(onChange);
    _bound.add((target, onChange));
  }

  /// Runs on a channel switch, before the loaders reload; reset per-channel
  /// state (filters, selections) here.
  void didChangeChannel() {}

  bool isBusy(String key) => _busy.contains(key);
  bool get anyBusy => _busy.isNotEmpty;

  /// Runs [body] unless [key] is already running, rebuilding around it.
  Future<void> busy(String key, Future<void> Function() body) async {
    if (!_busy.add(key)) return;
    setState(() {});
    try {
      await body();
    } finally {
      _busy.remove(key);
      if (mounted) setState(() {});
    }
  }

  @override
  void didUpdateWidget(covariant W oldWidget) {
    super.didUpdateWidget(oldWidget);
    for (final loader in _loaders) {
      loader.mod = mod;
    }
    if (oldWidget.mod.channel == mod.channel) return;
    didChangeChannel();
    _unbind();
    for (final (select, onChange) in _watches) {
      final target = select(mod);
      if (target == null) continue;
      target.addListener(onChange);
      _bound.add((target, onChange));
    }
    _busy.clear();
    for (final loader in _loaders) {
      loader.reset();
    }
  }

  void _unbind() {
    for (final (target, onChange) in _bound) {
      target.removeListener(onChange);
    }
    _bound.clear();
  }

  @override
  void dispose() {
    _unbind();
    for (final loader in _loaders) {
      loader.dispose();
    }
    super.dispose();
  }
}
