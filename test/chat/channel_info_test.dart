import 'package:ermchat/chat/channel/info.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('status text bumps only the status version, never tiles', () {
    final info = ChannelInfo();
    addTearDown(info.dispose);
    var structural = 0;
    var status = 0;
    info.version.addListener(() => structural++);
    info.statusVersion.addListener(() => status++);

    info.setStatus('Live with 10 viewers');
    expect(info.status, 'Live with 10 viewers');
    expect(structural, 0);
    expect(status, 1);

    // Same text is a no-op on both notifiers.
    info.setStatus('Live with 10 viewers');
    expect(structural, 0);
    expect(status, 1);

    // The 30s poll ticking viewer counts must not invalidate tiles.
    info.setStatus('Live with 11 viewers');
    expect(structural, 0);
    expect(status, 2);
  });

  test('structural writes still bump the tile-dropping version', () {
    final info = ChannelInfo();
    addTearDown(info.dispose);
    var structural = 0;
    var status = 0;
    info.version.addListener(() => structural++);
    info.statusVersion.addListener(() => status++);

    info.setBroadcasterId('123');
    info.setHistoryLoaded(true);
    info.touch();
    expect(structural, 3);
    expect(status, 0);

    // Guarded setters stay silent on identical values.
    info.setBroadcasterId('123');
    info.setHistoryLoaded(true);
    expect(structural, 3);
  });
}
