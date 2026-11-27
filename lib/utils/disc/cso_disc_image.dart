import 'dart:io';
import 'dart:typed_data';

import '../../services/logger_service.dart';
import '../optimized_md5_utils.dart';
import 'disc_image.dart';

/// A CISO/CSO compressed disc image: the `.iso` a PSP or PlayStation 2 disc
/// would have been, cut into fixed blocks and deflated one block at a time.
///
/// This is what most PSP libraries are actually stored as, and RetroAchievements
/// hashes the same bytes whatever the container — PPSSPP reads a `.cso` natively
/// and reports the hash our reader could not produce.
///
/// The format is a 24-byte header, then one 32-bit index entry per block plus a
/// terminator. An entry's low bits are the block's offset into the file (shifted
/// left by the header's alignment), its top bit means the block was stored
/// uncompressed, and a block's compressed length is the gap to the next entry.
/// The payload underneath is a plain 2048-byte-sector image, so once a block is
/// inflated there is no sector header to step over.
class CsoDiscImage extends DiscImage {
  static final _log = LoggerService.instance;

  /// How much of the compressed file one read pulls in.
  ///
  /// Blocks are stored in order and the callers above read forwards — walk the
  /// ISO9660 tree, then stream one executable — so a window is fetched once and
  /// the blocks inside it are inflated from memory. Going to the file per block
  /// would be ~2,900 reads for a PSP `EBOOT.BIN`, and on Android every one of
  /// them is a platform-channel round trip.
  static const int _windowBytes = 1 << 20;

  /// Marks an index entry whose block was stored rather than deflated.
  static const int _plainFlag = 0x80000000;

  final String _path;
  final int _blockSize;
  final int _align;
  final int _totalBytes;
  final Uint32List _index;

  /// The compressed window, and where in the file it starts.
  Uint8List? _window;
  int _windowStart = -1;

  /// The block inflated most recently. A block spans several sectors whenever
  /// the image was written with a block size above one sector.
  Uint8List? _cachedBlock;
  int _cachedBlockIndex = -1;

  CsoDiscImage._({
    required this._path,
    required this._blockSize,
    required this._align,
    required this._totalBytes,
    required this._index,
  });

  /// Opens the CSO at [path], or returns null when it is not one we can read.
  static Future<CsoDiscImage?> open(String path) async {
    final header = await OptimizedMd5Utils.readRange(path, 0, 24);
    if (header.length < 24) return null;

    if (header[0] != 0x43 || // C
        header[1] != 0x49 || // I
        header[2] != 0x53 || // S
        header[3] != 0x4F) {
      // O
      _log.w('CSO: $path is not a CISO image');
      return null;
    }

    final data = ByteData.sublistView(header);
    final version = header[0x14];
    if (version > 1) {
      // Version 2 mixes codecs per block and is not what any library holds.
      _log.w('CSO: unsupported version $version in $path');
      return null;
    }

    final totalBytes = data.getUint64(8, Endian.little);
    final blockSize = data.getUint32(0x10, Endian.little);
    final align = header[0x15];

    // The payload is a sector image, so a block has to be a whole number of
    // sectors for a sector to be sliced out of one.
    if (totalBytes <= 0 ||
        blockSize < discSectorSize ||
        blockSize % discSectorSize != 0) {
      _log.w('CSO: $path declares an unusable block size $blockSize');
      return null;
    }

    // Some writers leave the header size field at zero; the header is fixed.
    final headerSize = data.getUint32(4, Endian.little);
    final indexStart = headerSize < 24 ? 24 : headerSize;

    final blockCount = (totalBytes + blockSize - 1) ~/ blockSize;
    final indexBytes = await OptimizedMd5Utils.readRange(
      path,
      indexStart,
      (blockCount + 1) * 4,
    );
    if (indexBytes.length < (blockCount + 1) * 4) {
      _log.w('CSO: $path is truncated, its block index is incomplete');
      return null;
    }

    // The index is read as bytes and may land on any alignment, so it is copied
    // rather than viewed.
    final index = Uint32List(blockCount + 1);
    final indexData = ByteData.sublistView(indexBytes);
    for (var i = 0; i <= blockCount; i++) {
      index[i] = indexData.getUint32(i * 4, Endian.little);
    }

    return CsoDiscImage._(
      path: path,
      blockSize: blockSize,
      align: align,
      totalBytes: totalBytes,
      index: index,
    );
  }

  @override
  late final List<DiscTrackInfo> tracks = [
    DiscTrackInfo(
      number: 1,
      isData: true,
      startLba: 0,
      sectors: _totalBytes ~/ discSectorSize,
    ),
  ];

  @override
  Future<Uint8List?> readSector(int trackIndex, int lba) async {
    if (trackIndex != 0 || lba < 0) return null;

    final offset = lba * discSectorSize;
    if (offset + discSectorSize > _totalBytes) return null;

    final block = await _blockAt(offset ~/ _blockSize);
    if (block == null) return null;

    final within = offset % _blockSize;
    if (within + discSectorSize > block.length) return null;
    return Uint8List.sublistView(block, within, within + discSectorSize);
  }

  @override
  Future<void> close() async {
    _window = null;
    _windowStart = -1;
    _cachedBlock = null;
    _cachedBlockIndex = -1;
  }

  /// The uncompressed bytes of block [blockIndex], or null when it cannot be
  /// read back.
  Future<Uint8List?> _blockAt(int blockIndex) async {
    if (blockIndex < 0 || blockIndex >= _index.length - 1) return null;
    if (_cachedBlockIndex == blockIndex) return _cachedBlock;

    final start = (_index[blockIndex] & ~_plainFlag) << _align;
    final end = (_index[blockIndex + 1] & ~_plainFlag) << _align;
    final stored = end - start;
    if (stored <= 0) return null;

    // The final block is short whenever the image is not a whole number of
    // blocks long.
    final expected = _blockSize < _totalBytes - blockIndex * _blockSize
        ? _blockSize
        : _totalBytes - blockIndex * _blockSize;

    final plain = _index[blockIndex] & _plainFlag != 0;
    final raw = await _readCompressed(start, plain ? expected : stored);
    if (raw == null) return null;

    Uint8List? block;
    if (plain) {
      block = raw;
    } else {
      block = _inflate(raw, expected);
      // A block that would not compress is sometimes stored without the flag
      // that says so; its length gives it away.
      if (block == null && stored >= expected) {
        block = Uint8List.sublistView(raw, 0, expected);
      }
    }
    if (block == null || block.length < expected) {
      _log.w('CSO: could not read block $blockIndex of $_path');
      return null;
    }

    _cachedBlock = block;
    _cachedBlockIndex = blockIndex;
    return block;
  }

  /// [length] bytes of the compressed file at [offset], through the window.
  Future<Uint8List?> _readCompressed(int offset, int length) async {
    final window = _window;
    if (window != null &&
        offset >= _windowStart &&
        offset + length <= _windowStart + window.length) {
      final begin = offset - _windowStart;
      return Uint8List.sublistView(window, begin, begin + length);
    }

    // A block bigger than the window is read on its own rather than growing it.
    if (length > _windowBytes) {
      final bytes = await OptimizedMd5Utils.readRange(_path, offset, length);
      return bytes.length < length ? null : bytes;
    }

    final bytes = await OptimizedMd5Utils.readRange(
      _path,
      offset,
      _windowBytes,
    );
    if (bytes.length < length) return null;

    // Views handed out earlier stay valid: a refill allocates a new buffer and
    // nothing writes into one.
    _window = bytes;
    _windowStart = offset;
    return Uint8List.sublistView(bytes, 0, length);
  }

  /// Inflates a raw deflate stream, or returns null when it does not yield the
  /// [expected] bytes.
  ///
  /// The stream is followed by however many padding bytes the header's
  /// alignment demanded, which zlib stops before rather than rejecting; a
  /// truncated one it accepts just as quietly, so the length is what says
  /// whether the block came back whole.
  static Uint8List? _inflate(Uint8List data, int expected) {
    try {
      final out = ZLibDecoder(raw: true).convert(data);
      if (out.length < expected) return null;
      return out is Uint8List
          ? Uint8List.sublistView(out, 0, expected)
          : Uint8List.fromList(out.sublist(0, expected));
    } catch (_) {
      return null;
    }
  }
}
