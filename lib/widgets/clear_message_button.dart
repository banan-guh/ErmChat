import 'package:flutter/material.dart';

import '../l10n/l10n.dart';

/// Clears the message field. Greyed out while the text is empty, so a chrome
/// placement does not shift; the field hides it on its own.
class ClearMessageButton extends StatelessWidget {
  const ClearMessageButton({super.key, required this.controller, this.color});

  final TextEditingController controller;
  final Color? color;

  @override
  Widget build(BuildContext context) =>
      ValueListenableBuilder<TextEditingValue>(
        valueListenable: controller,
        builder: (context, value, _) {
          final empty = value.text.isEmpty;
          return Material(
            type: MaterialType.transparency,
            child: IconButton(
              icon: Icon(Icons.close, size: 24, color: empty ? null : color),
              tooltip: context.l10n.clearMessage,
              onPressed: empty ? null : controller.clear,
            ),
          );
        },
      );
}
