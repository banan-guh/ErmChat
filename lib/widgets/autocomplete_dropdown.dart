import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../services/suggestion.dart';

class AutocompleteDropdown extends StatefulWidget {
  final List<Suggestion> suggestions;
  final void Function(Suggestion) onSelect;

  const AutocompleteDropdown({
    super.key,
    required this.suggestions,
    required this.onSelect,
  });

  @override
  State<AutocompleteDropdown> createState() => _AutocompleteDropdownState();
}

class _AutocompleteDropdownState extends State<AutocompleteDropdown> {
  static const _fontSize = 16.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (widget.suggestions.isEmpty) return const SizedBox.shrink();
    return _buildChild(theme);
  }

  static const _emoteSize = 36.0;
  static const _rowHeight = 48.0;

  Widget _buildChild(ThemeData theme) {
    return LayoutBuilder(
      builder: (_, constraints) {
        final itemCount = widget.suggestions.length;
        final contentHeight = itemCount * _rowHeight;
        final maxH = constraints.maxHeight;
        final height = maxH.isFinite
            ? contentHeight.clamp(0.0, maxH)
            : contentHeight.toDouble();
        return SizedBox(
          height: height,
          child: Container(
            key: const Key('autocomplete_dropdown'),
            decoration: BoxDecoration(
              color: theme.scaffoldBackgroundColor,
              border: Border(
                top: BorderSide(
                  color: theme.dividerColor.withValues(alpha: 0.3),
                ),
              ),
            ),
            child: ListView.builder(
              padding: EdgeInsets.zero,
              physics: const ClampingScrollPhysics(),
              itemCount: itemCount,
              itemExtent: _rowHeight,
              itemBuilder: (_, i) =>
                  _buildRow(theme, widget.suggestions[i]),
            ),
          ),
        );
      },
    );
  }

  Widget _buildRow(ThemeData theme, Suggestion suggestion) {
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
                    child: CachedNetworkImage(
                      imageUrl: suggestion.emote.url,
                      fit: BoxFit.contain,
                      fadeInDuration: Duration.zero,
                      placeholder: (_, _) => const SizedBox(),
                      errorWidget: (_, _, _) =>
                          const Icon(Icons.image, size: 16),
                    ),
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
