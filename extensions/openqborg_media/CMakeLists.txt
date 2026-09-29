# OpenQBORG media GDExtension: decodes FFmpeg-supported audio (AAC, M4A, Opus,
# FLAC, WMA, AIFF, WebM, ALAC, ...) to PCM, and animated images and video
# (GIF, APNG, Motion JPEG, ...) to RGBA frames, for Godot.
#
#   cmake -S extensions/openqborg_media -B build/audio -DCMAKE_BUILD_TYPE=Release
#   cmake --build build/audio -j
#
# The library lands in shared/openqborg_media/bin/, which both Godot projects
# see as res://addons/openqborg_media/.
cmake_minimum_required(VERSION 3.22)
project(openqborg_media LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

set(REPO_ROOT ${CMAKE_CURRENT_SOURCE_DIR}/../..)
if(NOT DEFINED GODOTCPP_TARGET)
	set(GODOTCPP_TARGET template_release CACHE STRING "godot-cpp build target")
endif()
add_subdirectory(${REPO_ROOT}/third_party/godot-cpp ${CMAKE_BINARY_DIR}/godot-cpp EXCLUDE_FROM_ALL)

find_package(PkgConfig REQUIRED)
pkg_check_modules(FFMPEG REQUIRED IMPORTED_TARGET libavformat libavcodec libswresample libswscale libavutil)

add_library(openqborg_media SHARED
	src/register_types.cpp
	src/ffmpeg_audio_decoder.cpp
	src/ffmpeg_frame_decoder.cpp
)
target_link_libraries(openqborg_media PRIVATE godot::cpp PkgConfig::FFMPEG)

option(OQB_BUNDLE_FFMPEG "Load FFmpeg libraries bundled next to the extension" OFF)
if(OQB_BUNDLE_FFMPEG)
	set_target_properties(openqborg_media PROPERTIES BUILD_RPATH "\$ORIGIN" INSTALL_RPATH "\$ORIGIN")
endif()

# Godot's naming: libopenqborg_media.<platform>.<arch>.so
string(TOLOWER ${CMAKE_SYSTEM_NAME} OQB_PLATFORM)
if(OQB_PLATFORM STREQUAL "darwin")
	set(OQB_PLATFORM macos)
endif()
string(TOLOWER ${CMAKE_SYSTEM_PROCESSOR} OQB_ARCH)
if(OQB_ARCH STREQUAL "amd64")
	set(OQB_ARCH x86_64)
elseif(OQB_ARCH STREQUAL "aarch64")
	set(OQB_ARCH arm64)
endif()
set_target_properties(openqborg_media PROPERTIES
	OUTPUT_NAME openqborg_media.${OQB_PLATFORM}.${OQB_ARCH}
	LIBRARY_OUTPUT_DIRECTORY ${REPO_ROOT}/shared/openqborg_media/bin
	RUNTIME_OUTPUT_DIRECTORY ${REPO_ROOT}/shared/openqborg_media/bin
)
