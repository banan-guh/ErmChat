import 'package:ermchat/screens/whats_new_pages.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the showcase shows once per minor version', () {
    expect(
      showcaseFor('0.10.0', '0.9.10', now: DateTime(2026, 10, 21)),
      isNotNull,
      reason: 'new minor',
    );
    expect(showcaseFor('0.10.2', '0.10.1'), isNull, reason: 'patch release');
    expect(showcaseFor('0.10.1', ''), isNotNull, reason: 'dev arm replays');
    expect(
      showcaseFor('0.9.10', ''),
      isNotNull,
      reason: 'dev arm shows the newest showcase before its release',
    );
    expect(showcaseFor('0.99.0', '0.10.0'), isNull, reason: 'no pages');
    expect(
      showcaseFor('0.10.0', '0.9.10', now: DateTime(2026, 10, 26)),
      isNull,
      reason: 'past its end date, its art is gone',
    );
    expect(
      showcaseFor('0.10.0', '', now: DateTime(2026, 11, 1)),
      isNotNull,
      reason: 'the dev arm ignores the end date',
    );
    expect(
      showcaseFor(
        '0.10.0',
        '0.9.10',
        now: DateTime(2026, 10, 21),
      )!.where((p) => p.iosOnly),
      isEmpty,
      reason: 'iOS-only pages stay off other platforms',
    );
  });
}
