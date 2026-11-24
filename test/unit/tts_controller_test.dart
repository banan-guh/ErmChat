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
  int languageChecks = 0;
  String? setEngineId;
  Map<String, String>? setVoiceRaw;
  List<dynamic>? engines;
  List<dynamic>? voices;
  String? defaultEngine;

  @override
  Future<dynamic> isLanguageAvailable(String language) async {
    languageChecks++;
    return true;
  }

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
  // Enabling from the settings screen goes through checkAndPrepare; init()
  // skips the engine while TTS is off.
  await c.checkAndPrepare();
  return c;
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  test('init skips the engine while TTS is off', () async {
    await (await SharedPreferences.getInstance()).clear();
    final off = FakeTts();
    await TtsController(tts: off).init();
    expect(off.languageChecks, 0, reason: 'nothing speaks while off');
    expect(off.setEngineId, isNull);
    expect(off.setVoiceRaw, isNull);

    await (await SharedPreferences.getInstance()).setBool('tts_enabled', true);
    final on = FakeTts();
    await TtsController(tts: on).init();
    expect(on.languageChecks, 1, reason: 'an enabled launch checks once');
    await (await SharedPreferences.getInstance()).clear();
  });

  test('disabled init does not construct the platform engine', () async {
    await (await SharedPreferences.getInstance()).clear();
    var builds = 0;
    final fake = FakeTts();
    final controller = TtsController(
      engineFactory: () {
        builds++;
        return fake;
      },
    );

    await controller.init();
    await controller.shutdown();
    expect(builds, 0, reason: 'disabled TTS must not bind the native engine');

    await (await SharedPreferences.getInstance()).setBool('tts_enabled', true);
    await controller.loadFromPrefs();
    await controller.checkAndPrepare();
    expect(builds, 1);
    expect(fake.languageChecks, 1);
    await (await SharedPreferences.getInstance()).clear();
  });

  test('speaks active channel, ignores others', () async {
    final fake = FakeTts();
    final c = await makeController(fake);
    c.handleMessage('chan', buildMsg(text: 'hi'), 'chan');
    c.handleMessage('other', buildMsg(text: 'nope'), 'chan');
    await pumpEventQueue();
    expect(fake.spoken, ['Bob. hi']);
  });

  test('a notice does not hide the next speaker name', () async {
    final fake = FakeTts();
    final c = await makeController(fake);
    c.handleMessage('chan', buildMsg(text: 'sub!', isSystem: true), 'chan');
    c.handleMessage('chan', buildMsg(text: 'hi'), 'chan');
    await pumpEventQueue();
    expect(fake.spoken.last, 'Bob. hi');
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

  test('user ignore list blocks a user', () async {
    final fake = FakeTts();
    final c = await makeController(fake);
    c.setUserIgnoreList(['bob']);
    c.handleMessage('chan', buildMsg(text: 'hi'), 'chan');
    await pumpEventQueue();
    expect(fake.spoken, isEmpty);
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
}
