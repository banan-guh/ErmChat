import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

/// Full-screen viewer for an expanded chat image embed.
Future<void> showImageEmbedViewer(BuildContext context, String url) {
  return showGeneralDialog(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Dismiss image',
    barrierColor: Colors.black.withValues(alpha: 0.8),
    transitionDuration: const Duration(milliseconds: 150),
    pageBuilder: (_, _, _) => _ImageEmbedViewer(url: url),
    transitionBuilder: (_, animation, _, child) =>
        FadeTransition(opacity: animation, child: child),
  );
}

class _ImageEmbedViewer extends StatefulWidget {
  const _ImageEmbedViewer({required this.url});

  final String url;

  @override
  State<_ImageEmbedViewer> createState() => _ImageEmbedViewerState();
}

class _ImageEmbedViewerState extends State<_ImageEmbedViewer>
    with SingleTickerProviderStateMixin {
  /// Pixels dragged down. Resets on release unless past the dismiss line.
  double _drag = 0;

  /// Snap-back driver for under-threshold releases.
  late final AnimationController _snapBack = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 150),
  );
  late final CurvedAnimation _snapCurve = CurvedAnimation(
    parent: _snapBack,
    curve: Curves.easeOut,
  );
  double _snapFrom = 0;

  @override
  void initState() {
    super.initState();
    _snapBack.addListener(() {
      if (!mounted) return;
      setState(() => _drag = _snapFrom * (1 - _snapCurve.value));
    });
  }

  @override
  void dispose() {
    _snapCurve.dispose();
    _snapBack.dispose();
    super.dispose();
  }

  void _onDragUpdate(DragUpdateDetails details) {
    _snapBack.stop();
    setState(() {
      _drag = (_drag + details.delta.dy).clamp(0.0, double.infinity);
    });
  }

  void _onDragEnd(DragEndDetails details) {
    // Pop at once: the route fade covers the exit, so the scrim never lingers.
    if (_drag > 120 || (details.primaryVelocity ?? 0) > 500) {
      Navigator.of(context).pop();
      return;
    }
    _snapFrom = _drag;
    _snapBack.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    final height = MediaQuery.sizeOf(context).height;
    final opacity = (1 - _drag / (height * 0.6)).clamp(0.0, 1.0);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onVerticalDragUpdate: _onDragUpdate,
      onVerticalDragEnd: _onDragEnd,
      child: Opacity(
        opacity: opacity,
        child: Transform.translate(
          offset: Offset(0, _drag),
          child: Stack(
            children: [
              const SizedBox.expand(),
              Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: CachedNetworkImage(
                    imageUrl: widget.url,
                    fit: BoxFit.contain,
                    placeholder: (_, _) => const SizedBox(
                      width: 48,
                      height: 48,
                      child: CircularProgressIndicator(),
                    ),
                    errorWidget: (_, _, _) => const Icon(
                      Icons.broken_image,
                      size: 48,
                      color: Colors.white70,
                    ),
                  ),
                ),
              ),
              SafeArea(
                child: Align(
                  alignment: Alignment.topRight,
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: Container(
                      decoration: const BoxDecoration(
                        color: Colors.black45,
                        shape: BoxShape.circle,
                      ),
                      child: IconButton(
                        icon: const Icon(Icons.close, color: Colors.white),
                        tooltip: 'Close',
                        onPressed: () => Navigator.of(context).pop(),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
