import 'package:ermchat/services/twitch_oauth.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('TwitchOAuth.parseFragment', () {
    test('extracts access_token and state from fragment (implicit grant)', () {
      final url =
          'https://example.com/twitch-callback'
          '#access_token=testtoken123'
          '&state=abc123';
      final params = TwitchOAuth.parseFragment(url);
      expect(params['access_token'], 'testtoken123');
      expect(params['state'], 'abc123');
    });

    test('extracts token and state from fragment with extra params', () {
      final url =
          'https://example.com/twitch-callback'
          '#access_token=token1'
          '&scope=chat%3Aread+chat%3Aedit'
          '&state=xyz'
          '&token_type=bearer';
      final params = TwitchOAuth.parseFragment(url);
      expect(params['access_token'], 'token1');
      expect(params['state'], 'xyz');
      expect(params['token_type'], 'bearer');
    });

    test('extracts error from fragment', () {
      final url =
          'https://example.com/twitch-callback'
          '#error=access_denied&error_description=User+denied+access';
      final params = TwitchOAuth.parseFragment(url);
      expect(params['error'], 'access_denied');
      expect(params['error_description'], 'User denied access');
    });

    test('returns empty map for URL without fragment', () {
      final url = 'https://example.com/twitch-callback';
      final params = TwitchOAuth.parseFragment(url);
      expect(params, isEmpty);
    });

    test('returns empty map for URL with empty fragment', () {
      final url = 'https://example.com/twitch-callback#';
      final params = TwitchOAuth.parseFragment(url);
      expect(params, isEmpty);
    });

    test('returns empty map when no auth-related params present', () {
      final url = 'https://example.com/twitch-callback#foo=bar';
      final params = TwitchOAuth.parseFragment(url);
      expect(params['access_token'], isNull);
      expect(params['state'], isNull);
      expect(params['error'], isNull);
      expect(params['foo'], 'bar');
    });

    test('handles URL with query params and fragment', () {
      final url =
          'https://example.com/twitch-callback'
          '?some=query'
          '#access_token=token123&state=abc';
      final params = TwitchOAuth.parseFragment(url);
      // parseFragment only looks at the fragment, not query params
      expect(params['access_token'], 'token123');
      expect(params['state'], 'abc');
    });

    test('extracts token from complex redirect URL', () {
      final url =
          'https://example.com/twitch-callback'
          '#access_token=abc123def456'
          '&scope=chat%3Aread+chat%3Aedit'
          '&state=csrf_token_here'
          '&token_type=bearer';
      final params = TwitchOAuth.parseFragment(url);
      expect(params['access_token'], 'abc123def456');
      expect(params['scope'], 'chat:read chat:edit');
      expect(params['state'], 'csrf_token_here');
      expect(params['token_type'], 'bearer');
    });
  });

  group('TwitchOAuth.generateAuthUrl', () {
    test('requests blocked_users scopes for the block feature', () {
      final urlInfo = TwitchOAuth.generateAuthUrl();
      expect(urlInfo, isNotNull);

      final url = Uri.parse(urlInfo!.url);
      final scopes = url.queryParameters['scope']!.split(' ');
      expect(
        scopes,
        containsAll(['user:manage:blocked_users', 'user:read:blocked_users']),
      );
    });

    test('requests core chat scopes', () {
      final urlInfo = TwitchOAuth.generateAuthUrl();
      expect(urlInfo, isNotNull);

      final url = Uri.parse(urlInfo!.url);
      final scopes = url.queryParameters['scope']!.split(' ');
      expect(
        scopes,
        containsAll([
          'chat:read',
          'chat:edit',
          'user:write:chat',
          'user:manage:chat_color',
          'moderator:manage:banned_users',
          'moderator:manage:chat_messages',
          'moderator:manage:announcements',
          'moderator:manage:shoutouts',
          'user:read:emotes',
        ]),
      );
    });

    test('requests channel.moderate scopes for the moderation feed', () {
      final urlInfo = TwitchOAuth.generateAuthUrl();
      expect(urlInfo, isNotNull);

      final url = Uri.parse(urlInfo!.url);
      final scopes = url.queryParameters['scope']!.split(' ');
      expect(
        scopes,
        containsAll([
          'moderator:read:blocked_terms',
          'moderator:read:chat_settings',
          'moderator:read:unban_requests',
          'moderator:read:warnings',
          'moderator:read:moderators',
          'moderator:read:vips',
        ]),
      );
    });

    test('does not request EventSub-only scopes', () {
      final urlInfo = TwitchOAuth.generateAuthUrl();
      expect(urlInfo, isNotNull);

      final url = Uri.parse(urlInfo!.url);
      final scopes = url.queryParameters['scope']!.split(' ');
      expect(scopes, isNot(contains('user:read:chat')));
      expect(scopes, isNot(contains('channel:moderate')));
    });
  });
}
