import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import '../twitch_config.dart';

class TwitchAuth extends ChangeNotifier {
  String? accessToken;
  String? refreshToken;
  final FlutterSecureStorage _storage;

  TwitchAuth({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  bool get isConfigured => TwitchConfig.isConfigured && accessToken != null;

  bool get hasStoredTokens => accessToken != null && refreshToken != null;

  Future<void> load() async {
    accessToken = await _storage.read(key: 'access_token');
    refreshToken = await _storage.read(key: 'refresh_token');
  }

  Future<void> _save() async {
    await _storage.write(key: 'access_token', value: accessToken ?? '');
    await _storage.write(key: 'refresh_token', value: refreshToken ?? '');
  }

  void setCredentials({required String accessToken, String? refreshToken}) {
    this.accessToken = accessToken;
    this.refreshToken = refreshToken;
    _save();
    notifyListeners();
  }

  Future<void> clear() async {
    accessToken = null;
    refreshToken = null;
    await _storage.delete(key: 'access_token');
    await _storage.delete(key: 'refresh_token');
    notifyListeners();
  }

  Future<bool> refresh() async {
    if (!TwitchConfig.isConfigured || refreshToken == null) return false;
    try {
      final body = <String, String>{
        'grant_type': 'refresh_token',
        'refresh_token': refreshToken!,
        'client_id': TwitchConfig.clientId,
      };
      if (TwitchConfig.clientSecret.isNotEmpty) {
        body['client_secret'] = TwitchConfig.clientSecret;
      }
      final res = await http.post(
        Uri.parse('https://id.twitch.tv/oauth2/token'),
        body: body,
      );
      if (res.statusCode != 200) return false;
      final data = jsonDecode(res.body) as Map;
      accessToken = data['access_token'] as String;
      final newRt = data['refresh_token'] as String?;
      if (newRt != null && newRt.isNotEmpty) refreshToken = newRt;
      await _save();
      return true;
    } catch (_) {
      return false;
    }
  }
}
