import 'dart:async';

import 'package:flutter/material.dart';

/// Full-screen overlay that plays the nuke animation, then dismisses.
class NukeOverlay extends StatefulWidget {
  const NukeOverlay({super.key, this.onDone});

  /// Shows the overlay and returns a future that completes when it is removed.
  static Future<void> show(BuildContext context) async {
    final completer = Completer<void>();
    final entry = OverlayEntry(
      builder: (_) => NukeOverlay(onDone: completer.complete),
    );
    Overlay.of(context).insert(entry);
    await completer.future;
    entry.remove();
  }

  final VoidCallback? onDone;

  @override
  State<NukeOverlay> createState() => _NukeOverlayState();
}

class _NukeOverlayState extends State<NukeOverlay> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    // 59 frames * 40ms = 2360ms. Pad a little for decode latency.
    _timer = Timer(const Duration(milliseconds: 2600), _dismiss);
  }

  void _dismiss() {
    widget.onDone?.call();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Colors.black54,
      child: Center(
        child: Image.asset(
          'assets/WAYTOOERM.webp',
          gaplessPlayback: false,
          fit: BoxFit.contain,
        ),
      ),
    );
  }
}
