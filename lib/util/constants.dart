import 'dart:math';

const httpTimeout = Duration(seconds: 10);

Duration applyReconnectJitter(Duration base) {
  final jitter = 0.75 + Random().nextDouble() * 0.5;
  return Duration(milliseconds: (base.inMilliseconds * jitter).toInt());
}
