// Static module registry (iOS: DLL modules linked into the host exe).
//
// On iOS the app bundle cannot load unsigned .dylibs at runtime, so the guest
// DLLs (XMediaFacade, SpeechFacade, ...) are compiled into static archives
// linked directly into the host executable. Each such module registers its
// renamed `ReXModule_Register` / `ReXModule_GetImageInfo` here at static init
// (see rexglue_configure_module_target in cmake); kernel_state consults this
// table before deciding the shared-lib load failed.

#pragma once

#include <rex/image_info.h>
#include <rex/system/function_dispatcher.h>

namespace rex::system {

struct StaticModuleEntry {
  rex::runtime::FunctionDispatcher::RegisterFn register_fn;
  const rex::PPCImageInfo* (*get_image_info_fn)();
};

void RegisterStaticModule(const char* shared_lib_name, StaticModuleEntry entry);

const StaticModuleEntry* LookupStaticModule(const char* shared_lib_name);

}  // namespace rex::system
