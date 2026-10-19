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
enum SendPlace {
  /// Emote and send sit in the field.
  field('f'),

  /// Send runs down the island's side, beside the field and the row.
  column('c'),

  /// Send ends the row, which then stays up while typing.
  row('r');

  const SendPlace(this.code);

  /// One letter in [ChromeThemeSpec.encode].
  final String code;
}

/// Where the emote button goes. A spec that never set it follows send: in
/// the field while send is, otherwise at the row's start.
enum EmotePlace {
  /// The field's start.
  field('f'),

  /// The row's start.
  row('r');

  const EmotePlace(this.code);

  /// One letter in [ChromeThemeSpec.encode].
  final String code;
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
    this.send = SendPlace.field,
    this._emote,
    this.islandFlush = false,
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

  /// The island's button row, left of its free gap, after emote.
  final List<ChromeAction> rowStart;

  /// The island's button row, right of its free gap, before send.
  final List<ChromeAction> rowEnd;

  final SendPlace send;

  final EmotePlace? _emote;

  /// Where the emote button sits: the place set, else the one send implies.
  EmotePlace get emote =>
      _emote ?? (send == SendPlace.field ? EmotePlace.field : EmotePlace.row);

  /// The island runs edge to edge under the nav bar, rounded only on top.
  final bool islandFlush;

  /// Loading shows as a bar along the top of the button row instead of a
  /// spinner in the join button.
  final bool busyBar;

  /// The row's actions, start then end.
  List<ChromeAction> get rowActions => [...rowStart, ...rowEnd];

  /// Whether the island has a button row: it holds an action, or emote or
  /// send left the field for it.
  bool get hasRow =>
      rowActions.isNotEmpty ||
      send != SendPlace.field ||
      emote == EmotePlace.row;

  /// A copy with send at [place] and the emote button where it is now.
  ChromeThemeSpec placeSend(SendPlace place) =>
      copyWith(send: place, emote: emote);

  /// Send ends the row instead of running down the island's side. The row
  /// then stays up while typing.
  bool get sendInRow => send == SendPlace.row;

  bool places(ChromeAction action) =>
      stripActions.contains(action) ||
      (header == HeaderStyle.appBar && appBarActions.contains(action)) ||
      rowActions.contains(action);

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
  /// strip when the theme hid them, so it cannot lock the user out.
  ChromeThemeSpec normalized() {
    var spec = this;
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

  /// The slots this header style shows.
  List<LayoutSlot> get slots => [
    LayoutSlot.strip,
    if (header == HeaderStyle.appBar) LayoutSlot.appBar,
    LayoutSlot.rowStart,
    LayoutSlot.rowEnd,
  ];

  List<ChromeAction> actionsIn(LayoutSlot slot) => switch (slot) {
    LayoutSlot.strip => stripActions,
    LayoutSlot.appBar => appBarActions,
    LayoutSlot.rowStart => rowStart,
    LayoutSlot.rowEnd => rowEnd,
  };

  /// Where [action] shows, or null when it is not placed.
  LayoutSlot? slotOf(ChromeAction action) {
    for (final slot in slots) {
      if (actionsIn(slot).contains(action)) return slot;
    }
    return null;
  }

  /// A copy with [action] moved to [slot] at [index] (the end by default),
  /// or removed when [slot] is null. An action sits in one place.
  ChromeThemeSpec place(ChromeAction action, LayoutSlot? slot, {int? index}) {
    final lists = {
      for (final s in LayoutSlot.values) s: [...actionsIn(s)]..remove(action),
    };
    if (slot != null) {
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
    SendPlace? send,
    EmotePlace? emote,
    bool? islandFlush,
    bool? busyBar,
  }) => ChromeThemeSpec(
    name: name ?? this.name,
    header: header ?? this.header,
    stripActions: stripActions ?? this.stripActions,
    appBarActions: appBarActions ?? this.appBarActions,
    rowStart: rowStart ?? this.rowStart,
    rowEnd: rowEnd ?? this.rowEnd,
    send: send ?? this.send,
    emote: emote ?? _emote,
    islandFlush: islandFlush ?? this.islandFlush,
    busyBar: busyBar ?? this.busyBar,
  );

  /// Longest [name] a theme keeps.
  static const maxNameLength = 32;

  static const _prefix = 'ermchat-theme:1';

  /// A short single line for pasting. Every action letter appears at most
  /// once, so a theme stays well under a hundred characters plus its name.
  String encode() {
    String codes(List<ChromeAction> a) => a.map((x) => x.code).join();
    final flags = [if (islandFlush) 'F', if (busyBar) 'B'].join();
    return [
      _prefix,
      if (name.isNotEmpty) 'n=${Uri.encodeComponent(name)}',
      'h=${header.code}',
      if (stripActions.isNotEmpty) 't=${codes(stripActions)}',
      if (appBarActions.isNotEmpty) 'a=${codes(appBarActions)}',
      if (rowStart.isNotEmpty) 'r=${codes(rowStart)}',
      if (rowEnd.isNotEmpty) 'R=${codes(rowEnd)}',
      's=${send.code}',
      'e=${emote.code}',
      if (flags.isNotEmpty) 'f=$flags',
    ].join(';');
  }

  /// Parses [encode]'s line, or null when it isn't one. Unknown letters are
  /// skipped and an action placed twice keeps its first place, so a
  /// hand-edited line still loads as something usable. A line without an
  /// emote place follows send, as every line did before it existed.
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
    final seen = <ChromeAction>{};
    List<ChromeAction> actions(String key) => [
      for (final c in (fields[key] ?? '').split(''))
        if (ChromeAction.values.where((a) => a.code == c).firstOrNull
            case final a? when seen.add(a))
          a,
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
    return ChromeThemeSpec(
      name: name.length > maxNameLength
          ? name.substring(0, maxNameLength)
          : name,
      header: header,
      stripActions: actions('t'),
      appBarActions: actions('a'),
      rowStart: actions('r'),
      rowEnd: actions('R'),
      send:
          SendPlace.values.where((s) => s.code == fields['s']).firstOrNull ??
          SendPlace.field,
      emote: EmotePlace.values.where((e) => e.code == fields['e']).firstOrNull,
      islandFlush: flags.contains('F'),
      busyBar: flags.contains('B'),
    );
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
      other.send == send &&
      other.emote == emote &&
      other.islandFlush == islandFlush &&
      other.busyBar == busyBar;

  @override
  int get hashCode => Object.hash(
    name,
    header,
    Object.hashAll(stripActions),
    Object.hashAll(appBarActions),
    Object.hashAll(rowStart),
    Object.hashAll(rowEnd),
    send,
    emote,
    islandFlush,
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
      send: SendPlace.column,
    ),
  ),

  /// After ermchat 0.9: a titled app bar, just the field below.
  dankchat3(
    ChromeThemeSpec(
      header: HeaderStyle.appBar,
      appBarActions: [
        ChromeAction.join,
        ChromeAction.mentions,
        ChromeAction.overflow,
      ],
      stripActions: [ChromeAction.viewMenu],
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
      send: SendPlace.row,
      islandFlush: true,
      busyBar: true,
    ),
  );

  const ChromeTheme(this.spec);

  final ChromeThemeSpec spec;
}
