import 'dart:async';

import 'package:flutter/material.dart';

import '../chat/chat.dart';
import '../composer/composer_controller.dart';
import '../services/chat_connection_manager.dart';
import '../services/mod_actions.dart';
import '../services/twitch_auth.dart';
import '../widgets/mod_view.dart';
import '../widgets/panel_manager.dart';
import '../widgets/tab_drag_focus.dart';

// Shell-owned state the mod view panel reads but does not own.
abstract class ModPanelsHost extends ShellState {
  bool isMounted();
  void markDirty();
  void showNotice(String text);
  bool get showInput;
  void setShowInput(bool value);
  bool get emoteSheetOpen;
  Future<void> closeEmoteSheet();
  void clearComposerSuggestions();
  FocusNode get composerFocusNode;
}

// Moderation panel and its show verb.
class ModPanels {
  static const tabCount = 8;

  /// Terms tab index. The composer borrows its input while this tab is open.
  static const termsTabIndex = 6;
  ModPanels({
    required this.panelManager,
    required this.chat,
    required this.chatConn,
    required this.twitchAuth,
    required this.modActions,
    required this.modTab,
    required this.composer,
    required this.closeSearch,
    required this.host,
  });

  final PanelManager panelManager;
  final Chat chat;
  final ChatConnectionManager chatConn;
  final TwitchAuth twitchAuth;
  final ModActions modActions;
  final TabController Function() modTab;
  final ComposerController composer;
  final VoidCallback closeSearch;
  final ModPanelsHost host;

  final modPanelVersion = ValueNotifier(0);

  /// Shared blocked-term input. The Terms tab owns no field; the composer
  /// borrows this controller while the Terms tab is open (search pattern).
  final termsField = TextEditingController();
  final termsAdding = ValueNotifier<bool>(false);

  /// Bumped after a successful add so the Terms list reloads.
  final termsVersion = ValueNotifier<int>(0);

  bool _termsRestoredInput = false;
  String? _termsChannel;
  bool _termsWasActive = false;

  /// Layout work deferred from a live drag crossing to settle.
  bool _termsLayoutPending = false;

  /// Status-row hide follows only on settle; the input swap is live, and
  /// resizing the composer mid-drag would feed back into the page.
  bool _termsChromeActive = false;

  /// Half-drag focus: crossings report at 50% via [_onModFocus], settle
  /// syncs through [onModTabChanged].
  late final tabDragFocus = TabDragFocus(
    tab: modTab,
    onFocusChanged: _onModFocus,
  );

  void dispose() {
    modPanelVersion.dispose();
    tabDragFocus.dispose();
    termsField.dispose();
    termsAdding.dispose();
    termsVersion.dispose();
  }

  // Mod branch of panel data fan-out.
  void refreshOnData(String? changedChannel) {
    if (panelManager.activePanel != OverlayPanel.modView) return;
    // Modes are per selected channel; background channels need no work.
    if (changedChannel != null && changedChannel != host.selectedChannel) {
      return;
    }
    modPanelVersion.value++;
  }

  Future<void> showModView() async {
    closeSearch();
    await panelManager.closePanel();
    if (!host.isMounted()) return;
    composer.unfocus();
    // Always enter on Queue so a reorder never lands on the wrong tab.
    // jumpTo (not a bare index set) so the warp swallows travel updates.
    try {
      tabDragFocus.jumpTo(0);
    } catch (_) {}
    panelManager.activePanel = OverlayPanel.modView;
    panelManager.openThreadRoot = null;
    host.markDirty();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (host.isMounted()) {
        panelManager.animateRatio(
          panelManager.modSheetRatio,
          0.0,
          PanelManager.fullHeightFraction,
          PanelManager.sheetAnimDuration,
        );
      }
    });
  }

  /// True while the composer should morph into the blocked-term input:
  /// mod view open on the Terms tab. Tracks drags live, so the box
  /// unlocks at the 50% crossing instead of on settle.
  bool get termsInputActive =>
      panelManager.activePanel == OverlayPanel.modView &&
      host.selectedChannel != null &&
      tabDragFocus.effectiveIndex == termsTabIndex;

  /// Composer chrome follows only on settle; the input swap is live.
  bool get termsChromeHidden =>
      panelManager.activePanel == OverlayPanel.modView &&
      host.selectedChannel != null &&
      _termsChromeActive;

  /// Settle path for the tab-controller listener. Crossings report live
  /// through [_onModFocus]; this only catches what the drag did not.
  /// Never grabs focus; the keyboard only comes up on user tap.
  void onModTabChanged() {
    if (modTab().indexIsChanging) return;
    tabDragFocus.syncFromController();
  }

  void _onModFocus(int index) {
    if (!host.isMounted()) return;
    final active =
        panelManager.activePanel == OverlayPanel.modView &&
        host.selectedChannel != null &&
        index == termsTabIndex;
    if (tabDragFocus.dragFocus.value != null) {
      // Live drag: the morph follows the finger through ComposerBar's
      // drag subscription alone, no HomeScreen rebuild; keyboard and
      // layout effects wait for settle so the viewport never shifts
      // mid-gesture.
      if (active == _termsWasActive) return;
      _termsWasActive = active;
      _termsLayoutPending = true;
      return;
    }
    // Settle path (also covers tab taps): full effects, including any
    // layout work deferred from the drag.
    final layoutOnly = active == _termsWasActive && _termsLayoutPending;
    _termsLayoutPending = false;
    if (!layoutOnly) {
      if (active == _termsWasActive) return;
      _termsWasActive = active;
    }
    _termsChromeActive = active;
    if (active) {
      final channel = host.selectedChannel;
      if (_termsChannel != channel) {
        _termsChannel = channel;
        termsField.clear();
      }
      if (!host.showInput) {
        host.setShowInput(true);
        _termsRestoredInput = true;
      }
      if (host.emoteSheetOpen) unawaited(host.closeEmoteSheet());
      host.clearComposerSuggestions();
      host.markDirty();
    } else {
      if (_termsRestoredInput) {
        _termsRestoredInput = false;
        host.setShowInput(false);
      }
      host.composerFocusNode.unfocus();
      host.markDirty();
    }
  }

  /// Channel switch: drafts belong to one channel, so drop them.
  void syncTermsToSelected() {
    final channel = host.selectedChannel;
    if (_termsChannel == channel) return;
    _termsChannel = channel;
    termsField.clear();
  }

  /// Panel close hook: restore input visibility, drop the draft.
  void onPanelClosed() {
    tabDragFocus.reset();
    _termsLayoutPending = false;
    _termsChromeActive = false;
    final wasTerms = _termsWasActive;
    _termsWasActive = false;
    if (_termsRestoredInput) {
      _termsRestoredInput = false;
      host.setShowInput(false);
    }
    if (termsField.text.isNotEmpty) termsField.clear();
    _termsChannel = null;
    if (wasTerms) host.composerFocusNode.unfocus();
  }

  Future<void> submitTerms() async {
    final channel = host.selectedChannel;
    if (channel == null) return;
    final text = termsField.text.trim();
    if (text.isEmpty || termsAdding.value) return;
    if (text.length < 2 || text.length > 500) {
      host.showNotice('Terms must be 2-500 characters.');
      return;
    }
    termsAdding.value = true;
    try {
      final result = await modActions.addBlockedTerm(twitchAuth, channel, text);
      if (!host.isMounted()) return;
      if (result.ok) {
        termsField.clear();
        host.showNotice('Blocked term added.');
        termsVersion.value++;
      } else {
        host.showNotice(modErrorText(result));
      }
    } finally {
      termsAdding.value = false;
    }
  }

  Color _termsAccent(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return host.composerFocusNode.hasFocus
        ? scheme.primary
        : scheme.onSurfaceVariant;
  }

  // 48px prefix slot for the borrowed input: static block marker.
  Widget termsPrefixSlot() {
    return Builder(
      builder: (context) => SizedBox(
        width: 48,
        height: 48,
        child: ListenableBuilder(
          listenable: host.composerFocusNode,
          builder: (_, _) =>
              Icon(Icons.block_outlined, color: _termsAccent(context)),
        ),
      ),
    );
  }

  // 48px suffix slot for the borrowed input: add button with spinner.
  Widget termsSubmitSlot() {
    return Builder(
      builder: (context) => SizedBox(
        width: 48,
        height: 48,
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            borderRadius: BorderRadius.circular(24),
            onTap: submitTerms,
            child: ListenableBuilder(
              listenable: Listenable.merge([
                termsAdding,
                host.composerFocusNode,
              ]),
              builder: (_, _) {
                if (termsAdding.value) {
                  return const Padding(
                    padding: EdgeInsets.all(14),
                    child: CircularProgressIndicator(strokeWidth: 2),
                  );
                }
                return Icon(Icons.add, color: _termsAccent(context));
              },
            ),
          ),
        ),
      ),
    );
  }

  Widget modViewPanel(
    BuildContext context, {
    required Widget Function({
      required bool offstage,
      required ValueNotifier<double> ratio,
      required Widget header,
      required Widget body,
    })
    overlaySheet,
    required VoidCallback closePanel,
    ValueChanged<String>? onShowUser,
  }) {
    final channel = host.selectedChannel ?? '';
    return overlaySheet(
      offstage: panelManager.activePanel != OverlayPanel.modView,
      ratio: panelManager.modSheetRatio,
      header: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.arrow_back),
                  tooltip: 'Back',
                  onPressed: closePanel,
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    channel.isEmpty ? 'Mod view' : 'Mod view · #$channel',
                    style: TextStyle(
                      fontSize: 20,
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                  ),
                ),
              ],
            ),
          ),
          // Stream-first order: live work before people, settings last.
          // Matches ModViewPanel children in mod_view.dart; keep Queue at 0.
          SizedBox(
            height: 40,
            child: TabBar(
              controller: modTab(),
              isScrollable: true,
              tabAlignment: TabAlignment.start,
              labelPadding: const EdgeInsets.symmetric(horizontal: 12),
              indicator: BoxDecoration(
                border: Border(
                  bottom: BorderSide(
                    color: Theme.of(context).colorScheme.primary,
                    width: 2,
                  ),
                ),
              ),
              indicatorSize: TabBarIndicatorSize.label,
              tabs: [
                ValueListenableBuilder<int>(
                  valueListenable:
                      chat.channelFor(channel)?.moderation.heldVersion ??
                      ValueNotifier(0),
                  builder: (_, _, _) {
                    final pending =
                        chat.channelFor(channel)?.moderation.held.length ?? 0;
                    return Tab(
                      text: pending > 0 ? 'Queue ($pending)' : 'Queue',
                    );
                  },
                ),
                const Tab(text: 'Activity'),
                const Tab(text: 'Modes'),
                const Tab(text: 'Channel'),
                const Tab(text: 'Users'),
                const Tab(text: 'Requests'),
                const Tab(text: 'Terms'),
                const Tab(text: 'Setup'),
              ],
            ),
          ),
          Divider(height: 1, color: Theme.of(context).dividerColor),
        ],
      ),
      body: ModViewPanel(
        channel: channel,
        chat: chat,
        modActions: modActions,
        auth: twitchAuth,
        tabController: modTab(),
        refresh: modPanelVersion,
        termsVersion: termsVersion,
        dragFocus: tabDragFocus,
        onNotice: host.showNotice,
        onShowUser: onShowUser,
        isBroadcaster: channel.isNotEmpty && chatConn.isBroadcaster(channel),
        isModerationActive: (c) =>
            c.isNotEmpty && chatConn.isModerationActive(c),
        isAutomodActive: (c) => c.isNotEmpty && chatConn.isAutomodActive(c),
        getRoomModes: (c) => c.isEmpty ? const {} : chatConn.roomStateTags(c),
      ),
    );
  }
}
