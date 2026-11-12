import 'dart:async';

import 'package:ermchat/services/archive.dart';
import 'package:ermchat/services/archive_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a stuck archive open gives up instead of hanging reads', () async {
    // Opening waits on the platform's reply, which a hot restart can lose.
    // Before the timeout this future stayed pending forever and every
    // history read hung behind it.
    final stuck = Completer<ArchiveStore?>();
    final store = await Archive.withOpenTimeout(
      stuck.future,
      timeout: const Duration(milliseconds: 20),
    );
    expect(store, isNull);
    // Let the late-close continuation finish before the test ends.
    stuck.complete(null);
  });
}
