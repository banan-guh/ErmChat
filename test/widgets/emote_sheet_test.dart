import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:url_launcher_platform_interface/link.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';
import 'package:ermchat/models/generic_emote.dart';
import 'package:ermchat/widgets/emote_sheet.dart';

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

  Widget wrapMany(List<GenericEmote> emotes) {
    return MaterialApp(
      home: Scaffold(
        body: EmoteSheet(
          emotes: emotes,
          messageController: TextEditingController(),
          focusNode: FocusNode(),
          onClose: () {},
        ),
      ),
    );
  }

  Widget wrap(GenericEmote emote) => wrapMany([emote]);

  GenericEmote sevenTvEmote({String? baseName, bool zeroWidth = false}) {
    return GenericEmote(
      id: '7tv-1',
      code: 'Cope',
      type: EmoteType.sevenTv,
      url: 'https://cdn.7tv.app/emote/1/1x.webp',
      baseName: baseName,
      isZeroWidth: zeroWidth,
      ownerChannel: 'CopeQueen',
    );
  }

  testWidgets('shows name, type label and creator rows', (tester) async {
    await tester.pumpWidget(wrap(sevenTvEmote()));
    await tester.pump();
    await tester.pump();

    expect(find.text('Cope'), findsOneWidget);
    expect(find.text('7TV Global Emote'), findsOneWidget);
    expect(find.text('Created by CopeQueen'), findsOneWidget);
    expect(find.textContaining('Alias of'), findsNothing);
  });

  testWidgets('shows "Alias of" row for 7TV alias emotes', (tester) async {
    await tester.pumpWidget(wrap(sevenTvEmote(baseName: 'BaseEmote')));
    await tester.pump();
    await tester.pump();

    expect(find.text('Alias of BaseEmote'), findsOneWidget);
  });

  testWidgets('type label appends Zero Width suffix', (tester) async {
    await tester.pumpWidget(wrap(sevenTvEmote(zeroWidth: true)));
    await tester.pump();
    await tester.pump();

    expect(find.text('7TV Global Emote (Zero Width)'), findsOneWidget);
  });

  testWidgets('Open emote link opens the provider URL', (tester) async {
    await tester.pumpWidget(wrap(sevenTvEmote()));
    await tester.pump();
    await tester.pump();

    await tester.tap(find.text('Open emote link'));
    await tester.pump();
    await tester.pump();

    expect(fakeLauncher.lastUrl, 'https://7tv.app/emotes/7tv-1');
    expect(fakeLauncher.lastMode, PreferredLaunchMode.externalApplication);
  });

  testWidgets('Open emote link shows a snackbar when launch fails', (
    tester,
  ) async {
    fakeLauncher.succeed = false;
    await tester.pumpWidget(wrap(sevenTvEmote()));
    await tester.pump();
    await tester.pump();

    await tester.tap(find.text('Open emote link'));
    await tester.pump();
    await tester.pump();

    expect(find.textContaining('Could not open'), findsOneWidget);
  });

  testWidgets('tapping the emote image opens the image URL', (tester) async {
    await tester.pumpWidget(wrap(sevenTvEmote()));
    await tester.pump();
    await tester.pump();

    await tester.tap(find.byType(CachedNetworkImage));
    await tester.pump();
    await tester.pump();

    expect(fakeLauncher.lastUrl, 'https://cdn.7tv.app/emote/1/1x.webp');
  });

  testWidgets('multi-emote sheet swipes sideways to the next emote', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrapMany(
        List.generate(
          2,
          (i) => GenericEmote(
            id: 'e$i',
            code: 'Emote$i',
            type: EmoteType.sevenTv,
            url: 'https://cdn.7tv.app/emote/e$i/1x.webp',
            baseName: i == 1 ? 'BaseEmote' : null,
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('Emote0'), findsWidgets);
    expect(find.text('Alias of BaseEmote'), findsNothing);

    await tester.drag(find.byType(TabBarView), const Offset(-300, 0));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();

    expect(find.text('Alias of BaseEmote'), findsOneWidget);
  });
}
