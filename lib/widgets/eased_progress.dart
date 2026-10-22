import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';

import 'design_tokens.dart';

/// Builds with [progress] eased between its updates, so a value that moves in
/// chunks reads as one smooth sweep. A drop (a new run starting over) jumps
/// at once instead of unwinding. [builder] gets the eased value, which holds
/// its last figure after [progress] clears, and whether a run is active.
class EasedProgress extends StatefulWidget {
  const EasedProgress({
    super.key,
    required this.progress,
    required this.builder,
  });

  final ValueListenable<double?> progress;
  final Widget Function(BuildContext context, double value, bool active)
  builder;

  @override
  State<EasedProgress> createState() => _EasedProgressState();
}

class _EasedProgressState extends State<EasedProgress>
    with SingleTickerProviderStateMixin {
  late final _ease = AnimationController(
    vsync: this,
    duration: Motion.normal,
    value: 1,
  );
  double _from = 0;
  double _to = 0;

  double get _value =>
      _from + (_to - _from) * Motion.enter.transform(_ease.value);

  @override
  void initState() {
    super.initState();
    widget.progress.addListener(_onChange);
    _to = _from = widget.progress.value ?? 0;
  }

  @override
  void didUpdateWidget(EasedProgress old) {
    super.didUpdateWidget(old);
    if (old.progress != widget.progress) {
      old.progress.removeListener(_onChange);
      widget.progress.addListener(_onChange);
    }
  }

  void _onChange() {
    final target = widget.progress.value;
    if (target != null) {
      final now = _value;
      if (target < now) {
        _from = _to = target;
        _ease.value = 1;
      } else {
        _from = now;
        _to = target;
        _ease.forward(from: 0);
      }
    }
    setState(() {});
  }

  @override
  void dispose() {
    widget.progress.removeListener(_onChange);
    _ease.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _ease,
    builder: (context, _) =>
        widget.builder(context, _value, widget.progress.value != null),
  );
}
