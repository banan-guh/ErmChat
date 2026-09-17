import 'package:flutter/services.dart';

// Ports Android's mark-as-replaced DEL undo: a single backspace right after
// an autocomplete insertion restores the text the user had typed. SAFE mode
// validates the region content, not just the cursor position.
class AutocompleteRevertFormatter extends TextInputFormatter {
  int? _start;
  String? _original;
  String? _replacement;

  void markReplaced({
    required int start,
    required String original,
    required String replacement,
  }) {
    _start = start;
    _original = original;
    _replacement = replacement;
  }

  void clear() {
    _start = null;
    _original = null;
    _replacement = null;
  }

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final start = _start;
    final original = _original;
    final replacement = _replacement;
    if (start == null || original == null || replacement == null) {
      return newValue;
    }
    if (!newValue.selection.isCollapsed) {
      clear();
      return newValue;
    }

    final prev = oldValue.text;
    final text = newValue.text;
    final replEnd = start + replacement.length;

    if (replacement.isEmpty ||
        start < 0 ||
        replEnd > prev.length ||
        replEnd - 1 > text.length ||
        text.length != prev.length - 1 ||
        newValue.selection.baseOffset != replEnd - 1 ||
        text.substring(start, replEnd - 1) !=
            replacement.substring(0, replacement.length - 1) ||
        text.substring(replEnd - 1) != prev.substring(replEnd)) {
      clear();
      return newValue;
    }

    clear();
    return TextEditingValue(
      text: '${prev.substring(0, start)}$original${prev.substring(replEnd)}',
      selection: TextSelection.collapsed(offset: start + original.length),
    );
  }
}
