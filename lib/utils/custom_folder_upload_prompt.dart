import 'dart:io';
import 'dart:isolate';

import 'package:neostation/l10n/app_locale.dart';

import 'save_file_listing.dart';

/// More files than a save folder usually holds: the prompt warns that the
/// folder may be the wrong one (a ROM or media folder picked by mistake).
const int manySaveFiles = 1000;

/// A file this large is unlikely to be a save (a disc image, a video); the
/// prompt names how many there are and the largest. They still upload: some
/// standalone saves are large, such as Dolphin's 16 MB memory card.
const int largeSaveFile = 64 * 1024 * 1024;

/// What uploading a standalone save folder would send, as the upload itself
/// lists it.
class SaveFolderSummary {
  const SaveFolderSummary({
    required this.files,
    required this.bytes,
    required this.largeFiles,
    required this.largestBytes,
  });

  final int files;
  final int bytes;

  /// Files over the large-file size ([largeSaveFile] by default).
  final int largeFiles;
  final int largestBytes;
}

/// [summariseSaveFolder] in a background isolate, for a folder that may hold
/// thousands of files.
///
/// Started from here, where the closure captures nothing but [folder]: a
/// closure built inside a widget's method shares its captured variables with
/// the method's other closures, which can include the State itself, and that
/// can't be sent to an isolate.
Future<SaveFolderSummary> summariseSaveFolderInBackground(String folder) =>
    Isolate.run(() => summariseSaveFolder(folder));

/// Lists [folder] as the NeoSync upload does ([listSaveFilePaths]: every file,
/// in subfolders too, but no conflict backups) and adds up the sizes.
///
/// A file whose size can't be read is left out. Plain file I/O; see
/// [summariseSaveFolderInBackground] for large folders.
Future<SaveFolderSummary> summariseSaveFolder(
  String folder, {
  int largeFile = largeSaveFile,
}) async {
  final paths = await listSaveFilePaths([folder]);
  var files = 0;
  var bytes = 0;
  var largeFiles = 0;
  var largestBytes = 0;
  for (final path in paths) {
    final int size;
    try {
      size = await File(path).length();
    } on FileSystemException {
      continue;
    }
    files++;
    bytes += size;
    if (size > largestBytes) largestBytes = size;
    if (size > largeFile) largeFiles++;
  }
  return SaveFolderSummary(
    files: files,
    bytes: bytes,
    largeFiles: largeFiles,
    largestBytes: largestBytes,
  );
}

/// The confirmation's text for uploading [summary] from [folderLabel], with a
/// warning for each way the folder doesn't look like a save folder: many
/// files, large files, or more than the account's [freeBytes] (null when
/// unknown, then no warning). [text] resolves a string key.
///
/// The free-space warning is a heads-up, not a promise: files already in the
/// cloud count in both the summary and the space used, so re-adding a folder
/// that was uploaded before can warn when it would in fact fit.
String customFolderUploadPrompt({
  required SaveFolderSummary summary,
  required String folderLabel,
  required int? freeBytes,
  required String Function(String key) text,
}) {
  final lines = [
    text(AppLocale.customFolderUploadConfirm)
        .replaceFirst('{folder}', folderLabel)
        .replaceFirst('{count}', '${summary.files}')
        .replaceFirst('{size}', formatByteSize(summary.bytes)),
  ];
  if (summary.files >= manySaveFiles) {
    lines.add(text(AppLocale.customFolderUploadManyFiles));
  }
  if (summary.largeFiles > 0) {
    lines.add(
      text(AppLocale.customFolderUploadLargeFiles)
          .replaceFirst('{count}', '${summary.largeFiles}')
          .replaceFirst('{size}', formatByteSize(summary.largestBytes)),
    );
  }
  if (freeBytes != null && summary.bytes > freeBytes) {
    lines.add(
      text(
        AppLocale.customFolderUploadOverQuota,
      ).replaceFirst('{free}', formatByteSize(freeBytes < 0 ? 0 : freeBytes)),
    );
  }
  return lines.join('\n\n');
}

/// [bytes] in B, KB, MB or GB with one decimal, as NeoSync's file list and
/// quota show sizes.
String formatByteSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
}
