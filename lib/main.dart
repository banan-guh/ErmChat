import 'dart:io';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'screens/home_screen.dart';
import 'services/emote_cache_manager.dart';
import 'services/twitch_auth.dart';
import 'services/twitch_eventsub.dart';
import 'services/twitch_irc.dart';
import 'services/twitch_irc_read.dart';
import 'services/recent_messages.dart';
import 'theme_colors.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  CachedNetworkImageProvider.defaultCacheManager = EmoteCacheManager();
  if (Platform.isAndroid) {
    FlutterForegroundTask.initCommunicationPort();
  }
  runApp(const TwitchChatApp());
}

ThemeData buildLightTheme({Color seedColor = Colors.blue}) => ThemeData(
  colorScheme: ColorScheme.fromSeed(seedColor: seedColor),
  useMaterial3: true,
);

ThemeData buildDarkTheme({
  bool trueDark = false,
  Color seedColor = Colors.blue,
}) {
  final base = ColorScheme.fromSeed(
    seedColor: seedColor,
    brightness: Brightness.dark,
  );
  return ThemeData(
    colorScheme: trueDark
        ? base.copyWith(surface: Colors.black, onSurface: Colors.white)
        : base,
    useMaterial3: true,
  );
}

class TwitchChatApp extends StatefulWidget {
  final EventSubService? eventSubService;
  final IrcService? ircService;
  final IrcReadService? ircReadService;
  final RecentMessagesService? recentMessagesService;
  final String? initialCurrentUserLogin;

  const TwitchChatApp({
    super.key,
    this.eventSubService,
    this.ircService,
    this.ircReadService,
    this.recentMessagesService,
    this.initialCurrentUserLogin,
  });

  @override
  State<TwitchChatApp> createState() => _TwitchChatAppState();
}

class _TwitchChatAppState extends State<TwitchChatApp> {
  ThemeMode _themeMode = ThemeMode.system;
  bool _keepScreenOn = true;
  bool _trueDark = false;
  String _accentKey = kDefaultAccent;
  bool _tintedTabBar = false;
  Color get _seedColor =>
      kAccentPresets[_accentKey] ?? kAccentPresets[kDefaultAccent]!;
  final _twitchAuth = TwitchAuth();
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _loadPreferences();
  }

  Future<void> _loadPreferences() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString('themeMode');
      if (saved != null) {
        _themeMode = ThemeMode.values.firstWhere(
          (e) => e.name == saved,
          orElse: () => ThemeMode.system,
        );
      }
      _keepScreenOn = prefs.getBool('keep_screen_on') ?? true;
      WakelockPlus.toggle(enable: _keepScreenOn).ignore();
      _trueDark = prefs.getBool('true_dark') ?? false;
      _accentKey = prefs.getString('accent_color') ?? kDefaultAccent;
      _tintedTabBar = prefs.getBool('tinted_tab_bar') ?? false;
    } catch (e) {
      debugPrint('Failed to load preferences: $e');
    }
    await _twitchAuth.load();
    if (mounted) setState(() => _loaded = true);
  }

  void _setThemeMode(ThemeMode mode) {
    setState(() => _themeMode = mode);
    SharedPreferences.getInstance().then((prefs) {
      prefs.setString('themeMode', mode.name);
    });
  }

  void _setKeepScreenOn(bool value) {
    setState(() => _keepScreenOn = value);
    WakelockPlus.toggle(enable: value).ignore();
    SharedPreferences.getInstance().then((prefs) {
      prefs.setBool('keep_screen_on', value);
    });
  }

  void _setTrueDark(bool value) {
    setState(() => _trueDark = value);
    SharedPreferences.getInstance().then((prefs) {
      prefs.setBool('true_dark', value);
    });
  }

  void _setAccentColor(String key) {
    setState(() => _accentKey = key);
    SharedPreferences.getInstance().then((prefs) {
      prefs.setString('accent_color', key);
    });
  }

  void _setTintedTabBar(bool value) {
    setState(() => _tintedTabBar = value);
    SharedPreferences.getInstance().then((prefs) {
      prefs.setBool('tinted_tab_bar', value);
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) {
      return MaterialApp(
        themeMode: _themeMode,
        theme: buildLightTheme(seedColor: _seedColor),
        darkTheme: buildDarkTheme(trueDark: _trueDark, seedColor: _seedColor),
        home: const Scaffold(body: Center(child: CircularProgressIndicator())),
      );
    }

    return MaterialApp(
      title: 'ErmChat',
      themeMode: _themeMode,
      theme: buildLightTheme(seedColor: _seedColor),
      darkTheme: buildDarkTheme(trueDark: _trueDark, seedColor: _seedColor),
      home: HomeScreen(
        twitchAuth: _twitchAuth,
        onThemeChanged: _setThemeMode,
        onKeepScreenOnChanged: _setKeepScreenOn,
        onTrueDarkChanged: _setTrueDark,
        onAccentColorChanged: _setAccentColor,
        onTintedTabBarChanged: _setTintedTabBar,
        tintedTabBar: _tintedTabBar,
        eventSubService: widget.eventSubService,
        ircService: widget.ircService,
        ircReadService: widget.ircReadService,
        recentMessagesService: widget.recentMessagesService,
        initialCurrentUserLogin: widget.initialCurrentUserLogin,
      ),
    );
  }
}
