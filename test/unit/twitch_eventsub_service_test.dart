import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_twitch_app/services/twitch_eventsub.dart';

Map<String, dynamic> _welcome({String id = 'session-test', int timeout = 10}) =>
    {
      'metadata': {'message_type': 'session_welcome'},
      'payload': {
        'session': {'id': id, 'keepalive_timeout_seconds': timeout},
      },
    };

void main() {
  late EventSubService service;

  setUp(() {
    service = EventSubService();
  });

  tearDown(() {
    service.dispose();
  });

  group('initial state', () {
    test('isConnected is false', () {
      expect(service.isConnected, false);
    });

    test('sessionId is null', () {
      expect(service.sessionId, isNull);
    });
  });

  group('session lifecycle', () {
    test('handleRawMessage welcome sets sessionId and emits connected', () {
      final statuses = <EventSubStatus>[];
      service.onStatus.listen(statuses.add);

      service.handleRawMessage(_welcome(id: 'sess-lifecycle'));

      expect(service.sessionId, 'sess-lifecycle');
      expect(statuses, contains(EventSubStatus.connected));
    });

    test('second welcome overwrites sessionId', () {
      service.handleRawMessage(_welcome(id: 'sess-a'));
      expect(service.sessionId, 'sess-a');

      service.handleRawMessage(_welcome(id: 'sess-b'));
      expect(service.sessionId, 'sess-b');
    });

    test('disconnect clears sessionId', () {
      service.handleRawMessage(_welcome(id: 'sess-clear'));
      expect(service.sessionId, 'sess-clear');

      service.disconnect();
      expect(service.sessionId, isNull);
    });

    test('welcome after disconnect sets sessionId again', () {
      service.handleRawMessage(_welcome(id: 'first'));
      expect(service.sessionId, 'first');

      service.disconnect();
      expect(service.sessionId, isNull);

      service.handleRawMessage(_welcome(id: 'second'));
      expect(service.sessionId, 'second');
    });
  });

  group('disconnect', () {
    test('disconnect clears all state consistently', () {
      service.handleRawMessage(_welcome());
      service.disconnect();

      expect(service.sessionId, isNull);
      expect(service.isConnected, false);
    });
  });

  group('dispose', () {
    test('dispose does not crash when called fresh', () {
      final svc = EventSubService();
      expect(() => svc.dispose(), returnsNormally);
    });

    test('dispose after welcome does not crash', () {
      final svc = EventSubService();
      svc.handleRawMessage(_welcome());
      expect(() => svc.dispose(), returnsNormally);
    });
  });

  group('session completer', () {
    test('waitForSession completes after welcome', () async {
      final future = service.waitForSession();

      service.handleRawMessage(_welcome(id: 'sess-completer'));

      final result = await future;
      expect(result, 'sess-completer');
    });

    test('waitForSession returns immediately if session already set', () async {
      service.emitConnected();

      final result = await service.waitForSession();
      expect(result, 'test-session-id');
    });
  });
}
