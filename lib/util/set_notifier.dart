import 'package:flutter/foundation.dart';

/// A value notifier for values every emote widget listens to. [ChangeNotifier]
/// removes a listener with a linear scan, so a page of emotes unmounting costs
/// time quadratic in the listener count (seconds on a channel switch); here
/// listeners sit in a hash set and leave in constant time. A listener added
/// twice is held once.
class SetValueNotifier<T> implements ValueListenable<T> {
  SetValueNotifier(this._value);

  T _value;
  final _listeners = <VoidCallback>{};

  @override
  T get value => _value;

  set value(T next) {
    if (next == _value) return;
    _value = next;
    for (final listener in List.of(_listeners)) {
      // A listener removed by an earlier one this round is skipped.
      if (!_listeners.contains(listener)) continue;
      try {
        listener();
      } catch (e, stack) {
        FlutterError.reportError(
          FlutterErrorDetails(
            exception: e,
            stack: stack,
            library: 'ermchat',
            context: ErrorDescription('while notifying a SetValueNotifier'),
          ),
        );
      }
    }
  }

  @override
  void addListener(VoidCallback listener) => _listeners.add(listener);

  @override
  void removeListener(VoidCallback listener) => _listeners.remove(listener);

  void dispose() => _listeners.clear();
}
