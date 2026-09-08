import 'dart:async';
import 'dart:io';

import 'package:ermchat/util/log.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

/// Temp-dir path provider for all tests: span building constructs image
/// providers backed by [EmoteCacheManager], whose config touches the file
/// system on first use. Without this the platform-channel error surfaces as
/// an unhandled async error attributed to a random test.
class _FakePathProvider extends PathProviderPlatform {
  late final String tempDir = Directory.systemTemp
      .createTempSync('ermchat_test_')
      .path;

  @override
  Future<String?> getTemporaryPath() async => tempDir;

  @override
  Future<String?> getApplicationSupportPath() async => tempDir;
}

FutureOr<void> testExecutable(FutureOr<void> Function() testMain) async {
  // Keep the test console readable: production chat-pipeline diagnostics (IRC
  // joins, badge fetch failures, reconnect traces) are not useful test output;
  // expect()/assertions carry the failure signal. The Flutter test binding
  // forces debugPrint to a synchronous console printer, so silencing happens
  // at the app's logDebug hook instead.
  debugLogEnabled = false;
  PathProviderPlatform.instance = _FakePathProvider();
  await testMain();
}
