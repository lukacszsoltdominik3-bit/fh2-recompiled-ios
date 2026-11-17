/**
 * @file        ui/windowed_app_main_sdl.cpp
 * @brief       Entry point for windowed applications (SDL3 windowing)
 *
 * @copyright   Copyright (c) 2026 Tom Clay <tomc@tctechstuff.com>
 *              All rights reserved.
 *
 * @license     BSD 3-Clause License
 *              See LICENSE file in the project root for full license text.
 */

#include <algorithm>
#include <cstdlib>
#include <map>
#include <memory>
#include <string>
#include <vector>

#include <rex/cvar.h>
#include <rex/logging.h>
#include <rex/platform.h>
#if REX_PLATFORM_ANDROID || REX_PLATFORM_IOS
// SDL3 provides its own app entry on Android/iOS and renames user main() to
// SDL_main, so the system's UIApplicationMain / SDLActivity loop drives it.
#include <SDL3/SDL_main.h>
#endif
#if REX_PLATFORM_IOS
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <unistd.h>
#endif
#include <rex/ui/windowed_app.h>
#include <rex/ui/windowed_app_context_sdl.h>

#if REX_PLATFORM_WIN32
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#include <objbase.h>
#include <shellapi.h>
#endif

namespace {

int RunWindowedApp(int argc, char** argv) {
#if REX_PLATFORM_IOS
  // MoltenVK performance settings (environment variables, read when the Vulkan
  // instance is created; an existing value from the environment wins):
  // - Asynchronous queue submits: with the default (synchronous), every
  //   vkQueueSubmit encodes the whole frame into Metal on the calling thread -
  //   measured ~27-32 ms of a ~50 ms frame on the GPU command processor thread.
  //   Asynchronous submission moves that encoding to MoltenVK's own queue thread.
  // - Concurrent Metal shader compilation (fewer hitches on new pipelines).
  // Fast math is left at MoltenVK's default: forcing it off (tried while chasing
  // the black world, whose cause was the rectangle-list vertex loop) only cost GPU time.
  setenv("MVK_CONFIG_SYNCHRONOUS_QUEUE_SUBMITS", "0", 0);
  setenv("MVK_CONFIG_SHOULD_MAXIMIZE_CONCURRENT_COMPILATION", "1", 0);
  // - Discrete resource binding instead of Metal argument buffers: the emulator rebinds
  //   descriptor sets at nearly every draw, which MoltenVK turns into argument buffer encoding.
  //   A/B on an iPhone in a 3100-draw scene: 23-25 -> 27-28 fps, 8 % less CPU in total.
  setenv("MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS", "0", 0);
  // Tuning: Documents/fh2/mvk_env holds extra environment variables, one KEY=VALUE per
  // line (MoltenVK's MVK_CONFIG_* settings), applied before the Vulkan instance exists - for
  // A/B tests of MoltenVK options without a rebuild. They override the defaults above.
  if (const char* home = std::getenv("HOME")) {
    std::string mvk_env_path = std::string(home) + "/Documents/fh2/mvk_env";
    if (FILE* mvk_env_file = std::fopen(mvk_env_path.c_str(), "rb")) {
      char line[256];
      while (std::fgets(line, sizeof(line), mvk_env_file)) {
        std::string entry(line);
        while (!entry.empty() && (entry.back() == '\n' || entry.back() == '\r' ||
                                  entry.back() == ' ')) {
          entry.pop_back();
        }
        size_t equals = entry.find('=');
        if (entry.empty() || entry[0] == '#' || equals == std::string::npos || equals == 0) {
          continue;
        }
        setenv(entry.substr(0, equals).c_str(), entry.substr(equals + 1).c_str(), 1);
        std::fprintf(stderr, "[fh2-ios] mvk_env: %s\n", entry.c_str());
      }
      std::fclose(mvk_env_file);
    }
  }
  // Diagnostics: a file Documents/fh2/mvk_debug turns on MoltenVK's debug mode,
  // which makes Metal record each encoder's execution status, so a GPU hang is
  // logged with the encoders (and their gpu_rotulos debug signposts) that hung.
  // (Only when the file starts with '1': files can be overwritten, not deleted,
  // through devicectl, so writing '0' turns it off again. It logs the Metal
  // source of every shader it compiles - very slow when many pipelines compile.)
  if (const char* home = std::getenv("HOME")) {
    std::string mvk_debug_path = std::string(home) + "/Documents/fh2/mvk_debug";
    if (FILE* mvk_debug_file = std::fopen(mvk_debug_path.c_str(), "rb")) {
      if (std::fgetc(mvk_debug_file) == '1') {
        setenv("MVK_CONFIG_DEBUG", "1", 1);
      }
      std::fclose(mvk_debug_file);
    }
  }
  // The app bundle is read-only on iOS; move CWD to the sandbox Documents dir
  // so logs, config file, and generated assets all land in a writable place
  // the user can also reach through the Files app.
  if (const char* home = std::getenv("HOME")) {
    std::filesystem::path docs = std::filesystem::path(home) / "Documents";
    std::error_code ec;
    std::filesystem::create_directories(docs, ec);
    std::fprintf(stderr, "[fh2-ios] chdir(%s) => %d\n", docs.c_str(),
                 chdir(docs.c_str()));
  } else {
    std::fprintf(stderr, "[fh2-ios] HOME is unset; cwd stays at bundle\n");
  }
#endif
  auto remaining = rex::cvar::Init(argc, argv);
  rex::cvar::ApplyEnvironment();
  rex::InitLoggingEarly();

  int result;
  {
    rex::ui::SDLWindowedAppContext app_context;
    if (!app_context.Initialize()) {
      return EXIT_FAILURE;
    }

#if REX_PLATFORM_WIN32
    // Apartment-threaded COM for shell dialogs.
    if (FAILED(CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED))) {
      return EXIT_FAILURE;
    }
#endif

#if REX_PLATFORM_ANDROID
    // Android loads the app and its SDL entry point into the same shared
    // library. App creators register themselves through REX_DEFINE_APP; the
    // library carries exactly one game.
    auto app_creator = rex::ui::WindowedApp::GetOnlyCreator();
    if (!app_creator) {
      return EXIT_FAILURE;
    }
    std::unique_ptr<rex::ui::WindowedApp> app = app_creator(app_context);
#else
    std::unique_ptr<rex::ui::WindowedApp> app = rex::ui::GetWindowedAppCreator()(app_context);
#endif

    // Match remaining positional args to the app's expected options.
    const auto& option_names = app->GetPositionalOptions();
    std::map<std::string, std::string> parsed;
    size_t count = std::min(remaining.size(), option_names.size());
    for (size_t i = 0; i < count; ++i) {
      parsed[option_names[i]] = remaining[i];
    }
    app->SetParsedArguments(std::move(parsed));

    result = app->OnInitialize() ? app_context.RunMainMessageLoop() : EXIT_FAILURE;

    app->InvokeOnDestroy();
  }

#if REX_PLATFORM_WIN32
  CoUninitialize();
#endif

  return result;
}

#if REX_PLATFORM_WIN32
// Convert wide argv from CommandLineToArgvW to UTF-8 for cvar::Init.
std::vector<std::string> WideArgsToUtf8(int argc, wchar_t** wargv) {
  std::vector<std::string> args;
  args.reserve(static_cast<size_t>(argc));
  for (int i = 0; i < argc; ++i) {
    std::wstring wide(wargv[i]);
    if (wide.empty()) {
      args.emplace_back();
      continue;
    }
    int size = WideCharToMultiByte(CP_UTF8, 0, wide.data(), static_cast<int>(wide.size()), nullptr,
                                   0, nullptr, nullptr);
    std::string utf8(static_cast<size_t>(size), '\0');
    WideCharToMultiByte(CP_UTF8, 0, wide.data(), static_cast<int>(wide.size()), utf8.data(), size,
                        nullptr, nullptr);
    args.push_back(std::move(utf8));
  }
  return args;
}
#endif

}  // namespace

#if REX_PLATFORM_WIN32

int WINAPI wWinMain(HINSTANCE hinstance, HINSTANCE hinstance_prev, LPWSTR command_line,
                    int show_cmd) {
  (void)hinstance;
  (void)hinstance_prev;
  (void)command_line;
  (void)show_cmd;

  int wargc = 0;
  wchar_t** wargv = CommandLineToArgvW(GetCommandLineW(), &wargc);
  auto utf8_args = WideArgsToUtf8(wargc, wargv);
  LocalFree(wargv);

  std::vector<char*> argv_ptrs;
  argv_ptrs.reserve(utf8_args.size());
  for (auto& s : utf8_args) {
    argv_ptrs.push_back(s.data());
  }
  return RunWindowedApp(static_cast<int>(argv_ptrs.size()), argv_ptrs.data());
}

#else

int main(int argc, char* argv[]) {
  return RunWindowedApp(argc, argv);
}

#endif
