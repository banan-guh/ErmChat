import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../l10n/l10n.dart';

/// Sent-message history anchored to its chrome button.
class SentHistoryButton extends StatefulWidget {
  const SentHistoryButton({
    super.key,
    required this.history,
    required this.onSelect,
  });

  final ValueListenable<List<String>> history;
  final ValueChanged<String> onSelect;

  @override
  State<SentHistoryButton> createState() => _SentHistoryButtonState();
}

class _SentHistoryButtonState extends State<SentHistoryButton> {
  final _portal = OverlayPortalController();
  final _anchorKey = GlobalKey();
  bool _open = false;

  void _close() {
    if (!_open) return;
    setState(() => _open = false);
    _portal.hide();
  }

  void _toggle() {
    if (_open) {
      _close();
      return;
    }
    setState(() => _open = true);
    _portal.show();
  }

  void _select(String text) {
    _close();
    widget.onSelect(text);
  }

  Widget _menu(BuildContext context) {
    final media = MediaQuery.of(context);
    final size = media.size;
    final safeTop = media.padding.top + 8;
    final keyboardTop = size.height - media.viewInsets.bottom;
    final box = _anchorKey.currentContext?.findRenderObject();
    final anchor = box is RenderBox && box.hasSize
        ? box.localToGlobal(Offset.zero) & box.size
        : Rect.zero;
    // The composer can sit under the IME during a resize tick. Clamp to the
    // keyboard top so the menu never extends beneath it.
    final aboveBottom = math.min(anchor.top, keyboardTop - 8);
    final above = math.max(0.0, aboveBottom - safeTop);
    final belowTop = anchor.bottom + 8;
    final below = math.max(0.0, keyboardTop - belowTop);
    final openAbove = above >= below;
    final available = openAbove ? above : below;
    final width = math.min(320.0, size.width - 16);
    final maxLeft = math.max(8.0, size.width - width - 8);
    final left = (anchor.center.dx - width / 2).clamp(8.0, maxLeft);

    return SizedBox.expand(
      child: Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _close,
              child: const SizedBox.expand(),
            ),
          ),
          Positioned(
            left: left,
            top: openAbove ? null : belowTop,
            bottom: openAbove ? size.height - aboveBottom : null,
            width: width,
            child: Material(
              elevation: 6,
              clipBehavior: Clip.antiAlias,
              borderRadius: BorderRadius.circular(12),
              color: Theme.of(context).colorScheme.surfaceContainerHigh,
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: math.min(available, 360),
                ),
                child: ValueListenableBuilder<List<String>>(
                  valueListenable: widget.history,
                  builder: (_, items, _) {
                    if (items.isEmpty) {
                      return Padding(
                        padding: const EdgeInsets.all(20),
                        child: Text(context.l10n.sentHistoryEmpty),
                      );
                    }
                    return ListView.builder(
                      primary: false,
                      shrinkWrap: true,
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      itemCount: items.length,
                      itemBuilder: (_, i) => ListTile(
                        title: Text(
                          items[i],
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        onTap: () => _select(items[i]),
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_open,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop && _open) _close();
    },
    child: OverlayPortal(
      controller: _portal,
      overlayChildBuilder: _menu,
      child: IconButton(
        key: _anchorKey,
        icon: const Icon(Icons.history),
        tooltip: context.l10n.sentHistoryTitle,
        color: _open ? Theme.of(context).colorScheme.primary : null,
        onPressed: _toggle,
      ),
    ),
  );
}
