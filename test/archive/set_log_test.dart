import 'package:ermchat/archive/set_log.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Map<String, String> set(List<String> keys) => {for (final k in keys) k: k};

  test('replays the set as observed at any time', () {
    final log = SetLog();
    void observe(int ms, List<String> keys) {
      final o = log.diff(set(keys), ms);
      if (o == null) {
        log.touch(ms);
      } else {
        log.add(o);
      }
    }

    observe(10, ['a', 'b']);
    observe(20, ['b', 'c']);
    observe(25, ['b', 'c']);
    observe(30, ['a', 'b', 'c']);
    expect(log.at(5), isEmpty, reason: 'nothing before the first fetch');
    expect(log.at(15).keys, unorderedEquals(['a', 'b']));
    expect(
      log.at(20).keys,
      unorderedEquals(['b', 'c']),
      reason: 'a removal counts from the first fetch without the key',
    );
    expect(log.at(99).keys, unorderedEquals(['a', 'b', 'c']));
    expect(log.rows, hasLength(3), reason: 'an unchanged fetch adds no row');
    expect(log.rows[1].seenMs, 25, reason: 'it moves the last seen time');
    expect(log.rows[1].added.keys, ['c'], reason: 'later rows are diffs');
    expect(log.rows[1].removed, ['a']);
    // The same log reloaded from its rows replays the same.
    expect(SetLog(log.rows).at(22), log.at(22));
  });

  test('a long diff run ends in a whole snapshot', () {
    final log = SetLog();
    for (var i = 0; i < SetLog.fullEvery + 1; i++) {
      log.add(log.diff(set(['k$i']), i)!);
    }
    expect([for (final o in log.rows) o.full].where((f) => f), hasLength(2));
    expect(log.rows.last.added, {
      'k${SetLog.fullEvery}': 'k${SetLog.fullEvery}',
    });
    expect(log.latest.keys, ['k${SetLog.fullEvery}']);
  });

  test('a lazy diff stores what an encoded set does', () {
    final eager = SetLog();
    final lazy = SetLog();
    for (var i = 0; i < SetLog.fullEvery * 3; i++) {
      final items = {
        for (final k in ['k${i % 5}', 'k${i % 7}', 'k$i']) k: '$k@$i',
      };
      final a = eager.diff(items, i);
      final b = lazy.diffKeys(items.keys, (key) => items[key]!, i);
      expect(b?.full, a?.full, reason: 'both snapshot on the same fetch');
      expect(b?.added, a?.added);
      expect(b?.removed, a?.removed);
      expect(b?.hash, a?.hash);
      if (a == null) continue;
      eager.add(a);
      lazy.add(b!);
    }
    expect(
      [for (final o in lazy.rows) o.full].where((f) => f),
      hasLength(3),
      reason: 'every 32nd observation is whole',
    );
  });

  test('the hash covers keys only, in any order', () {
    expect(SetLog.hashKeys(['a', 'b']), SetLog.hashKeys(['b', 'a']));
    expect(SetLog.hashKeys(['a']), isNot(SetLog.hashKeys(['b'])));
  });

  test('an old snapshot decodes only when replayed', () {
    SetObservation full(int atMs, String added) => SetObservation.fromJson(
      atMs: atMs,
      seenMs: atMs,
      full: true,
      added: added,
      removed: '[]',
      hash: 'h',
    );
    // The older snapshot is not valid JSON. Loading the log must not touch
    // it; only the newest full and the deltas after it prime the state.
    final log = SetLog([full(1, 'not json'), full(2, '{"k":"v"}')]);
    expect(log.latest, {'k': 'v'});
  });
}
