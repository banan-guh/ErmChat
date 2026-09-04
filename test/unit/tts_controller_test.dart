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
    await pumpEventQueue();
    expect(fake.spoken, ['Bob. hi']);
  });

  test('message-only format drops the name', () async {
    final fake = FakeTts();
    final c = await makeController(fake);
    c.setFormatMode(TtsFormatMode.messageOnly);
    c.handleMessage('chan', buildMsg(text: 'hi'), 'chan');
    await pumpEventQueue();
    expect(fake.spoken, ['hi']);
  });

  test('force english uses "said"', () async {
    final fake = FakeTts();
    final c = await makeController(fake);
    c.setForceEnglish(true);
    expect(fake.setLanguageCalls, greaterThan(0));
    c.handleMessage('chan', buildMsg(text: 'hi'), 'chan');
    await pumpEventQueue();
    expect(fake.spoken, ['Bob said hi']);
  });

  test('does not repeat the name for consecutive same-user messages', () async {
    final fake = FakeTts();
    final c = await makeController(fake);
    c.setForceEnglish(true);
    c.handleMessage('chan', buildMsg(text: 'one'), 'chan');
    c.handleMessage('chan', buildMsg(text: 'two'), 'chan');
    await pumpEventQueue();
    expect(fake.spoken, ['Bob said one', 'two']);
  });

  test(
    'respects the ignore emotes setting when speaking emote codes',
    () async {
      const cases = [(true, 'hello'), (false, 'hello Kappa')];
      for (final (ignoreEmotes, expected) in cases) {
        final fake = FakeTts();
        final c = await makeController(fake);
        c.setFormatMode(TtsFormatMode.messageOnly);
        c.setIgnoreEmotes(ignoreEmotes);
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
        await pumpEventQueue();
        expect(fake.spoken, [expected], reason: 'ignoreEmotes: $ignoreEmotes');
      }
    },
  );

  test('strips urls', () async {
    final fake = FakeTts();
    final c = await makeController(fake);
    c.setFormatMode(TtsFormatMode.messageOnly);
    c.handleMessage(
      'chan',
      buildMsg(text: 'see https://twitch.tv/x now'),
      'chan',
    );
    await pumpEventQueue();
    expect(fake.spoken, ['see  now']);
  });

  test('does not skip emoji', () async {
    final fake = FakeTts();
    final c = await makeController(fake);
    c.setFormatMode(TtsFormatMode.messageOnly);
    c.handleMessage('chan', buildMsg(text: 'hi 🔥 there'), 'chan');
    await pumpEventQueue();
    expect(fake.spoken, ['hi 🔥 there']);
  });

  test('user ignore list blocks a user', () async {
    final fake = FakeTts();
    final c = await makeController(fake);
    c.setUserIgnoreList(['bob']);
    c.handleMessage('chan', buildMsg(text: 'hi'), 'chan');
    await pumpEventQueue();
    expect(fake.spoken, isEmpty);
  });

  test('does not speak when disabled', () async {
    final fake = FakeTts();
    final c = await makeController(fake);
    c.setEnabled(false);
    c.handleMessage('chan', buildMsg(text: 'hi'), 'chan');
    await pumpEventQueue();
    expect(fake.spoken, isEmpty);
  });

  test('applies the selected queue mode before speaking', () async {
    const cases = [(TtsQueueMode.newest, 0), (TtsQueueMode.queue, 1)];
    for (final (mode, expectedCall) in cases) {
      final fake = FakeTts();
      final c = await makeController(fake);
      c.setQueueMode(mode);
      c.handleMessage('chan', buildMsg(text: 'hi'), 'chan');
      await pumpEventQueue();
      expect(fake.setQueueModeCalls, [expectedCall], reason: 'mode: $mode');
      expect(fake.spoken, ['Bob. hi'], reason: 'mode: $mode');
    }
  });

  test('skips history and backfill', () async {
    final fake = FakeTts();
    final c = await makeController(fake);
    c.handleMessage(
      'chan',
      TwitchMessage(login: 'bob', text: 'old', isHistory: true),
      'chan',
    );
    await pumpEventQueue();
    expect(fake.spoken, isEmpty);
  });

  group('engine/voice picker', () {
    test('fetchOptions parses platform engines and voices', () async {
      final androidFake = FakeTts();
      androidFake.engines = [
        {'name': 'com.google.android.tts', 'label': 'Google TTS'},
        {'name': 'com.svox.pico', 'label': 'Pico TTS'},
      ];
      final androidController = TtsController(tts: androidFake);
      androidController.overrideIsAndroid = true;
      final androidOpts = await androidController.fetchOptions();
      expect(androidOpts, hasLength(2));
      expect(androidOpts[0].id, 'com.google.android.tts');
      expect(androidOpts[0].label, 'Google TTS');
      expect(androidOpts[1].label, 'Pico TTS');

      final iosFake = FakeTts();
      iosFake.voices = [
        {
          'name': 'Samantha',
          'locale': 'en-US',
          'identifier': 'com.apple.voice.en-US.Samantha',
        },
        {'name': 'Daniel', 'locale': 'en-GB', 'identifier': 'x'},
      ];
      final iosController = TtsController(tts: iosFake);
      iosController.overrideIsAndroid = false;
      final iosOpts = await iosController.fetchOptions();
      expect(iosOpts, hasLength(2));
      expect(iosOpts[0].id, 'com.apple.voice.en-US.Samantha');
      expect(iosOpts[0].label, 'Samantha (en-US)');
      expect(iosOpts[1].id, 'x');
    });

    test('applyOption routes the selection to the platform setter', () async {
      final engineFake = FakeTts();
      final engineController = TtsController(tts: engineFake);
      engineController.overrideIsAndroid = true;
      final engineOpt = TtsOption(
        id: 'com.google.android.tts',
        label: 'Google TTS',
        raw: {'name': 'com.google.android.tts'},
      );
      await engineController.applyOption(engineOpt);
      expect(engineFake.setEngineId, 'com.google.android.tts');

      final voiceFake = FakeTts();
      final voiceController = TtsController(tts: voiceFake);
      voiceController.overrideIsAndroid = false;
      final voiceOpt = TtsOption(
        id: 'x',
        label: 'Daniel (en-GB)',
        raw: {'name': 'Daniel', 'locale': 'en-GB'},
      );
      await voiceController.applyOption(voiceOpt);
      expect(voiceFake.setVoiceRaw, {'name': 'Daniel', 'locale': 'en-GB'});
    });

    test(
      'falls back to the device default without preselecting an engine',
      () async {
        await (await SharedPreferences.getInstance()).clear();
        final initFake = FakeTts();
        initFake.engines = [
          {'name': 'com.google.android.tts', 'label': 'Google TTS'},
        ];
        final initController = TtsController(tts: initFake);
        initController.overrideIsAndroid = true;
        await initController.init();
        expect(initFake.setEngineId, isNull);
        expect(initController.selectedOption, isNull);

        final blockedFake = FakeTts();
        blockedFake.engines = [];
        blockedFake.defaultEngine = 'com.google.android.tts';
        final blockedController = TtsController(tts: blockedFake);
        blockedController.overrideIsAndroid = true;
        final blockedOpts = await blockedController.fetchOptions();
        expect(blockedOpts, hasLength(1));
        expect(blockedOpts.first.id, 'com.google.android.tts');

        final emptyFake = FakeTts();
        emptyFake.engines = [];
        emptyFake.defaultEngine = null;
        final emptyController = TtsController(tts: emptyFake);
        emptyController.overrideIsAndroid = true;
        final emptyOpts = await emptyController.fetchOptions();
        expect(emptyOpts, hasLength(1));
        expect(emptyOpts.first.id, TtsController.defaultEngineId);
        expect(emptyOpts.first.label, 'Device default');

        final defaultFake = FakeTts();
        final defaultController = TtsController(tts: defaultFake);
        defaultController.overrideIsAndroid = true;
        const opt = TtsOption(
          id: TtsController.defaultEngineId,
          label: 'Device default',
          raw: {},
        );
        await defaultController.applyOption(opt);
        expect(defaultFake.setEngineId, isNull);
        expect(
          defaultController.selectedOption?.id,
          TtsController.defaultEngineId,
        );
      },
    );
  });
}
