import 'dart:ui' as ui;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'package:shared_preferences/shared_preferences.dart';
import '../../widgets/welcome_dialog.dart';

class DevSettingsScreen extends StatefulWidget {
  const DevSettingsScreen({super.key});

  @override
  State<DevSettingsScreen> createState() => _DevSettingsScreenState();
}

class _DevSettingsScreenState extends State<DevSettingsScreen> {
  bool _testWidgets = false;

  @override
  void initState() {
    super.initState();
    _loadTestWidgetsPref();
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

    // Test 1: Local boink fixture (from assets)
    log('=== Local boink (220KB, 190x64, 252 frames) ===');
    try {
      final assetData = await rootBundle.load('test/fixtures/7tv_boink_2x.webp');
      final bytes = assetData.buffer.asUint8List();
      log('Loaded asset: ${bytes.length} bytes');
      
      // Pure Dart per-frame
      final swDart = Stopwatch()..start();
      final dec = img.WebPDecoder(bytes);
      dec.startDecode(bytes);
      for (var i = 0; i < dec.numFrames(); i++) {
        dec.decodeFrame(i);
      }
      swDart.stop();
      log('Pure-Dart decodeFrame x${dec.numFrames()}: ${swDart.elapsedMilliseconds}ms');
      
      // Engine codec
      final swEngine = Stopwatch()..start();
      final codec = await ui.instantiateImageCodec(bytes);
      for (var i = 0; i < codec.frameCount; i++) {
        await codec.getNextFrame();
      }
      swEngine.stop();
      log('Engine instantiateImageCodec x${codec.frameCount}: ${swEngine.elapsedMilliseconds}ms');
    } catch (e) {
      log('Local test failed: $e');
    }

    // Test 2: Local kiss fixture
    log('\n=== Local kiss (48KB, 64x64, 47 frames) ===');
    try {
      final assetData = await rootBundle.load('test/fixtures/7tv_kiss_2x.webp');
      final bytes = assetData.buffer.asUint8List();
      log('Loaded asset: ${bytes.length} bytes');
      
      final swDart = Stopwatch()..start();
      final dec = img.WebPDecoder(bytes);
      dec.startDecode(bytes);
      for (var i = 0; i < dec.numFrames(); i++) {
        dec.decodeFrame(i);
      }
      swDart.stop();
      log('Pure-Dart decodeFrame x${dec.numFrames()}: ${swDart.elapsedMilliseconds}ms');
      
      final swEngine = Stopwatch()..start();
      final codec = await ui.instantiateImageCodec(bytes);
      for (var i = 0; i < codec.frameCount; i++) {
        await codec.getNextFrame();
      }
      swEngine.stop();
      log('Engine instantiateImageCodec x${codec.frameCount}: ${swEngine.elapsedMilliseconds}ms');
    } catch (e) {
      log('Kiss test failed: $e');
    }

    // Test 3: Fetch a real 7TV emote
    log('\n=== Remote 7TV emote (2x) ===');
    try {
      const url = 'https://cdn.7tv.app/emote/01JN98CJKDXP87J3QSW4M3CDXF/2x.webp';
      final resp = await http.get(Uri.parse(url));
      final bytes = resp.bodyBytes;
      log('Downloaded ${bytes.length} bytes');
      
      // Pure Dart
      final swDart = Stopwatch()..start();
      final dec = img.WebPDecoder(bytes);
      dec.startDecode(bytes);
      for (var i = 0; i < dec.numFrames(); i++) {
        dec.decodeFrame(i);
      }
      swDart.stop();
      log('Pure-Dart decodeFrame x${dec.numFrames()}: ${swDart.elapsedMilliseconds}ms');
      
      // Engine
      final swEngine = Stopwatch()..start();
      final codec = await ui.instantiateImageCodec(bytes);
      for (var i = 0; i < codec.frameCount; i++) {
        await codec.getNextFrame();
      }
      swEngine.stop();
      log('Engine instantiateImageCodec x${codec.frameCount}: ${swEngine.elapsedMilliseconds}ms');
    } catch (e) {
      log('Remote test failed: $e');
    }

    if (!context.mounted) return;
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Decode Benchmark Results'),
        content: SingleChildScrollView(
          child: SelectableText(results.join('\n'), style: const TextStyle(fontFamily: 'monospace')),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('OK')),
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
            subtitle: const Text('Compares pure-Dart vs engine codec on real emotes'),
            onTap: () => _runDecodeBenchmark(context),
          ),
        ],
      ),
    );
  }
}
