import 'package:ermchat/services/emote_manager.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('EmoteManager satisfies the read-only lookup port', () {
    final manager = EmoteManager();
    final EmoteLookupSource source = manager;

    expect(identical(source.images, manager.images), isTrue);
    expect(source.version, manager.version);
    expect(
      source.lookup('channel', null),
      manager.byCodeForSender('channel', null),
    );
  });
}
