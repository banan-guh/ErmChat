import 'dart:async';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../../util/log.dart';
import '../../services/emote_codec/native_emote_codec.dart';
import '../../widgets/emote_image.dart';
import '../../widgets/welcome_dialog.dart';

class DevSettingsScreen extends StatefulWidget {
  final ValueChanged<bool>? onTestWidgetsChanged;

  const DevSettingsScreen({super.key, this.onTestWidgetsChanged});

  @override
  State<DevSettingsScreen> createState() => _DevSettingsScreenState();
}

class _DevSettingsScreenState extends State<DevSettingsScreen> {
  bool _testWidgets = false;
  bool _useBrowserOAuth = false;

  @override
  void initState() {
    super.initState();
    _loadTestWidgetsPref();
    _loadOAuthMode();
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
    widget.onTestWidgetsChanged?.call(value);
  }

  Future<void> _loadOAuthMode() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(
      () => _useBrowserOAuth = prefs.getBool('use_browser_oauth') ?? false,
    );
  }

  Future<void> _setOAuthMode(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('use_browser_oauth', value);
    if (mounted) setState(() => _useBrowserOAuth = value);
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
      logDebug('[BENCH] $s');
    }

    log('native libwebp available: ${NativeEmoteCodec.isAvailable}');

    Future<void> runTest(String name, Uint8List bytes) async {
      log('\n=== $name (${bytes.length} bytes) ===');

      // decodeEmoteBytes falls back to pure-Dart *silently*, so probe the native
      // path directly and surface which one the production number came from.
      // Otherwise a slow "Production" result is indistinguishable from the
      // intended native path and the benchmark is misleading.
      String pathLabel;
      try {
        final probe = await NativeEmoteCodec.decodeWebp(bytes);
        if (probe != null) {
          pathLabel = 'native';
          for (final f in probe.frames) {
            f.dispose();
          }
        } else {
          pathLabel = 'pure-Dart (native unavailable)';
        }
      } catch (e) {
        pathLabel = 'pure-Dart (native threw)';
      }
      log('  decoder path: $pathLabel');

      // Production pipeline (what the app actually uses)
      final swProd = Stopwatch()..start();
      final frames = await decodeEmoteBytes(bytes);
      swProd.stop();
      final frameCount = frames.frames.length;
      final dims = frameCount > 0
          ? '${frames.frames.first.width}x${frames.frames.first.height}'
          : 'n/a';
      log(
        'Production decodeEmoteBytes [$pathLabel]: '
        '${swProd.elapsedMilliseconds}ms '
        '($frameCount frames, ${frames.totalDuration.inMilliseconds}ms total, $dims)',
      );
      if (frameCount == 0) {
        log('WARNING: production decode produced 0 frames — result is meaningless.');
      }
      // Frames are GPU-resident ui.Images. Dispose them so repeated runs don't
      // exhaust GPU memory and skew later timings (or fail outright).
      for (final f in frames.frames) {
        f.dispose();
      }

      // Engine codec (for comparison - only used for static images in production)
      final swEngine = Stopwatch()..start();
      ui.Codec? codec;
      try {
        codec = await ui.instantiateImageCodec(bytes);
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
      } finally {
        codec?.dispose();
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
            secondary: const Icon(Icons.language),
            title: const Text('Use browser for OAuth'),
            subtitle: const Text(
              'Opens Twitch login in external browser instead of in-app WebView',
            ),
            value: _useBrowserOAuth,
            onChanged: _setOAuthMode,
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
              'Compares production decoder (native/pure-Dart) vs engine codec',
            ),
            onTap: () => _runDecodeBenchmark(context),
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.receipt_long),
            title: const Text('Performance log'),
            subtitle: const Text(
              'Freeze diagnostics: lifecycle, truncation, sheet animations',
            ),
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const _PerfLogScreen()),
              );
            },
          ),
        ],
      ),
    );
  }
}

class _PerfLogScreen extends StatefulWidget {
  const _PerfLogScreen();

  @override
  State<_PerfLogScreen> createState() => _PerfLogScreenState();
}

class _PerfLogScreenState extends State<_PerfLogScreen> {
  List<String>? _previousSession;

  @override
  void initState() {
    super.initState();
    unawaited(_loadPreviousSession());
  }

  Future<void> _loadPreviousSession() async {
    final text = await PerfLog.I.readPreviousSession();
    if (!mounted) return;
    setState(() {
      _previousSession = text?.split('\n').where((l) => l.isNotEmpty).toList();
    });
  }

  void _copyAll() {
    final buffer = StringBuffer();
    if (_previousSession != null) {
      buffer
        ..writeln('=== previous session ===')
        ..writeAll(_previousSession!, '\n')
        ..writeln();
    }
    buffer
      ..writeln('=== current session ===')
      ..writeAll(PerfLog.I.entries(), '\n')
      ..writeln();
    Clipboard.setData(ClipboardData(text: buffer.toString()));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Copied ${PerfLog.I.entries().length} entries')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final current = PerfLog.I.entries().reversed.toList();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Performance log'),
        actions: [
          IconButton(
            icon: const Icon(Icons.copy),
            tooltip: 'Copy all',
            onPressed: _copyAll,
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Current session: ${current.length} entries',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
                if (_previousSession != null)
                  Text(
                    'Previous: ${_previousSession!.length} entries',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
              ],
            ),
          ),
          Expanded(
            child: ListView.builder(
              itemCount: current.length + (_previousSession?.length ?? 0),
              itemBuilder: (context, i) {
                final isPrev = i >= current.length;
                final line = isPrev
                    ? _previousSession![i - current.length]
                    : current[i];
                return Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 1,
                  ),
                  child: SelectableText(
                    line,
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 11,
                      color: isPrev
                          ? Theme.of(context).colorScheme.onSurfaceVariant
                          : null,
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
