import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
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
}
