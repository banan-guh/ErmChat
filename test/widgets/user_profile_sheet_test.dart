import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:url_launcher_platform_interface/link.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';
import 'package:ermchat/services/twitch_api.dart';
import 'package:ermchat/services/twitch_auth.dart';
import 'package:ermchat/widgets/user_profile_sheet.dart';

class _FakeUrlLauncher extends UrlLauncherPlatform {
  bool succeed = true;
  String? lastUrl;
  PreferredLaunchMode? lastMode;

  @override
  LinkDelegate? get linkDelegate => null;

  @override
  Future<bool> canLaunch(String url) async => true;

  @override
  Future<bool> launchUrl(String url, LaunchOptions options) async {
    lastUrl = url;
    lastMode = options.mode;
    return succeed;
  }

  @override
  Future<void> closeWebView() async {}
}

void main() {
  late _FakeUrlLauncher fakeLauncher;

  setUp(() {
    fakeLauncher = _FakeUrlLauncher();
    UrlLauncherPlatform.instance = fakeLauncher;
  });

  TwitchApi createApi() {
    return TwitchApi(
      client: MockClient(
        (_) async => http.Response(
          '{"data": [{"id": "123", "login": "testuser", "display_name": "TestUser", "created_at": "2020-01-01T00:00:00Z", "profile_image_url": "https://example.com/img.png"}]}',
          200,
        ),
      ),
    );
  }

  Widget wrap(TwitchApi api) {
    return MaterialApp(
      home: Scaffold(
        body: UserProfileSheet(
          username: 'testuser',
          userId: '123',
          displayName: 'TestUser',
          twitchApi: api,
          twitchAuth: TwitchAuth()..accessToken = 'test-token',
          messageController: TextEditingController(),
          focusNode: FocusNode(),
          onClose: () {},
        ),
      ),
    );
  }

  testWidgets('Report button opens twitch.tv/<login>/report', (tester) async {
    await tester.pumpWidget(wrap(createApi()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Report'));
    await tester.pumpAndSettle();

    expect(fakeLauncher.lastUrl, 'https://twitch.tv/testuser/report');
    expect(fakeLauncher.lastMode, PreferredLaunchMode.externalApplication);
  });

  testWidgets('Report button shows snackbar when launch fails', (tester) async {
    fakeLauncher.succeed = false;
    await tester.pumpWidget(wrap(createApi()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Report'));
    await tester.pumpAndSettle();

    expect(find.text('Could not open the report page'), findsOneWidget);
  });
}
