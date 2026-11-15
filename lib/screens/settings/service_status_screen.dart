import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../../l10n/l10n.dart';
import '../../providers/chat_pipeline.dart';
import '../../providers/feature_providers.dart';
import '../../services/chat_connection_manager.dart';
import '../../twitch_config.dart';
import 'settings_page.dart';

/// Live socket state plus reachability checks for the services chat depends
/// on. Server checks run when the screen opens and on demand, so no traffic
/// follows while it is closed.
class ServiceStatusScreen extends ConsumerStatefulWidget {
  const ServiceStatusScreen({super.key});

  @override
  ConsumerState<ServiceStatusScreen> createState() =>
      _ServiceStatusScreenState();
}

class _ServiceStatusScreenState extends ConsumerState<ServiceStatusScreen> {
  static const _probeTimeout = Duration(seconds: 5);
  static const _endpoints = <_Endpoint>[
    _Endpoint('Twitch', 'https://api.twitch.tv/helix/users', auth: true),
    _Endpoint('7TV', 'https://7tv.io/v3/emote-sets/global'),
    _Endpoint('BTTV', 'https://api.betterttv.net/3/cached/emotes/global'),
    _Endpoint('FFZ', 'https://api.frankerfacez.com/v1/set/global'),
    _Endpoint(
      'Recent messages',
      'https://recent-messages.robotty.de/api/v2/recent-messages/test',
    ),
  ];

  final _results = <String, _ProbeResult>{};
  Timer? _ticker;
  bool _probing = false;

  @override
  void initState() {
    super.initState();
    // Socket getters are plain reads, so poll them while the screen is open.
    _ticker = Timer.periodic(
      const Duration(seconds: 1),
      (_) => setState(() {}),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _probeAll();
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  Future<void> _probe(_Endpoint endpoint) async {
    Map<String, String>? headers;
    if (endpoint.auth) {
      final token = ref.read(twitchAuthProvider).accessToken;
      if (token == null) return;
      headers = {
        'Client-ID': TwitchConfig.clientId,
        'Authorization': 'Bearer $token',
      };
    }
    final client = http.Client();
    final watch = Stopwatch()..start();
    _ProbeResult result;
    try {
      final res = await client
          .get(Uri.parse(endpoint.url), headers: headers)
          .timeout(_probeTimeout);
      result = _ProbeResult(
        status: res.statusCode,
        ms: watch.elapsedMilliseconds,
      );
    } catch (_) {
      result = _ProbeResult(ms: watch.elapsedMilliseconds);
    } finally {
      client.close();
    }
    if (!mounted) return;
    setState(() => _results[endpoint.name] = result);
  }

  Future<void> _probeAll() async {
    if (_probing) return;
    final signedIn = ref.read(twitchAuthProvider).accessToken != null;
    setState(() => _probing = true);
    await Future.wait([
      for (final e in _endpoints)
        if (!e.auth || signedIn) _probe(e),
    ]);
    if (mounted) setState(() => _probing = false);
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(twitchAuthTickProvider);
    final signedIn = ref.read(twitchAuthProvider).accessToken != null;
    final manager = ref.watch(chatPipelineProvider);
    final services = manager.config.services;
    final l = context.l10n;
    final irc = services.irc;
    final read = services.ircRead;
    final eventSub = services.eventSub;
    final pubSub = services.pubSub;
    final sevenTv = services.sevenTvClient;

    return SettingsPage(
      title: Text(l.serviceStatus),
      actions: [
        IconButton(
          icon: _probing
              ? const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.refresh),
          tooltip: l.servicePingAll,
          onPressed: _probing ? null : _probeAll,
        ),
      ],
      body: ListView(
        children: [
          SettingsSectionHeader(l.serviceConnections),
          _ConnectionRow(
            name: 'Chat',
            detail: l.serviceChannels(manager.config.chat.names.length),
            connected: manager.isChatPipeConnected,
            reconnecting: manager.connectPhase == ChatPhase.reconnecting,
          ),
          _ConnectionRow(
            name: 'Chat read',
            connected: read.isConnected,
            reconnecting: read.isReconnecting || read.isDialing,
          ),
          _ConnectionRow(
            name: 'Chat write',
            connected: irc.isConnected,
            reconnecting: irc.isReconnecting || irc.isDialing,
          ),
          _ConnectionRow(
            name: 'EventSub',
            connected: eventSub.isConnected,
            reconnecting: eventSub.isReconnecting,
            stale: eventSub.isStale,
          ),
          _ConnectionRow(
            name: 'PubSub',
            connected: pubSub?.isConnected ?? false,
            reconnecting: pubSub?.isReconnecting ?? false,
            stale: pubSub?.isStale ?? false,
            enabled: pubSub != null,
          ),
          _ConnectionRow(
            name: '7TV events',
            connected: sevenTv?.isConnected ?? false,
            reconnecting: sevenTv?.isReconnecting ?? false,
            stale: sevenTv?.isStale ?? false,
            enabled: sevenTv != null && sevenTv.enabled,
          ),
          SettingsSectionHeader(l.serviceServers),
          for (final endpoint in _endpoints)
            _ProbeRow(
              endpoint: endpoint,
              result: _results[endpoint.name],
              probing: _probing,
              enabled: !endpoint.auth || signedIn,
              onProbe: () => _probe(endpoint),
            ),
        ],
      ),
    );
  }
}

class _Endpoint {
  const _Endpoint(this.name, this.url, {this.auth = false});
  final String name;
  final String url;

  /// Whether the probe needs the signed-in account's token.
  final bool auth;
}

class _ProbeResult {
  const _ProbeResult({this.status, required this.ms});
  final int? status;
  final int ms;

  bool get ok => status != null;
}

class _ConnectionRow extends StatelessWidget {
  const _ConnectionRow({
    required this.name,
    required this.connected,
    required this.reconnecting,
    this.stale = false,
    this.enabled = true,
    this.detail,
  });

  final String name;
  final bool connected;
  final bool reconnecting;
  final bool stale;
  final bool enabled;
  final String? detail;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final state = !enabled
        ? l.serviceOffline
        : connected
        ? stale
              ? '${l.connected} · ${l.serviceStale}'
              : l.connected
        : reconnecting
        ? l.statusReconnecting
        : l.statusDisconnected;
    final color = !enabled
        ? scheme.onSurfaceVariant
        : connected
        ? (stale ? Colors.orange : Colors.green)
        : reconnecting
        ? Colors.orange
        : scheme.error;
    return ListTile(
      leading: Icon(Icons.circle, size: 12, color: color),
      title: Text(name),
      subtitle: detail == null ? null : Text(detail!),
      trailing: Text(state, style: TextStyle(color: color)),
    );
  }
}

class _ProbeRow extends StatelessWidget {
  const _ProbeRow({
    required this.endpoint,
    required this.result,
    required this.probing,
    required this.enabled,
    required this.onProbe,
  });

  final _Endpoint endpoint;
  final _ProbeResult? result;
  final bool probing;
  final bool enabled;
  final VoidCallback onProbe;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final theme = Theme.of(context);
    final status = result?.status;
    final failed = result != null && !result!.ok;
    final color = !enabled
        ? theme.colorScheme.onSurfaceVariant
        : status == null
        ? failed
              ? theme.colorScheme.error
              : theme.colorScheme.onSurfaceVariant
        : status < 400
        ? Colors.green
        : Colors.orange;
    final detail = !enabled
        ? l.serviceSignInRequired
        : result == null
        ? null
        : failed
        ? '${l.servicePingFailed} · ${result!.ms}ms'
        : 'HTTP $status · ${result!.ms}ms';
    return ListTile(
      leading: Icon(Icons.dns_outlined, color: color),
      title: Text(endpoint.name),
      subtitle: Text(
        endpoint.url,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (detail != null) Text(detail, style: theme.textTheme.bodySmall),
          if (enabled)
            IconButton(
              icon: const Icon(Icons.network_ping),
              tooltip: l.servicePing,
              onPressed: probing ? null : onProbe,
            ),
        ],
      ),
    );
  }
}
