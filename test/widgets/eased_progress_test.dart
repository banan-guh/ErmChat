import 'package:ermchat/widgets/eased_progress.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('an idle upload never shadows a running reload', () {
    final upload = ValueNotifier<double?>(null);
    final reload = ValueNotifier<double?>(null);
    final active = ActiveProgress([upload, reload]);
    addTearDown(() {
      active.dispose();
      upload.dispose();
      reload.dispose();
    });

    reload.value = 0.4;
    expect(active.value, 0.4);
    upload.value = 0.7;
    expect(active.value, 0.7, reason: 'an upload outranks a reload');
    upload.value = null;
    expect(active.value, 0.4, reason: 'the reload takes over once it ends');
    reload.value = null;
    expect(active.value, isNull);
  });
}
