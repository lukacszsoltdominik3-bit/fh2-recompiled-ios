// iOS-only override for guest DLL modules that are statically linked into the
// host alongside the main recomp.
//
// Two things happen here:
//
// 1. `__imp__<name>` is made weak so identical PPC helper bodies emitted into
//    every module collapse to one symbol instead of a duplicate-symbol error.
//
// 2. `__imp__` is built with a macro-expanding concatenation (REX_IOS_CAT)
//    instead of a bare `##`, so that when a module pre-defines
//    `#define __savegprlr_26 <module>___savegprlr_26` (see the generated
//    *_rename_helpers.h in rexglue_configure_module_target) the rename reaches
//    the real body too, not just the thunk. This matters because the main
//    recomp is generated with REX_CONFIG_NON_VOLATILE_AS_LOCAL (its save/rest
//    helpers are deliberate no-ops) while the modules are not (their helpers
//    must really save/restore ctx.rNN). On macOS each module dylib keeps its
//    own copy; statically linked, the main's no-op would otherwise shadow the
//    module's working one and clobber non-volatile registers across calls.
//
// Appended to the module's PCH chain after fh2_pch.h, which already defined
// both macros behind #ifndef guards, so undef first.
#pragma once

#ifndef REX_IOS_MODULE_WEAK_H
#define REX_IOS_MODULE_WEAK_H

#define REX_IOS_CAT_(a, b) a##b
#define REX_IOS_CAT(a, b) REX_IOS_CAT_(a, b)

#undef DECLARE_REX_FUNC
#define DECLARE_REX_FUNC(name) \
  REX_EXTERN(name);            \
  REX_EXTERN(REX_IOS_CAT(__imp__, name))

#undef DEFINE_REX_FUNC
#define DEFINE_REX_FUNC(name)                                                        \
  extern "C" __attribute__((weak)) void REX_IOS_CAT(__imp__, name)(                 \
      PPCContext& __restrict, uint8_t*);                                             \
  __attribute__((weak, noinline)) extern "C" void name(                              \
      PPCContext& __restrict ctx, uint8_t* base) {                                   \
    [[clang::musttail]] return REX_IOS_CAT(__imp__, name)(ctx, base);                \
  }                                                                                  \
  extern "C" __attribute__((weak)) void REX_IOS_CAT(__imp__, name)(                 \
      [[maybe_unused]] PPCContext& __restrict ctx, uint8_t* base)

#endif  // REX_IOS_MODULE_WEAK_H
