/// NeoStation's version as written in `pubspec.yaml`, without the build
/// number: what the update check compares against the releases on GitHub.
///
/// The platforms don't all keep it as written. macOS takes only numbers in
/// `CFBundleShortVersionString`, so Flutter turns `1.0.0-rc.1` into `1.0.0.1`
/// there, and a release candidate read through package_info would look like
/// the release and never be offered it. Kept in step with `pubspec.yaml` by
/// `test_pure/app_version_test.dart`: change both together.
const String appVersion = '1.0.0-rc.2';
