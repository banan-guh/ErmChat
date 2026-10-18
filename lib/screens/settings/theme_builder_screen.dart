import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/l10n.dart';
import '../../chrome/home_app_bar.dart' show appTitleFits;
import '../../util/chrome_theme.dart';
import '../../util/prefs.dart';
import '../../util/prefs_store.dart';
import '../../widgets/dialogs.dart';

String chromeThemeLabel(AppLocalizations l, ChromeTheme t) => switch (t) {
  ChromeTheme.ermchat => l.chromeThemeErmchat,
  ChromeTheme.dankchat3 => l.chromeThemeDankchat3,
  ChromeTheme.dankchat4 => l.chromeThemeDankchat4,
};

/// A custom theme's name, or a numbered stand-in when it has none.
String customChromeThemeName(
  AppLocalizations l,
  ChromeThemeSpec spec,
  int index,
) => spec.name.isNotEmpty ? spec.name : l.themeBuilderUntitled(index + 1);

/// The user's themes: make one from a preset or from blank, paste one in,
/// edit, use, copy out or delete.
class ThemeBuilderScreen extends StatefulWidget {
  const ThemeBuilderScreen({super.key});

  @override
  State<ThemeBuilderScreen> createState() => _ThemeBuilderScreenState();
}

class _ThemeBuilderScreenState extends State<ThemeBuilderScreen> {
  Prefs? _prefs;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final prefs = await Prefs.load();
    if (mounted) setState(() => _prefs = prefs);
  }

  List<ChromeThemeSpec> get _themes => _prefs?.customChromeThemes ?? const [];

  String _key(int i) => '${Prefs.customChromeThemePrefix}$i';

  Future<void> _save(List<ChromeThemeSpec> themes, {String? select}) async {
    final prefs = _prefs ?? await Prefs.load();
    await prefs.setCustomChromeThemes(themes);
    if (select != null) await prefs.setChromeThemeKey(select);
    PrefsStore.instance.notifyChanged();
    await _reload();
  }

  Future<void> _create() async {
    final l = context.l10n;
    final start = await showChoiceDialog<ChromeThemeSpec>(
      context,
      title: l.themeBuilderStartFrom,
      value: null,
      options: [
        for (final t in ChromeTheme.values)
          (t.spec, chromeThemeLabel(l, t), ''),
        (ChromeThemeSpec.blank, l.themeBuilderBlank, l.themeBuilderBlankHint),
      ],
    );
    if (start == null || !mounted) return;
    await _edit(start, null);
  }

  Future<void> _edit(ChromeThemeSpec spec, int? index) async {
    final saved = await Navigator.of(context).push<ChromeThemeSpec>(
      MaterialPageRoute(builder: (_) => ThemeEditorScreen(initial: spec)),
    );
    if (saved == null) return;
    final themes = [..._themes];
    if (index == null) {
      themes.add(saved);
      // A new theme is made to be used.
      await _save(themes, select: _key(themes.length - 1));
    } else {
      themes[index] = saved;
      await _save(themes);
    }
  }

  Future<void> _import() async {
    final l = context.l10n;
    final messenger = ScaffoldMessenger.of(context);
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final spec = ChromeThemeSpec.decode(data?.text ?? '');
    if (spec == null) {
      messenger.showSnackBar(
        SnackBar(content: Text(l.themeBuilderImportFailed)),
      );
      return;
    }
    await _save([..._themes, spec]);
  }

  Future<void> _copy(ChromeThemeSpec spec) async {
    final messenger = ScaffoldMessenger.of(context);
    final copied = context.l10n.themeBuilderCopied;
    await Clipboard.setData(ClipboardData(text: spec.encode()));
    messenger.showSnackBar(SnackBar(content: Text(copied)));
  }

  Future<void> _delete(int index) async {
    final l = context.l10n;
    final ok = await confirmDialog(
      context,
      title: l.themeBuilderDeleteTitle,
      confirmLabel: l.delete,
      destructive: true,
    );
    if (!ok) return;
    final themes = [..._themes]..removeAt(index);
    // Indices past the deleted theme shift down; the deleted one falls
    // back to the default preset.
    final selected = _prefs?.chromeThemeKey ?? '';
    String? select;
    if (selected.startsWith(Prefs.customChromeThemePrefix)) {
      final i = int.tryParse(
        selected.substring(Prefs.customChromeThemePrefix.length),
      );
      if (i == index) select = ChromeTheme.ermchat.name;
      if (i != null && i > index) select = _key(i - 1);
    }
    await _save(themes, select: select);
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final themes = _themes;
    final selected = _prefs?.chromeThemeKey;
    return Scaffold(
      appBar: AppBar(
        title: Text(l.settingThemeBuilder),
        actions: [
          IconButton(
            tooltip: l.themeBuilderImport,
            icon: const Icon(Icons.content_paste),
            onPressed: _import,
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _create,
        icon: const Icon(Icons.add),
        label: Text(l.themeBuilderNew),
      ),
      body: themes.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Text(
                  l.themeBuilderEmpty,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            )
          : ListView(
              children: [
                for (var i = 0; i < themes.length; i++)
                  ListTile(
                    title: Text(customChromeThemeName(l, themes[i], i)),
                    subtitle: selected == _key(i)
                        ? Text(l.themeBuilderInUse)
                        : null,
                    onTap: () => _edit(themes[i], i),
                    trailing: PopupMenuButton<String>(
                      onSelected: (v) => switch (v) {
                        'use' => _save(themes, select: _key(i)),
                        'copy' => _copy(themes[i]),
                        _ => _delete(i),
                      },
                      itemBuilder: (_) => [
                        if (selected != _key(i))
                          PopupMenuItem(
                            value: 'use',
                            child: Text(l.themeBuilderUse),
                          ),
                        PopupMenuItem(
                          value: 'copy',
                          child: Text(l.themeBuilderCopy),
                        ),
                        PopupMenuItem(value: 'delete', child: Text(l.delete)),
                      ],
                    ),
                  ),
              ],
            ),
    );
  }
}

/// A placeable thing in the preview: one of the chrome actions, or send.
enum _Item {
  join,
  mentions,
  threads,
  settings,
  overflow,
  viewMenu,
  send;

  ChromeAction? get action =>
      ChromeAction.values.where((a) => a.name == name).firstOrNull;

  static _Item of(ChromeAction a) => values.byName(a.name);

  _Part get part => _Part.values.byName(name);

  IconData get icon => switch (this) {
    join => Icons.add,
    mentions => Icons.notifications_active,
    threads => Icons.forum_outlined,
    settings => Icons.settings,
    overflow => Icons.more_vert,
    viewMenu => Icons.expand_more,
    send => Icons.send,
  };
}

/// What the editor's dropdowns edit: the header, the composer, or one item.
enum _Part {
  header,
  composer,
  join,
  mentions,
  threads,
  settings,
  overflow,
  viewMenu,
  send;

  _Item? get item => _Item.values.where((i) => i.name == name).firstOrNull;

  String label(AppLocalizations l) => switch (this) {
    header => l.themeOptionHeader,
    composer => l.themeOptionComposer,
    join => l.themeActionJoin,
    mentions => l.themeActionMentions,
    threads => l.themeActionThreads,
    settings => l.themeActionSettings,
    overflow => l.themeActionOverflow,
    viewMenu => l.themeActionViewMenu,
    send => l.themeActionSend,
  };
}

/// Where an item can sit. Send takes the field, the side column or the
/// row's end; actions take everything else.
enum _Zone {
  appBar,
  strip,
  rowStart,
  rowEnd,
  field,
  column,
  hidden;

  String label(AppLocalizations l, HeaderStyle header) => switch (this) {
    appBar => l.themeRegionAppBar,
    strip =>
      header == HeaderStyle.bubbles ? l.themeRegionPills : l.themeRegionStrip,
    rowStart => l.themeRegionRowStart,
    rowEnd => l.themeRegionRowEnd,
    field => l.themeRegionField,
    column => l.themeRegionColumn,
    hidden => l.themeRegionHidden,
  };
}

/// Edits one theme on a live preview. Pops the edited spec on save.
class ThemeEditorScreen extends StatefulWidget {
  const ThemeEditorScreen({super.key, required this.initial});

  final ChromeThemeSpec initial;

  @override
  State<ThemeEditorScreen> createState() => _ThemeEditorScreenState();
}

class _ThemeEditorScreenState extends State<ThemeEditorScreen> {
  late ChromeThemeSpec _spec = widget.initial;
  late final _name = TextEditingController(text: widget.initial.name);
  _Part _part = _Part.header;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  ChromeThemeSpec get _result => _spec.copyWith(name: _name.text.trim());

  bool get _dirty => _result != widget.initial;

  _Zone _zoneOf(_Item item) {
    if (item == _Item.send) {
      return switch (_spec.send) {
        SendPlace.field => _Zone.field,
        SendPlace.column => _Zone.column,
        SendPlace.row => _Zone.rowEnd,
      };
    }
    final a = item.action!;
    if (_spec.header == HeaderStyle.appBar && _spec.appBarActions.contains(a)) {
      return _Zone.appBar;
    }
    if (_spec.stripActions.contains(a)) return _Zone.strip;
    if (_spec.rowStart.contains(a)) return _Zone.rowStart;
    if (_spec.rowEnd.contains(a)) return _Zone.rowEnd;
    return _Zone.hidden;
  }

  List<_Zone> _zonesFor(_Item item) => item == _Item.send
      ? const [_Zone.field, _Zone.column, _Zone.rowEnd]
      : [
          if (_spec.header == HeaderStyle.appBar) _Zone.appBar,
          _Zone.strip,
          _Zone.rowStart,
          _Zone.rowEnd,
          _Zone.hidden,
        ];

  bool _accepts(_Item item, _Zone zone) => _zonesFor(item).contains(zone);

  /// Moves [item] into [zone], before [before] when it is an item there,
  /// and selects it.
  void _move(_Item item, _Zone zone, {_Item? before}) {
    if (!_accepts(item, zone)) return;
    setState(() {
      _part = item.part;
      if (item == _Item.send) {
        _spec = _spec.copyWith(
          send: switch (zone) {
            _Zone.column => SendPlace.column,
            _Zone.rowEnd || _Zone.rowStart => SendPlace.row,
            _ => SendPlace.field,
          },
        );
        return;
      }
      final a = item.action!;
      List<ChromeAction> without(List<ChromeAction> list) =>
          [...list]..remove(a);
      List<ChromeAction> into(List<ChromeAction> list) {
        final out = without(list);
        final at = before?.action == null ? -1 : out.indexOf(before!.action!);
        at < 0 ? out.add(a) : out.insert(at, a);
        return out;
      }

      List<ChromeAction> pick(_Zone z, List<ChromeAction> list) =>
          zone == z ? into(list) : without(list);
      _spec = _spec.copyWith(
        appBarActions: pick(_Zone.appBar, _spec.appBarActions),
        stripActions: pick(_Zone.strip, _spec.stripActions),
        rowStart: pick(_Zone.rowStart, _spec.rowStart),
        rowEnd: pick(_Zone.rowEnd, _spec.rowEnd),
      );
    });
  }

  void _setHeader(HeaderStyle header) => setState(() {
    // App bar actions would vanish without an app bar; they join the strip.
    _spec = header == HeaderStyle.appBar
        ? _spec.copyWith(header: header)
        : _spec.copyWith(
            header: header,
            stripActions: [..._spec.appBarActions, ..._spec.stripActions],
            appBarActions: const [],
          );
  });

  void _edit(ChromeThemeSpec Function(ChromeThemeSpec) change) =>
      setState(() => _spec = change(_spec));

  /// The selected part's properties, one dropdown each.
  List<Widget> _properties(AppLocalizations l) {
    final spec = _spec;
    final item = _part.item;
    return [
      if (_part == _Part.header)
        _dropdown<HeaderStyle>(l.themePropStyle, spec.header, [
          (HeaderStyle.strip, l.themeHeaderStrip),
          (HeaderStyle.appBar, l.themeHeaderAppBar),
          (HeaderStyle.bubbles, l.themeHeaderPills),
        ], _setHeader),
      if (_part == _Part.composer)
        _dropdown<bool>(l.themePropStyle, spec.islandFlush, [
          (false, l.themeComposerIsland),
          (true, l.themeComposerFlush),
        ], (v) => _edit((s) => s.copyWith(islandFlush: v))),
      if (item != null)
        _dropdown<_Zone>(l.themePropPlace, _zoneOf(item), [
          for (final z in _zonesFor(item)) (z, z.label(l, spec.header)),
        ], (z) => _move(item, z)),
      if (_part == _Part.join)
        _dropdown<bool>(l.themeOptionLoading, spec.busyBar, [
          (false, l.themeLoadingSpinner),
          (true, l.themeLoadingBar),
        ], (v) => _edit((s) => s.copyWith(busyBar: v))),
    ];
  }

  Widget _dropdown<T>(
    String label,
    T value,
    List<(T, String)> options,
    ValueChanged<T> onChanged,
  ) => DropdownButtonFormField<T>(
    // Keyed by value, so a change made in the preview shows here.
    key: ValueKey((_part, label, value)),
    initialValue: value,
    isExpanded: true,
    decoration: InputDecoration(
      labelText: label,
      isDense: true,
      border: const OutlineInputBorder(),
    ),
    items: [
      for (final (v, text) in options)
        DropdownMenuItem(
          value: v,
          child: Text(text, overflow: TextOverflow.ellipsis),
        ),
    ],
    onChanged: (v) {
      if (v != null) onChanged(v);
    },
  );

  Future<void> _confirmLeave() async {
    final l = context.l10n;
    final nav = Navigator.of(context);
    final ok = await confirmDialog(
      context,
      title: l.themeBuilderDiscardTitle,
      confirmLabel: l.themeBuilderDiscard,
      destructive: true,
    );
    if (ok) nav.pop();
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final theme = Theme.of(context);
    final valid = _spec.reachesSettings;
    final hidden = [
      for (final a in ChromeAction.values)
        if (_zoneOf(_Item.of(a)) == _Zone.hidden) _Item.of(a),
    ];
    final properties = _properties(l);
    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _confirmLeave();
      },
      child: Scaffold(
        appBar: AppBar(
          titleSpacing: 0,
          // The name edits in place; a tap anywhere else lets it go.
          title: TextField(
            controller: _name,
            style: theme.textTheme.titleLarge,
            textInputAction: TextInputAction.done,
            inputFormatters: [
              LengthLimitingTextInputFormatter(ChromeThemeSpec.maxNameLength),
            ],
            decoration: InputDecoration(
              hintText: l.themeBuilderNameHint,
              border: InputBorder.none,
            ),
            onTapOutside: (_) => FocusManager.instance.primaryFocus?.unfocus(),
            onChanged: (_) => setState(() {}),
          ),
          actions: [
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: FilledButton(
                onPressed: valid
                    ? () => Navigator.of(context).pop(_result)
                    : null,
                child: Text(l.save),
              ),
            ),
          ],
        ),
        body: SafeArea(
          top: false,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: Row(
                  children: [
                    Expanded(
                      child: _dropdown<_Part>(l.themeBuilderElement, _part, [
                        for (final p in _Part.values) (p, p.label(l)),
                      ], (p) => setState(() => _part = p)),
                    ),
                    for (final p in properties.take(1)) ...[
                      const SizedBox(width: 12),
                      Expanded(child: p),
                    ],
                  ],
                ),
              ),
              // A second property (app name, loading, settings) gets its
              // own row under the first pair.
              for (final p in properties.skip(1))
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                  child: Row(
                    children: [
                      const Spacer(),
                      const SizedBox(width: 12),
                      Expanded(child: p),
                    ],
                  ),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: Text(
                  valid ? l.themeBuilderHint : l.themeBuilderNoSettings,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: valid
                        ? theme.colorScheme.onSurfaceVariant
                        : theme.colorScheme.error,
                  ),
                ),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: _ThemePreview(
                    spec: _spec,
                    selected: _part,
                    onSelect: (p) => setState(() => _part = p),
                    onDrop: _move,
                    accepts: _accepts,
                  ),
                ),
              ),
              _ZoneTarget(
                zone: _Zone.hidden,
                accepts: _accepts,
                onDrop: _move,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Row(
                    children: [
                      Text(
                        l.themeRegionHidden,
                        style: theme.textTheme.titleSmall,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: SizedBox(
                          height: 48,
                          child: Row(
                            children: [
                              for (final item in hidden)
                                _PreviewItem(
                                  item: item,
                                  zone: _Zone.hidden,
                                  selected: _part == item.part,
                                  onSelect: (p) => setState(() => _part = p),
                                  onDrop: _move,
                                  accepts: _accepts,
                                ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

typedef _Accepts = bool Function(_Item item, _Zone zone);
typedef _OnDrop = void Function(_Item item, _Zone zone, {_Item? before});

/// A drop zone: anything [accepts] lets in lands at its end, and the zone
/// lights up while a valid item hovers.
class _ZoneTarget extends StatelessWidget {
  const _ZoneTarget({
    required this.zone,
    required this.accepts,
    required this.onDrop,
    required this.child,
  });

  final _Zone zone;
  final _Accepts accepts;
  final _OnDrop onDrop;
  final Widget child;

  @override
  Widget build(BuildContext context) => DragTarget<_Item>(
    onWillAcceptWithDetails: (d) => accepts(d.data, zone),
    onAcceptWithDetails: (d) => onDrop(d.data, zone),
    builder: (context, candidates, _) => DecoratedBox(
      decoration: BoxDecoration(
        color: candidates.isEmpty
            ? null
            : Theme.of(context).colorScheme.primary.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
      ),
      child: child,
    ),
  );
}

/// One button in the preview: tap to select it, drag it anywhere it fits.
/// Dropping another item on it puts that one just before it.
class _PreviewItem extends StatelessWidget {
  const _PreviewItem({
    required this.item,
    required this.zone,
    required this.selected,
    required this.onSelect,
    required this.onDrop,
    required this.accepts,
  });

  final _Item item;
  final _Zone zone;
  final bool selected;
  final ValueChanged<_Part> onSelect;
  final _OnDrop onDrop;
  final _Accepts accepts;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget icon({bool lifted = false}) => Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: selected || lifted
            ? scheme.primaryContainer
            : Colors.transparent,
        border: selected ? Border.all(color: scheme.primary, width: 2) : null,
      ),
      child: Icon(
        item.icon,
        size: 22,
        color: selected || lifted ? scheme.onPrimaryContainer : null,
      ),
    );
    return DragTarget<_Item>(
      onWillAcceptWithDetails: (d) => d.data != item && accepts(d.data, zone),
      onAcceptWithDetails: (d) => onDrop(d.data, zone, before: item),
      // A bar on the left marks where a hovering item lands, without moving
      // anything.
      builder: (context, candidates, _) => DecoratedBox(
        decoration: BoxDecoration(
          border: Border(
            left: BorderSide(
              color: candidates.isEmpty ? Colors.transparent : scheme.primary,
              width: 2,
            ),
          ),
        ),
        child: Draggable<_Item>(
          data: item,
          feedback: Material(
            type: MaterialType.transparency,
            child: icon(lifted: true),
          ),
          childWhenDragging: Opacity(opacity: 0.3, child: icon()),
          child: GestureDetector(
            onTap: () => onSelect(item.part),
            child: icon(),
          ),
        ),
      ),
    );
  }
}

/// The theme drawn as a phone screen: header, chat and the composer. Every
/// part selects on tap, and placed buttons drag.
class _ThemePreview extends StatelessWidget {
  const _ThemePreview({
    required this.spec,
    required this.selected,
    required this.onSelect,
    required this.onDrop,
    required this.accepts,
  });

  final ChromeThemeSpec spec;
  final _Part selected;
  final ValueChanged<_Part> onSelect;
  final _OnDrop onDrop;
  final _Accepts accepts;

  Widget _items(_Zone zone, List<_Item> items, {double minWidth = 24}) =>
      _ZoneTarget(
        zone: zone,
        accepts: accepts,
        onDrop: onDrop,
        child: ConstrainedBox(
          constraints: BoxConstraints(minWidth: minWidth, minHeight: 40),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final item in items)
                _PreviewItem(
                  item: item,
                  zone: zone,
                  selected: selected == item.part,
                  onSelect: onSelect,
                  onDrop: onDrop,
                  accepts: accepts,
                ),
            ],
          ),
        ),
      );

  List<_Item> _of(List<ChromeAction> actions) => [
    for (final a in actions) _Item.of(a),
  ];

  /// A tappable region that outlines while its part is selected.
  Widget _part(
    BuildContext context,
    _Part part,
    Widget child, {
    BorderRadius radius = BorderRadius.zero,
  }) => GestureDetector(
    behavior: HitTestBehavior.opaque,
    onTap: () => onSelect(part),
    child: DecoratedBox(
      position: DecorationPosition.foreground,
      decoration: BoxDecoration(
        borderRadius: radius,
        border: selected == part
            ? Border.all(color: Theme.of(context).colorScheme.primary, width: 2)
            : null,
      ),
      child: child,
    ),
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final l = context.l10n;
    // The tabs give way to the actions and clip, as a full strip scrolls.
    Widget tabs() => SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      physics: const NeverScrollableScrollPhysics(),
      child: Row(
        children: [
          for (final (i, name) in const ['#forsen', '#vedal987'].indexed)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Text(
                name,
                style: theme.textTheme.labelLarge?.copyWith(
                  color: i == 0 ? scheme.primary : scheme.onSurfaceVariant,
                ),
              ),
            ),
        ],
      ),
    );
    Widget pill(Widget child) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(24),
      ),
      child: child,
    );
    final strip = _items(_Zone.strip, _of(spec.stripActions));
    final header = switch (spec.header) {
      HeaderStyle.strip => Row(
        children: [
          Expanded(child: tabs()),
          strip,
        ],
      ),
      HeaderStyle.appBar => Column(
        children: [
          SizedBox(
            height: 48,
            child: Row(
              children: [
                // The real bar spans the screen, so the name shows here
                // exactly when it will there.
                if (appTitleFits(
                  context,
                  MediaQuery.sizeOf(context).width,
                  spec.appBarActions.length,
                ))
                  Padding(
                    padding: const EdgeInsets.only(left: 12),
                    child: Text(l.appTitle, style: theme.textTheme.titleMedium),
                  ),
                const Spacer(),
                _items(_Zone.appBar, _of(spec.appBarActions)),
              ],
            ),
          ),
          Row(
            children: [
              Expanded(child: tabs()),
              strip,
            ],
          ),
        ],
      ),
      HeaderStyle.bubbles => Row(
        children: [
          Flexible(child: pill(tabs())),
          const Spacer(),
          pill(strip),
        ],
      ),
    };
    // Chat reads from the left, newest at the bottom, as in a channel.
    Widget line(double width, Color name) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 10,
            decoration: BoxDecoration(
              color: name.withValues(alpha: 0.7),
              borderRadius: BorderRadius.circular(5),
            ),
          ),
          const SizedBox(width: 8),
          Flexible(
            child: FractionallySizedBox(
              widthFactor: width,
              child: Container(
                height: 10,
                decoration: BoxDecoration(
                  color: scheme.onSurface.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(5),
                ),
              ),
            ),
          ),
        ],
      ),
    );
    final chat = Align(
      alignment: Alignment.bottomLeft,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            line(0.7, Colors.redAccent),
            line(0.45, Colors.lightBlueAccent),
            line(0.9, Colors.greenAccent),
            line(0.35, Colors.amberAccent),
            line(0.6, Colors.purpleAccent),
            line(0.8, Colors.lightBlueAccent),
          ],
        ),
      ),
    );
    // The emote button follows send, so tapping it edits send.
    final emote = GestureDetector(
      onTap: () => onSelect(_Part.send),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Icon(
          Icons.emoji_emotions_outlined,
          color: scheme.onSurfaceVariant,
        ),
      ),
    );
    final send = [_Item.send];
    final field = Row(
      children: [
        if (spec.send == SendPlace.field) emote,
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
            child: Text(
              l.typeMessageHint,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
        _items(_Zone.field, spec.send == SendPlace.field ? send : const []),
      ],
    );
    final row = Row(
      children: [
        if (spec.send != SendPlace.field) emote,
        _items(_Zone.rowStart, _of(spec.rowStart)),
        const Spacer(),
        _items(_Zone.rowEnd, [
          ..._of(spec.rowEnd),
          if (spec.send == SendPlace.row) _Item.send,
        ]),
      ],
    );
    const corner = Radius.circular(20);
    final radius = spec.islandFlush
        ? const BorderRadius.vertical(top: corner)
        : const BorderRadius.all(corner);
    final island = Padding(
      padding: spec.islandFlush ? EdgeInsets.zero : const EdgeInsets.all(8),
      child: _part(
        context,
        _Part.composer,
        radius: radius,
        Container(
          decoration: BoxDecoration(
            color: scheme.surfaceContainer,
            borderRadius: radius,
          ),
          child: IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      field,
                      // With no row in the theme, an outlined strip stays
                      // as a place to drop the first button.
                      if (spec.hasRow)
                        row
                      else
                        Container(
                          margin: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                          decoration: BoxDecoration(
                            border: Border.all(color: scheme.outlineVariant),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: row,
                        ),
                    ],
                  ),
                ),
                _items(
                  _Zone.column,
                  spec.send == SendPlace.column ? send : const [],
                ),
              ],
            ),
          ),
        ),
      ),
    );
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: theme.scaffoldBackgroundColor,
        border: Border.all(color: scheme.outlineVariant),
        borderRadius: BorderRadius.circular(24),
      ),
      child: Column(
        children: [
          _part(
            context,
            _Part.header,
            Container(
              color: spec.header == HeaderStyle.bubbles
                  ? null
                  : scheme.surfaceContainerLow,
              padding: const EdgeInsets.fromLTRB(4, 4, 4, 4),
              child: header,
            ),
          ),
          Expanded(child: chat),
          island,
        ],
      ),
    );
  }
}
