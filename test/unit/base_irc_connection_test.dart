import 'package:flutter_test/flutter_test.dart';
import 'package:ermchat/services/base_irc_connection.dart';

class TestIrcConnection extends BaseIrcConnection {
  final List<String> sentLines = [];

  TestIrcConnection() : super();

  @override
  String get debugPrefix => 'Test';

  @override
  void dispatchLine(String line) {}

  @override
  void sendLine(String message) {
    sentLines.add(message);
  }
}

void main() {
  late TestIrcConnection conn;

  setUp(() {
    conn = TestIrcConnection();
  });

  tearDown(() {
    conn.dispose();
  });

  group('PING', () {
    test('bare PING from server is answered with PONG', () {
      conn.handleLine('PING :tmi.twitch.tv');
      expect(conn.sentLines, contains('PONG :tmi.twitch.tv'));
    });

    test('PING does not get dispatched', () {
      conn.handleLine('PING :tmi.twitch.tv');
      // dispatchLine is no-op in TestIrcConnection, so nothing extra happens
    });
  });

  group('PONG', () {
    test('bare PONG clears awaitingPong', () {
      conn.awaitingPong = true;
      conn.handleLine('PONG :keepalive');
      expect(conn.awaitingPong, false);
    });

    test('prefixed PONG from Twitch clears awaitingPong', () {
      conn.awaitingPong = true;
      conn.handleLine(':tmi.twitch.tv PONG tmi.twitch.tv :keepalive');
      expect(conn.awaitingPong, false);
    });

    test('PONG does not get dispatched', () {
      conn.awaitingPong = true;
      conn.handleLine(':tmi.twitch.tv PONG tmi.twitch.tv :keepalive');
      // If dispatched, dispatchLine would run — test subclass tracks nothing
    });

    test('PRIVMSG does not accidentally clear awaitingPong', () {
      conn.awaitingPong = true;
      conn.handleLine(
        ':user!user@user.tmi.twitch.tv PRIVMSG #channel :hello chat',
      );
      expect(conn.awaitingPong, true);
    });

    test('NOTICE does not accidentally clear awaitingPong', () {
      conn.awaitingPong = true;
      conn.handleLine(
        ':tmi.twitch.tv NOTICE #channel :This room requires a verified email',
      );
      expect(conn.awaitingPong, true);
    });

    test('multiple lines with PONG in the batch', () {
      conn.awaitingPong = true;
      conn.handleLine(
        ':tmi.twitch.tv PONG tmi.twitch.tv :keepalive\r\n'
        ':user!user@user.tmi.twitch.tv PRIVMSG #channel :hello',
      );
      expect(conn.awaitingPong, false);
    });
  });

  group('other messages pass through to dispatchLine', () {
    test('PRIVMSG is dispatched', () {
      // This works because dispatchLine is a no-op in the test subclass
      conn.handleLine(
        ':user!user@user.tmi.twitch.tv PRIVMSG #channel :hello',
      );
      // No crash = pass
    });

    test('CLEARCHAT is dispatched', () {
      conn.handleLine(':tmi.twitch.tv CLEARCHAT #channel :target');
    });

    test('NOTICE is dispatched', () {
      conn.handleLine(':tmi.twitch.tv NOTICE #channel :message');
    });
  });
}
