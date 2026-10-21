import 'dart:io';

import 'package:ermchat/util/log.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory dir;

  setUp(() {
    debugLogEnabled = false;
    dir = Directory.systemTemp.createTempSync('app_log_test');
  });
  tearDown(() => dir.deleteSync(recursive: true));

  test('entries survive a restart and read newest first', () async {
    final first = AppLog.test();
    await first.init(dir: dir);
    first.record('A', 'one');
    first.record('A', 'two\nsecond line');
    await first.flush();

    final second = AppLog.test();
    await second.init(dir: dir);
    second.record('B', 'three');
    final entries = await second.read();

    final bodies = [for (final e in entries) e.substring(e.indexOf('['))];
    expect(bodies, [
      '[B] three',
      '[LOG] session start',
      '[A] two\n    second line',
      '[A] one',
      '[LOG] session start',
    ], reason: 'a multi-line entry stays whole and in order');
  });

  test('old sessions are pruned past the disk budget', () async {
    final logs = Directory('${dir.path}/logs')..createSync();
    final big = 'x' * (AppLog.maxBytes ~/ 2);
    for (final name in [
      '1000000000000-000',
      '1100000000000-000',
      '1200000000000-000',
    ]) {
      File('${logs.path}/$name.txt').writeAsStringSync(big);
    }
    File('${dir.path}/perf_log.txt').writeAsStringSync('legacy');

    final log = AppLog.test();
    await log.init(dir: dir);
    await log.flush();

    final names = logs.listSync().map((f) => f.uri.pathSegments.last).toList()
      ..sort();
    expect(
      names.contains('1000000000000-000.txt'),
      isFalse,
      reason: 'oldest goes',
    );
    expect(
      names.contains('1200000000000-000.txt'),
      isTrue,
      reason: 'newest stays',
    );
    expect(File('${dir.path}/perf_log.txt').existsSync(), isFalse);
  });

  test('copy keeps the newest entries within the limit', () {
    final entries = ['newest', 'middle', 'oldest'];
    expect(AppLog.copyText(entries, limit: 15), ('newest\nmiddle\n', 2));
  });
}
