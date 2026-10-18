import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/l10n.dart';
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

  IconData get icon => switch (this) {
    join => Icons.add,
    mentions => Icons.notifications_active,
    threads => Icons.forum_outlined,
    settings => Icons.settings,
    overflow => Icons.more_vert,
    viewMenu => Icons.expand_more,
    send => Icons.send,
  };

  String label(AppLocalizations l) => switch (this) {
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
  _Item? _selected;

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

  /// Moves [item] into [zone], before [before] when it is an item there.
  void _move(_Item item, _Zone zone, {_Item? before}) {
    if (!_zonesFor(item).contains(zone)) return;
    setState(() {
      _selected = null;
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

  Future<void> _tapItem(_Item item) async {
    if (_selected != item) {
      setState(() => _selected = item);
    }
    final l = context.l10n;
    final current = _zoneOf(item);
    final zone = await showChoiceDialog<_Zone>(
      context,
      title: l.themeMoveTo(item.label(l)),
      value: current,
      options: [
        for (final z in _zonesFor(item)) (z, z.label(l, _spec.header), ''),
      ],
    );
    if (!mounted) return;
    if (zone == null || zone == current) {
      setState(() => _selected = null);
      return;
    }
    _move(item, zone);
  }

  Future<T?> _pick<T>(
    String title,
    T value,
    List<(T, String, String)> options,
  ) => showChoiceDialog<T>(
    context,
    title: title,
    value: value,
    options: options,
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
    final spec = _spec;
    final valid = spec.reachesSettings;
    final options = <(String, String, VoidCallback)>[
      (
        l.themeOptionHeader,
        switch (spec.header) {
          HeaderStyle.strip => l.themeHeaderStrip,
          HeaderStyle.appBar => l.themeHeaderAppBar,
          HeaderStyle.bubbles => l.themeHeaderPills,
        },
        () async {
          final h = await _pick(l.themeOptionHeader, spec.header, [
            (HeaderStyle.strip, l.themeHeaderStrip, l.themeHeaderStripHint),
            (HeaderStyle.appBar, l.themeHeaderAppBar, l.themeHeaderAppBarHint),
            (HeaderStyle.bubbles, l.themeHeaderPills, l.themeHeaderPillsHint),
          ]);
          if (h != null) _setHeader(h);
        },
      ),
      if (spec.header == HeaderStyle.appBar)
        (
          l.themeOptionAppName,
          spec.appBarTitle ? l.themeAppNameShown : l.themeAppNameHidden,
          () async {
            final v = await _pick(l.themeOptionAppName, spec.appBarTitle, [
              (true, l.themeAppNameShown, l.themeAppNameShownHint),
              (false, l.themeAppNameHidden, l.themeAppNameHiddenHint),
            ]);
            if (v != null) {
              setState(() => _spec = _spec.copyWith(appBarTitle: v));
            }
          },
        ),
      (
        l.themeOptionComposer,
        spec.islandFlush ? l.themeComposerFlush : l.themeComposerIsland,
        () async {
          final v = await _pick(l.themeOptionComposer, spec.islandFlush, [
            (false, l.themeComposerIsland, l.themeComposerIslandHint),
            (true, l.themeComposerFlush, l.themeComposerFlushHint),
          ]);
          if (v != null) setState(() => _spec = _spec.copyWith(islandFlush: v));
        },
      ),
      (
        l.themeOptionSettings,
        spec.settingsInMenu ? l.themeSettingsInMenu : l.themeSettingsButton,
        () async {
          final v = await _pick(l.themeOptionSettings, spec.settingsInMenu, [
            (false, l.themeSettingsButton, l.themeSettingsButtonHint),
            (true, l.themeSettingsInMenu, l.themeSettingsInMenuHint),
          ]);
          if (v != null) {
            setState(() => _spec = _spec.copyWith(settingsInMenu: v));
          }
        },
      ),
      (
        l.themeOptionLoading,
        spec.busyBar ? l.themeLoadingBar : l.themeLoadingSpinner,
        () async {
          final v = await _pick(l.themeOptionLoading, spec.busyBar, [
            (false, l.themeLoadingSpinner, l.themeLoadingSpinnerHint),
            (true, l.themeLoadingBar, l.themeLoadingBarHint),
          ]);
          if (v != null) setState(() => _spec = _spec.copyWith(busyBar: v));
        },
      ),
    ];
    final hidden = [
      for (final a in ChromeAction.values)
        if (_zoneOf(_Item.of(a)) == _Zone.hidden) _Item.of(a),
    ];
    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _confirmLeave();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(l.themeBuilderEdit),
          actions: [
            TextButton(
              onPressed: valid
                  ? () => Navigator.of(context).pop(_result)
                  : null,
              child: Text(l.save),
            ),
          ],
        ),
        body: ListView(
          padding: const EdgeInsets.only(bottom: 24),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: TextField(
                controller: _name,
                maxLength: ChromeThemeSpec.maxNameLength,
                decoration: InputDecoration(labelText: l.themeBuilderName),
                onChanged: (_) => setState(() {}),
              ),
            ),
            SizedBox(
              height: 56,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                children: [
                  for (final (title, value, onTap) in options)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: ActionChip(
                        label: Text('$title: $value'),
                        onPressed: onTap,
                      ),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                valid ? l.themeBuilderHint : l.themeBuilderNoSettings,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: valid
                      ? Theme.of(context).colorScheme.onSurfaceVariant
                      : Theme.of(context).colorScheme.error,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: _ThemePreview(
                spec: spec,
                selected: _selected,
                onTap: _tapItem,
                onDrop: _move,
                accepts: (item, zone) => _zonesFor(item).contains(zone),
              ),
            ),
            _ZoneTarget(
              zone: _Zone.hidden,
              accepts: (item, zone) => _zonesFor(item).contains(zone),
              onDrop: _move,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l.themeRegionHidden,
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    const SizedBox(height: 8),
                    SizedBox(
                      height: 48,
                      child: Row(
                        children: [
                          for (final item in hidden)
                            _PreviewItem(
                              item: item,
                              zone: _Zone.hidden,
                              selected: _selected == item,
                              onTap: _tapItem,
                              onDrop: _move,
                              accepts: (i, z) => _zonesFor(i).contains(z),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
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

/// One button in the preview: tap to move it, drag it anywhere it fits.
/// Dropping another item on it puts that one just before it.
class _PreviewItem extends StatelessWidget {
  const _PreviewItem({
    required this.item,
    required this.zone,
    required this.selected,
    required this.onTap,
    required this.onDrop,
    required this.accepts,
  });

  final _Item item;
  final _Zone zone;
  final bool selected;
  final void Function(_Item item) onTap;
  final _OnDrop onDrop;
  final _Accepts accepts;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget icon({bool lifted = false}) => Container(
      width: 36,
      height: 36,
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
          child: Tooltip(
            message: item.label(context.l10n),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: () => onTap(item),
              child: icon(),
            ),
          ),
        ),
      ),
    );
  }
}

/// The theme drawn as a small phone screen: header, a few chat lines and the
/// composer, with every placed button live for tapping and dragging.
class _ThemePreview extends StatelessWidget {
  const _ThemePreview({
    required this.spec,
    required this.selected,
    required this.onTap,
    required this.onDrop,
    required this.accepts,
  });

  final ChromeThemeSpec spec;
  final _Item? selected;
  final void Function(_Item item) onTap;
  final _OnDrop onDrop;
  final _Accepts accepts;

  Widget _items(_Zone zone, List<_Item> items, {double minWidth = 36}) =>
      _ZoneTarget(
        zone: zone,
        accepts: accepts,
        onDrop: onDrop,
        child: ConstrainedBox(
          constraints: BoxConstraints(minWidth: minWidth, minHeight: 36),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final item in items)
                _PreviewItem(
                  item: item,
                  zone: zone,
                  selected: selected == item,
                  onTap: onTap,
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
              padding: const EdgeInsets.symmetric(horizontal: 8),
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
          Row(
            children: [
              if (spec.appBarTitle)
                Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: Text(l.appTitle, style: theme.textTheme.titleMedium),
                ),
              const Spacer(),
              _items(_Zone.appBar, _of(spec.appBarActions)),
            ],
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
    Widget line(double widthFactor) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: FractionallySizedBox(
        alignment: Alignment.centerLeft,
        widthFactor: widthFactor,
        child: Container(
          height: 8,
          decoration: BoxDecoration(
            color: scheme.onSurface.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(4),
          ),
        ),
      ),
    );
    final emote = Padding(
      padding: const EdgeInsets.all(6),
      child: Icon(
        Icons.emoji_emotions_outlined,
        color: scheme.onSurfaceVariant,
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
              style: theme.textTheme.bodyMedium?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
        _items(
          _Zone.field,
          spec.send == SendPlace.field ? send : const [],
          minWidth: 24,
        ),
      ],
    );
    final row = Row(
      children: [
        if (spec.send != SendPlace.field) emote,
        _items(_Zone.rowStart, _of(spec.rowStart), minWidth: 24),
        const Spacer(),
        _items(_Zone.rowEnd, minWidth: 24, [
          ..._of(spec.rowEnd),
          if (spec.send == SendPlace.row) _Item.send,
        ]),
      ],
    );
    const corner = Radius.circular(20);
    final island = Container(
      margin: spec.islandFlush ? EdgeInsets.zero : const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: scheme.surfaceContainer,
        borderRadius: spec.islandFlush
            ? const BorderRadius.vertical(top: corner)
            : const BorderRadius.all(corner),
      ),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                // The row stays a drop zone while the theme has none, dimmed,
                // so a button can always be dragged in.
                children: [
                  field,
                  Opacity(opacity: spec.hasRow ? 1 : 0.4, child: row),
                ],
              ),
            ),
            _items(
              _Zone.column,
              spec.send == SendPlace.column ? send : const [],
              minWidth: 24,
            ),
          ],
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
          Container(
            color: spec.header == HeaderStyle.bubbles
                ? null
                : scheme.surfaceContainerLow,
            padding: const EdgeInsets.fromLTRB(4, 8, 4, 4),
            child: header,
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Column(
              children: [
                line(0.7),
                line(0.5),
                line(0.85),
                line(0.4),
                line(0.6),
              ],
            ),
          ),
          island,
        ],
      ),
    );
  }
}
