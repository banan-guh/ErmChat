import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import 'design_tokens.dart';

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
    final showHeader = available >= 120;

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
            child: TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: 1),
              duration: Motion.fast,
              curve: Motion.enter,
              builder: (context, t, child) => Opacity(
                opacity: t,
                child: Transform.scale(
                  scale: 0.98 + 0.02 * t,
                  alignment: Alignment.bottomCenter,
                  child: child,
                ),
              ),
              child: Material(
                elevation: 3,
                clipBehavior: Clip.antiAlias,
                borderRadius: BorderRadius.circular(Radii.medium),
                color: Theme.of(context).colorScheme.surfaceContainerHigh,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(Radii.medium),
                    border: Border.all(
                      color: Theme.of(
                        context,
                      ).colorScheme.outlineVariant.withValues(alpha: 0.45),
                    ),
                  ),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      maxHeight: math.min(available, 360),
                    ),
                    child: ValueListenableBuilder<List<String>>(
                      valueListenable: widget.history,
                      builder: (_, items, _) => Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (showHeader) ...[
                            Padding(
                              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                              child: Row(
                                children: [
                                  Icon(
                                    Icons.history,
                                    size: 18,
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.onSurfaceVariant,
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      context.l10n.sentHistoryTitle,
                                      style: Theme.of(
                                        context,
                                      ).textTheme.titleSmall,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Divider(
                              height: 1,
                              color: Theme.of(context)
                                  .colorScheme
                                  .outlineVariant
                                  .withValues(alpha: 0.35),
                            ),
                          ],
                          if (items.isEmpty)
                            Padding(
                              padding: EdgeInsets.symmetric(
                                horizontal: 20,
                                vertical: showHeader ? 24 : 8,
                              ),
                              child: showHeader
                                  ? Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(
                                          Icons.history_outlined,
                                          size: 24,
                                          color: Theme.of(
                                            context,
                                          ).colorScheme.onSurfaceVariant,
                                        ),
                                        const SizedBox(height: 8),
                                        Text(
                                          context.l10n.sentHistoryEmpty,
                                          textAlign: TextAlign.center,
                                          style: Theme.of(
                                            context,
                                          ).textTheme.bodyMedium,
                                        ),
                                      ],
                                    )
                                  : Text(
                                      context.l10n.sentHistoryEmpty,
                                      textAlign: TextAlign.center,
                                      style: Theme.of(
                                        context,
                                      ).textTheme.bodyMedium,
                                    ),
                            )
                          else
                            Flexible(
                              child: ListView.builder(
                                primary: false,
                                shrinkWrap: true,
                                padding: const EdgeInsets.fromLTRB(0, 4, 0, 8),
                                itemCount: items.length,
                                itemBuilder: (_, i) => Material(
                                  type: MaterialType.transparency,
                                  child: InkWell(
                                    onTap: () => _select(items[i]),
                                    child: ConstrainedBox(
                                      constraints: const BoxConstraints(
                                        minHeight: 44,
                                      ),
                                      child: Padding(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 16,
                                          vertical: 10,
                                        ),
                                        child: Align(
                                          alignment: Alignment.centerLeft,
                                          child: Text(
                                            items[i],
                                            style: Theme.of(
                                              context,
                                            ).textTheme.bodyMedium,
                                            maxLines: 2,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
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
