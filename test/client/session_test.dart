import 'package:ermchat/client/session.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('apply announces, seed and clear stay silent', () {
    final session = Session();
    addTearDown(session.dispose);
    var ticks = 0;
    session.version.addListener(() => ticks++);

    session.seed('alice', userId: '1');
    expect(session.login, 'alice');
    expect(session.userId, '1');
    expect(ticks, 0, reason: 'seed must not announce');

    session.apply('bob', userId: '2');
    expect(session.login, 'bob');
    expect(session.userId, '2');
    expect(ticks, 1);

    session.apply('bob', keepUserId: true);
    expect(session.userId, '2', reason: 'keepUserId preserves the id');
    expect(ticks, 2);

    session.clear();
    expect(session.login, isNull);
    expect(session.userId, isNull);
    expect(ticks, 2, reason: 'clear stays silent');
  });
}
