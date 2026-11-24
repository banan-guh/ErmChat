import 'package:ermchat/channels/channel_manager.dart';
import 'package:ermchat/channels/channel_session.dart';
import 'package:ermchat/composer/composer_controller.dart';
import 'package:ermchat/panels/threads.dart';
import 'package:ermchat/services/notification_service.dart';
import 'package:ermchat/widgets/broadcast_widgets.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

mixin _Unimplemented {
  @override
  Never noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('$runtimeType.${invocation.memberName}');
}

class _FakeSession extends ChangeNotifier
    with _Unimplemented
    implements ChannelSession {
  _FakeSession({required List<String> names, this._selected})
    : _names = List.of(names);

  List<String> _names;
  String? _selected;

  @override
  List<String> get channelNames => List.unmodifiable(_names);

  @override
  String? Function() get selectedChannel =>
      () => _selected;

  void reorder(List<String> names) => _names = List.of(names);

  void select(String? channel) => _selected = channel;

  void emit() => notifyListeners();

  @override
  int? selectChannel(String channel) {
    if (_selected == channel) return null;
    _selected = channel;
    return 0;
  }

  @override
  void focusChannel(String channel) {}

  @override
  Future<bool> addChannel(String channelName, {bool focus = true}) async {
    final name = channelName.trim().toLowerCase();
    if (name.isEmpty || _names.contains(name)) return false;
    _names.add(name);
    _selected = name;
    notifyListeners();
    await Future<void>.value();
    notifyListeners();
    return true;
  }
}

class _FakeComposer with _Unimplemented implements ComposerController {
  int focuses = 0;

  @override
  void focus() => focuses++;

  @override
  void refreshCooldown() {}

  @override
  void onChannelChanged() {}
}

class _FakeThreads with _Unimplemented implements ThreadPanels {
  @override
  void clearOpenThread() {}
}

class _FakeBroadcastWidgets with _Unimplemented implements BroadcastWidgets {}

class _FakeNotifications with _Unimplemented implements NotificationService {}

void main() {
  group('ChannelManager shell dirtying', () {
    ({
      ChannelManager manager,
      _FakeSession session,
      _FakeComposer composer,
      ValueNotifier<List<String>> names,
      ValueNotifier<int> index,
      Map<String, ValueNotifier<bool>> atBottom,
      int Function() dirty,
    })
    harness({
      List<String> names = const ['one', 'two'],
      String? selected = 'one',
    }) {
      final session = _FakeSession(names: names, selected: selected);
      final composer = _FakeComposer();
      final channelNotifier = ValueNotifier<List<String>>(List.of(names));
      final selectedTabIndex = ValueNotifier(0);
      final atBottom = <String, ValueNotifier<bool>>{};
      var dirty = 0;
      final manager = ChannelManager(
        session: session,
        composer: composer,
        threads: _FakeThreads(),
        broadcastWidgets: _FakeBroadcastWidgets(),
        tileCache: {},
        channelNotifier: channelNotifier,
        selectedTabIndex: selectedTabIndex,
        isMounted: () => true,
        markDirty: () => dirty++,
        mutate: (fn) => fn(),
        closePanel: () async {},
        atBottomNotifier: (channel) =>
            atBottom.putIfAbsent(channel, () => ValueNotifier(true)),
        disposeChannelNotifiers: (_) {},
        forgetAtBottomNotifier: (_) {},
        forgetSearch: (_) {},
        invalidateCaches: () {},
        notificationService: _FakeNotifications(),
        mentionPush: () => false,
      );
      addTearDown(() {
        manager.dispose();
        session.dispose();
        channelNotifier.dispose();
        selectedTabIndex.dispose();
        for (final notifier in atBottom.values) {
          notifier.dispose();
        }
      });
      return (
        manager: manager,
        session: session,
        composer: composer,
        names: channelNotifier,
        index: selectedTabIndex,
        atBottom: atBottom,
        dirty: () => dirty,
      );
    }

    test('content-only notifications leave the shell clean', () {
      final h = harness();

      h.session.emit();
      h.session.emit();

      expect(h.dirty(), 0);
      expect(h.names.value, ['one', 'two']);
      expect(h.index.value, 0);
      expect(h.composer.focuses, 0);
    });

    test(
      'membership, order, selection and add focus dirty the shell',
      () async {
        final h = harness();

        h.session.reorder(['two', 'one']);
        h.session.emit();
        expect(h.dirty(), 1);
        expect(h.names.value, ['two', 'one']);
        expect(h.index.value, 1);

        h.session.select('two');
        h.session.emit();
        expect(h.dirty(), 2);
        expect(h.index.value, 0);

        await h.manager.addChannel('three');
        expect(h.dirty(), 3);
        expect(h.names.value, ['two', 'one', 'three']);
        expect(h.index.value, 2);
        expect(h.atBottom['three']?.value, isTrue);
        expect(h.composer.focuses, 1);

        h.session.emit();
        expect(
          h.dirty(),
          3,
          reason: 'the post-subscribe notify is content-only',
        );

        h.manager.commitChannelSelection(0, rebuild: false);
        h.session.emit();
        expect(
          h.dirty(),
          3,
          reason: 'selection already committed its own UI path',
        );

        await h.manager.addChannel('', focus: true);
        h.session.emit();
        expect(h.dirty(), 3);
        expect(
          h.composer.focuses,
          1,
          reason: 'a failed add must not retain focus',
        );
      },
    );
  });
}
