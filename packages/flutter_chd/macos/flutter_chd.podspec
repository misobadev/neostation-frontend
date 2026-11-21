#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint flutter_chd.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'flutter_chd'
  s.version          = '0.0.1'
  s.summary          = 'Reads CD tracks and sectors out of CHD disc images.'
  s.description      = <<-DESC
Reads CD tracks and sectors out of CHD disc images, over a vendored libchdr.
                       DESC
  s.homepage         = 'https://github.com/misobadev/neostation-frontend'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'NeoStation' => 'neostation@neogamelab.com' }

  # This will ensure the source files in Classes/ are included in the native
  # builds of apps using this FFI plugin. Podspec does not support relative
  # paths, so Classes contains a forwarder C file that relatively imports
  # `../src/*` so that the C sources can be shared among all target platforms.
  s.source           = { :path => '.' }
  s.source_files = 'Classes/**/*'

  s.dependency 'FlutterMacOS'

  s.platform = :osx, '14.5'
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    # flutter_chd.c includes libchdr's public headers by their own prefix.
    'HEADER_SEARCH_PATHS' => '"$(PODS_TARGET_SRCROOT)/../src/libchdr/include"',
  }
  s.swift_version = '5.0'
end
