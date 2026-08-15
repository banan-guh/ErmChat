import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ermchat/screens/settings/account_screen.dart';
import 'package:ermchat/services/twitch_auth.dart';

void main() {
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
  });

  Widget wrap(TwitchAuth auth) {
    return MaterialApp(home: AccountScreen(twitchAuth: auth));
  }

  TwitchAuth twoAccounts() {
    final auth = TwitchAuth();
    auth.setCredentials(accessToken: 'token_a');
    auth.setUser('alice', '111', profileImageUrl: 'https://example.com/a.png');
    auth.setCredentials(accessToken: 'token_b');
    auth.setUser('bob', '222');
    return auth;
  }

  testWidgets('lists saved accounts with the active one marked', (
    tester,
  ) async {
    final auth = twoAccounts();
    await tester.pumpWidget(wrap(auth));
    await tester.pump();

    expect(find.text('Accounts'), findsOneWidget);
    expect(find.text('alice'), findsOneWidget);
    expect(find.text('bob'), findsOneWidget);
    expect(find.text('Active'), findsOneWidget);
    expect(find.byIcon(Icons.check), findsOneWidget);
  });

  testWidgets('tapping an account switches the active account', (tester) async {
    final auth = twoAccounts();
    await tester.pumpWidget(wrap(auth));
    await tester.pump();
    expect(auth.login, 'bob');

    await tester.tap(find.text('alice'));
    await tester.pumpAndSettle();
    expect(auth.login, 'alice');
    expect(auth.accessToken, 'token_a');
  });

  testWidgets('avatar uses the saved profile image url', (tester) async {
    final auth = twoAccounts();
    await tester.pumpWidget(wrap(auth));
    await tester.pump();

    final avatars = tester.widgetList<CircleAvatar>(find.byType(CircleAvatar));
    final urls = avatars
        .map((a) => a.foregroundImage)
        .whereType<NetworkImage>()
        .map((n) => n.url)
        .toList();
    expect(urls, contains('https://example.com/a.png'));
  });

  testWidgets('long press asks for confirmation and removes the account', (
    tester,
  ) async {
    final auth = twoAccounts();
    await tester.pumpWidget(wrap(auth));
    await tester.pump();

    await tester.longPress(find.text('alice'));
    await tester.pumpAndSettle();
    expect(find.text('Remove account?'), findsOneWidget);
    expect(
      find.text('Are you sure you want to remove @alice?'),
      findsOneWidget,
    );

    await tester.tap(find.text('Remove'));
    await tester.pumpAndSettle();
    expect(auth.accounts.length, 1);
    expect(auth.accounts.single.login, 'bob');
    expect(find.text('alice'), findsNothing);
  });

  testWidgets('cancel keeps the account', (tester) async {
    final auth = twoAccounts();
    await tester.pumpWidget(wrap(auth));
    await tester.pump();

    await tester.longPress(find.text('alice'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(auth.accounts.length, 2);
    expect(find.text('alice'), findsOneWidget);
  });

  testWidgets('success state offers Add account and Disconnect', (
    tester,
  ) async {
    final auth = twoAccounts();
    await tester.pumpWidget(wrap(auth));
    await tester.pump();

    expect(find.text('Add account'), findsOneWidget);
    expect(find.text('Disconnect'), findsOneWidget);
  });

  testWidgets('removing the last account falls back to the login button', (
    tester,
  ) async {
    final auth = TwitchAuth();
    auth.setCredentials(accessToken: 'token_a');
    auth.setUser('alice', '111');
    await tester.pumpWidget(wrap(auth));
    await tester.pump();

    await tester.longPress(find.text('alice'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove'));
    await tester.pumpAndSettle();

    expect(auth.accounts, isEmpty);
    expect(find.text('Login'), findsOneWidget);
  });
}
