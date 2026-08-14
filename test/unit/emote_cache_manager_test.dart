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
    manager.lastUsedAt = (url) =>
        url.contains('b.png') ? t.add(const Duration(hours: 10)) : t;

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

  test('a full cache is full and does not persist new files', () async {
    final t = DateTime(2026, 1, 1, 12);
    repo.seed([
      _obj('https://example.com/a.png', t, id: 1),
      _obj('https://example.com/b.png', t.add(const Duration(hours: 1)), id: 2),
      _obj('https://example.com/c.png', t.add(const Duration(hours: 2)), id: 3),
    ]);
    manager.maxObjects = 3;

    expect(await manager.isFull(), isTrue);

    // Served in-memory instead: the mocked 400 download fails, but the repo
    // must stay untouched (no entry is added for the new URL).
    await expectLater(
      manager.getFileStream('https://example.com/new.png'),
      emitsError(anything),
    );

    expect(repo.keys, hasLength(3));
  });

  test('writes are accepted while under the cap', () async {
    final t = DateTime(2026, 1, 1, 12);
    repo.seed([_obj('https://example.com/a.png', t, id: 1)]);
    manager.maxObjects = 3;

    expect(await manager.isFull(), isFalse);
  });
}
