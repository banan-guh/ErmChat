import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ermchat/models/twitch_message.dart';
import 'package:ermchat/services/mod_actions.dart';
import 'package:ermchat/services/twitch_api.dart';
import 'package:ermchat/services/twitch_auth.dart';
import 'package:ermchat/widgets/user_profile_sheet.dart';

void main() {
  testWidgets('user sheet seeks to the whole card and never flashes history', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final api = TwitchApi(
      client: MockClient((request) async {
        // Follow age resolves a frame later and, being empty, sets no state.
        // That used to leave the sheet parked on the loading card.
        if (request.url.path.contains('followers')) {
          await Future<void>.delayed(const Duration(milliseconds: 300));
          return http.Response('{"data": []}', 200);
        }
        return http.Response(
          '{"data": [{"id": "123", "login": "testuser", "display_name": "TestUser", "created_at": "2020-01-01T00:00:00Z", "profile_image_url": "https://example.com/img.png"}]}',
          200,
        );
      }),
    );

    // Mirrors UserSheets.showUserProfile across opens: a fresh controller,
    // reuse of the last measured card as the initial size, and the auto-seek
    // flag that keeps the history hidden until the divider settles.
    var savedExtent = 0.0;
    late DraggableScrollableController sheetController;
    late ValueNotifier<double?> autoSeek;

    double? seekTarget;
    void seekToCard() {
      final target = savedExtent;
      if (seekTarget == target) return;
      if (seekTarget == null &&
          (sheetController.size - target).abs() <= 0.002) {
        return;
      }
      seekTarget = target;
      autoSeek.value = target;
      sheetController.animateTo(
        target,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOutCubic,
      );
    }

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () {
                sheetController = DraggableScrollableController();
                autoSeek = ValueNotifier<double?>(null);
                showModalBottomSheet(
                  context: context,
                  isScrollControlled: true,
                  enableDrag: false,
                  builder: (ctx) => Listener(
                    onPointerDown: (_) {
                      autoSeek.value = null;
                      seekTarget = null;
                    },
                    child: DraggableScrollableSheet(
                      controller: sheetController,
                      initialChildSize: savedExtent > 0.02
                          ? savedExtent
                          : 0.001,
                      minChildSize: 0,
                      maxChildSize: 1,
                      expand: false,
                      snap: false,
                      builder: (_, scrollController) => UserProfileSheet(
                        username: 'testuser',
                        userId: '123',
                        displayName: 'TestUser',
                        broadcasterUserId: 'b123',
                        twitchApi: api,
                        twitchAuth: TwitchAuth()..accessToken = 'test-token',
                        messageController: TextEditingController(),
                        focusNode: FocusNode(),
                        onClose: () => Navigator.pop(ctx),
                        scrollController: scrollController,
                        sheetController: sheetController,
                        autoSeek: autoSeek,
                        sheetMinExtent: 0,
                        onCardMeasured: (naturalH) {
                          savedExtent = (naturalH / 800.0).clamp(0.0, 1.0);
                          autoSeek.value = savedExtent;
                          if (!sheetController.isAttached) {
                            WidgetsBinding.instance.addPostFrameCallback((_) {
                              if (sheetController.isAttached) seekToCard();
                            });
                            return;
                          }
                          seekToCard();
                        },
                        userMessages: [
                          for (var i = 0; i < 30; i++)
                            TwitchMessage(
                              login: 'testuser',
                              text: 'm$i',
                              channel: 'somechannel',
                            ),
                        ],
                        messageRowBuilder: (context, msg) =>
                            Text('row:${msg.text}'),
                      ),
                    ),
                  ),
                ).whenComplete(() {
                  sheetController.dispose();
                  autoSeek.dispose();
                });
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );

    Future<double> openAndTrackMaxListHeight() async {
      await tester.tap(find.text('open'));
      var maxListH = 0.0;
      for (var i = 0; i < 80; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        final lists = find.byType(ListView).evaluate();
        if (lists.isNotEmpty) {
          maxListH = math.max(
            maxListH,
            tester.getSize(find.byType(ListView)).height,
          );
        }
        if (i > 40 && find.text('Report').evaluate().isNotEmpty) break;
      }
      return maxListH;
    }

    // First open: grows from a sliver to the whole card, list never shows.
    expect(await openAndTrackMaxListHeight(), lessThan(0.5));
    expect(sheetController.size, closeTo(savedExtent, 0.02));
    expect(find.text('Report'), findsOneWidget);

    // Dismiss, then reopen with the card extent reused as the initial size.
    // The loading card measures shorter, so the sheet sits above it for a
    // frame; the history must stay hidden until the divider settles.
    Navigator.of(tester.element(find.byType(Scaffold).first)).pop();
    await tester.pumpAndSettle();
    expect(await openAndTrackMaxListHeight(), lessThan(0.5));
    expect(sheetController.size, closeTo(savedExtent, 0.02));
    expect(tester.getSize(find.byType(ListView)).height, closeTo(0, 1));
  });

  testWidgets('late card measurement does not collapse an expanded sheet', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    // Hold the follow-age lookup open so the second card measurement lands
    // after the user has expanded the sheet.
    final follow = Completer<http.Response>();
    final api = TwitchApi(
      client: MockClient((request) async {
        if (request.url.path.contains('followers')) return follow.future;
        return http.Response(
          '{"data": [{"id": "123", "login": "testuser", "display_name": "TestUser", "created_at": "2020-01-01T00:00:00Z", "profile_image_url": "https://example.com/img.png"}]}',
          200,
        );
      }),
    );

    // Mirrors UserSheets.showUserProfile: no-yank guard on late measurements.
    final sheetController = DraggableScrollableController();
    final autoSeek = ValueNotifier<double?>(null);
    final historyController = ScrollController();
    double? seekTarget;
    var cardExtent = 0.0;
    void seekToCard() {
      final target = cardExtent;
      if (seekTarget == target) return;
      if (seekTarget == null &&
          (sheetController.size - target).abs() <= 0.002) {
        return;
      }
      seekTarget = target;
      autoSeek.value = target;
      sheetController.animateTo(
        target,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOutCubic,
      );
    }

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () {
                showModalBottomSheet(
                  context: context,
                  isScrollControlled: true,
                  enableDrag: false,
                  builder: (ctx) => Listener(
                    onPointerDown: (_) {
                      autoSeek.value = null;
                      seekTarget = null;
                    },
                    child: DraggableScrollableSheet(
                      controller: sheetController,
                      initialChildSize: 0.001,
                      minChildSize: 0,
                      maxChildSize: 1,
                      expand: false,
                      snap: false,
                      shouldCloseOnMinExtent: false,
                      builder: (_, scrollController) => UserProfileSheet(
                        username: 'testuser',
                        userId: '123',
                        displayName: 'TestUser',
                        broadcasterUserId: 'b',
                        channel: 'somechannel',
                        canModerate: true,
                        modActions: ModActions(
                          twitchApi: api,
                          getChannelUserIds: () => const {},
                          getCurrentUserId: () => null,
                        ),
                        twitchApi: api,
                        twitchAuth: TwitchAuth()..accessToken = 'test-token',
                        messageController: TextEditingController(),
                        focusNode: FocusNode(),
                        onClose: () => Navigator.pop(ctx),
                        scrollController: historyController,
                        anchor: scrollController,
                        sheetController: sheetController,
                        autoSeek: autoSeek,
                        sheetMinExtent: 0,
                        onCardMeasured: (naturalH) {
                          final target = (naturalH / 800.0).clamp(0.0, 1.0);
                          final attached = sheetController.isAttached;
                          final size = attached ? sheetController.size : 0.0;
                          final seeking =
                              seekTarget != null &&
                              (size - seekTarget!).abs() > 0.005;
                          final userExpanded =
                              !seeking && attached && size > cardExtent + 0.05;
                          cardExtent = target;
                          if (userExpanded) {
                            autoSeek.value = null;
                            return;
                          }
                          autoSeek.value = target;
                          if (!attached) {
                            WidgetsBinding.instance.addPostFrameCallback((_) {
                              if (sheetController.isAttached) seekToCard();
                            });
                            return;
                          }
                          seekToCard();
                        },
                        userMessages: [
                          for (var i = 0; i < 30; i++)
                            TwitchMessage(
                              login: 'testuser',
                              text: 'm$i',
                              channel: 'somechannel',
                            ),
                        ],
                        messageRowBuilder: (context, msg) =>
                            Text('row:${msg.text}'),
                      ),
                    ),
                  ),
                ).whenComplete(() {
                  sheetController.dispose();
                  historyController.dispose();
                  autoSeek.dispose();
                });
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(sheetController.size, closeTo(cardExtent, 0.02));

    // Expand like a user.
    await tester.dragFrom(const Offset(200, 700), const Offset(0, -600));
    await tester.pumpAndSettle();
    final expanded = sheetController.size;
    expect(expanded, greaterThan(cardExtent + 0.05));

    // The follow-age row arrives; the expanded sheet must not collapse.
    final before = cardExtent;
    follow.complete(
      http.Response('{"data":[{"followed_at":"2020-01-01T00:00:00Z"}]}', 200),
    );
    await tester.pumpAndSettle();
    expect(cardExtent, greaterThan(before + 0.02));
    expect(sheetController.size, closeTo(expanded, 0.02));
  });
}
