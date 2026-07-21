import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'screens/home_screen.dart';
import 'services/twitch_auth.dart';
import 'services/twitch_eventsub.dart';
import 'services/twitch_irc.dart';
import 'services/twitch_irc_read.dart';
import 'services/recent_messages.dart';
import 'services/seven_tv_event_client.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  FlutterForegroundTask.initCommunicationPort();
  runApp(const TwitchChatApp());
}

class TwitchChatApp extends StatefulWidget {
  final EventSubService? eventSubService;
  final IrcService? ircService;
  final IrcReadService? ircReadService;
  final RecentMessagesService? recentMessagesService;
  final SevenTvEventClient? sevenTvEventClient;
  final String? initialCurrentUserLogin;

  const TwitchChatApp({
    super.key,
    this.eventSubService,
    this.ircService,
    this.ircReadService,
    this.recentMessagesService,
    this.sevenTvEventClient,
    this.initialCurrentUserLogin,
  });

  @override
  State<TwitchChatApp> createState() => _TwitchChatAppState();
}

class _TwitchChatAppState extends State<TwitchChatApp> {
  ThemeMode _themeMode = ThemeMode.system;
  final _twitchAuth = TwitchAuth();
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _twitchAuth
        .load()
        .then((_) {
          if (mounted) setState(() => _loaded = true);
        })
        .catchError((_) {
          if (mounted) setState(() => _loaded = true);
        });
  }

  void _setThemeMode(ThemeMode mode) {
    setState(() => _themeMode = mode);
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) {
      return MaterialApp(
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
          useMaterial3: true,
        ),
        home: const Scaffold(body: Center(child: CircularProgressIndicator())),
      );
    }

    return MaterialApp(
      title: 'Twitch Chat',
      themeMode: _themeMode,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.deepPurple,
          brightness: Brightness.dark,
          surface: Colors.black,
        ),
        useMaterial3: true,
      ),
      home: HomeScreen(
        twitchAuth: _twitchAuth,
        onThemeChanged: _setThemeMode,
        eventSubService: widget.eventSubService,
        ircService: widget.ircService,
        ircReadService: widget.ircReadService,
        recentMessagesService: widget.recentMessagesService,
        sevenTvEventClient: widget.sevenTvEventClient,
        initialCurrentUserLogin: widget.initialCurrentUserLogin,
      ),
    );
  }
}
