/// Chrome themes: where the header, the button row and their actions go.
/// Each theme is a [ChromeThemeSpec]; consumers read the spec, never the
/// theme itself, so adding one is a new enum value and its spec.
library;

/// How the top of the screen is built.
enum HeaderStyle {
  /// One strip: channel tabs, then the strip's actions.
  strip,

  /// A titled app bar with its actions above a plain tab strip.
  appBar,

  /// The strip split into floating pills: tabs, then actions.
  bubbles,
}

/// A chrome button that a theme places in the header or the row.
enum ChromeAction {
  /// Join a channel.
  join,

  /// The bell: mentions and whispers.
  mentions,

  /// Threads dashboard.
  threads,

  /// Settings.
  settings,

  /// The ⋮ menu: upload, reload emotes, reconnect.
  overflow,

  /// The view menu: fullscreen, input, stream, search.
  viewMenu,
}

class ChromeThemeSpec {
  const ChromeThemeSpec({
    required this.header,
    required this.stripActions,
    required this.rowActions,
    this.appBarActions = const [],
    this.appBarTitle = false,
    this.rowActionsRight = false,
    this.sendInRow = false,
    this.islandFlush = false,
    this.settingsInMenu = false,
    this.busyBar = false,
  });

  final HeaderStyle header;

  /// The strip's end, in order; for [HeaderStyle.bubbles], the action
  /// pill. Join elsewhere drops the strip's trailing join tab.
  final List<ChromeAction> stripActions;

  /// The app bar's actions, in order, for [HeaderStyle.appBar].
  final List<ChromeAction> appBarActions;

  /// The island's button row, in order. Empty drops the row, and emote and
  /// send stay in the field.
  final List<ChromeAction> rowActions;

  /// The app bar shows the app's name.
  final bool appBarTitle;

  /// The row's actions sit right, beside send, with emote alone on the left.
  final bool rowActionsRight;

  /// Send ends the row instead of running down the island's side. The row
  /// then stays up while typing.
  final bool sendInRow;

  /// The island runs edge to edge under the nav bar, rounded only on top.
  final bool islandFlush;

  /// Settings heads the ⋮ menu instead of being a button.
  final bool settingsInMenu;

  /// Loading shows as a bar along the top of the button row instead of a
  /// spinner in the join button.
  final bool busyBar;

  bool places(ChromeAction action) =>
      stripActions.contains(action) ||
      appBarActions.contains(action) ||
      rowActions.contains(action);
}

enum ChromeTheme {
  ermchat(
    ChromeThemeSpec(
      header: HeaderStyle.strip,
      stripActions: [ChromeAction.viewMenu],
      rowActions: [
        ChromeAction.settings,
        ChromeAction.overflow,
        ChromeAction.threads,
        ChromeAction.mentions,
      ],
    ),
  ),

  /// After ermchat 0.9: a titled app bar, just the field below.
  dankchat3(
    ChromeThemeSpec(
      header: HeaderStyle.appBar,
      appBarTitle: true,
      appBarActions: [
        ChromeAction.join,
        ChromeAction.mentions,
        ChromeAction.overflow,
      ],
      stripActions: [ChromeAction.viewMenu],
      rowActions: [],
      settingsInMenu: true,
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
      rowActions: [ChromeAction.threads, ChromeAction.viewMenu],
      rowActionsRight: true,
      sendInRow: true,
      islandFlush: true,
      settingsInMenu: true,
      busyBar: true,
    ),
  );

  const ChromeTheme(this.spec);

  final ChromeThemeSpec spec;
}
