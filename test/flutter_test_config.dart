import 'dart:async';

import 'package:ermchat/util/log.dart';

FutureOr<void> testExecutable(FutureOr<void> Function() testMain) async {
  // Keep the test console readable: production chat-pipeline diagnostics (IRC
  // joins, badge fetch failures, reconnect traces) are not useful test output;
  // expect()/assertions carry the failure signal. The Flutter test binding
  // forces debugPrint to a synchronous console printer, so silencing happens
  // at the app's logDebug hook instead.
  debugLogEnabled = false;
  await testMain();
}
