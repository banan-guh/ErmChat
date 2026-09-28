import 'package:flutter/material.dart';

/// A badge that shows its name on tap, with a circular splash.
class BadgeChip extends StatefulWidget {
  const BadgeChip({super.key, required this.label, required this.child});

  final String label;
  final Widget child;

  @override
  State<BadgeChip> createState() => _BadgeChipState();
}

class _BadgeChipState extends State<BadgeChip> {
  final _tooltip = GlobalKey<TooltipState>();

  @override
  Widget build(BuildContext context) {
    // Manual trigger: a tap-triggered Tooltip would lose the tap to the ink.
    // Above, so the name never covers the card text under the badges.
    return Tooltip(
      key: _tooltip,
      message: widget.label,
      triggerMode: TooltipTriggerMode.manual,
      preferBelow: false,
      // The ink sits over the image, 2px past its edge, without moving it.
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          widget.child,
          Positioned.fill(
            left: -4,
            top: -4,
            right: -4,
            bottom: -4,
            child: Material(
              type: MaterialType.transparency,
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: () => _tooltip.currentState?.ensureTooltipVisible(),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
