import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import '../../utils/lifo_semaphore.dart';
import '../romm_service.dart';

/// An [ImageProvider] for a RomM cover, fetched through [RommService] under a
/// shared concurrency bound.
///
/// `Image.network` cannot be used for these. `NetworkImage` fetches on
/// Flutter's own process-wide `HttpClient`, which is separate from
/// [RommService]'s and has no `maxConnectionsPerHost`, and production code has
/// no hook to configure it — `debugNetworkImageHttpClientProvider` is
/// debug-only. A screenful of grid tiles therefore opened as many sockets to
/// the RomM server as it had tiles, competing with the request fetching the
/// next page of games on the same host. On a large platform that is how the
/// page request itself came to time out.
///
/// ScreenScraper already solves this for its own client with a semaphore; this
/// is the same answer for RomM's covers. [maxConcurrent] is deliberately small:
/// tiles are fetched to be looked at now, and a bounded queue paints the
/// visible rows sooner than a burst that starts everything at once and
/// finishes nothing.
///
/// The queue is newest-first ([LifoSemaphore]), which matters as much as the
/// bound. A scroll asks for every tile it passes, so under a fair FIFO queue
/// the covers on screen would wait behind every tile already scrolled by — on
/// a slow server, minutes of waiting for images nobody will look at. Serving
/// the newest request first means the queue is always headed by whatever the
/// user is looking at now.
///
/// Flutter gives no way to *cancel* the stale ones. `ImageCache` keeps its own
/// listener on a pending completer for the whole load (`image_cache.dart`,
/// `putIfAbsent`), so `addOnLastListenerRemovedCallback` cannot fire while a
/// fetch is in flight and there is no supported signal for "no tile wants this
/// any more". They therefore still run — just last, behind everything visible.
///
/// This writes nothing to disk. The decoded frame lives in Flutter's
/// `ImageCache` exactly as it did before — what changes is how the bytes are
/// fetched, not where they are kept.
@immutable
class RommCoverImage extends ImageProvider<RommCoverImage> {
  /// Concurrent cover fetches allowed across the whole app.
  ///
  /// Five, matching ScreenScraper's bound. Enough to keep a scroll fed on a
  /// LAN server, few enough to leave connections for the API calls the browse
  /// screen needs to keep working while covers load.
  static const int maxConcurrent = 5;

  static final LifoSemaphore _gate = LifoSemaphore(maxConcurrent);

  /// The absolute cover URL, already resolved by
  /// [RommService.tileCoverUrlCandidates].
  final String url;

  /// The service whose auth headers and bounded client the fetch goes through.
  final RommService service;

  /// Applied to the decoded frame, as `Image.network`'s `scale` was.
  final double scale;

  const RommCoverImage(this.url, this.service, {this.scale = 1.0});

  @override
  Future<RommCoverImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture<RommCoverImage>(this);

  @override
  ImageStreamCompleter loadImage(
    RommCoverImage key,
    ImageDecoderCallback decode,
  ) {
    return MultiFrameImageStreamCompleter(
      codec: _load(key, decode),
      scale: key.scale,
      debugLabel: key.url,
      informationCollector: () => [DiagnosticsProperty<String>('URL', key.url)],
    );
  }

  Future<ui.Codec> _load(
    RommCoverImage key,
    ImageDecoderCallback decode,
  ) async {
    await _gate.acquire();
    final RommImageFetch result;
    try {
      // `quiet: true`: a 404 on the first candidate is the documented way to
      // reach the second (see `tileCoverUrlCandidates`), so a miss here is
      // expected traffic rather than something to warn about once per tile.
      // It does not mute transport failures — see `fetchImage`.
      result = await key.service.fetchImage(key.url, quiet: true);
    } finally {
      // `fetchImage` is written to be total, but "total" is a property of the
      // callee that nothing here enforces; a slot leaked from this block wedges
      // every cover in the app after `maxConcurrent` of them, permanently.
      _gate.release();
    }
    final bytes = result.bytes;
    if (bytes == null || bytes.isEmpty) {
      // Only a definite negative is remembered. A timeout, a dropped socket or
      // a 5xx must stay retryable: a handheld that roams Wi-Fi mid-scroll
      // would otherwise blacklist every cover that was in flight and leave the
      // grid grey for the rest of the session.
      if (result.isAbsent) key.service.markDeadCover(key.url);
      // The same shape `NetworkImage` fails with, so the card's existing
      // `errorBuilder` keeps working and still advances to the next candidate.
      throw NetworkImageLoadException(statusCode: 404, uri: Uri.parse(key.url));
    }
    return decode(await ui.ImmutableBuffer.fromUint8List(bytes));
  }

  @override
  bool operator ==(Object other) =>
      other is RommCoverImage && other.url == url && other.scale == scale;

  @override
  int get hashCode => Object.hash(url, scale);

  @override
  String toString() => 'RommCoverImage("$url", scale: $scale)';
}
