import 'package:flutter_test/flutter_test.dart';
import 'package:ermchat/util/crash_report.dart';

void main() {
  test('reportError forwards to the plugged reporter', () {
    Object? captured;
    StackTrace? capturedStack;
    crashReporter = (e, s) {
      captured = e;
      capturedStack = s;
    };
    reportError('boom', StackTrace.current);
    expect(captured, 'boom');
    expect(capturedStack, isNotNull);
    crashReporter = null;
  });
}
