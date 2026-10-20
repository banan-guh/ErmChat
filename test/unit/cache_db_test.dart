import 'dart:io';

import 'package:ermchat/services/cache_db.dart';
import 'package:ermchat/services/emote_meta_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Directory dir;
  late String path;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('ermchat_cache_db');
    path = '${dir.path}/cache.db';
    CacheDb.I.overrideForTesting(databaseFactoryFfi, path);
    EmoteMetaStore.I.overrideDirectory(dir);
  });

  tearDown(() async {
    await CacheDb.I.reset();
    CacheDb.I.overrideForTesting(databaseFactoryFfi, inMemoryDatabasePath);
    EmoteMetaStore.I.reset();
    await dir.delete(recursive: true);
  });

  const row = (url: 'u', lastUsed: 1, hour: 2, buckets: '0');

  // The store is a cache: anything it cannot use is dropped and rebuilt.
  test('an unreadable or foreign file starts over empty', () async {
    for (final (name, setUpFile) in <(String, Future<void> Function())>[
      ('garbage', () => File(path).writeAsString('not sqlite at all')),
      (
        'other schema',
        () async {
          final db = await databaseFactoryFfi.openDatabase(path);
          await db.execute('CREATE TABLE emote_usage (x)');
          await db.setVersion(99);
          await db.close();
        },
      ),
    ]) {
      await CacheDb.I.reset();
      await databaseFactoryFfi.deleteDatabase(path);
      await setUpFile();
      await EmoteMetaStore.I.write('emote_usage', '{}');

      expect(await CacheDb.I.usage(), isEmpty, reason: name);
      await CacheDb.I.writeUsage([row], const []);
      expect(
        (await CacheDb.I.usage()).single,
        row,
        reason: '$name: rebuilt store takes writes',
      );
      expect(
        await EmoteMetaStore.I.read('emote_usage'),
        isNull,
        reason: '$name: the blob the table replaces is deleted',
      );
    }
  });

  test('stored data survives a reopen', () async {
    await CacheDb.I.writeUsage([row], const []);
    await CacheDb.I.writePaints([('p', '{"id":"p"}')]);
    await CacheDb.I.writePaintUsers([
      (userId: 'a', paintId: 'p', at: 5),
    ], const []);
    await CacheDb.I.reset();

    expect((await CacheDb.I.usage()).single, row);
    expect(await CacheDb.I.paints(), ['{"id":"p"}']);
    expect(await CacheDb.I.paintUsers(beforeMs: 0, keep: 10), [
      (userId: 'a', paintId: 'p', at: 5),
    ]);
    await CacheDb.I.writePaints([('q', '{"id":"q"}')], replace: true);
    expect(await CacheDb.I.paints(), [
      '{"id":"q"}',
    ], reason: 'a full catalog drops retired paints');
  });

  test('paint users prune by age, then keep the newest', () async {
    await CacheDb.I.writePaintUsers([
      for (var i = 0; i < 5; i++) (userId: 'u$i', paintId: 'p', at: i),
    ], const []);

    final kept = await CacheDb.I.paintUsers(beforeMs: 1, keep: 2);
    expect(kept.map((r) => r.userId).toSet(), {'u3', 'u4'});
    expect(await CacheDb.I.paintUsers(beforeMs: 0, keep: 10), hasLength(2));
  });
}
