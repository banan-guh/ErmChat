import 'dart:async';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../../util/log.dart';
import '../../util/webp_anim.dart';
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

    Future<void> runTest(String name, Uint8List bytes) async {
      log('\n=== $name (${bytes.length} bytes) ===');

      // Production pipeline (what the app actually uses - engine-first,
      // per-frame fallback on transparent-frame bug).
      final swProd = Stopwatch()..start();
      final frames = await decodeEmoteBytes(bytes);
      swProd.stop();
      final frameCount = frames.frames.length;
      final dims = frameCount > 0
          ? '${frames.frames.first.width}x${frames.frames.first.height}'
          : 'n/a';
      log(
        'Production decodeEmoteBytes: '
        '${swProd.elapsedMilliseconds}ms '
        '($frameCount frames, ${frames.totalDuration.inMilliseconds}ms total, $dims)',
      );
      if (frameCount == 0) {
        log('WARNING: production decode produced 0 frames - result is meaningless.');
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
            leading: const Icon(Icons.compare_arrows),
            title: const Text('Decode diagnosis (engine-only)'),
            subtitle: const Text(
              'Engine baseline vs engine+ANMF-durations vs engine '
              'per-frame composite. No libwebp. Use the two emote presets.',
            ),
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const _DecodeDiagScreen()),
              );
            },
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

class _DecodeDiagScreen extends StatefulWidget {
  const _DecodeDiagScreen();

  @override
  State<_DecodeDiagScreen> createState() => _DecodeDiagScreenState();
}

class _DecodeDiagScreenState extends State<_DecodeDiagScreen> {
  final _url = TextEditingController();
  bool _loading = false;
  String _log = '';
  List<ui.Image> _allFrames = [];
  _Variant? _baseline;
  _Variant? _anmfTiming;
  _Variant? _composite;

  @override
  void dispose() {
    _url.dispose();
    for (final f in _allFrames) {
      f.dispose();
    }
    super.dispose();
  }

  void _reset() {
    for (final f in _allFrames) {
      f.dispose();
    }
    _allFrames = [];
    _baseline = null;
    _anmfTiming = null;
    _composite = null;
  }

  Future<void> _run() async {
    _reset();
    setState(() => _loading = true);
    _Variant? base;
    _Variant? comp;
    WebpAnimInfo? meta;
    final sb = StringBuffer();
    try {
      final resp = await http.get(Uri.parse(_url.text.trim()));
      if (resp.statusCode != 200) throw StateError('HTTP ${resp.statusCode}');
      final bytes = resp.bodyBytes;
      meta = parseWebpAnim(bytes);
      sb.writeln(
        'ANMF frames: ${meta.frames.length}, canvas '
        '${meta.canvasW}x${meta.canvasH}, alpha=${meta.hasAlpha}',
      );

      // Variant 1: the current engine path (instantiateImageCodec + getNextFrame),
      // played at the engine's own reported durations. Reproduces both bugs.
      base = await _decodeBaseline(bytes, meta);
      sb.writeln(
        'Engine (engine durations): ${base.frames.length} frames, '
        'truncated=${base.truncated}, frozen=${base.frozen}'
        "${base.error != null ? '\n  ERROR: ${base.error}' : ''}",
      );
      sb.writeln(
        '  engine durations (first 5): '
        '${base.durations.take(5).map((d) => d.inMilliseconds).join(', ')}',
      );
      sb.writeln(
        '  ANMF   durations (first 5): '
        '${meta.frames.take(5).map((f) => f.durationMs).join(', ')}',
      );

      // Variant 3: engine per-frame still decode + spec compositing, at ANMF
      // durations. Tests whether an engine-only path (no libwebp) is viable.
      comp = await _decodeComposite(bytes, meta);
      sb.writeln(
        'Engine per-frame + composite: ${comp.frames.length} frames'
        "${comp.error != null ? '\n  ERROR: ${comp.error}' : ''}",
      );
    } catch (e) {
      sb.writeln('Top-level error: $e');
    }

    if (!mounted) return;
    setState(() {
      _baseline = base;
      // Same frames as baseline, but the correct ANMF durations. Isolates
      // whether Bug A is purely a duration-source problem.
      _anmfTiming = (base != null && meta != null)
          ? _Variant(
              label: 'Engine (ANMF durations)',
              frames: base.frames,
              durations: meta.frames
                  .map((f) => Duration(milliseconds: f.durationMs))
                  .toList(),
            )
          : null;
      _composite = comp;
      _log = sb.toString();
      _loading = false;
    });
  }

  Future<_Variant> _decodeBaseline(Uint8List bytes, WebpAnimInfo meta) async {
    ui.Codec? codec;
    final frames = <ui.Image>[];
    final durations = <Duration>[];
    String? error;
    var frozen = false;
    try {
      codec = await ui.instantiateImageCodec(bytes);
      for (var i = 0; i < codec.frameCount; i++) {
        final f =
            await codec.getNextFrame().timeout(const Duration(seconds: 3));
        frames.add(f.image);
        durations.add(f.duration);
      }
    } on TimeoutException {
      frozen = true;
      error = 'getNextFrame timed out (frozen) after ${frames.length} frames';
    } catch (e) {
      error = 'getNextFrame failed at frame ${frames.length}: $e';
    } finally {
      codec?.dispose();
    }
    final truncated = frames.length != meta.frames.length;
    _allFrames.addAll(frames);
    return _Variant(
      label: 'Engine (engine durations)',
      frames: frames,
      durations: durations,
      truncated: truncated,
      frozen: frozen,
      error: error,
    );
  }

  Future<_Variant> _decodeComposite(Uint8List bytes, WebpAnimInfo meta) async {
    final compositor = WebpEngineCompositor(meta.canvasW, meta.canvasH);
    final frames = <ui.Image>[];
    final durations = <Duration>[];
    String? error;
    try {
      for (var i = 0; i < meta.frames.length; i++) {
        final f = meta.frames[i];
        final standalone = buildStandaloneFrameWebp(f);
        final codec = await ui.instantiateImageCodec(standalone);
        final hi = await codec.getNextFrame();
        final prev = i > 0 ? meta.frames[i - 1] : null;
        final out = await compositor.composite(prev, f, hi.image);
        hi.image.dispose();
        codec.dispose();
        frames.add(out);
        durations.add(Duration(milliseconds: f.durationMs));
      }
    } catch (e) {
      error = 'per-frame composite failed at frame ${frames.length}: $e';
    }
    _allFrames.addAll(frames);
    return _Variant(
      label: 'Engine per-frame + composite',
      frames: frames,
      durations: durations,
      error: error,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Decode diagnosis (engine-only)')),
      body: ListView(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _url,
                    decoration: const InputDecoration(
                      hintText: 'emote webp url',
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: _loading ? null : _run,
                  child: _loading
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Run'),
                ),
              ],
            ),
          ),
          Wrap(
            spacing: 8,
            children: [
              TextButton(
                onPressed: () => _url.text =
                    'https://cdn.7tv.app/emote/01H5ECBJ080004C067KYDBPSQ2/2x.webp',
                child: const Text('too-slow emote'),
              ),
              TextButton(
                onPressed: () => _url.text =
                    'https://cdn.7tv.app/emote/01HE9BETT0000CZHS2ZR11A3ZN/2x.webp',
                child: const Text('freeze emote'),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: SelectableText(
              _log,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
          ),
          if (_baseline != null) _pane(_baseline!),
          if (_anmfTiming != null) _pane(_anmfTiming!),
          if (_composite != null) _pane(_composite!),
        ],
      ),
    );
  }

  Widget _pane(_Variant v) => Card(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(6),
              child: Text(
                v.label,
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
            if (v.error != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Text(
                  v.error!,
                  style: const TextStyle(
                    fontSize: 11,
                    color: Colors.red,
                  ),
                ),
              ),
            SizedBox(height: 160, child: _FramePlayer(v.frames, v.durations)),
          ],
        ),
      );
}

class _Variant {
  const _Variant({
    required this.label,
    required this.frames,
    required this.durations,
    this.truncated = false,
    this.frozen = false,
    this.error,
  });
  final String label;
  final List<ui.Image> frames;
  final List<Duration> durations;
  final bool truncated;
  final bool frozen;
  final String? error;
}

/// Frame-accurate player for a decoded [EmoteFrameData]-like bundle. The frames
/// are owned by the diagnosis screen (disposed there), so this widget never
/// disposes them - it only drives playback for visual comparison.
class _FramePlayer extends StatefulWidget {
  const _FramePlayer(this.frames, this.durations);
  final List<ui.Image> frames;
  final List<Duration> durations;

  @override
  State<_FramePlayer> createState() => _FramePlayerState();
}

class _FramePlayerState extends State<_FramePlayer> {
  int _i = 0;
  Timer? _t;

  @override
  void initState() {
    super.initState();
    _schedule();
  }

  void _schedule() {
    if (widget.frames.isEmpty) return;
    final d = widget.durations[_i];
    _t = Timer(
      d > Duration.zero ? d : const Duration(milliseconds: 40),
      () {
        if (!mounted) return;
        setState(() => _i = (_i + 1) % widget.frames.length);
        _schedule();
      },
    );
  }

  @override
  void dispose() {
    _t?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.frames.isEmpty) {
      return const Center(child: Text('no frames'));
    }
    return Stack(
      fit: StackFit.expand,
      children: [
        RawImage(image: widget.frames[_i], fit: BoxFit.contain),
        Positioned(
          left: 4,
          top: 4,
          child: Text(
            'f ${_i + 1}/${widget.frames.length}',
            style: const TextStyle(
              fontSize: 11,
              color: Colors.white,
              backgroundColor: Colors.black54,
            ),
          ),
        ),
      ],
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
