import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

// Dropdown for search, mod view, and fullscreen, input, stream toggles.
class ChromeMenuButton extends StatefulWidget {
  final VoidCallback onToggleFullscreen;
  final VoidCallback onToggleInput;
  final VoidCallback? onToggleStream;
  final bool Function()? showStreamToggle;
  final bool Function()? streamActive;
  final VoidCallback? onShowModView;
  final bool Function()? showModView;
  final VoidCallback? onToggleSearch;

  /// Glass spike: glass tile trigger to match the floating glass header.
  final bool glass;

  const ChromeMenuButton({
    super.key,
    required this.onToggleFullscreen,
    required this.onToggleInput,
    this.onToggleStream,
    this.showStreamToggle,
    this.streamActive,
    this.onShowModView,
    this.showModView,
    this.onToggleSearch,
    this.glass = false,
  });

  @override
  State<ChromeMenuButton> createState() => ChromeMenuButtonState();
}

class ChromeMenuButtonState extends State<ChromeMenuButton> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final arrow = AnimatedRotation(
      turns: _open ? 0.5 : 0.0,
      duration: const Duration(milliseconds: 175),
      child: Icon(
        Icons.expand_more,
        size: 20,
        color: theme.colorScheme.onSurfaceVariant,
      ),
    );
    return PopupMenuButton<String>(
      position: PopupMenuPosition.under,
      popUpAnimationStyle: const AnimationStyle(
        duration: Duration(milliseconds: 175),
      ),
      onOpened: () => setState(() => _open = true),
      onCanceled: () => setState(() => _open = false),
      onSelected: (value) {
        setState(() => _open = false);
        switch (value) {
          case 'modview':
            widget.onShowModView?.call();
            break;
          case 'search':
            widget.onToggleSearch?.call();
            break;
          case 'fullscreen':
            widget.onToggleFullscreen();
            break;
          case 'input':
            widget.onToggleInput();
            break;
          case 'stream':
            widget.onToggleStream?.call();
            break;
        }
      },
      itemBuilder: (_) {
        final showMod = widget.showModView?.call() ?? false;
        final showStream = widget.showStreamToggle?.call() ?? false;
        final active = widget.streamActive?.call() ?? false;
        return [
          if (showMod)
            const PopupMenuItem(value: 'modview', child: Text('Mod view')),
          const PopupMenuItem(value: 'search', child: Text('Search')),
          const PopupMenuItem(
            value: 'fullscreen',
            child: Text('Toggle fullscreen'),
          ),
          const PopupMenuItem(value: 'input', child: Text('Toggle input')),
          if (showStream)
            PopupMenuItem(
              value: 'stream',
              child: Text(active ? 'Hide stream' : 'Show stream'),
            ),
        ];
      },
      child: widget.glass
          ? GlassContainer(
              quality: GlassQuality.premium,
              useOwnLayer: true,
              shape: const LiquidRoundedSuperellipse(borderRadius: 8),
              child: Padding(padding: const EdgeInsets.all(4), child: arrow),
            )
          : Container(
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: theme.colorScheme.outlineVariant),
              ),
              padding: const EdgeInsets.all(4),
              child: arrow,
            ),
    );
  }
}
