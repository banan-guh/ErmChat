import 'package:flutter_cache_manager/flutter_cache_manager.dart';

/// In-memory [CacheInfoRepository] for cache tests. Seeded entries are
/// directly observable via [keys].
class FakeCacheRepo implements CacheInfoRepository {
  final Map<String, CacheObject> _byKey = {};

  void seed(List<CacheObject> objects) {
    for (final o in objects) {
      _byKey[o.key] = o;
    }
  }

  List<String> get keys => _byKey.keys.toList()..sort();

  @override
  Future<bool> exists() async => _byKey.isNotEmpty;

  @override
  Future<bool> open() async => true;

  @override
  Future<dynamic> updateOrInsert(CacheObject cacheObject) async {
    _byKey[cacheObject.key] = cacheObject;
  }

  @override
  Future<CacheObject> insert(
    CacheObject cacheObject, {
    bool setTouchedToNow = true,
  }) async {
    _byKey[cacheObject.key] = cacheObject;
    return cacheObject;
  }

  @override
  Future<CacheObject?> get(String key) async => _byKey[key];

  @override
  Future<int> delete(int id) async {
    final before = _byKey.length;
    _byKey.removeWhere((_, o) => o.id == id);
    return before - _byKey.length;
  }

  @override
  Future<int> deleteAll(Iterable<int> ids) async {
    final idSet = ids.toSet();
    final before = _byKey.length;
    _byKey.removeWhere((_, o) => idSet.contains(o.id));
    return before - _byKey.length;
  }

  @override
  Future<int> update(
    CacheObject cacheObject, {
    bool setTouchedToNow = true,
  }) async {
    _byKey[cacheObject.key] = cacheObject;
    return 1;
  }

  @override
  Future<List<CacheObject>> getAllObjects() async => _byKey.values.toList();

  @override
  Future<List<CacheObject>> getObjectsOverCapacity(int capacity) async => [];

  @override
  Future<List<CacheObject>> getOldObjects(Duration maxAge) async => [];

  @override
  Future<bool> close() async => true;

  @override
  Future<void> deleteDataFile() async {}
}
