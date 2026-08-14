import 'dart:ui' as ui;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../../widgets/emote_image.dart';
import '../../widgets/welcome_dialog.dart';

class DevSettingsScreen extends StatefulWidget {
  const DevSettingsScreen({super.key});

  @override
  State<DevSettingsScreen> createState() => _DevSettingsScreenState();
}

class _DevSettingsScreenState extends State<DevSettingsScreen> {
  bool _testWidgets = false;
  bool _forceEngineCodec = false;

  @override
  void initState() {
    super.initState();
    _loadTestWidgetsPref();
    _loadEngineCodecPref();
  }

  Future<void> _loadTestWidgetsPref() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() => _testWidgets = prefs.getBool('test_chat_widgets') ?? false);
  }

  Future<void> _setTestWidgets(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('test_chat_widgets', value);
    if (mounted) setState(() => _testWidgets = value);
  }

  Future<void> _loadEngineCodecPref() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() => _forceEngineCodec = prefs.getBool('force_engine_codec') ?? false);
    useEngineCodecForAnimated = _forceEngineCodec;
  }

  Future<void> _setForceEngineCodec(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('force_engine_codec', value);
    if (mounted) setState(() => _forceEngineCodec = value);
    useEngineCodecForAnimated = value;
  }

  Future<void> _replayWelcomeScreen(BuildContext context) async {
    if (kIsWeb) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('welcome_seen', false);
    if (!context.mounted) return;
    showWelcomeDialog(context);
  }

  Future<void> _runDecodeBenchmark(BuildContext context) async {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Running decode benchmark...')),
    );

    final results = <String>[];
    void log(String s) {
      results.add(s);
      debugPrint('[BENCH] $s');
    }

    Future<void> runTest(String name, Uint8List bytes) async {
      log('\n=== $name (${bytes.length} bytes) ===');

      // Production pipeline (what the app actually uses)
      final swProd = Stopwatch()..start();
      final frames = await decodeEmoteBytes(bytes);
      swProd.stop();
      log(
        'Production decodeEmoteBytes: ${swProd.elapsedMilliseconds}ms '
        '(${frames.frames.length} frames, ${frames.totalDuration.inMilliseconds}ms total)',
      );

      // Engine codec (for comparison - only used for static images in production)
      final swEngine = Stopwatch()..start();
      try {
        final codec = await ui.instantiateImageCodec(bytes);
        for (var i = 0; i < codec.frameCount; i++) {
          await codec.getNextFrame();
        }
        swEngine.stop();
        log(
          'Engine instantiateImageCodec: ${swEngine.elapsedMilliseconds}ms '
          '(${codec.frameCount} frames)',
        );
      } catch (e) {
        swEngine.stop();
        log('Engine codec failed: $e');
      }
    }

    // Test 1: Local boink fixture
    try {
      final assetData = await rootBundle.load(
        'test/fixtures/7tv_boink_2x.webp',
      );
      await runTest(
        'Local boink (190x64, animated WebP)',
        assetData.buffer.asUint8List(),
      );
    } catch (e) {
      log('Local boink test failed: $e');
    }

    // Test 2: Local kiss fixture
    try {
      final assetData = await rootBundle.load('test/fixtures/7tv_kiss_2x.webp');
      await runTest(
        'Local kiss (64x64, animated WebP)',
        assetData.buffer.asUint8List(),
      );
    } catch (e) {
      log('Local kiss test failed: $e');
    }

    // Test 3: Fetch a real 7TV emote
    try {
      const url =
          'https://cdn.7tv.app/emote/01JN98CJKDXP87J3QSW4M3CDXF/2x.webp';
      final resp = await http.get(Uri.parse(url));
      await runTest('Remote 7TV emote (2x)', resp.bodyBytes);
    } catch (e) {
      log('Remote test failed: $e');
    }

    if (!context.mounted) return;
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Decode Benchmark Results'),
        content: SingleChildScrollView(
          child: SelectableText(
            results.join('\n'),
            style: const TextStyle(fontFamily: 'monospace'),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Dev settings')),
      body: ListView(
        children: [
          SwitchListTile(
            secondary: const Icon(Icons.bug_report_outlined),
            title: const Text('Test chat widgets'),
            subtitle: const Text(
              'Show poll, prediction and hype train cards with updating fake data',
            ),
            value: _testWidgets,
            onChanged: _setTestWidgets,
          ),
          const Divider(),
          SwitchListTile(
            secondary: const Icon(Icons.layers_outlined),
            title: const Text('Force engine codec for animated emotes'),
            subtitle: const Text(
              'Use Flutter instantiateImageCodec for WebP/GIF (has transparency bugs)',
            ),
            value: _forceEngineCodec,
            onChanged: _setForceEngineCodec,
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.replay),
            title: const Text('Replay welcome screen'),
            subtitle: const Text('Show the first-launch popup again'),
            onTap: () => _replayWelcomeScreen(context),
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.speed),
            title: const Text('Run WebP decode benchmark'),
            subtitle: const Text(
              'Compares pure-Dart vs engine codec on real emotes',
            ),
            onTap: () => _runDecodeBenchmark(context),
          ),
        ],
      ),
    );
  }
}
