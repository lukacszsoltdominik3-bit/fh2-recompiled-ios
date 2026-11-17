# iOS toolchain for FH2 Recompiled / ReXGlue SDK.
#
# Usage:
#   cmake --preset ios-arm64-release -S sdk -B sdk/out/ios-arm64
#
# TargetConditionals.h sets TARGET_OS_MAC=1 for every Apple platform, so
# REX_PLATFORM_MAC (in rex/platform.h) stays 1 on iOS. iOS-specific divergences
# (static MoltenVK, MAP_FIXED guest memory, 16 KiB vs 4 KiB pages) are gated on
# TARGET_OS_IOS inside the source files that need them.

set(CMAKE_SYSTEM_NAME iOS)
set(CMAKE_SYSTEM_PROCESSOR arm64)

# SDL3's CMake uses the legacy `IOS` variable (ios-cmake convention) to pick
# the UIKit video backend. CMake's native iOS support does not set it; set it
# here so SDL3 compiles in `src/video/uikit/*.m` instead of the Cocoa driver.
set(IOS TRUE)
set(APPLE TRUE)

set(CMAKE_OSX_DEPLOYMENT_TARGET "16.0" CACHE STRING "Minimum iOS deployment target")
set(CMAKE_OSX_ARCHITECTURES "arm64" CACHE STRING "Target architectures")

# Default to on-device SDK; override to iphonesimulator for the simulator.
set(CMAKE_OSX_SYSROOT "iphoneos" CACHE STRING "iOS SDK (iphoneos or iphonesimulator)")

# iOS apps bundle their own code; static libs are the only clean path.
# Keep MoltenVK's own target shape, but force everything else static.
set(BUILD_SHARED_LIBS OFF CACHE BOOL "iOS: build static libraries" FORCE)

# No installer wizard / loose files on iOS; game payload gets packaged in the
# .app bundle by the UIKit shell (Phase 4).
set(REXGLUE_IOS ON CACHE BOOL "ReXGlue: build for iOS" FORCE)

# iOS doesn't ship Vulkan Loader; MoltenVK gets static-linked into the app.
# Keep REXGLUE_USE_VULKAN=ON so the Vulkan code paths stay compiled.
set(REXGLUE_USE_VULKAN ON CACHE BOOL "" FORCE)
set(REXGLUE_USE_D3D12 OFF CACHE BOOL "" FORCE)

# Make the Vulkan loader a static lib on iOS. Its CMake calls this macOS-only,
# but the loader itself compiles identically on iOS — the restriction is just
# a warning. iOS cannot sideload dylibs so static is the only option.
set(APPLE_STATIC_LOADER ON CACHE BOOL "" FORCE)
# vulkan-framework (the .framework bundle) is macOS-only; it needs signing
# and we don't ship it on iOS. Build only the static loader.
set(BUILD_FRAMEWORK OFF CACHE BOOL "" FORCE)

# Signing: filled in on the command line or by the Xcode UI. Automatic signing
# wants a team; simulator and unsigned configure-only runs work without it.
set(FH2_IOS_DEVELOPMENT_TEAM "" CACHE STRING
    "Apple Developer Team ID (required for on-device builds)")
set(FH2_IOS_BUNDLE_IDENTIFIER "com.fh2recomp.fh2" CACHE STRING
    "iOS bundle identifier (reverse-DNS; must match provisioning profile)")
