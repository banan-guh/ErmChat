import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import '../../util/constants.dart';
import '../../util/data_usage.dart';

/// Emote list requests stay gzipped until they land and unpack here, so the
/// data meter counts the bytes that crossed the network. A 7TV channel list
/// is about a tenth of its unpacked size on the wire.
final _client = IOClient(HttpClient()..autoUncompress = false);

/// GETs [uri] for an emote provider: counted, unpacked, and failing on a
/// transient status like the other provider requests.
Future<http.Response> getEmoteList(
  Uri uri, {
  Map<String, String> headers = const {},
}) async {
  final res = await _client
      .get(uri, headers: {...headers, 'accept-encoding': 'gzip'})
      .timeout(httpTimeout);
  DataUsageStats.I.recordJson(res.bodyBytes.length);
  throwOnTransientHttpError(res.statusCode, uri);
  if (res.headers['content-encoding']?.toLowerCase() != 'gzip') return res;
  return http.Response.bytes(
    gzip.decode(res.bodyBytes),
    res.statusCode,
    headers: res.headers,
    request: res.request,
  );
}
