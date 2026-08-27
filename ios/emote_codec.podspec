#
# Native emote codec pod: libwebp (from the third_party/libwebp git submodule)
# statically compiled with the C shim, so the Dart FFI layer can load it via
# DynamicLibrary.process().
#
# F-Droid is Android-only (CMake path); this pod serves the GH Actions iOS job.
#
Pod::Spec.new do |s|
  s.name = 'emote_codec'
  s.version = '0.1.0'
  s.summary = 'libwebp-based animated WebP decoder shim for emote rendering'
  s.homepage = 'https://github.com/banan-guh/ermchat'
  s.license = { :type => 'BSD', :file => '../THIRD_PARTY_LICENSES' }
  s.author = { 'ermchat' => 'banan-guh' }
  s.source = { :path => '.' }
  s.static_framework = true
  s.platforms = { :ios => '13.0' }

  # Decoder set only: dec/demux/dsp/utils + the webp headers. The encoder and
  # muxer are not needed by the shim.
  s.source_files = [
    '../native/emote_codec.c',
    '../third_party/libwebp/src/dec/**/*.c',
    '../third_party/libwebp/src/demux/**/*.c',
    '../third_party/libwebp/src/dsp/**/*.c',
    '../third_party/libwebp/src/utils/**/*.c',
  ]
  s.public_header_files = '../native/emote_codec.h'
  s.pod_target_xcconfig = {
    'HEADER_SEARCH_PATHS' => [
      '$(PODS_TARGET_SRCROOT)/../native',
      '$(PODS_TARGET_SRCROOT)/../third_party/libwebp/src',
    ].join(' '),
    # No WEBP_USE_THREAD: libwebp is built single-threaded (matching Android),
    # so the shim's threaded anim decoder can't deadlock from a Dart isolate.
    'GCC_PREPROCESSOR_DEFINITIONS' => '$(inherited)',
  }
end
