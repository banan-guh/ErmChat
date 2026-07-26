import 'package:flutter_test/flutter_test.dart';
import 'package:ermchat/services/user_store.dart';

void main() {
  group('UserStore', () {
    test('returns empty set for unknown channel', () {
      final store = UserStore();
      expect(store.usersForChannel('channel'), isEmpty);
    });

    test('returns added users for channel', () {
      final store = UserStore();
      store.addUser('chan', 'User1');
      store.addUser('chan', 'User2');
      final users = store.usersForChannel('chan');
      expect(users, contains('User1'));
      expect(users, contains('User2'));
      expect(users.length, 2);
    });

    test('touches user moves to end of LRU', () {
      final store = UserStore();
      store.addUser('chan', 'User1');
      store.addUser('chan', 'User2');
      store.addUser('chan', 'User1');
      final users = store.usersForChannel('chan');
      final list = users.toList();
      expect(list.first, 'User2');
      expect(list.last, 'User1');
    });

    test('isolates channels', () {
      final store = UserStore();
      store.addUser('chan1', 'User1');
      store.addUser('chan2', 'User2');
      expect(store.usersForChannel('chan1'), {'User1'});
      expect(store.usersForChannel('chan2'), {'User2'});
    });

    test('evicts oldest when exceeding max', () {
      final store = UserStore();
      for (var i = 0; i < 5001; i++) {
        store.addUser('chan', 'User$i');
      }
      final users = store.usersForChannel('chan');
      expect(users.length, 5000);
      expect(users, isNot(contains('User0')));
      expect(users, contains('User5000'));
    });

    test('removeChannel clears channel', () {
      final store = UserStore();
      store.addUser('chan', 'User1');
      store.removeChannel('chan');
      expect(store.usersForChannel('chan'), isEmpty);
    });

    test('ignores empty display name', () {
      final store = UserStore();
      store.addUser('chan', '');
      expect(store.usersForChannel('chan'), isEmpty);
    });
  });
}
