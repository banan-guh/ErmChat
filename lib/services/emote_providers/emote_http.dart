import 'dart:io';
import 'dart:isolate';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import '../../util/constants.dart';
import '../../util/data_usage.dart';

/// Emote list requests stay gzipped until they land and unpack here, so the
/// data meter counts the bytes that crossed the network. A 7TV channel list
/// is about a tenth of its unpacked size on the wire.
/// One client keeps connections alive across lists. It is rebuilt when
/// [HttpOverrides] change, so a test's fake applies.
IOClient get _client {
  final overrides = HttpOverrides.current;
  final held = _held;
  if (held != null && identical(overrides, _heldFor)) return held;
  _heldFor = overrides;
  return _held = IOClient(HttpClient()..autoUncompress = false);
}

IOClient? _held;
HttpOverrides? _heldFor;

/// Bodies past this unpack off the UI isolate; smaller ones are not worth
/// the hop.
const _isolateUnpackBytes = 64 * 1024;

/// GETs [uri] for an emote provider: counted, unpacked, and failing on a
/// transient status like the other provider requests.
Future<http.Response> getEmoteList(
  Uri uri, {
  Map<String, String> headers = const {},
}) async {
  final res = await _client
      .get(uri, headers: {...headers, 'accept-encoding': 'gzip'})
      .timeout(httpTimeout);
  DataUsageStats.I.recordJson(res.bodyBytes.length, uri);
  throwOnTransientHttpError(res.statusCode, uri);
  if (res.headers['content-encoding']?.toLowerCase() != 'gzip') return res;
  final packed = res.bodyBytes;
  return http.Response.bytes(
    packed.length > _isolateUnpackBytes
        ? await Isolate.run(() => gzip.decode(packed))
        : gzip.decode(packed),
    res.statusCode,
    headers: res.headers,
    request: res.request,
  );
}
