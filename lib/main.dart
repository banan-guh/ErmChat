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
import 'services/recent_messages.dart';
import 'theme_colors.dart';
import 'util/log.dart';
import 'widgets/tabbed_layout.dart';

void main() async {
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
  sliderTheme: const SliderThemeData(
    year2023: false,
  ), // ignore: deprecated_member_use
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
    sliderTheme: const SliderThemeData(
      year2023: false,
    ), // ignore: deprecated_member_use
  );
}

Widget _edgeExclusionWrapper(BuildContext context, Widget? child) {
  final mq = MediaQuery.of(context);
  final left = mq.systemGestureInsets.left;
  final right = mq.systemGestureInsets.right;
  return Stack(
    children: [
      child!,
      if (left > 0)
        Positioned(
          left: 0,
          top: 0,
          bottom: 0,
          width: left,
          child: const EdgeExclusionZone(),
        ),
      if (right > 0)
        Positioned(
          right: 0,
          top: 0,
          bottom: 0,
          width: right,
          child: const EdgeExclusionZone(),
        ),
    ],
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
    } catch (e) {
      logDebug('Failed to load preferences: $e');
    }
    try {
      await _twitchAuth.load();
    } catch (e) {
      // A secure-storage failure must not hang the app on the loading
      // spinner forever; fall back to anonymous.
      logDebug('Failed to load accounts: $e');
    }
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

  @override
  Widget build(BuildContext context) {
    if (!_loaded) {
      return MaterialApp(
        themeMode: _themeMode,
        theme: buildLightTheme(seedColor: _seedColor),
        darkTheme: buildDarkTheme(trueDark: _trueDark, seedColor: _seedColor),
        builder: _edgeExclusionWrapper,
        home: const Scaffold(body: Center(child: CircularProgressIndicator())),
      );
    }

    return MaterialApp(
      title: 'ErmChat',
      themeMode: _themeMode,
      theme: buildLightTheme(seedColor: _seedColor),
      darkTheme: buildDarkTheme(trueDark: _trueDark, seedColor: _seedColor),
      builder: _edgeExclusionWrapper,
      home: HomeScreen(
        twitchAuth: _twitchAuth,
        onThemeChanged: _setThemeMode,
        onKeepScreenOnChanged: _setKeepScreenOn,
        onTrueDarkChanged: _setTrueDark,
        onAccentColorChanged: _setAccentColor,
        eventSubService: widget.eventSubService,
        ircService: widget.ircService,
        ircReadService: widget.ircReadService,
        recentMessagesService: widget.recentMessagesService,
        initialCurrentUserLogin: widget.initialCurrentUserLogin,
      ),
    );
  }
}
