// ignore_for_file: deprecated_member_use

import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'providers/app_providers.dart';
import 'providers/feature_providers.dart';
import 'screens/home_screen.dart';
import 'services/twitch_auth.dart';
import 'eventsub/transport/connection.dart';
import 'irc/transport/read.dart';
import 'irc/transport/write.dart';
import 'services/recent_messages.dart';
import 'services/twitch_badge_service.dart';
import 'theme_colors.dart';
import 'util/log.dart';
import 'util/prefs.dart';
import 'util/crash_report.dart';
import 'widgets/app_snack.dart';
import 'widgets/tabbed_layout.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Edge-to-edge: draw behind the system bars and take manual ownership
  // of insets (bars via viewPadding, keyboard via viewInsets). The engine
  // flips the window flags; themes declare transparent bars + icon style.
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  // Surface framework and async errors in release instead of silently
  // dropping them; a backend can be plugged via [crashReporter]. Details the
  // framework flagged silent (expected, already handled) are skipped.
  FlutterError.onError = (details) {
    if (details.silent) return;
    reportError(details.exception, details.stack);
  };
  // Badges/avatars (CachedNetworkImage) use the library's default cache manager,
  // not EmoteCacheManager. EmoteCacheManager enforces a small, emote-only disk
  // cap and throws when full; routing badges through it made them vanish once
  // the emote cache filled (and permanently at cap 0). Emote images fetch via
  // EmoteCacheManager directly, so they are unaffected by this decoupling.

  if (Platform.isAndroid) {
    FlutterForegroundTask.initCommunicationPort();
  }
  unawaited(_warmHistory());
  runZonedGuarded(() => runApp(const TwitchChatApp()), reportError);
}

/// Pre-warms chat history during boot, concurrent with storage and first frame.
Future<void> _warmHistory() async {
  try {
    final prefs = await Prefs.load();
    final channels = prefs.channels;
    if (channels.isNotEmpty) {
      RecentMessagesService.warm(
        channels,
        limit: prefs.recentMessagesLimit,
        config: RecentMessagesConfig.fromPrefs(prefs),
      );
    }
  } catch (_) {
    // Prefs unavailable: HomeScreen fetches normally later.
  }
}

ThemeData buildLightTheme({Color seedColor = Colors.blue}) => ThemeData(
  colorScheme: ColorScheme.fromSeed(seedColor: seedColor),
  useMaterial3: true,
  sliderTheme: const SliderThemeData(year2023: false),
  snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
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
    sliderTheme: const SliderThemeData(year2023: false),
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
  );
}

Widget _edgeExclusionWrapper(BuildContext context, Widget? child) {
  final mq = MediaQuery.of(context);
  final left = mq.systemGestureInsets.left;
  final right = mq.systemGestureInsets.right;
  // Bar icon contrast follows the resolved theme; transparent bars let
  // content show through underneath. Rebuilt with the app on theme change.
  final dark = Theme.of(context).brightness == Brightness.dark;
  final overlay = SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    systemNavigationBarColor: Colors.transparent,
    statusBarIconBrightness: dark ? Brightness.light : Brightness.dark,
    statusBarBrightness: dark ? Brightness.dark : Brightness.light,
    systemNavigationBarIconBrightness: dark
        ? Brightness.light
        : Brightness.dark,
  );
  return AnnotatedRegion<SystemUiOverlayStyle>(
    value: overlay,
    child: Stack(
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
    ),
  );
}

class TwitchChatApp extends StatefulWidget {
  final EventSubService? eventSubService;
  final IrcService? ircService;
  final IrcReadService? ircReadService;
  final RecentMessagesService? recentMessagesService;
  final TwitchBadgeService? badgeService;
  final String? initialCurrentUserLogin;

  const TwitchChatApp({
    super.key,
    this.eventSubService,
    this.ircService,
    this.ircReadService,
    this.recentMessagesService,
    this.badgeService,
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
  final _snackPopObserver = SnackPopObserver();

  @override
  void initState() {
    super.initState();
    _loadPreferences();
  }

  Future<void> _loadPreferences() async {
    try {
      final prefs = await Prefs.load();
      _themeMode = prefs.themeMode;
      _keepScreenOn = prefs.keepScreenOn;
      WakelockPlus.toggle(enable: _keepScreenOn).ignore();
      _trueDark = prefs.trueDark;
      _accentKey = prefs.accentColor;
    } catch (e) {
      logDebug('Failed to load preferences: $e');
    }
    try {
      await _twitchAuth.load();
    } catch (e) {
      // Fall back to anonymous so storage failure doesn't block startup.
      logDebug('Failed to load accounts: $e');
    }
    if (mounted) setState(() => _loaded = true);
  }

  void _setThemeMode(ThemeMode mode) {
    setState(() => _themeMode = mode);
    Prefs.load().then((prefs) => prefs.setThemeMode(mode));
  }

  void _setKeepScreenOn(bool value) {
    setState(() => _keepScreenOn = value);
    WakelockPlus.toggle(enable: value).ignore();
    Prefs.load().then((prefs) => prefs.setKeepScreenOn(value));
  }

  void _setTrueDark(bool value) {
    setState(() => _trueDark = value);
    Prefs.load().then((prefs) => prefs.setTrueDark(value));
  }

  void _setAccentColor(String key) {
    setState(() => _accentKey = key);
    Prefs.load().then((prefs) => prefs.setAccentColor(key));
  }

  /// Test seams: a non-null widget field swaps the matching provider for the
  /// supplied fake so widget tests wire the app without real sockets.
  List<Override> get _providerOverrides => [
    twitchAuthProvider.overrideWithValue(_twitchAuth),
    if (widget.eventSubService != null)
      eventSubServiceProvider.overrideWithValue(widget.eventSubService!),
    if (widget.ircService != null)
      ircServiceProvider.overrideWithValue(widget.ircService!),
    if (widget.ircReadService != null)
      ircReadServiceProvider.overrideWithValue(widget.ircReadService!),
    if (widget.recentMessagesService != null)
      recentMessagesServiceProvider.overrideWithValue(
        widget.recentMessagesService!,
      ),
    if (widget.badgeService != null)
      badgeServiceProvider.overrideWithValue(widget.badgeService!),
  ];

  @override
  Widget build(BuildContext context) {
    if (!_loaded) {
      return ProviderScope(
        overrides: _providerOverrides,
        child: MaterialApp(
          themeMode: _themeMode,
          theme: buildLightTheme(seedColor: _seedColor),
          darkTheme: buildDarkTheme(trueDark: _trueDark, seedColor: _seedColor),
          builder: _edgeExclusionWrapper,
          scaffoldMessengerKey: rootScaffoldMessengerKey,
          navigatorObservers: [_snackPopObserver],
          home: const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          ),
        ),
      );
    }

    return ProviderScope(
      overrides: _providerOverrides,
      child: MaterialApp(
        title: 'ErmChat',
        themeMode: _themeMode,
        theme: buildLightTheme(seedColor: _seedColor),
        darkTheme: buildDarkTheme(trueDark: _trueDark, seedColor: _seedColor),
        builder: _edgeExclusionWrapper,
        scaffoldMessengerKey: rootScaffoldMessengerKey,
        navigatorObservers: [_snackPopObserver],
        home: HomeScreen(
          onThemeChanged: _setThemeMode,
          onKeepScreenOnChanged: _setKeepScreenOn,
          onTrueDarkChanged: _setTrueDark,
          onAccentColorChanged: _setAccentColor,
          initialCurrentUserLogin: widget.initialCurrentUserLogin,
        ),
      ),
    );
  }
}
