import 'package:neostation/constants/system_folder_names.dart';
import 'package:neostation/utils/android_app_icon_paths.dart';
import 'package:path/path.dart' as path;
import 'package:test/test.dart';

void main() {
  group('SystemFolderNames for Android Games', () {
    test('both Android systems list installed apps', () {
      expect(SystemFolderNames.isAndroidApps('android'), isTrue);
      expect(SystemFolderNames.isAndroidApps('android_games'), isTrue);
      expect(SystemFolderNames.isAndroidApps('nes'), isFalse);
      expect(SystemFolderNames.isAndroidApps(null), isFalse);
    });

    test('Android Games rows and art resolve to android', () {
      expect(SystemFolderNames.rowSystemFolder('android_games'), 'android');
      expect(SystemFolderNames.rowSystemFolder('android'), 'android');
      expect(SystemFolderNames.rowSystemFolder('snes'), 'snes');
      expect(SystemFolderNames.artFolderName('android_games'), 'android');
      expect(SystemFolderNames.artFolderName('snes'), 'snes');
    });

    test('Android Games offers neither recursive scan nor subfolder view', () {
      expect(
        SystemFolderNames.recursiveScanExcluded,
        contains(SystemFolderNames.androidGames),
      );
      expect(
        SystemFolderNames.subfolderViewExcluded,
        containsAll(SystemFolderNames.recursiveScanExcluded),
      );
    });
  });

  group('AndroidAppIconPaths', () {
    test('keeps the full package name', () {
      expect(
        path.basename(AndroidAppIconPaths.iconPath('/media', 'com.tencent.ig')),
        'com.tencent.ig.png',
      );
    });

    test('two packages that share a prefix get two files', () {
      expect(
        AndroidAppIconPaths.iconPath('/media', 'com.tencent.ig'),
        isNot(AndroidAppIconPaths.iconPath('/media', 'com.tencent.tmgp.cf')),
      );
    });

    test('stays out of the per-system art folders', () {
      final icon = AndroidAppIconPaths.iconPath('/media', 'com.tencent.ig');

      expect(
        path.dirname(icon),
        path.join('/media', AndroidAppIconPaths.folder),
      );
      expect(
        path.split(icon),
        isNot(anyOf(contains('android'), contains('android_games'))),
      );
    });
  });
}
