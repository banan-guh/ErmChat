cmake_minimum_required(VERSION 3.10)

project(emote_codec LANGUAGES C)

# Disable libwebp's tools/libraries we don't need (option() only honors cache
# entries, hence CACHE ... FORCE to override the defaults).
set(WEBP_BUILD_CWEBP OFF CACHE BOOL "" FORCE)
set(WEBP_BUILD_DWEBP OFF CACHE BOOL "" FORCE)
set(WEBP_BUILD_GIF2WEBP OFF CACHE BOOL "" FORCE)
set(WEBP_BUILD_IMG2WEBP OFF CACHE BOOL "" FORCE)
set(WEBP_BUILD_VWEBP OFF CACHE BOOL "" FORCE)
set(WEBP_BUILD_WEBPINFO OFF CACHE BOOL "" FORCE)
set(WEBP_BUILD_LIBWEBPMUX OFF CACHE BOOL "" FORCE)
set(WEBP_BUILD_WEBPMUX OFF CACHE BOOL "" FORCE)
set(WEBP_BUILD_ANIM_UTILS OFF CACHE BOOL "" FORCE)
set(WEBP_BUILD_EXTRAS OFF CACHE BOOL "" FORCE)
set(WEBP_BUILD_WEBP_JS OFF CACHE BOOL "" FORCE)

set(LIBWEBP_SRC ${CMAKE_CURRENT_SOURCE_DIR}/../../../../../third_party/libwebp)

# Static webp/webpdemux objects are linked into the shared emote_codec lib,
# so they must be compiled as PIC.
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

add_subdirectory(${LIBWEBP_SRC} ${CMAKE_CURRENT_BINARY_DIR}/libwebp)

# Strip GNU build IDs so reproducible-build verification against GitHub Actions
# builds succeeds (AGP 9 dropped the externalNativeBuild `arguments` DSL hook,
# so the flag lives here instead of build.gradle.kts).
set(CMAKE_SHARED_LINKER_FLAGS "${CMAKE_SHARED_LINKER_FLAGS} -Wl,--build-id=none")

add_library(emote_codec SHARED ${CMAKE_CURRENT_SOURCE_DIR}/../../../../../native/emote_codec.c)
target_include_directories(emote_codec PRIVATE ${LIBWEBP_SRC}/src)
target_link_libraries(emote_codec PRIVATE webpdemux webp)
