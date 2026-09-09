import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ermchat/services/pip_service.dart';
import 'package:ermchat/services/stream_player_controller.dart';

class FakePipService extends PipService {
  FakePipService() : super(channel: const MethodChannel('test/pip'));

  int enterCalls = 0;
  bool? lastAutoEnter;
  bool? lastPlaying;

  @override
  Future<bool> enterPip() async {
    enterCalls++;
    return true;
  }

  @override
  Future<void> setAutoEnter(bool enabled) async {
    lastAutoEnter = enabled;
  }

  @override
  Future<void> updatePipActions({required bool playing}) async {
    lastPlaying = playing;
  }
}

StreamPlayerController _controller({PipService? pipService}) {
  final controller = StreamPlayerController();
  controller.pipService = pipService;
  return controller;
}

void main() {
  group('StreamPlayerController PiP', () {
    test('enterPip is a no-op without an active channel', () async {
      final pip = FakePipService();
      final controller = _controller(pipService: pip);
      controller.setPipEnabled(true);
      await controller.enterPip();
      expect(pip.enterCalls, 0);
    });

    test('enterPip is a no-op when audio-only', () async {
      final pip = FakePipService();
      final controller = _controller(pipService: pip);
      controller.setPipEnabled(true);
      controller.toggleStream('shroud');
      controller.toggleAudioOnly();
      await controller.enterPip();
      expect(pip.enterCalls, 0);
    });

    test('enterPip is a no-op when PiP is disabled', () async {
      final pip = FakePipService();
      final controller = _controller(pipService: pip);
      controller.toggleStream('shroud');
      await controller.enterPip();
      expect(pip.enterCalls, 0);
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

    test('canPip requires retainWebview', () {
      final controller = _controller(pipService: FakePipService());
      controller.setPipEnabled(true);
      controller.setRetainWebview(false);
      controller.toggleStream('shroud');
      expect(controller.canPip, isFalse);
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
}
