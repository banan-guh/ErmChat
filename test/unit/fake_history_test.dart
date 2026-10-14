import 'package:ermchat/util/fake_history.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('rows are a pure function of channel and index', () async {
    FakeHistory.loadDelay = Duration.zero;
    const ch = FakeHistory.denseChannel;
    final row = FakeHistory.blockSize * 40 + 17;
    final block = await FakeHistory.rows(ch, row - 17, row + 239);
    expect(block, hasLength(FakeHistory.blockSize));
    final again = FakeHistory.rowAt(ch, row);
    expect(block[17].text, again.text, reason: 'text differs between calls');
    expect(block[17].timestamp, again.timestamp);
    expect(
      FakeHistory.timeOf(ch, row + 1).isAfter(FakeHistory.timeOf(ch, row)),
      isTrue,
      reason: 'row times must increase with the index',
    );
  });

  test('rowAtTime inverts timeOf across the testchannel gap', () {
    const ch = FakeHistory.testChannel;
    final last = FakeHistory.rowCount(ch) - 1;
    var widest = Duration.zero;
    for (var r = 1; r <= last; r++) {
      final d = FakeHistory.timeOf(
        ch,
        r,
      ).difference(FakeHistory.timeOf(ch, r - 1));
      if (d > widest) widest = d;
      expect(FakeHistory.rowAtTime(ch, FakeHistory.timeOf(ch, r)), r);
    }
    expect(widest, greaterThan(const Duration(days: 3)), reason: 'no gap');
  });
}
