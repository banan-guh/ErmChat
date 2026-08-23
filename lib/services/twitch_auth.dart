import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../twitch_config.dart';

/// A saved Twitch account: its login identity plus OAuth credentials.
/// [userId] stays null until the Helix user lookup resolves (the first lookup
/// is cached so cold starts skip it). [profileImageUrl] is saved from the same
/// lookup and powers the avatar in the account switcher.
class TwitchAccount {
  final String login;
  final String? userId;
  final String accessToken;
  final String? refreshToken;
  final String? profileImageUrl;
  final bool expired;

  const TwitchAccount({
    required this.login,
    this.userId,
    required this.accessToken,
    this.refreshToken,
    this.profileImageUrl,
    this.expired = false,
  });

  Map<String, dynamic> toJson() => {
    'login': login,
    if (userId != null) 'user_id': userId,
    'access_token': accessToken,
    if (refreshToken != null) 'refresh_token': refreshToken,
    if (profileImageUrl != null) 'profile_image_url': profileImageUrl,
    if (expired) 'expired': true,
  };

  factory TwitchAccount.fromJson(Map<String, dynamic> json) => TwitchAccount(
    login: json['login'] as String? ?? '',
    userId: json['user_id'] as String?,
    accessToken: json['access_token'] as String? ?? '',
    refreshToken: json['refresh_token'] as String?,
    profileImageUrl: json['profile_image_url'] as String?,
    expired: json['expired'] == true,
  );
}

class TwitchAuth extends ChangeNotifier {
  static const _kAccounts = 'accounts';
  static const _kActiveLogin = 'active_login';
  static const _kPendingToken = 'pending_token';
  static const _kPendingRefresh = 'pending_refresh_token';
  // Legacy single-account keys (pre multi-account), migrated on load.
  static const _kLegacyToken = 'access_token';
  static const _kLegacyRefresh = 'refresh_token';
  static const _kLegacyLogin = 'user_login';
  static const _kLegacyUserId = 'user_id';

  /// Credentials of the currently active account. `login`/`userId` stay null
  /// while a freshly OAuth'd credential is still being resolved.
  String? accessToken;
  String? refreshToken;
  String? login;
  String? userId;
  String? profileImageUrl;
  bool _activeExpired = false;

  /// Whether the active account's token has been confirmed dead (401 from
  /// validate or IRC login-failure NOTICE). True until [setCredentials] or
  /// [setUser] replaces the credentials.
  bool get isActiveExpired => _activeExpired;

  /// All saved accounts. The active one is what [accessToken]/[login] expose.
  List<TwitchAccount> accounts = [];

  final FlutterSecureStorage _storage;
  // Serializes every storage access so queued fire-and-forget writes can't
  // race later reads (e.g. a pending-token write vs its delete).
  Future<void> _storageQueue = Future<void>.value();

  TwitchAuth({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  bool get isConfigured => TwitchConfig.isConfigured && accessToken != null;

  TwitchAccount? get activeAccount {
    final active = login;
    if (active == null) return null;
    return _byLogin(active);
  }

  Future<T> _enqueue<T>(Future<T> Function() op) {
    final result = _storageQueue.then((_) => op());
    _storageQueue = result.then((_) {}, onError: (_) {});
    return result;
  }

  Future<String?> _readKey(String key) =>
      _enqueue(() => _storage.read(key: key));

  Future<void> _writeKey(String key, String value) =>
      _enqueue(() => _storage.write(key: key, value: value));

  Future<void> _deleteKey(String key) =>
      _enqueue(() => _storage.delete(key: key));

  TwitchAccount? _byLogin(String login) {
    final needle = login.toLowerCase();
    for (final account in accounts) {
      if (account.login.toLowerCase() == needle) return account;
    }
    return null;
  }

  List<TwitchAccount> _decodeAccounts(String? raw) {
    if (raw == null || raw.isEmpty) return [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return [];
      return [
        for (final entry in decoded)
          if (entry is Map<String, dynamic>) TwitchAccount.fromJson(entry),
      ];
    } catch (_) {
      return [];
    }
  }

  Future<void> _saveAccounts() {
    return _writeKey(
      _kAccounts,
      jsonEncode([for (final account in accounts) account.toJson()]),
    );
  }

  void _applyAccount(TwitchAccount account) {
    accessToken = account.accessToken;
    refreshToken = account.refreshToken;
    login = account.login;
    userId = account.userId;
    profileImageUrl = account.profileImageUrl;
    _activeExpired = account.expired;
  }

  Future<void> load() async {
    accounts = _decodeAccounts(await _readKey(_kAccounts));

    // Migrate the legacy single-account keys into the registry.
    if (accounts.isEmpty) {
      final legacyToken = await _readKey(_kLegacyToken);
      if (legacyToken != null && legacyToken.isNotEmpty) {
        final legacyLogin = await _readKey(_kLegacyLogin);
        if (legacyLogin != null && legacyLogin.isNotEmpty) {
          final legacyRefresh = await _readKey(_kLegacyRefresh);
          final legacyUserId = await _readKey(_kLegacyUserId);
          accounts = [
            TwitchAccount(
              login: legacyLogin,
              userId: (legacyUserId == null || legacyUserId.isEmpty)
                  ? null
                  : legacyUserId,
              accessToken: legacyToken,
              refreshToken: (legacyRefresh == null || legacyRefresh.isEmpty)
                  ? null
                  : legacyRefresh,
            ),
          ];
          await _saveAccounts();
        } else {
          // A token whose user was never resolved: keep it pending.
          final legacyRefresh = await _readKey(_kLegacyRefresh);
          accessToken = legacyToken;
          refreshToken = (legacyRefresh == null || legacyRefresh.isEmpty)
              ? null
              : legacyRefresh;
          login = null;
          userId = null;
          await _writeKey(_kPendingToken, accessToken!);
          await _writeKey(_kPendingRefresh, refreshToken ?? '');
        }
        await _deleteKey(_kLegacyToken);
        await _deleteKey(_kLegacyRefresh);
        await _deleteKey(_kLegacyLogin);
        await _deleteKey(_kLegacyUserId);
      }
    }

    if (accounts.isNotEmpty) {
      final activeLogin = await _readKey(_kActiveLogin);
      var active = (activeLogin != null && activeLogin.isNotEmpty)
          ? _byLogin(activeLogin)
          : null;
      active ??= accounts.first;
      _applyAccount(active);
      return;
    }

    // No named account: apply a pending credential if one is waiting for its
    // user lookup.
    if (accessToken == null) {
      final pending = await _readKey(_kPendingToken);
      if (pending != null && pending.isNotEmpty) {
        accessToken = pending;
        final pendingRefresh = await _readKey(_kPendingRefresh);
        refreshToken = (pendingRefresh == null || pendingRefresh.isEmpty)
            ? null
            : pendingRefresh;
        login = null;
        userId = null;
      }
    }
  }

  void setCredentials({required String accessToken, String? refreshToken}) {
    this.accessToken = accessToken;
    this.refreshToken = refreshToken;
    // A new credential pair may belong to a different account - drop the
    // cached user until the account is resolved again.
    login = null;
    userId = null;
    profileImageUrl = null;
    _activeExpired = false;
    // Persist as pending until setUser resolves the account identity.
    _writeKey(_kPendingToken, accessToken);
    _writeKey(_kPendingRefresh, refreshToken ?? '');
    notifyListeners();
  }

  /// Attributes a Helix identity resolution to the active account.
  ///
  /// Pass [resolvedWithToken] as the access token the lookup was made with:
  /// if active credentials changed while the lookup was in flight (account
  /// switch), the result is stale for the new account and is ignored entirely.
  /// Without that guard, writing back would pair the old account's login with
  /// whichever token is active at resolution time and corrupt the registry.
  void setUser(
    String? login,
    String? userId, {
    String? profileImageUrl,
    String? resolvedWithToken,
  }) {
    if (resolvedWithToken != null && resolvedWithToken != accessToken) return;
    this.login = login;
    this.userId = userId;
    this.profileImageUrl = profileImageUrl;
    final token = accessToken;
    if (login == null || token == null) {
      notifyListeners();
      return;
    }
    final existing = _byLogin(login);
    final account = TwitchAccount(
      login: login,
      userId: userId,
      accessToken: token,
      refreshToken: refreshToken,
      profileImageUrl: profileImageUrl,
      expired: _activeExpired,
    );
    final changed =
        existing == null ||
        existing.userId != userId ||
        existing.accessToken != token ||
        existing.refreshToken != refreshToken ||
        existing.profileImageUrl != profileImageUrl ||
        existing.expired != _activeExpired;
    if (existing != null) {
      accounts[accounts.indexOf(existing)] = account;
    } else {
      accounts.add(account);
    }
    _deleteKey(_kPendingToken);
    _deleteKey(_kPendingRefresh);
    if (changed) {
      _saveAccounts();
      _writeKey(_kActiveLogin, login);
      notifyListeners();
    }
  }

  /// Marks the active account's token as expired (401 from validate or
  /// IRC login-failure NOTICE). The flag persists across the active account
  /// in the registry so the settings UI can display it, and is cleared by
  /// [setCredentials] / [setUser] when fresh credentials arrive.
  void markActiveExpired() {
    if (_activeExpired) return;
    _activeExpired = true;
    final current = login;
    if (current != null) {
      final idx = accounts.indexWhere(
        (a) => a.login.toLowerCase() == current.toLowerCase(),
      );
      if (idx >= 0) {
        final old = accounts[idx];
        accounts[idx] = TwitchAccount(
          login: old.login,
          userId: old.userId,
          accessToken: old.accessToken,
          refreshToken: old.refreshToken,
          profileImageUrl: old.profileImageUrl,
          expired: true,
        );
        _saveAccounts();
      }
    }
    notifyListeners();
  }

  Future<void> switchTo(String login) async {
    final account = _byLogin(login);
    if (account == null) return;
    _applyAccount(account);
    await _writeKey(_kActiveLogin, login);
    notifyListeners();
  }

  Future<void> removeAccount(String login) async {
    final wasActive = login.toLowerCase() == this.login?.toLowerCase();
    accounts.removeWhere(
      (account) => account.login.toLowerCase() == login.toLowerCase(),
    );
    if (accounts.isEmpty) {
      if (wasActive) {
        accessToken = null;
        refreshToken = null;
        this.login = null;
        userId = null;
        profileImageUrl = null;
      }
      await _writeKey(_kAccounts, '[]');
      await _deleteKey(_kActiveLogin);
      await _deleteKey(_kPendingToken);
      await _deleteKey(_kPendingRefresh);
    } else {
      if (wasActive) {
        // Fall back to the first remaining account.
        _applyAccount(accounts.first);
        await _writeKey(_kActiveLogin, accounts.first.login);
      }
      await _saveAccounts();
    }
    notifyListeners();
  }

  Future<void> clear() async {
    final current = login;
    if (current != null) {
      await removeAccount(current);
      return;
    }
    accessToken = null;
    refreshToken = null;
    login = null;
    userId = null;
    profileImageUrl = null;
    accounts = [];
    await _writeKey(_kAccounts, '[]');
    await _deleteKey(_kActiveLogin);
    await _deleteKey(_kPendingToken);
    await _deleteKey(_kPendingRefresh);
    notifyListeners();
  }
}
