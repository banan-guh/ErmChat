import 'package:ermchat/archive/intern_table.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('ids stay put through removal until a compaction closes the gaps', () {
    final t = InternTable<String>();
    expect(
      [
        for (final w in ['a', 'b', 'c', 'b', 'd']) t.intern(w),
      ],
      [0, 1, 2, 1, 3],
    );
    t.remove([1, 2]);
    expect(t[1], isNull);
    expect(t.intern('e'), 4, reason: 'removed ids are never handed out again');
    expect(t.sparse, isFalse, reason: '3 of 5 ids are live');
    t.remove([0]);
    expect(t.sparse, isTrue);

    final plan = t.compactPlan();
    expect(t[3], 'd', reason: 'planning changes nothing');
    expect(t.compact(), plan);
    expect(plan, [-1, -1, -1, 0, 1]);
    expect([for (final (id, v) in t.entries) '$id$v'], ['0d', '1e']);
    expect(t.idOf('e'), 1);
    expect(t.intern('f'), 2);
  });

  test('saved entries restore at their ids and a failed write rolls back', () {
    final t = InternTable<String>()
      ..put(4, 'late')
      ..put(0, 'first');
    expect(t.length, 5);
    expect(t.intern('new'), 5);
    t.truncate(5);
    expect(t.idOf('new'), isNull);
    expect(t.intern('again'), 5);
  });

  test('a sparse table never leaves slots behind', () {
    final t = InternTable<String>.sparse();
    t
      ..intern('a')
      ..intern('b')
      ..remove([0]);
    expect(t.count, 1);
    expect(t.sparse, isFalse, reason: 'only dense tables compact');
    t.replace(1, 'c');
    expect(t.idOf('b'), isNull);
    expect(t.idOf('c'), 1);
  });
}
