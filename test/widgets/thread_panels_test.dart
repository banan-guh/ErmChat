import 'dart:async';

import 'package:ermchat/chat/chat.dart';
import 'package:ermchat/composer/composer_controller.dart';
import 'package:ermchat/l10n/app_localizations.dart';
import 'package:ermchat/models/twitch_message.dart';
import 'package:ermchat/panels/threads.dart';
import 'package:ermchat/services/archive_reader.dart';
import 'package:ermchat/services/archive_store.dart';
import 'package:ermchat/sheets/message_menu.dart';
import 'package:ermchat/sheets/user_sheet.dart';
import 'package:ermchat/widgets/message_builder.dart';
import 'package:ermchat/widgets/panel_manager.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _SlowArchive extends ArchiveReader {
  _SlowArchive() : super(Future<ArchiveStore?>.value(null));

  final rows = Completer<List<TwitchMessage>>();

  @override
  Future<List<TwitchMessage>> threadRows(String channel, String rootId) =>
      rows.future;
}

class _FakeComposer implements ComposerController {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _FakeBuilder implements MessageBuilder {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _FakeUserSheets implements UserSheets {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

TwitchMessage _msg(
  String id, {
  String? parent,
  String? root,
  String text = '',
}) => TwitchMessage(
  login: 'x',
  text: text.isEmpty ? id : text,
  messageId: id,
  channel: 'test',
  replyToParentId: parent,
  replyThreadRootId: root,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('thread rows land in the list the panel view holds', () async {
    final chat = Chat();
    addTearDown(chat.dispose);
    final channel = chat.ensure('test');
    final root = _msg('r1', text: 'root');
    final reply = _msg('c1', parent: 'r1', root: 'r1', text: 'reply');
    channel.threads.index([root, reply], lookupRoot: channel.messages.byId);

    final panelManager = PanelManager(
      vsync: const TestVSync(),
      markDirty: () {},
      isMounted: () => true,
    );
    addTearDown(panelManager.dispose);
    final tab = TabController(length: 3, vsync: const TestVSync());
    addTearDown(tab.dispose);
    final archive = _SlowArchive();
    final panels = ThreadPanels(
      panelManager: panelManager,
      chat: chat,
      threadsTab: () => tab,
      composer: _FakeComposer(),
      messageBuilder: _FakeBuilder(),
      userSheets: _FakeUserSheets(),
      menus: MessageMenus(
        findThreadRoot: (_) => null,
        showThreadView: (_) async {},
        startReply: (_) {},
        canModerate: (_) => false,
        pinMessage: (_, _) {},
        deleteMessage: (_, _) {},
      ),
      selectedChannel: () => 'test',
      isMounted: () => true,
      markDirty: () {},
      switchChannelTo: (_) {},
      showNotice: (_) {},
      showTimestamps: () => false,
      timestampFormat: () => 'HH:mm',
      chatFontSize: () => 14,
      checkeredMessages: () => false,
      highlightOpacity: () => 0.6,
      lineSeparator: () => false,
      sharedChatMode: () => 'spotlight',
      namePaintService: () => null,
      copyMessage: (_) {},
      strings: () => lookupAppLocalizations(const Locale('en')),
      archiveReader: archive,
    );
    addTearDown(panels.dispose);

    // A reply landing while the panel is closed waits for the open: a closed
    // panel takes no live rows.
    channel.receive(
      _msg('c0', parent: 'r1', root: 'r1', text: 'closed'),
      maxMessages: 100,
      isSelected: true,
      ownLogin: 'me',
    );
    panels.refreshOnData('test');
    expect(
      panels.threadMsgCount.value,
      0,
      reason: 'a closed panel must not follow live rows',
    );

    await panels.showThreadView(root);
    // The list the panel's ChatView was built with.
    final openList = panelManager.threadMessages;
    expect(
      openList.map((m) => m.messageId),
      contains('c0'),
      reason: 'opening the panel catches up on the rows it skipped',
    );

    // The archive read lands after the panel frame, as a real DB read does.
    archive.rows.complete([_msg('a1', parent: 'r1', root: 'r1', text: 'old')]);
    await Future<void>.delayed(Duration.zero);

    expect(
      panelManager.threadMessages,
      same(openList),
      reason: 'the archive load must not swap the list the view holds',
    );
    expect(openList.map((m) => m.messageId), contains('a1'));

    // A live reply while the panel is open.
    channel.receive(
      _msg('c2', parent: 'r1', root: 'r1', text: 'fresh'),
      maxMessages: 100,
      isSelected: true,
      ownLogin: 'me',
    );
    panels.refreshOnData('test');

    expect(
      openList.map((m) => m.messageId),
      contains('c2'),
      reason: 'a live reply must reach the list the view holds',
    );
  });
}
