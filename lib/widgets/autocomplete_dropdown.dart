import 'package:flutter/material.dart';
import 'emote_image.dart';
import '../models/generic_emote.dart';
import '../services/suggestion.dart';

class AutocompleteDropdown extends StatefulWidget {
  final List<Suggestion> suggestions;
  final void Function(Suggestion) onSelect;
  final void Function(GenericEmote)? onEmoteViewed;

  const AutocompleteDropdown({
    super.key,
    required this.suggestions,
    required this.onSelect,
    this.onEmoteViewed,
  });

  @override
  State<AutocompleteDropdown> createState() => _AutocompleteDropdownState();
}

class _AutocompleteDropdownState extends State<AutocompleteDropdown> {
  static const _fontSize = 16.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 150),
      switchInCurve: Curves.decelerate,
      switchOutCurve: Curves.easeIn,
      transitionBuilder: (child, animation) => FadeTransition(
        opacity: animation,
        child: SizeTransition(
          sizeFactor: animation,
          axis: Axis.vertical,
          alignment: Alignment.topCenter,
          child: child,
        ),
      ),
      child: widget.suggestions.isEmpty
          ? const SizedBox.shrink()
          : AnimatedSize(
              duration: const Duration(milliseconds: 300),
              curve: Curves.ease,
              alignment: Alignment.topCenter,
              child: _buildChild(theme),
            ),
    );
  }

  static const _emoteSize = 36.0;
  static const _rowHeight = 48.0;

  Widget _buildChild(ThemeData theme) {
    final itemCount = widget.suggestions.length;
    final contentHeight = itemCount * _rowHeight;
    return SizedBox(
      height: contentHeight.toDouble(),
      child: Container(
        key: const Key('autocomplete_dropdown'),
        decoration: BoxDecoration(
          color: theme.scaffoldBackgroundColor,
          border: Border(
            top: BorderSide(color: theme.dividerColor.withValues(alpha: 0.3)),
          ),
        ),
        child: ListView.builder(
          padding: EdgeInsets.zero,
          physics: const ClampingScrollPhysics(),
          itemCount: itemCount,
          itemExtent: _rowHeight,
          itemBuilder: (_, i) => _buildRow(theme, widget.suggestions[i]),
        ),
      ),
    );
  }

  Widget _buildRow(ThemeData theme, Suggestion suggestion) {
    if (suggestion is EmoteSuggestion) {
      widget.onEmoteViewed?.call(suggestion.emote);
    }
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: () => widget.onSelect(suggestion),
        child: SizedBox(
          height: _rowHeight,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                switch (suggestion) {
                  UserSuggestion() => Icon(
                    Icons.person,
                    size: 28,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  EmoteSuggestion() => SizedBox(
                    width: _emoteSize,
                    height: _emoteSize,
                    child: EmoteImage(
                      url: suggestion.emote.url,
                      width: _emoteSize,
                      height: _emoteSize,
                      fit: BoxFit.contain,
                      placeholder: ShimmerEmotePlaceholder(
                        width: _emoteSize,
                        height: _emoteSize,
                      ),
                      errorWidget: const Icon(Icons.image, size: 16),
                    ),
                  ),
                  CommandSuggestion() => Icon(
                    Icons.tag,
                    size: 28,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                },
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    suggestion.displayText,
                    style: const TextStyle(fontSize: _fontSize),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
