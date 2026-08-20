import 'package:flutter_tts/flutter_tts.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/widgets.dart';
import 'package:ermchat/services/tts_controller.dart';
import 'package:ermchat/models/twitch_message.dart';
import 'package:shared_preferences/shared_preferences.dart';

class FakeTts extends FlutterTts {
  final List<String> spoken = [];
  final List<int> setQueueModeCalls = [];
  int stopCalls = 0;
  int setLanguageCalls = 0;
  String? setEngineId;
  Map<String, String>? setVoiceRaw;
  List<dynamic>? engines;
  List<dynamic>? voices;
  String? defaultEngine;

  @override
  Future<dynamic> isLanguageAvailable(String language) async => true;

  @override
  Future<dynamic> get getEngines async => engines;

  @override
  Future<dynamic> get getVoices async => voices;

  @override
  Future<dynamic> get getDefaultEngine async => defaultEngine;

  @override
  Future<dynamic> speak(String text, {bool focus = false}) async {
    spoken.add(text);
    return null;
  }

  @override
  Future<dynamic> stop() async {
    stopCalls++;
    return null;
  }

  @override
  Future<dynamic> setLanguage(String language) async {
    setLanguageCalls++;
    return null;
  }

  @override
  Future<dynamic> setQueueMode(int queueMode) async {
    setQueueModeCalls.add(queueMode);
    return null;
  }

  @override
  Future<dynamic> setEngine(String engine) async {
    setEngineId = engine;
    return null;
  }

  @override
  Future<dynamic> setVoice(Map<String, String> voice) async {
    setVoiceRaw = voice;
    return null;
  }
}

TwitchMessage buildMsg({
  String login = 'bob',
  String displayName = 'Bob',
  String text = 'hello',
  List<EmotePosition>? emotePositions,
  bool isSystem = false,
}) => TwitchMessage(
  login: login,
  displayName: displayName,
  text: text,
  emotePositions: emotePositions,
  isSystem: isSystem,
);

Future<TtsController> makeController(FakeTts fake) async {
  final c = TtsController(tts: fake);
  await c.init();
  c.setEnabled(true);
  return c;
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  test('speaks active channel, ignores others', () async {
    final fake = FakeTts();
    final c = await makeController(fake);
    c.handleMessage('chan', buildMsg(text: 'hi'), 'chan');
    c.handleMessage('other', buildMsg(text: 'nope'), 'chan');
    await Future.delayed(const Duration(milliseconds: 10));
    expect(fake.spoken, ['Bob. hi']);
  });

  test('message-only format drops the name', () async {
    final fake = FakeTts();
    final c = await makeController(fake);
    c.setFormatMode(TtsFormatMode.messageOnly);
    c.handleMessage('chan', buildMsg(text: 'hi'), 'chan');
    await Future.delayed(const Duration(milliseconds: 10));
    expect(fake.spoken, ['hi']);
  });

  test('force english uses "said"', () async {
    final fake = FakeTts();
    final c = await makeController(fake);
    c.setForceEnglish(true);
    expect(fake.setLanguageCalls, greaterThan(0));
    c.handleMessage('chan', buildMsg(text: 'hi'), 'chan');
    await Future.delayed(const Duration(milliseconds: 10));
    expect(fake.spoken, ['Bob said hi']);
  });

  test('does not repeat the name for consecutive same-user messages', () async {
    final fake = FakeTts();
    final c = await makeController(fake);
    c.setForceEnglish(true);
    c.handleMessage('chan', buildMsg(text: 'one'), 'chan');
    c.handleMessage('chan', buildMsg(text: 'two'), 'chan');
    await Future.delayed(const Duration(milliseconds: 10));
    expect(fake.spoken, ['Bob said one', 'two']);
  });

  test('strips emotes when enabled', () async {
    final fake = FakeTts();
    final c = await makeController(fake);
    c.setFormatMode(TtsFormatMode.messageOnly);
    final m = buildMsg(
      text: 'hello Kappa',
      emotePositions: [
        EmotePosition(
          emoteId: '1',
          startIndex: 6,
          endIndex: 11,
          emoteCode: 'Kappa',
        ),
      ],
    );
    c.handleMessage('chan', m, 'chan');
    await Future.delayed(const Duration(milliseconds: 10));
    expect(fake.spoken, ['hello']);
  });

  test('keeps emotes when disabled', () async {
    final fake = FakeTts();
    final c = await makeController(fake);
    c.setFormatMode(TtsFormatMode.messageOnly);
    c.setIgnoreEmotes(false);
    final m = buildMsg(
      text: 'hello Kappa',
      emotePositions: [
        EmotePosition(
          emoteId: '1',
          startIndex: 6,
          endIndex: 11,
          emoteCode: 'Kappa',
        ),
      ],
    );
    c.handleMessage('chan', m, 'chan');
    await Future.delayed(const Duration(milliseconds: 10));
    expect(fake.spoken, ['hello Kappa']);
  });

  test('strips urls', () async {
    final fake = FakeTts();
    final c = await makeController(fake);
    c.setFormatMode(TtsFormatMode.messageOnly);
    c.handleMessage(
      'chan',
      buildMsg(text: 'see https://twitch.tv/x now'),
      'chan',
    );
    await Future.delayed(const Duration(milliseconds: 10));
    expect(fake.spoken, ['see  now']);
  });

  test('does not skip emoji', () async {
    final fake = FakeTts();
    final c = await makeController(fake);
    c.setFormatMode(TtsFormatMode.messageOnly);
    c.handleMessage('chan', buildMsg(text: 'hi 🔥 there'), 'chan');
    await Future.delayed(const Duration(milliseconds: 10));
    expect(fake.spoken, ['hi 🔥 there']);
  });

  test('user ignore list blocks a user', () async {
    final fake = FakeTts();
    final c = await makeController(fake);
    c.setUserIgnoreList(['bob']);
    c.handleMessage('chan', buildMsg(text: 'hi'), 'chan');
    await Future.delayed(const Duration(milliseconds: 10));
    expect(fake.spoken, isEmpty);
  });

  test('does not speak when disabled', () async {
    final fake = FakeTts();
    final c = await makeController(fake);
    c.setEnabled(false);
    c.handleMessage('chan', buildMsg(text: 'hi'), 'chan');
    await Future.delayed(const Duration(milliseconds: 10));
    expect(fake.spoken, isEmpty);
  });

  test('newest queue mode uses QUEUE_FLUSH (0)', () async {
    final fake = FakeTts();
    final c = await makeController(fake);
    c.setQueueMode(TtsQueueMode.newest);
    c.handleMessage('chan', buildMsg(text: 'hi'), 'chan');
    await Future.delayed(const Duration(milliseconds: 10));
    expect(fake.setQueueModeCalls, [0]);
    expect(fake.spoken, ['Bob. hi']);
  });

  test('queue mode uses QUEUE_ADD (1)', () async {
    final fake = FakeTts();
    final c = await makeController(fake);
    c.setQueueMode(TtsQueueMode.queue);
    c.handleMessage('chan', buildMsg(text: 'hi'), 'chan');
    await Future.delayed(const Duration(milliseconds: 10));
    expect(fake.setQueueModeCalls, [1]);
    expect(fake.spoken, ['Bob. hi']);
  });

  test('skips history and backfill', () async {
    final fake = FakeTts();
    final c = await makeController(fake);
    c.handleMessage(
      'chan',
      TwitchMessage(login: 'bob', text: 'old', isHistory: true),
      'chan',
    );
    await Future.delayed(const Duration(milliseconds: 10));
    expect(fake.spoken, isEmpty);
  });

  group('engine/voice picker', () {
    test('fetchOptions parses Android engines', () async {
      final fake = FakeTts();
      fake.engines = [
        {'name': 'com.google.android.tts', 'label': 'Google TTS'},
        {'name': 'com.svox.pico', 'label': 'Pico TTS'},
      ];
      final c = TtsController(tts: fake);
      c.overrideIsAndroid = true;
      final opts = await c.fetchOptions();
      expect(opts, hasLength(2));
      expect(opts[0].id, 'com.google.android.tts');
      expect(opts[0].label, 'Google TTS');
      expect(opts[1].label, 'Pico TTS');
    });

    test('fetchOptions parses iOS voices', () async {
      final fake = FakeTts();
      fake.voices = [
        {
          'name': 'Samantha',
          'locale': 'en-US',
          'identifier': 'com.apple.voice.en-US.Samantha',
        },
        {'name': 'Daniel', 'locale': 'en-GB', 'identifier': 'x'},
      ];
      final c = TtsController(tts: fake);
      c.overrideIsAndroid = false;
      final opts = await c.fetchOptions();
      expect(opts, hasLength(2));
      expect(opts[0].id, 'com.apple.voice.en-US.Samantha');
      expect(opts[0].label, 'Samantha (en-US)');
      expect(opts[1].id, 'x');
    });

    test('applyOption routes Android to setEngine', () async {
      final fake = FakeTts();
      final c = TtsController(tts: fake);
      c.overrideIsAndroid = true;
      final opt = TtsOption(
        id: 'com.google.android.tts',
        label: 'Google TTS',
        raw: {'name': 'com.google.android.tts'},
      );
      await c.applyOption(opt);
      expect(fake.setEngineId, 'com.google.android.tts');
    });

    test('applyOption routes non-Android to setVoice', () async {
      final fake = FakeTts();
      final c = TtsController(tts: fake);
      c.overrideIsAndroid = false;
      final opt = TtsOption(
        id: 'x',
        label: 'Daniel (en-GB)',
        raw: {'name': 'Daniel', 'locale': 'en-GB'},
      );
      await c.applyOption(opt);
      expect(fake.setVoiceRaw, {'name': 'Daniel', 'locale': 'en-GB'});
    });

    test('init does not auto-select an engine (uses system default)', () async {
      await (await SharedPreferences.getInstance()).clear();
      final fake = FakeTts();
      fake.engines = [
        {'name': 'com.google.android.tts', 'label': 'Google TTS'},
      ];
      final c = TtsController(tts: fake);
      c.overrideIsAndroid = true;
      await c.init();
      expect(fake.setEngineId, isNull);
      expect(c.selectedOption, isNull);
    });

    test('fetchOptions falls back to default engine when blocked', () async {
      final fake = FakeTts();
      fake.engines = [];
      fake.defaultEngine = 'com.google.android.tts';
      final c = TtsController(tts: fake);
      c.overrideIsAndroid = true;
      final opts = await c.fetchOptions();
      expect(opts, hasLength(1));
      expect(opts.first.id, 'com.google.android.tts');
    });

    test('checkAndPrepare succeeds with no enumerable engines', () async {
      final fake = FakeTts();
      fake.engines = [];
      fake.defaultEngine = 'com.google.android.tts';
      final c = TtsController(tts: fake);
      c.overrideIsAndroid = true;
      expect(await c.checkAndPrepare(), isTrue);
    });

    test(
      'fetchOptions offers Device default when nothing is enumerable',
      () async {
        final fake = FakeTts();
        fake.engines = [];
        fake.defaultEngine = null;
        final c = TtsController(tts: fake);
        c.overrideIsAndroid = true;
        final opts = await c.fetchOptions();
        expect(opts, hasLength(1));
        expect(opts.first.id, TtsController.defaultEngineId);
        expect(opts.first.label, 'Device default');
      },
    );

    test('Device default option does not call setEngine', () async {
      final fake = FakeTts();
      final c = TtsController(tts: fake);
      c.overrideIsAndroid = true;
      final opt = const TtsOption(
        id: TtsController.defaultEngineId,
        label: 'Device default',
        raw: {},
      );
      await c.applyOption(opt);
      expect(fake.setEngineId, isNull);
      expect(c.selectedOption?.id, TtsController.defaultEngineId);
    });
  });
}
