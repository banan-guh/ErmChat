import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import '../twitch_config.dart';

class TwitchAuth extends ChangeNotifier {
  String? accessToken;
  String? refreshToken;
  SharedPreferences? _prefs;

  Future<SharedPreferences> _getPrefs() async {
    _prefs ??= await SharedPreferences.getInstance();
    return _prefs!;
  }

  bool get isConfigured => TwitchConfig.isConfigured && accessToken != null;

  bool get hasStoredTokens => accessToken != null && refreshToken != null;

  Future<void> load() async {
    final prefs = await _getPrefs();
    final at = prefs.getString('access_token');
    final rt = prefs.getString('refresh_token');
    if (at != null && at.isNotEmpty) accessToken = at;
    if (rt != null && rt.isNotEmpty) refreshToken = rt;
  }

  Future<void> _save() async {
    final prefs = await _getPrefs();
    await prefs.setString('access_token', accessToken ?? '');
    await prefs.setString('refresh_token', refreshToken ?? '');
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
    final prefs = await _getPrefs();
    await prefs.remove('access_token');
    await prefs.remove('refresh_token');
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
