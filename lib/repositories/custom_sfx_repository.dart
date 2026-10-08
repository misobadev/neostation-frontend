import 'dart:io';
import 'dart:math';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../models/custom_sfx.dart';
import '../services/saf_directory_service.dart';

/// Owns durable copies of imported clips, independent of picker permissions.
class CustomSfxRepository {
  static const maxBytes = 5 * 1024 * 1024;
  final Future<Directory> Function() directory;
  CustomSfxRepository({Future<Directory> Function()? directory})
    : directory = directory ?? getApplicationSupportDirectory;

  Future<String> resolve(CustomSfx sound) async =>
      p.join((await directory()).path, sound.path);

  Future<CustomSfx> stage(String source, String filename) async {
    final ext = p.extension(filename).toLowerCase();
    if (!const ['.wav', '.mp3', '.ogg', '.flac'].contains(ext)) {
      throw const FormatException('format');
    }
    final saf = source.startsWith('content://');
    final size = saf
        ? await SafDirectoryService.getFileSize(source)
        : await File(source).length();
    if (size <= 0) throw const FormatException('invalid');
    if (size > maxBytes) throw const FormatException('size');
    final folder = Directory(p.join((await directory()).path, 'custom_sfx'));
    await folder.create(recursive: true);
    final name =
        '${DateTime.now().microsecondsSinceEpoch}_${Random.secure().nextInt(1 << 32)}$ext';
    final sound = CustomSfx(path: 'custom_sfx/$name', filename: filename);
    final file = File(await resolve(sound));
    try {
      final sink = file.openWrite();
      var copied = 0;
      try {
        if (saf) {
          while (copied < size) {
            final bytes = await SafDirectoryService.readRange(
              source,
              copied,
              min(256 * 1024, size - copied),
            );
            if (bytes == null || bytes.isEmpty) {
              throw const FormatException('invalid');
            }
            copied += bytes.length;
            if (copied > maxBytes) throw const FormatException('size');
            sink.add(bytes);
          }
        } else {
          await for (final bytes in File(source).openRead()) {
            copied += bytes.length;
            if (copied > maxBytes) throw const FormatException('size');
            sink.add(bytes);
          }
        }
        if (copied == 0) throw const FormatException('invalid');
        await sink.flush();
      } finally {
        await sink.close();
      }
      return sound;
    } catch (_) {
      await remove(sound);
      rethrow;
    }
  }

  Future<void> remove(CustomSfx sound) async {
    final file = File(await resolve(sound));
    if (await file.exists()) await file.delete();
  }
}
