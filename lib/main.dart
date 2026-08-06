import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'screens/home_screen.dart';
import 'services/twitch_auth.dart';
import 'services/twitch_eventsub.dart';
import 'services/twitch_irc.dart';
import 'services/twitch_irc_read.dart';
import 'services/recent_messages.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  if (Platform.isAndroid) {
    FlutterForegroundTask.initCommunicationPort();
  }
  runApp(const TwitchChatApp());
}

ThemeData buildLightTheme() => ThemeData(
  colorScheme:
      ColorScheme.fromSeed(
        seedColor: Colors.deepPurple,
        surface: const Color(0xFFF0F0F0),
      ).copyWith(
        onSurface: const Color(0xFF1A1A1A),
        onSurfaceVariant: const Color(0xFF3A3A3A),
        surfaceContainerLowest: const Color(0xFFFCFCFC),
        surfaceContainerLow: const Color(0xFFF2F3F5),
        surfaceContainer: const Color(0xFFEBEDEF),
        surfaceContainerHigh: const Color(0xFFE0E3E7),
        surfaceContainerHighest: const Color(0xFFCED1D6),
      ),
  useMaterial3: true,
);

ThemeData buildDarkTheme() => ThemeData(
  colorScheme: ColorScheme.fromSeed(
    seedColor: Colors.deepPurple,
    brightness: Brightness.dark,
    surface: Colors.black,
  ),
  useMaterial3: true,
);

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

  @override
  Widget build(BuildContext context) {
    if (!_loaded) {
      return MaterialApp(
        themeMode: _themeMode,
        theme: buildLightTheme(),
        darkTheme: buildDarkTheme(),
        home: const Scaffold(body: Center(child: CircularProgressIndicator())),
      );
    }

    return MaterialApp(
      title: 'ErmChat',
      themeMode: _themeMode,
      theme: buildLightTheme(),
      darkTheme: buildDarkTheme(),
      home: HomeScreen(
        twitchAuth: _twitchAuth,
        onThemeChanged: _setThemeMode,
        onKeepScreenOnChanged: _setKeepScreenOn,
        eventSubService: widget.eventSubService,
        ircService: widget.ircService,
        ircReadService: widget.ircReadService,
        recentMessagesService: widget.recentMessagesService,
        initialCurrentUserLogin: widget.initialCurrentUserLogin,
      ),
    );
  }
}
