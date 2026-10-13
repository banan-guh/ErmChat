import 'package:ermchat/util/fake_history.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('rows are a pure function of channel and index', () async {
    FakeHistory.loadDelay = Duration.zero;
    const ch = FakeHistory.denseChannel;
    final block = await FakeHistory.loadBlock(ch, 40);
    expect(block, hasLength(FakeHistory.blockSize));
    final row = FakeHistory.blockSize * 40 + 17;
    final again = FakeHistory.rowAt(ch, row);
    expect(block[17].text, again.text, reason: 'text differs between calls');
    expect(block[17].timestamp, again.timestamp);
    expect(
      FakeHistory.timeOf(ch, row + 1).isAfter(FakeHistory.timeOf(ch, row)),
      isTrue,
      reason: 'row times must increase with the index',
    );
  });
}
