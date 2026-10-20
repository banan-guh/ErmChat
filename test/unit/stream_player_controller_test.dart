import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ermchat/services/pip_service.dart';
import 'package:ermchat/services/stream_player_controller.dart';
import '../helpers/fake_pip_service.dart';

StreamPlayerController _controller({PipService? pipService}) {
  final controller = StreamPlayerController();
  controller.pipService = pipService;
  return controller;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  group('StreamPlayerController PiP', () {
    test('enterPip is a no-op unless eligible', () async {
      final setups = <String, void Function(StreamPlayerController)>{
        'no active channel': (c) => c.setPipEnabled(true),
        'audio-only': (c) {
          c.setPipEnabled(true);
          c.toggleStream('shroud');
          c.toggleAudioOnly();
        },
        'pip disabled': (c) => c.toggleStream('shroud'),
      };
      for (final entry in setups.entries) {
        final pip = FakePipService();
        final controller = _controller(pipService: pip);
        entry.value(controller);
        await controller.enterPip();
        expect(pip.enterCalls, 0, reason: entry.key);
      }
    });

    test('enterPip reaches the host when eligible', () async {
      final pip = FakePipService();
      final controller = _controller(pipService: pip);
      controller.setPipEnabled(true);
      controller.toggleStream('shroud');
      await controller.enterPip();
      expect(pip.enterCalls, 1);
    });

    test('setPipActive exits theater mode', () {
      final controller = _controller(pipService: FakePipService());
      controller.toggleStream('shroud');
      controller.toggleTheaterMode();
      expect(controller.isTheaterMode, isTrue);
      controller.setPipActive(true);
      expect(controller.isInPip, isTrue);
      expect(controller.isTheaterMode, isFalse);
    });

    test('closeStream clears PiP state', () {
      final controller = _controller(pipService: FakePipService());
      controller.toggleStream('shroud');
      controller.setPipActive(true);
      controller.closeStream();
      expect(controller.isInPip, isFalse);
      expect(controller.isActive, isFalse);
    });

    test('takePipAction returns and clears the queued action', () {
      final controller = _controller(pipService: FakePipService());
      expect(controller.takePipAction(), isNull);
      controller.notifyPipAction('pause');
      expect(controller.takePipAction(), 'pause');
      expect(controller.takePipAction(), isNull);
    });

    test('setPipPlaying notifies only on flips', () {
      final controller = _controller(pipService: FakePipService());
      var notifies = 0;
      controller.addListener(() => notifies++);
      controller.setPipPlaying(true);
      controller.setPipPlaying(true);
      controller.setPipPlaying(false);
      expect(controller.pipPlaying, isFalse);
      expect(notifies, 2);
    });
  });

  group('StreamPlayerController', () {
    test('stream, audio-only and theater flags stay consistent', () {
      final controller = StreamPlayerController();
      addTearDown(controller.dispose);
      controller.toggleStream('foo');
      expect(controller.currentChannel, 'foo');
      expect(controller.isActive, isTrue);

      controller.toggleAudioOnly();
      expect(controller.isAudioOnly, isTrue);
      controller.toggleStream('bar');
      expect(controller.currentChannel, 'bar');
      expect(controller.isAudioOnly, isFalse, reason: 'switching resets it');

      controller.toggleTheaterMode();
      expect(controller.isTheaterMode, isTrue);
      controller.toggleAudioOnly();
      expect(controller.isTheaterMode, isFalse);
      expect(controller.isAudioOnly, isTrue);

      controller.toggleStream('bar');
      expect(controller.currentChannel, isNull);
      expect(controller.isActive, isFalse);
    });

    test('playerUrl carries the channel with extensions off', () {
      final controller = StreamPlayerController();
      final url = controller.playerUrl('foo');
      expect(url, contains('channel=foo'));
      expect(url, contains('enableExtensions=false'));
      controller.dispose();
    });

    test('split fraction clamps and render death bumps generation', () {
      final controller = StreamPlayerController();
      controller.setSplitFraction(0.9);
      expect(controller.splitFraction, 0.8);
      controller.setSplitFraction(0.1);
      expect(controller.splitFraction, 0.2);
      final generation = controller.generation;
      controller.onRenderProcessGone();
      expect(controller.generation, generation + 1);
      controller.dispose();
    });
  });

  group('StreamPlayerController VOD', () {
    test(
      'plays the video from an offset and maps position to archive time',
      () {
        final controller = StreamPlayerController();
        final start = DateTime.utc(2026, 10, 14, 18);
        controller.watchVod(
          'foo',
          '123',
          start,
          at: const Duration(hours: 1, minutes: 2, seconds: 3),
        );
        expect(
          controller.playerUrl('foo'),
          contains('video=v123&time=1h2m3s'),
          reason: 'the embed seeks with h/m/s',
        );
        expect(controller.vodPlayback.value, (
          channel: 'foo',
          time: start.add(const Duration(minutes: 62, seconds: 3)),
        ), reason: 'chat at playback t is the row stamped start + t');
        controller.onVodPosition(const Duration(seconds: 90));
        expect(
          controller.vodPlayback.value?.time,
          start.add(const Duration(seconds: 90)),
        );
        const late = Duration(hours: 47, minutes: 59, seconds: 59);
        controller.watchVod('foo', '123', start, at: late);
        expect(
          controller.playerUrl('foo'),
          contains('time=47h59m59s'),
          reason: 'a 48h VOD seeks past a day in hours, not days',
        );
        expect(
          controller.vodPlayback.value?.time,
          start.add(late),
          reason: 'two days in maps to two days of archive',
        );
        controller.closeStream();
        expect(
          controller.vodPlayback.value,
          isNull,
          reason: 'close ends follow',
        );
        expect(controller.playerUrl('foo'), contains('channel=foo'));
        controller.dispose();
      },
    );
  });
}
