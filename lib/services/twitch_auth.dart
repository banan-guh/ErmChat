import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import '../twitch_config.dart';

class TwitchAuth extends ChangeNotifier {
  String? accessToken;
  String? refreshToken;
  String? login;
  String? userId;
  final FlutterSecureStorage _storage;

  TwitchAuth({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  bool get isConfigured => TwitchConfig.isConfigured && accessToken != null;

  bool get hasStoredTokens => accessToken != null && refreshToken != null;

  Future<void> load() async {
    accessToken = await _storage.read(key: 'access_token');
    if (accessToken?.isEmpty ?? false) accessToken = null;
    refreshToken = await _storage.read(key: 'refresh_token');
    if (refreshToken?.isEmpty ?? false) refreshToken = null;
    login = await _storage.read(key: 'user_login');
    if (login?.isEmpty ?? false) login = null;
    userId = await _storage.read(key: 'user_id');
    if (userId?.isEmpty ?? false) userId = null;
  }

  Future<void> _save() async {
    await _storage.write(key: 'access_token', value: accessToken ?? '');
    await _storage.write(key: 'refresh_token', value: refreshToken ?? '');
  }

  Future<void> _saveUser() async {
    await _storage.write(key: 'user_login', value: login ?? '');
    await _storage.write(key: 'user_id', value: userId ?? '');
  }

  void setCredentials({required String accessToken, String? refreshToken}) {
    this.accessToken = accessToken;
    this.refreshToken = refreshToken;
    // A new credential pair may belong to a different account — drop the
    // cached user until the account is resolved again.
    login = null;
    userId = null;
    _save();
    _saveUser();
    notifyListeners();
  }

  void setUser(String? login, String? userId) {
    this.login = login;
    this.userId = userId;
    _saveUser();
  }

  Future<void> clear() async {
    accessToken = null;
    refreshToken = null;
    login = null;
    userId = null;
    await _storage.delete(key: 'access_token');
    await _storage.delete(key: 'refresh_token');
    await _storage.delete(key: 'user_login');
    await _storage.delete(key: 'user_id');
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
      debugPrint('[TwitchAuth] failed to refresh token');
      return false;
    }
  }
}
