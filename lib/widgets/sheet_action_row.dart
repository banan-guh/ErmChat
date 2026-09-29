import 'package:flutter/material.dart';

/// One button in a [SheetActionRow].
class SheetAction {
  const SheetAction({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;
}

/// Compact row of icon-over-label buttons for bottom sheet actions, in place
/// of a stack of full-width list tiles. Fixed height (see [heightFor]) so
/// pagers can size themselves without measuring.
class SheetActionRow extends StatelessWidget {
  const SheetActionRow({super.key, required this.actions});

  final List<SheetAction> actions;

  static const _labelSize = 12.0;
  static const _labelHeight = 1.3;

  /// Row height at [scaler]'s text scale.
  static double heightFor(TextScaler scaler) =>
      8 + 24 + 4 + scaler.scale(_labelSize) * _labelHeight + 8;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.onSurfaceVariant;
    return SizedBox(
      height: heightFor(MediaQuery.textScalerOf(context)),
      child: Row(
        children: [
          for (final action in actions)
            Expanded(
              child: InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: action.onTap,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(action.icon, size: 24, color: color),
                    const SizedBox(height: 4),
                    Text(
                      action.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: _labelSize,
                        height: _labelHeight,
                        color: color,
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
