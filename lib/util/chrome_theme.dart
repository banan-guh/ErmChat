/// Chrome themes: where the header, the button row and their actions go.
/// Each theme is a [ChromeThemeSpec]; consumers read the spec, never the
/// theme itself. The presets are locked specs; custom themes are specs the
/// user builds, stored and shared through [ChromeThemeSpec.encode].
library;

import 'package:flutter/foundation.dart';

/// How the top of the screen is built.
enum HeaderStyle {
  /// One strip: channel tabs, then the strip's actions.
  strip('s'),

  /// A titled app bar with its actions above a plain tab strip.
  appBar('a'),

  /// The strip split into floating pills: tabs, then actions.
  bubbles('b');

  const HeaderStyle(this.code);

  /// One letter in [ChromeThemeSpec.encode].
  final String code;
}

/// A chrome button that a theme places in the header or the row.
enum ChromeAction {
  /// Join a channel.
  join('j'),

  /// The bell: mentions and whispers.
  mentions('m'),

  /// Threads dashboard.
  threads('t'),

  /// Settings.
  settings('s'),

  /// The ⋮ menu: upload, reload emotes, reconnect.
  overflow('o'),

  /// The view menu: fullscreen, input, stream, search.
  viewMenu('v');

  const ChromeAction(this.code);

  /// One letter in [ChromeThemeSpec.encode].
  final String code;
}

/// Where send goes.
/// How the field and its buttons sit at the bottom of the screen.
enum ComposerStyle {
  /// A floating island with rounded corners.
  island,

  /// The island runs edge to edge under the nav bar, rounded only on top.
  flush,

  /// A plain outlined field with a floating label and no island.
  classic,
}

enum SendPlace {
  /// Send sits in the field row.
  field('f'),

  /// Send runs down the island's side, beside the field and the row.
  column('c'),

  /// Send ends the row, which then stays up while typing.
  row('r');

  const SendPlace(this.code);

  /// One letter in [ChromeThemeSpec.encode].
  final String code;
}

/// A composer button the layout places but never removes.
enum ComposerPart {
  emote('e'),
  send('x');

  const ComposerPart(this.code);

  /// One letter in [ChromeThemeSpec.encode].
  final String code;
}

/// A place a [ComposerPart] can sit: either side of the field, down the
/// island's side (send only), or in the button row (the emote button takes
/// its start, send its end).
enum PartPlace { fieldStart, fieldEnd, column, row }

/// A button in the field row: a chrome action or a composer part.
@immutable
class FieldItem {
  const FieldItem.action(ChromeAction this.action) : part = null;
  const FieldItem.part(ComposerPart this.part) : action = null;

  static const emote = FieldItem.part(ComposerPart.emote);
  static const send = FieldItem.part(ComposerPart.send);

  final ChromeAction? action;
  final ComposerPart? part;

  /// One letter in [ChromeThemeSpec.encode].
  String get code => action?.code ?? part!.code;

  static FieldItem? fromCode(String c) {
    for (final a in ChromeAction.values) {
      if (a.code == c) return FieldItem.action(a);
    }
    for (final p in ComposerPart.values) {
      if (p.code == c) return FieldItem.part(p);
    }
    return null;
  }

  @override
  bool operator ==(Object other) =>
      other is FieldItem && other.action == action && other.part == part;

  @override
  int get hashCode => Object.hash(action, part);
}

/// A place a [ChromeAction] can sit.
enum LayoutSlot {
  /// The strip's end (the action pill for [HeaderStyle.bubbles]).
  strip,

  /// The app bar, for [HeaderStyle.appBar].
  appBar,

  /// The island's button row, left of its gap.
  rowStart,

  /// The island's button row, right of its gap.
  rowEnd,

  /// The field row, before the text field.
  fieldStart,

  /// The field row, after the text field.
  fieldEnd;

  bool get isField => this == fieldStart || this == fieldEnd;
}

/// Why an action cannot leave the layout.
enum LayoutBlock {
  /// It would leave settings unreachable.
  settings,

  /// It would leave no way to the view menu.
  viewPath,
}

@immutable
class ChromeThemeSpec {
  const ChromeThemeSpec({
    this.name = '',
    required this.header,
    required this.stripActions,
    this.rowStart = const [],
    this.rowEnd = const [],
    this.appBarActions = const [],
    this.fieldStart = const [FieldItem.emote],
    this.fieldEnd = const [FieldItem.send],
    this.sendAside = SendPlace.column,
    this.compact = false,
    this.composer = ComposerStyle.island,
    this.busyBar = false,
  });

  /// The theme's name; presets are named in the UI instead.
  final String name;

  final HeaderStyle header;

  /// The strip's end, in order; for [HeaderStyle.bubbles], the action
  /// pill. Join elsewhere drops the strip's trailing join tab.
  final List<ChromeAction> stripActions;

  /// The app bar's actions, in order, for [HeaderStyle.appBar].
  final List<ChromeAction> appBarActions;

  /// The island's button row, left of its free gap.
  final List<ChromeAction> rowStart;

  /// The island's button row, right of its free gap.
  final List<ChromeAction> rowEnd;

  /// The field row's buttons before the text field, in order.
  final List<FieldItem> fieldStart;

  /// The field row's buttons after the text field, in order.
  final List<FieldItem> fieldEnd;

  /// Where send sits while it is not in the field row: the side column or
  /// the row's end.
  final SendPlace sendAside;

  /// The island's button row hides while typing, leaving the field row.
  /// Only an [isIsland] layout can have it.
  final bool compact;

  final ComposerStyle composer;

  /// A floating island: the style that takes glass and [compact].
  bool get isIsland => composer == ComposerStyle.island;

  /// The island runs edge to edge under the nav bar, rounded only on top.
  bool get islandFlush => composer == ComposerStyle.flush;

  /// Loading shows as a bar along the top of the button row instead of a
  /// spinner in the join button.
  final bool busyBar;

  /// Most buttons the field row holds, both sides together.
  static const fieldCap = 2;

  /// The field row's buttons, start then end.
  List<FieldItem> get fieldItems => [...fieldStart, ...fieldEnd];

  bool inField(FieldItem item) =>
      fieldStart.contains(item) || fieldEnd.contains(item);

  /// Where send sits: in the field, else where it was put aside.
  SendPlace get send => inField(FieldItem.send)
      ? SendPlace.field
      : sendAside == SendPlace.row
      ? SendPlace.row
      : SendPlace.column;

  /// Whether the emote button sits at the row's start instead of the field.
  bool get emoteInRow => !inField(FieldItem.emote);

  /// The row's actions, start then end.
  List<ChromeAction> get rowActions => [...rowStart, ...rowEnd];

  /// The actions in the field row.
  List<ChromeAction> get fieldActions => [
    for (final i in fieldItems)
      if (i.action != null) i.action!,
  ];

  /// Whether the island has a button row: it holds an action, or emote or
  /// send left the field for it.
  bool get hasRow =>
      rowActions.isNotEmpty || send != SendPlace.field || emoteInRow;

  /// Send ends the row instead of running down the island's side. The row
  /// then stays up while typing.
  bool get sendInRow => send == SendPlace.row;

  bool places(ChromeAction action) =>
      stripActions.contains(action) ||
      (header == HeaderStyle.appBar && appBarActions.contains(action)) ||
      rowActions.contains(action) ||
      fieldActions.contains(action);

  /// Settings heads the ⋮ menu whenever it isn't placed as a button.
  bool get settingsInMenu => !places(ChromeAction.settings);

  /// Settings stays reachable: a button, or the ⋮ menu it heads.
  bool get reachesSettings =>
      places(ChromeAction.settings) || places(ChromeAction.overflow);

  /// Whether the theme keeps the app usable: settings are reachable and the
  /// view menu (search, input, fullscreen) has a button or the ⋮ menu it can
  /// fall back to.
  bool get isUsable =>
      reachesSettings &&
      (places(ChromeAction.viewMenu) || places(ChromeAction.overflow));

  /// A copy that is [isUsable]: settings and a view path are restored on the
  /// strip when the theme hid them, so it cannot lock the user out. It is
  /// also [fitted].
  ChromeThemeSpec normalized() {
    var spec = fitted();
    if (!spec.reachesSettings) {
      spec = spec.copyWith(
        stripActions: [...spec.stripActions, ChromeAction.settings],
      );
    }
    if (!spec.places(ChromeAction.viewMenu) &&
        !spec.places(ChromeAction.overflow)) {
      spec = spec.copyWith(
        stripActions: [...spec.stripActions, ChromeAction.viewMenu],
      );
    }
    return spec;
  }

  /// A copy that obeys the field row's rules. It holds at most [fieldCap]
  /// buttons, and an action cut from it lands at the row's end. Leaving the
  /// island clears [compact]. Under [compact] send sits in the field, since
  /// the row and the side column are gone while typing.
  ChromeThemeSpec fitted() {
    final start = [...fieldStart];
    final end = [...fieldEnd];
    final spill = <ChromeAction>[];
    void cutLast() {
      final cut = end.isNotEmpty ? end.removeLast() : start.removeLast();
      if (cut.action != null) spill.add(cut.action!);
    }

    while (start.length + end.length > fieldCap) {
      cutLast();
    }
    final keepsCompact = compact && isIsland;
    if (keepsCompact &&
        !start.contains(FieldItem.send) &&
        !end.contains(FieldItem.send)) {
      if (start.length + end.length >= fieldCap) cutLast();
      end.add(FieldItem.send);
    }
    return copyWith(
      fieldStart: start,
      fieldEnd: end,
      rowEnd: [...rowEnd, ...spill],
      compact: keepsCompact,
    );
  }

  /// The slots this header style shows.
  List<LayoutSlot> get slots => [
    LayoutSlot.strip,
    if (header == HeaderStyle.appBar) LayoutSlot.appBar,
    LayoutSlot.rowStart,
    LayoutSlot.rowEnd,
    LayoutSlot.fieldStart,
    LayoutSlot.fieldEnd,
  ];

  /// The actions in [slot], in order.
  List<ChromeAction> actionsIn(LayoutSlot slot) => switch (slot) {
    LayoutSlot.strip => stripActions,
    LayoutSlot.appBar => appBarActions,
    LayoutSlot.rowStart => rowStart,
    LayoutSlot.rowEnd => rowEnd,
    LayoutSlot.fieldStart || LayoutSlot.fieldEnd => [
      for (final i in itemsIn(slot))
        if (i.action != null) i.action!,
    ],
  };

  /// Everything in [slot], in order. Only the field holds parts.
  List<FieldItem> itemsIn(LayoutSlot slot) => switch (slot) {
    LayoutSlot.fieldStart => fieldStart,
    LayoutSlot.fieldEnd => fieldEnd,
    _ => [for (final a in actionsIn(slot)) FieldItem.action(a)],
  };

  /// Where [action] shows, or null when it is not placed.
  LayoutSlot? slotOf(ChromeAction action) {
    for (final slot in slots) {
      if (actionsIn(slot).contains(action)) return slot;
    }
    return null;
  }

  /// Whether the field row can take [item]: it is in the field already or
  /// the field has room.
  bool canPlaceField(FieldItem item) =>
      inField(item) || fieldItems.length < fieldCap;

  /// Whether [action] may go to [slot].
  bool canPlace(ChromeAction action, LayoutSlot slot) =>
      !slot.isField || canPlaceField(FieldItem.action(action));

  /// Where [part] shows now.
  PartPlace placeOf(ComposerPart part) {
    final item = FieldItem.part(part);
    if (fieldStart.contains(item)) return PartPlace.fieldStart;
    if (fieldEnd.contains(item)) return PartPlace.fieldEnd;
    if (part == ComposerPart.emote) return PartPlace.row;
    return send == SendPlace.row ? PartPlace.row : PartPlace.column;
  }

  /// Whether [part] may be put at [place]. Under [compact] send stays in
  /// the field, the only place that survives typing.
  bool canPlacePart(ComposerPart part, PartPlace place) => switch (place) {
    PartPlace.fieldStart ||
    PartPlace.fieldEnd => canPlaceField(FieldItem.part(part)),
    PartPlace.column => part == ComposerPart.send && !compact,
    PartPlace.row => part == ComposerPart.emote || !compact,
  };

  static List<FieldItem> _with(
    List<FieldItem> side,
    FieldItem item,
    int? index,
  ) {
    final out = [...side]..remove(item);
    var at = index ?? side.length;
    final from = side.indexOf(item);
    if (from >= 0 && from < at) at--;
    return out..insert(at.clamp(0, out.length), item);
  }

  /// A copy with [action] moved to [slot] at [index] (the end by default),
  /// or removed when [slot] is null. An action sits in one place. A full
  /// field row refuses it.
  ChromeThemeSpec place(ChromeAction action, LayoutSlot? slot, {int? index}) {
    if (slot != null && !canPlace(action, slot)) return this;
    final item = FieldItem.action(action);
    final lists = {
      for (final s in LayoutSlot.values)
        if (!s.isField) s: [...actionsIn(s)]..remove(action),
    };
    var start = [...fieldStart]..remove(item);
    var end = [...fieldEnd]..remove(item);
    if (slot == LayoutSlot.fieldStart) {
      start = _with(fieldStart, item, index);
    } else if (slot == LayoutSlot.fieldEnd) {
      end = _with(fieldEnd, item, index);
    } else if (slot != null) {
      final target = lists[slot]!;
      var at = index ?? actionsIn(slot).length;
      final from = actionsIn(slot).indexOf(action);
      if (from >= 0 && from < at) at--;
      target.insert(at.clamp(0, target.length), action);
    }
    return copyWith(
      stripActions: lists[LayoutSlot.strip],
      appBarActions: lists[LayoutSlot.appBar],
      rowStart: lists[LayoutSlot.rowStart],
      rowEnd: lists[LayoutSlot.rowEnd],
      fieldStart: start,
      fieldEnd: end,
    );
  }

  /// A copy with [part] at [place], at [index] on a field side. A place it
  /// cannot take leaves the copy unchanged.
  ChromeThemeSpec placePart(ComposerPart part, PartPlace place, {int? index}) {
    if (!canPlacePart(part, place)) return this;
    final item = FieldItem.part(part);
    var start = [...fieldStart]..remove(item);
    var end = [...fieldEnd]..remove(item);
    if (place == PartPlace.fieldStart) start = _with(fieldStart, item, index);
    if (place == PartPlace.fieldEnd) end = _with(fieldEnd, item, index);
    return copyWith(
      fieldStart: start,
      fieldEnd: end,
      sendAside: part != ComposerPart.send
          ? sendAside
          : place == PartPlace.row
          ? SendPlace.row
          : place == PartPlace.column
          ? SendPlace.column
          : sendAside,
    );
  }

  /// Why [action] cannot be removed, or null when it can. A layout that
  /// already lacks a path blocks nothing about it.
  LayoutBlock? removeBlock(ChromeAction action) {
    final after = place(action, null);
    if (reachesSettings && !after.reachesSettings) return LayoutBlock.settings;
    if (isUsable && !after.isUsable) return LayoutBlock.viewPath;
    return null;
  }

  /// A copy in header style [style]. Leaving the app bar moves its actions
  /// onto the strip so none are lost.
  ChromeThemeSpec withHeader(HeaderStyle style) {
    if (style == header) return this;
    if (style == HeaderStyle.appBar) return copyWith(header: style);
    return copyWith(
      header: style,
      appBarActions: const [],
      stripActions: [
        ...stripActions,
        for (final a in appBarActions)
          if (!stripActions.contains(a)) a,
      ],
    );
  }

  ChromeThemeSpec copyWith({
    String? name,
    HeaderStyle? header,
    List<ChromeAction>? stripActions,
    List<ChromeAction>? appBarActions,
    List<ChromeAction>? rowStart,
    List<ChromeAction>? rowEnd,
    List<FieldItem>? fieldStart,
    List<FieldItem>? fieldEnd,
    SendPlace? sendAside,
    bool? compact,
    ComposerStyle? composer,
    bool? busyBar,
  }) => ChromeThemeSpec(
    name: name ?? this.name,
    header: header ?? this.header,
    stripActions: stripActions ?? this.stripActions,
    appBarActions: appBarActions ?? this.appBarActions,
    rowStart: rowStart ?? this.rowStart,
    rowEnd: rowEnd ?? this.rowEnd,
    fieldStart: fieldStart ?? this.fieldStart,
    fieldEnd: fieldEnd ?? this.fieldEnd,
    sendAside: sendAside ?? this.sendAside,
    compact: compact ?? this.compact,
    composer: composer ?? this.composer,
    busyBar: busyBar ?? this.busyBar,
  );

  /// Longest [name] a theme keeps.
  static const maxNameLength = 32;

  static const _prefix = 'ermchat-theme:1';

  /// A short single line for pasting. Every letter appears at most once, so
  /// a theme stays well under a hundred characters plus its name.
  String encode() {
    String actions(List<ChromeAction> a) => a.map((x) => x.code).join();
    String items(List<FieldItem> a) => a.map((x) => x.code).join();
    final flags = [
      if (islandFlush) 'F',
      if (composer == ComposerStyle.classic) 'Q',
      if (busyBar) 'B',
    ].join();
    return [
      _prefix,
      if (name.isNotEmpty) 'n=${Uri.encodeComponent(name)}',
      'h=${header.code}',
      if (stripActions.isNotEmpty) 't=${actions(stripActions)}',
      if (appBarActions.isNotEmpty) 'a=${actions(appBarActions)}',
      if (rowStart.isNotEmpty) 'r=${actions(rowStart)}',
      if (rowEnd.isNotEmpty) 'R=${actions(rowEnd)}',
      if (fieldStart.isNotEmpty) 'fs=${items(fieldStart)}',
      if (fieldEnd.isNotEmpty) 'fe=${items(fieldEnd)}',
      's=${send.code}',
      'c=${compact ? 1 : 0}',
      if (flags.isNotEmpty) 'f=$flags',
    ].join(';');
  }

  /// Parses [encode]'s line, or null when it isn't one. Unknown letters are
  /// skipped and a button placed twice keeps its first place, so a
  /// hand-edited line still loads as something usable. A line with no `c=`
  /// predates the field row: its emote and send places map onto the field,
  /// and an island with a row, send not in it, gets [compact] (the layout it
  /// always showed on a phone).
  static ChromeThemeSpec? decode(String text) {
    final parts = text.trim().split(';');
    if (parts.isEmpty || parts.first != _prefix) return null;
    final fields = <String, String>{};
    for (final p in parts.skip(1)) {
      final eq = p.indexOf('=');
      if (eq <= 0) continue;
      fields[p.substring(0, eq)] = p.substring(eq + 1);
    }
    final header = HeaderStyle.values
        .where((h) => h.code == fields['h'])
        .firstOrNull;
    if (header == null) return null;
    final seen = <FieldItem>{};
    List<ChromeAction> actions(String key) => [
      for (final c in (fields[key] ?? '').split(''))
        if (FieldItem.fromCode(c) case final i?
            when i.action != null && seen.add(i))
          i.action!,
    ];
    List<FieldItem> items(String key) => [
      for (final c in (fields[key] ?? '').split(''))
        if (FieldItem.fromCode(c) case final i? when seen.add(i)) i,
    ];
    String name;
    try {
      name = Uri.decodeComponent(fields['n'] ?? '');
    } on ArgumentError {
      name = '';
    } on FormatException {
      name = '';
    }
    final flags = fields['f'] ?? '';
    final flush = flags.contains('F');
    final send =
        SendPlace.values.where((s) => s.code == fields['s']).firstOrNull ??
        SendPlace.field;
    final strip = actions('t');
    final appBar = actions('a');
    final rowStart = actions('r');
    final rowEnd = actions('R');
    List<FieldItem> start;
    List<FieldItem> end;
    bool compact;
    if (fields.containsKey('c')) {
      start = items('fs');
      end = items('fe');
      compact = fields['c'] == '1';
    } else {
      final emoteInField = switch (fields['e']) {
        'f' => true,
        'r' => false,
        _ => send == SendPlace.field,
      };
      final hadRow =
          rowStart.isNotEmpty ||
          rowEnd.isNotEmpty ||
          send != SendPlace.field ||
          !emoteInField;
      compact = !flush && hadRow && send != SendPlace.row;
      start = [if (emoteInField || compact) FieldItem.emote];
      end = [if (send == SendPlace.field || compact) FieldItem.send];
    }
    return ChromeThemeSpec(
      name: name.length > maxNameLength
          ? name.substring(0, maxNameLength)
          : name,
      header: header,
      stripActions: strip,
      appBarActions: appBar,
      rowStart: rowStart,
      rowEnd: rowEnd,
      fieldStart: start,
      fieldEnd: end,
      sendAside: send == SendPlace.row ? SendPlace.row : SendPlace.column,
      compact: compact,
      composer: flush
          ? ComposerStyle.flush
          : flags.contains('Q')
          ? ComposerStyle.classic
          : ComposerStyle.island,
      busyBar: flags.contains('B'),
    ).fitted();
  }

  /// A plain strip with settings and the view menu, emote and send in the
  /// field: the start for a theme built from nothing.
  static const blank = ChromeThemeSpec(
    header: HeaderStyle.strip,
    stripActions: [ChromeAction.settings, ChromeAction.viewMenu],
  );

  @override
  bool operator ==(Object other) =>
      other is ChromeThemeSpec &&
      other.name == name &&
      other.header == header &&
      listEquals(other.stripActions, stripActions) &&
      listEquals(other.appBarActions, appBarActions) &&
      listEquals(other.rowStart, rowStart) &&
      listEquals(other.rowEnd, rowEnd) &&
      listEquals(other.fieldStart, fieldStart) &&
      listEquals(other.fieldEnd, fieldEnd) &&
      other.send == send &&
      other.compact == compact &&
      other.composer == composer &&
      other.busyBar == busyBar;

  @override
  int get hashCode => Object.hash(
    name,
    header,
    Object.hashAll(stripActions),
    Object.hashAll(appBarActions),
    Object.hashAll(rowStart),
    Object.hashAll(rowEnd),
    Object.hashAll(fieldStart),
    Object.hashAll(fieldEnd),
    send,
    compact,
    composer,
    busyBar,
  );
}

enum ChromeTheme {
  ermchat(
    ChromeThemeSpec(
      header: HeaderStyle.strip,
      stripActions: [ChromeAction.viewMenu],
      rowStart: [
        ChromeAction.settings,
        ChromeAction.overflow,
        ChromeAction.threads,
        ChromeAction.mentions,
      ],
      // Send runs down the island's side, not in the field row. Compact
      // would pull it into the field, so the preset leaves compact off.
      fieldEnd: [],
      sendAside: SendPlace.column,
    ),
  ),

  /// After ermchat 0.9: a titled app bar, a plain outlined field below.
  dankchat3(
    ChromeThemeSpec(
      header: HeaderStyle.appBar,
      appBarActions: [
        ChromeAction.join,
        ChromeAction.mentions,
        ChromeAction.overflow,
      ],
      stripActions: [ChromeAction.viewMenu],
      composer: ComposerStyle.classic,
    ),
  ),

  /// After DankChat 4: header pills, an edge-to-edge bar with send in it.
  dankchat4(
    ChromeThemeSpec(
      header: HeaderStyle.bubbles,
      stripActions: [
        ChromeAction.join,
        ChromeAction.mentions,
        ChromeAction.overflow,
      ],
      rowEnd: [ChromeAction.threads, ChromeAction.viewMenu],
      fieldStart: [],
      fieldEnd: [],
      sendAside: SendPlace.row,
      composer: ComposerStyle.flush,
      busyBar: true,
    ),
  );

  const ChromeTheme(this.spec);

  final ChromeThemeSpec spec;
}
