import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ermchat/models/twitch_message.dart';
import 'package:ermchat/services/twitch_api.dart';
import 'package:ermchat/services/twitch_auth.dart';
import 'package:ermchat/widgets/user_profile_sheet.dart';

void main() {
  testWidgets('history builds only once the sheet rises past the card', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final api = TwitchApi(
      client: MockClient((request) async {
        if (request.url.path.contains('followers')) {
          return http.Response('{"data": []}', 200);
        }
        return http.Response(
          '{"data": [{"id": "123", "login": "testuser", "display_name": "TestUser", "created_at": "2020-01-01T00:00:00Z", "profile_image_url": "https://example.com/img.png"}]}',
          200,
        );
      }),
    );
    // Production wiring: the sheet controller rides the anchor, the list
    // scrolls on its own controller.
    final sheetController = DraggableScrollableController();
    final historyController = ScrollController();
    addTearDown(sheetController.dispose);
    addTearDown(historyController.dispose);
    var cardExtent = 0.0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DraggableScrollableSheet(
            controller: sheetController,
            initialChildSize: 0.001,
            minChildSize: 0,
            maxChildSize: 1,
            expand: false,
            snap: false,
            builder: (_, scrollController) => UserProfileSheet(
              username: 'testuser',
              userId: '123',
              displayName: 'TestUser',
              twitchApi: api,
              twitchAuth: TwitchAuth()..accessToken = 'test-token',
              messageController: TextEditingController(),
              focusNode: FocusNode(),
              onClose: () {},
              scrollController: historyController,
              anchor: scrollController,
              sheetController: sheetController,
              sheetMinExtent: 0,
              onCardMeasured: (naturalH) {
                cardExtent = (naturalH / 800.0).clamp(0.0, 1.0);
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (sheetController.isAttached) {
                    sheetController.jumpTo(cardExtent);
                  }
                });
              },
              userMessages: [
                for (var i = 0; i < 5; i++)
                  TwitchMessage(
                    login: 'testuser',
                    text: 'm$i',
                    channel: 'somechannel',
                  ),
              ],
              messageRowBuilder: (context, msg) => Text('row:${msg.text}'),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(cardExtent, greaterThan(0));
    expect(find.byType(ListView), findsNothing);

    sheetController.jumpTo(1.0);
    await tester.pumpAndSettle();
    expect(find.text('row:m4'), findsOneWidget);

    // Back at the card the list stays built.
    sheetController.jumpTo(cardExtent);
    await tester.pumpAndSettle();
    expect(find.byType(ListView, skipOffstage: false), findsOneWidget);
  });
}
