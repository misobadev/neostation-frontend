import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

/// Sends a request through [client] and reads its answer within [timeout]. A
/// request that runs out of time throws [TimeoutException], which callers
/// report like any network error, and its connection is closed.
Future<http.Response> sendWithTimeout(
  http.Client client,
  String method,
  Uri uri, {
  Map<String, String>? headers,
  String? body,
  required Duration timeout,
}) async {
  final abort = Completer<void>();
  final request = http.AbortableRequest(
    method,
    uri,
    abortTrigger: abort.future,
  );
  if (headers != null) request.headers.addAll(headers);
  if (body != null) request.body = body;
  try {
    return await client
        .send(request)
        .then(http.Response.fromStream)
        .timeout(timeout);
  } finally {
    // Closes the connection of a request that ran out of time; one that
    // answered in full is unaffected.
    abort.complete();
  }
}

/// Sends a request through [client] and reads its answer, of any size: the
/// headers must arrive within [headerTimeout] and each chunk of the body within
/// [stallTimeout] of the last. There is no limit on the whole transfer, so a
/// large file over a slow link is fine as long as it keeps arriving. A request
/// that stops moving throws [TimeoutException], which callers report like any
/// network error, and its connection is closed.
Future<http.Response> readWithStallTimeout(
  http.Client client,
  String method,
  Uri uri, {
  Map<String, String>? headers,
  required Duration headerTimeout,
  required Duration stallTimeout,
}) async {
  final abort = Completer<void>();
  final request = http.AbortableRequest(
    method,
    uri,
    abortTrigger: abort.future,
  );
  if (headers != null) request.headers.addAll(headers);
  try {
    final response = await client.send(request).timeout(headerTimeout);
    final body = await http.ByteStream(
      response.stream.timeout(stallTimeout),
    ).toBytes();
    return http.Response.bytes(
      body,
      response.statusCode,
      headers: response.headers,
      reasonPhrase: response.reasonPhrase,
      request: response.request,
    );
  } finally {
    // Closes the connection of a request that stopped moving; one read in
    // full is unaffected.
    abort.complete();
  }
}

/// The client a NeoSync service uses when none is passed in: connecting is
/// held to [connectTimeout] too, so an unreachable host fails as fast as a
/// silent one.
http.Client neoSyncHttpClient(Duration connectTimeout) =>
    IOClient(HttpClient()..connectionTimeout = connectTimeout);
