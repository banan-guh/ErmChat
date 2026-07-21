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

    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 150),
      switchInCurve: Curves.decelerate,
      switchOutCurve: Curves.easeIn,
      transitionBuilder: (child, animation) {
        return FadeTransition(
          opacity: animation,
          child: SizeTransition(
            sizeFactor: animation,
            axis: Axis.vertical,
            alignment: Alignment.topCenter,
            child: child,
          ),
        );
      },
      child: widget.suggestions.isEmpty
          ? const SizedBox.shrink()
          : _buildContent(theme),
    );
  }

  Widget _buildContent(ThemeData theme) {
    return AnimatedSize(
      duration: const Duration(milliseconds: 300),
      curve: Curves.ease,
      alignment: Alignment.topCenter,
      child: Container(
        key: const Key('autocomplete_dropdown'),
        decoration: BoxDecoration(
          color: theme.scaffoldBackgroundColor,
          border: Border(
            top: BorderSide(color: theme.dividerColor.withValues(alpha: 0.3)),
          ),
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final suggestion in widget.suggestions)
                _buildRow(theme, suggestion),
            ],
          ),
        ),
      ),
    );
  }

  static const _emoteSize = 28.0;
  static const _rowHeight = 40.0;

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
                    size: 22,
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
