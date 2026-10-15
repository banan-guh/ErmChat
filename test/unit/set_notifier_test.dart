import 'package:ermchat/util/set_notifier.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('notifies on change, skips listeners removed mid-notify', () {
    final n = SetValueNotifier(0);
    final calls = <String>[];
    void b() => calls.add('b');
    void a() {
      calls.add('a');
      n.removeListener(b);
    }

    n
      ..addListener(a)
      ..addListener(b)
      ..addListener(a);
    n.value = 0;
    expect(calls, isEmpty, reason: 'an equal value notifies nobody');
    n.value = 1;
    expect(calls, ['a'], reason: 'b left before its turn; a is held once');
  });
}
