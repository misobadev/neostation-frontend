import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/utils/custom_folder_upload_prompt.dart';
import 'package:path/path.dart' as p;

// Picking a NeoSync standalone save folder uploaded everything in it at once:
// a wrong folder sent thousands of files, with nothing to say so first. The
// prompt now says how much would go up, and warns when it doesn't look like a
// save folder.

String english(String key) => AppLocale.en[key] as String;

void main() {
  group('summariseSaveFolder', () {
    late Directory folder;

    setUp(() async {
      folder = await Directory.systemTemp.createTemp('upload_prompt_');
    });
    tearDown(() => folder.delete(recursive: true));

    void write(String relative, int bytes) {
      final file = File(p.join(folder.path, relative));
      file.parent.createSync(recursive: true);
      file.writeAsBytesSync(List.filled(bytes, 0));
    }

    test(
      'counts every file the upload would send, in subfolders too',
      () async {
        write('a.sav', 10);
        write(p.join('slot1', 'b.sav'), 30);
        // A conflict backup never goes up.
        write('a.sav.neosync.bak', 500);

        final summary = await summariseSaveFolder(folder.path);

        expect(summary.files, 2);
        expect(summary.bytes, 40);
        expect(summary.largeFiles, 0);
      },
    );

    test('names the files over the large-file size, and the largest', () async {
      write('a.sav', 10);
      write('disc.iso', 300);
      write('other.bin', 200);

      final summary = await summariseSaveFolder(folder.path, largeFile: 100);

      expect(summary.largeFiles, 2);
      expect(summary.largestBytes, 300);
    });

    test('runs in a background isolate', () async {
      write('a.sav', 10);
      write(p.join('slot1', 'b.sav'), 30);

      final summary = await summariseSaveFolderInBackground(folder.path);

      expect(summary.files, 2);
      expect(summary.bytes, 40);
    });

    test('a missing folder has nothing to upload', () async {
      final summary = await summariseSaveFolder(p.join(folder.path, 'gone'));

      expect(summary.files, 0);
    });
  });

  group('customFolderUploadPrompt', () {
    String prompt(SaveFolderSummary summary, {int? freeBytes}) =>
        customFolderUploadPrompt(
          summary: summary,
          folderLabel: 'saves',
          freeBytes: freeBytes,
          text: english,
        );

    test(
      'says how many files and how much data would go up, and from where',
      () {
        final text = prompt(
          const SaveFolderSummary(
            files: 3,
            bytes: 2048,
            largeFiles: 0,
            largestBytes: 1024,
          ),
          freeBytes: 1 << 30,
        );

        expect(text, contains('3'));
        expect(text, contains('2.0 KB'));
        expect(text, contains('saves'));
        expect(
          text,
          isNot(contains(english(AppLocale.customFolderUploadManyFiles))),
        );
        expect(text, isNot(contains('64 MB')));
      },
    );

    test(
      'warns when there are more files than a save folder usually holds',
      () {
        final text = prompt(
          const SaveFolderSummary(
            files: manySaveFiles,
            bytes: 100,
            largeFiles: 0,
            largestBytes: 1,
          ),
        );

        expect(text, contains(english(AppLocale.customFolderUploadManyFiles)));
        expect(
          prompt(
            const SaveFolderSummary(
              files: manySaveFiles - 1,
              bytes: 100,
              largeFiles: 0,
              largestBytes: 1,
            ),
          ),
          isNot(contains(english(AppLocale.customFolderUploadManyFiles))),
        );
      },
    );

    test('names large files and the largest', () {
      final text = prompt(
        const SaveFolderSummary(
          files: 4,
          bytes: 5 << 30,
          largeFiles: 2,
          largestBytes: 4 << 30,
        ),
      );

      expect(text, contains('64 MB'));
      expect(text, contains('4.0 GB'));
    });

    test('warns when it is more than the free NeoSync space', () {
      const summary = SaveFolderSummary(
        files: 2,
        bytes: 3 << 20,
        largeFiles: 0,
        largestBytes: 2 << 20,
      );

      expect(prompt(summary, freeBytes: 1 << 20), contains('1.0 MB'));
      expect(
        prompt(summary, freeBytes: 1 << 20),
        contains(
          english(AppLocale.customFolderUploadOverQuota).split('{').first,
        ),
      );
      // Unknown free space, or enough of it: no warning.
      expect(
        prompt(summary),
        isNot(
          contains(
            english(AppLocale.customFolderUploadOverQuota).split('{').first,
          ),
        ),
      );
      expect(
        prompt(summary, freeBytes: 4 << 20),
        isNot(
          contains(
            english(AppLocale.customFolderUploadOverQuota).split('{').first,
          ),
        ),
      );
    });
  });
}
