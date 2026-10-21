import 'package:ermchat/screens/whats_new_pages.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the showcase shows once per minor version', () {
    expect(showcaseFor('0.10.0', '0.9.10'), isNotNull, reason: 'new minor');
    expect(showcaseFor('0.10.2', '0.10.1'), isNull, reason: 'patch release');
    expect(showcaseFor('0.10.1', ''), isNotNull, reason: 'dev arm replays');
    expect(
      showcaseFor('0.9.10', ''),
      isNotNull,
      reason: 'dev arm shows the newest showcase before its release',
    );
    expect(showcaseFor('0.99.0', '0.10.0'), isNull, reason: 'no pages');
    expect(
      showcaseFor('0.10.0', '0.9.10')!.where((p) => p.iosOnly),
      isEmpty,
      reason: 'iOS-only pages stay off other platforms',
    );
  });
}
