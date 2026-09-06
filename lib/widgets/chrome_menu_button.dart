import 'package:flutter/material.dart';

// Dropdown for mod view plus fullscreen, input, and stream toggles.
class ChromeMenuButton extends StatefulWidget {
  final VoidCallback onToggleFullscreen;
  final VoidCallback onToggleInput;
  final VoidCallback? onToggleStream;
  final bool Function()? showStreamToggle;
  final bool Function()? streamActive;
  final VoidCallback? onShowModView;
  final bool Function()? showModView;

  const ChromeMenuButton({
    super.key,
    required this.onToggleFullscreen,
    required this.onToggleInput,
    this.onToggleStream,
    this.showStreamToggle,
    this.streamActive,
    this.onShowModView,
    this.showModView,
  });

  @override
  State<ChromeMenuButton> createState() => ChromeMenuButtonState();
}

class ChromeMenuButtonState extends State<ChromeMenuButton> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
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
            const PopupMenuItem(
              value: 'modview',
              child: Row(
                children: [
                  Icon(Icons.shield_outlined, size: 20),
                  SizedBox(width: 12),
                  Text('Mod view'),
                ],
              ),
            ),
          if (showMod) const PopupMenuDivider(),
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
      child: Container(
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(8),
        ),
        padding: const EdgeInsets.all(4),
        child: AnimatedRotation(
          turns: _open ? 0.5 : 0.0,
          duration: const Duration(milliseconds: 175),
          child: Icon(
            Icons.expand_more,
            size: 20,
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}
