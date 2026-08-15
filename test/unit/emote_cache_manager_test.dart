import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ermchat/services/emote_cache_manager.dart';

import '../helpers/fake_cache_repo.dart';

CacheObject _obj(String url, DateTime touched, {int? id}) => CacheObject(
  url,
  id: id,
  relativePath: 'file_${url.hashCode}.png',
  validTill: DateTime(2030),
  touched: touched,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeCacheRepo repo;
  late EmoteCacheManager manager;

  setUp(() {
    repo = FakeCacheRepo();
    manager = EmoteCacheManager.forTesting(
      Config('test', repo: repo, fileSystem: MemoryCacheSystem()),
    );
  });

  test('evicts down to maxObjects by least-recently-touched', () async {
    final t = DateTime(2026, 1, 1, 12);
    repo.seed([
      _obj('https://example.com/a.png', t, id: 1),
      _obj('https://example.com/b.png', t.add(const Duration(hours: 1)), id: 2),
      _obj('https://example.com/c.png', t.add(const Duration(hours: 2)), id: 3),
      _obj('https://example.com/d.png', t.add(const Duration(hours: 3)), id: 4),
      _obj('https://example.com/e.png', t.add(const Duration(hours: 4)), id: 5),
    ]);
    manager.maxObjects = 3;

    await manager.enforceNow();

    expect(repo.keys, [
      'https://example.com/c.png',
      'https://example.com/d.png',
      'https://example.com/e.png',
    ]);
  });

  test('registry priority overrides the file touched time', () async {
    final t = DateTime(2026, 1, 1, 12);
    repo.seed([
      // a: recently touched on disk, but long-unused per the registry.
      _obj('https://example.com/a.png', t.add(const Duration(hours: 5)), id: 1),
      // b: long untouched on disk, but recently used per the registry.
      _obj('https://example.com/b.png', t, id: 2),
    ]);
    manager.maxObjects = 1;
    manager.priorityScore = (url) => url.contains('b.png') ? 1.0 : 0.0;

    await manager.enforceNow();

    expect(repo.keys, ['https://example.com/b.png']);
  });

  test('a zero cap evicts everything', () async {
    final t = DateTime(2026, 1, 1, 12);
    repo.seed([
      _obj('https://example.com/a.png', t, id: 1),
      _obj('https://example.com/b.png', t.add(const Duration(hours: 1)), id: 2),
    ]);
    manager.maxObjects = 0;

    await manager.enforceNow();

    expect(repo.keys, isEmpty);
  });

  test('evicts nothing when under maxObjects', () async {
    final t = DateTime(2026, 1, 1, 12);
    repo.seed([
      _obj('https://example.com/a.png', t, id: 1),
      _obj('https://example.com/b.png', t.add(const Duration(hours: 1)), id: 2),
    ]);
    manager.maxObjects = 5;

    await manager.enforceNow();

    expect(repo.keys, [
      'https://example.com/a.png',
      'https://example.com/b.png',
    ]);
  });

  test('a full cache evicts the lowest-priority file to make room', () async {
    final t = DateTime(2026, 1, 1, 12);
    repo.seed([
      _obj('https://example.com/a.png', t, id: 1),
      _obj('https://example.com/b.png', t.add(const Duration(hours: 1)), id: 2),
      _obj('https://example.com/c.png', t.add(const Duration(hours: 2)), id: 3),
    ]);
    manager.maxObjects = 3;

    expect(await manager.isFull(), isTrue);

    // The write evicts the lowest-priority file (a, oldest by far) before
    // attempting the download. The mocked 400 download then fails, so the
    // repo keeps the two higher-priority files and gains nothing.
    await expectLater(
      manager.getFileStream('https://example.com/new.png'),
      emitsError(anything),
    );

    expect(repo.keys, [
      'https://example.com/b.png',
      'https://example.com/c.png',
    ]);
  });

  test('write-time eviction skips candidates within the read grace', () async {
    // All candidates were used/stored within the grace window, so nothing is
    // evictable and the write falls back to the temp-file path: the mocked
    // download fails but the repo stays untouched (the overflow grace is
    // covered by the 30s temp-file policy, not repo eviction).
    final t = DateTime.now();
    repo.seed([
      _obj('https://example.com/a.png', t, id: 1),
      _obj('https://example.com/b.png', t, id: 2),
      _obj('https://example.com/c.png', t, id: 3),
    ]);
    manager.maxObjects = 3;

    await expectLater(
      manager.getFileStream('https://example.com/new1.png'),
      emitsError(anything),
    );
    await expectLater(
      manager.getFileStream('https://example.com/new2.png'),
      emitsError(anything),
    );

    expect(repo.keys, hasLength(3));
  });

  test('write-time eviction picks the lowest-scored entry', () async {
    final t = DateTime(2026, 1, 1, 12);
    repo.seed([
      _obj('https://example.com/a.png', t, id: 1),
      _obj('https://example.com/b.png', t, id: 2),
      _obj('https://example.com/c.png', t, id: 3),
    ]);
    manager.maxObjects = 3;
    // b is the lowest-scored emote even though it is not the oldest on disk.
    manager.priorityScore = (url) => switch (url) {
      'https://example.com/a.png' => 1.0,
      'https://example.com/b.png' => 0.2,
      _ => 0.9,
    };
    manager.lastUsedAt = (url) => t.add(const Duration(days: 1));

    await expectLater(
      manager.getFileStream('https://example.com/new.png'),
      emitsError(anything),
    );

    expect(repo.keys, [
      'https://example.com/a.png',
      'https://example.com/c.png',
    ]);
  });

  test('writes are accepted while under the cap', () async {
    final t = DateTime(2026, 1, 1, 12);
    repo.seed([_obj('https://example.com/a.png', t, id: 1)]);
    manager.maxObjects = 3;

    expect(await manager.isFull(), isFalse);
  });

  test('repeated isFull within the TTL reuses one repo scan', () async {
    final t = DateTime(2026, 1, 1, 12);
    repo.seed([
      _obj('https://example.com/a.png', t, id: 1),
      _obj('https://example.com/b.png', t, id: 2),
    ]);
    manager.maxObjects = 3;

    // A burst of sequential fetches: each isFull must not re-scan the repo.
    expect(await manager.isFull(), isFalse);
    expect(await manager.isFull(), isFalse);
    expect(await manager.isFull(), isFalse);

    expect(repo.getAllObjectsCalls, 1);
  });
}
