import 'package:flutter/services.dart';
import 'package:ermchat/services/pip_service.dart';

/// Test double for the `ermchat/pip` bridge: records host calls and lets a
/// test drive [onPipChanged] the way the native host would.
class FakePipService extends PipService {
  FakePipService() : super(channel: const MethodChannel('test/pip'));

  int enterCalls = 0;
  bool? lastAutoEnter;
  bool? lastPlaying;

  /// Fires the host callback that opens or closes the OS PiP window.
  void triggerPipChanged(bool inPip) => onPipChanged?.call(inPip);

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
