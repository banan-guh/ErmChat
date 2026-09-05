import 'package:flutter/material.dart';

import '../composer/composer_controller.dart';
import '../services/chat_connection_manager.dart';
import '../services/chat_store.dart';
import '../services/mod_actions.dart';
import '../services/twitch_auth.dart';
import '../widgets/mod_view.dart';
import '../widgets/panel_manager.dart';

// Shell-owned state the mod view panel reads but does not own.
abstract class ModPanelsHost extends ShellState {
  bool isMounted();
  void markDirty();
}

// Moderation panel and its show verb.
class ModPanels {
  ModPanels({
    required this.panelManager,
    required this.chatStore,
    required this.chatConn,
    required this.twitchAuth,
    required this.modActions,
    required this.modTab,
    required this.composer,
    required this.host,
  });

  final PanelManager panelManager;
  final ChatStore chatStore;
  final ChatConnectionManager chatConn;
  final TwitchAuth twitchAuth;
  final ModActions modActions;
  final TabController Function() modTab;
  final ComposerController composer;
  final ModPanelsHost host;

  final modPanelVersion = ValueNotifier(0);

  void dispose() {
    modPanelVersion.dispose();
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
    await panelManager.closePanel();
    if (!host.isMounted()) return;
    composer.unfocus();
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
          TabBar(
            controller: modTab(),
            padding: const EdgeInsets.fromLTRB(100.0, 0.0, 100.0, 0.0),
            // Three tabs like the threads panel: center the strip and let
            // it scroll instead of clipping labels on narrow phones.
            isScrollable: true,
            tabAlignment: TabAlignment.center,
            tabs: const [
              Tab(text: 'Queue'),
              Tab(text: 'Modes'),
              Tab(text: 'Mods'),
            ],
          ),
          Divider(height: 1, color: Theme.of(context).dividerColor),
        ],
      ),
      body: ModViewPanel(
        channel: channel,
        store: chatStore,
        modActions: modActions,
        auth: twitchAuth,
        tabController: modTab(),
        refresh: modPanelVersion,
        isModerationActive: (c) =>
            c.isNotEmpty && chatConn.isModerationActive(c),
        isAutomodActive: (c) => c.isNotEmpty && chatConn.isAutomodActive(c),
        getRoomModes: (c) => c.isEmpty ? const {} : chatConn.roomStateTags(c),
      ),
    );
  }
}
