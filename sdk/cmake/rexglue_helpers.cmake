#==========================================================
# rexglue_helpers.cmake
#
# Three helpers, each with a single responsibility:
#   rexglue_apply_target_settings(<target>)        - common compile/platform flags
#   rexglue_configure_target(<target>)             - host application
#   rexglue_configure_module_target(<target> ...)  - guest DLL module
#==========================================================
include_guard(GLOBAL)

function(_rexglue_stage_macos_vulkan_runtime target_name)
    if(TARGET Vulkan::Loader AND TARGET MoltenVK::MoltenVK)
        set(_rexglue_vulkan_loader Vulkan::Loader)
        set(_rexglue_moltenvk MoltenVK::MoltenVK)
        set(_rexglue_moltenvk_icd "${REXGLUE_ROOT}/cmake/MoltenVK_icd.json")
    elseif(TARGET rex::vulkan-loader AND TARGET rex::moltenvk)
        set(_rexglue_vulkan_loader rex::vulkan-loader)
        set(_rexglue_moltenvk rex::moltenvk)
        set(_rexglue_moltenvk_icd "${REXGLUE_MOLTENVK_ICD}")
    else()
        message(FATAL_ERROR "rexglue: pinned macOS Vulkan runtime targets are unavailable")
    endif()

    add_custom_command(TARGET ${target_name} POST_BUILD
        COMMAND ${CMAKE_COMMAND} -E make_directory
            "$<TARGET_FILE_DIR:${target_name}>/vulkan/lib"
            "$<TARGET_FILE_DIR:${target_name}>/vulkan/share/vulkan/icd.d"
        COMMAND ${CMAKE_COMMAND} -E copy_if_different
            "$<TARGET_FILE:${_rexglue_vulkan_loader}>"
            "$<TARGET_FILE_DIR:${target_name}>/vulkan/lib/libvulkan.1.dylib"
        COMMAND ${CMAKE_COMMAND} -E copy_if_different
            "$<TARGET_FILE:${_rexglue_moltenvk}>"
            "$<TARGET_FILE_DIR:${target_name}>/vulkan/lib/libMoltenVK.dylib"
        COMMAND ${CMAKE_COMMAND} -E copy_if_different
            "${_rexglue_moltenvk_icd}"
            "$<TARGET_FILE_DIR:${target_name}>/vulkan/share/vulkan/icd.d/MoltenVK_icd.json"
        VERBATIM
    )
endfunction()

#==========================================================
# rexglue_apply_target_settings(<target>) - Common flags
#
# Applied to both host apps and guest DLL modules. Compile/link flags only;
# runtime DLL staging is the host's job (see rexglue_configure_target).
#==========================================================
function(rexglue_apply_target_settings target_name)
    if(UNIX AND NOT APPLE)
        # Large executable support
        if(CMAKE_SYSTEM_PROCESSOR MATCHES "x86_64|AMD64")
            target_link_options(${target_name} PRIVATE -Wl,--no-relax)
            target_compile_options(${target_name} PRIVATE -mcmodel=large)
        elseif(ANDROID)
            # armv8-a by default, for ARMv8.0 devices (e.g. Snapdragon 665 / Cortex-A73/A53) as well as newer
            # ones. REXGLUE_ANDROID_MARCH picks another (armv8.2-a: inline LSE atomics, for Snapdragon 845 and
            # newer).
            if(NOT REXGLUE_ANDROID_MARCH)
                set(REXGLUE_ANDROID_MARCH armv8-a)
            endif()
            target_compile_options(${target_name} PRIVATE -march=${REXGLUE_ANDROID_MARCH})
        elseif(CMAKE_SYSTEM_PROCESSOR MATCHES "aarch64|ARM64")
            target_compile_options(${target_name} PRIVATE -march=armv8-a)
        endif()
    endif()

    if(NOT MSVC)
        if(CMAKE_SYSTEM_PROCESSOR MATCHES "x86_64|AMD64")
            target_compile_options(${target_name} PRIVATE -msse4.1)
        endif()
    endif()
endfunction()

#==========================================================
# rexglue_configure_target(<target>) - Host application
#
# Adds:
#   - SDL3 entry point source (windowed_app_main_sdl.cpp)
#   - ReXApp base class source (rex_app.cpp)
#   - Build-config define for the version stamp
#   - $ORIGIN RPATH on UNIX so the host finds librexruntime.so next to itself
#   - Windows POST_BUILD copy of TARGET_RUNTIME_DLLS and the FidelityFX DLLs.
#     Guest modules colocate with the host (see rexglue_configure_module_target),
#     so this single copy handles them transitively.
#==========================================================
function(rexglue_configure_target target_name)
    cmake_parse_arguments(ARG "" "" "GPU_PLUGINS" ${ARGN})

    if(REXGLUE_PLATFORM_SWITCH)
        # Single static NRO: see cmake/rexglue_switch.cmake.
        rexglue_switch_configure_target(${target_name} ${ARGN})
        return()
    endif()

    target_sources(${target_name} PRIVATE
        ${REXGLUE_SHARE_DIR}/windowed_app_main_sdl.cpp
        ${REXGLUE_SHARE_DIR}/rex_app.cpp)

    target_compile_definitions(${target_name} PRIVATE
        REXGLUE_BUILD_CONFIG="$<CONFIG>")

    if(UNIX AND NOT APPLE)
        set_target_properties(${target_name} PROPERTIES
            INSTALL_RPATH "$ORIGIN"
            BUILD_WITH_INSTALL_RPATH ON
        )
    elseif(APPLE)
        # macOS analogue of $ORIGIN: resolve @rpath dylibs (librexruntime,
        # libTracyClient, ...) next to the executable. Pairs with the runtime
        # dylib staging below so the app is self-contained.
        set_target_properties(${target_name} PROPERTIES
            INSTALL_RPATH "@executable_path"
            BUILD_WITH_INSTALL_RPATH ON
        )
    endif()

    rexglue_apply_target_settings(${target_name})

    if(WIN32)
        # Stage runtime DLLs (rexruntime, TracyClient, etc.) next to the host
        # binary on every link. copy_if_different is a no-op when up to date.
        add_custom_command(TARGET ${target_name} POST_BUILD
            COMMAND "$<$<BOOL:$<TARGET_RUNTIME_DLLS:${target_name}>>:${CMAKE_COMMAND};-E;copy_if_different;$<TARGET_RUNTIME_DLLS:${target_name}>;$<TARGET_FILE_DIR:${target_name}>>"
            COMMAND_EXPAND_LISTS
            VERBATIM
        )
    elseif(APPLE AND NOT CMAKE_SYSTEM_NAME STREQUAL "iOS")
        # macOS: $<TARGET_RUNTIME_DLLS> does not resolve imported dylibs, so
        # stage the shared runtime libraries explicitly next to the executable
        # (paired with the @executable_path rpath above). Everything else the
        # runtime links (fmt, spdlog, SDL3, ...) is static. Target names
        # differ between an in-tree build and an installed SDK import.
        # iOS: everything is already static-linked into the .app, no staging.
        foreach(_rexglue_runtime_lib rex::runtime rexruntime rex::TracyClient TracyClient)
            if(TARGET ${_rexglue_runtime_lib})
                add_custom_command(TARGET ${target_name} POST_BUILD
                    COMMAND ${CMAKE_COMMAND} -E copy_if_different
                        $<TARGET_FILE:${_rexglue_runtime_lib}>
                        $<TARGET_FILE_DIR:${target_name}>
                    VERBATIM
                )
            endif()
        endforeach()
    endif()

    if(WIN32)
        # FidelityFX is linked PRIVATE by rexui (to avoid propagating DLL
        # requirements to tool-mode targets), so copy its DLLs explicitly.
        foreach(_fx amd_fidelityfx_vk amd_fidelityfx_dx12)
            if(TARGET ${_fx})
                add_custom_command(TARGET ${target_name} POST_BUILD
                    COMMAND ${CMAKE_COMMAND} -E copy_if_different
                        $<TARGET_FILE:${_fx}>
                        $<TARGET_FILE_DIR:${target_name}>
                    VERBATIM
                )
            endif()
        endforeach()
    endif()

    # Stage requested GPU emulation plugins next to the executable. Plugins
    # are runtime-loaded (never linked), so TARGET_RUNTIME_DLLS misses them.
    # iOS: plugins are statically linked into the app binary (see gpu_plugin_loader
    # fallback to rex_gpu_create), so skip the colocation copy.
    if(NOT CMAKE_SYSTEM_NAME STREQUAL "iOS")
        foreach(_plugin IN LISTS ARG_GPU_PLUGINS)
            if(TARGET rexgpu-${_plugin})
                # In-tree build: depend on it so it gets built.
                set(_plugin_target rexgpu-${_plugin})
                add_dependencies(${target_name} ${_plugin_target})
            elseif(TARGET rex::gpu-${_plugin})
                # Installed SDK import.
                set(_plugin_target rex::gpu-${_plugin})
            else()
                message(FATAL_ERROR
                    "rexglue_configure_target: unknown GPU plugin '${_plugin}' "
                    "(no target rexgpu-${_plugin} or rex::gpu-${_plugin})")
            endif()
            # A target of its own, not a POST_BUILD step of the executable: POST_BUILD only runs when
            # the executable relinks, so a rebuilt plugin was left stale next to it.
            add_custom_target(${target_name}_stage_gpu_${_plugin} ALL
                COMMAND ${CMAKE_COMMAND} -E copy_if_different
                    $<TARGET_FILE:${_plugin_target}>
                    $<TARGET_FILE_DIR:${target_name}>
                VERBATIM
            )
            if(TARGET rexgpu-${_plugin})
                add_dependencies(${target_name}_stage_gpu_${_plugin} rexgpu-${_plugin})
            endif()
            add_dependencies(${target_name}_stage_gpu_${_plugin} ${target_name})
            unset(_plugin_target)
        endforeach()
    else()
        # iOS: no runtime loading of signed dylibs, so the GPU plugin is linked
        # statically into the host. Force-load so its plugin_main.cpp
        # (rex_gpu_abi_version / rex_gpu_create exports) is pulled into the
        # final executable; the static-linked branch in gpu_plugin_loader.cpp
        # calls those entry points directly.
        foreach(_plugin IN LISTS ARG_GPU_PLUGINS)
            if(TARGET rexgpu-${_plugin})
                add_dependencies(${target_name} rexgpu-${_plugin})
                target_link_options(${target_name} PRIVATE
                    "LINKER:-force_load,$<TARGET_FILE:rexgpu-${_plugin}>")
                target_link_libraries(${target_name} PRIVATE rexgpu-${_plugin})
            endif()
        endforeach()
        # Static Vulkan loader + MoltenVK + Metal/IOSurface frameworks.
        # vulkan_instance.cpp on iOS takes vkGetInstanceProcAddr / vkDestroyInstance
        # directly, which must resolve at link time. MoltenVK provides them; the
        # loader's trampoline.o has them too but conflicts with MoltenVK's copy.
        # Link MoltenVK (force_load so static ctors + Objective-C categories fire),
        # add Metal / IOSurface / QuartzCore frameworks MoltenVK needs, skip the
        # Vulkan loader on iOS so we don't double-define the entries.
        if(TARGET MoltenVK)
            add_dependencies(${target_name} MoltenVK)
            target_link_options(${target_name} PRIVATE
                "LINKER:-force_load,$<TARGET_FILE:MoltenVK>")
            target_link_libraries(${target_name} PRIVATE MoltenVK)
        endif()
        target_link_libraries(${target_name} PRIVATE
            "-framework Metal"
            "-framework IOSurface"
            "-framework QuartzCore"
            "-framework Foundation"
            "-framework CoreGraphics"
            "-framework UIKit")
    endif()

    if(APPLE AND REXGLUE_USE_VULKAN AND NOT CMAKE_SYSTEM_NAME STREQUAL "iOS")
        _rexglue_stage_macos_vulkan_runtime(${target_name})
    endif()
endfunction()

#==========================================================
# rexglue_configure_module_target(<target> [HOST <host_target>])
#   - Guest DLL module
#
# Output is colocated with HOST (or CMAKE_RUNTIME_OUTPUT_DIRECTORY) so the
# host's LoadUserModule finds it; the host is wired to depend on the module
# so a top-level build of the host pulls in all guest DLLs. No runtime DLL
# staging here; the host's POST_BUILD copy covers shared dependencies.
#==========================================================
function(rexglue_configure_module_target target_name)
    cmake_parse_arguments(ARG "" "HOST" "" ${ARGN})

    if(ARG_HOST AND CMAKE_SYSTEM_NAME STREQUAL "iOS")
        # iOS: no unsigned shared libraries, so we cannot ship module .dylibs.
        # Convert the module library to STATIC, rename its C-level
        # ReXModule_Register / ReXModule_GetImageInfo to a per-module name to
        # avoid link-time collisions with sibling modules, emit a tiny .cpp
        # that registers the renamed symbols with the static-module table at
        # static init, and link the whole thing into the host.
        # The module is already declared STATIC on iOS (see dll_targets.cmake).
        string(MAKE_C_IDENTIFIER "${target_name}" _rxmod_sym)
        set(_rxmod_adaptor
            "${CMAKE_CURRENT_BINARY_DIR}/${target_name}_static_register.cpp")
        file(WRITE "${_rxmod_adaptor}" "// Auto-generated — do not edit.\n"
            "// iOS static module adaptor for ${target_name}.\n"
            "#include <rex/system/static_module_registry.h>\n"
            "#include <rex/image_info.h>\n"
            "#include <rex/system/function_dispatcher.h>\n\n"
            "extern \"C\" void ${_rxmod_sym}_ReXModule_Register(rex::runtime::IModuleRegistrar*);\n"
            "extern \"C\" const rex::PPCImageInfo* ${_rxmod_sym}_ReXModule_GetImageInfo();\n\n"
            "namespace {\n"
            "struct Registrar {\n"
            "  Registrar() {\n"
            "    rex::system::RegisterStaticModule(\n"
            "        \"${target_name}\",\n"
            "        rex::system::StaticModuleEntry{&${_rxmod_sym}_ReXModule_Register,\n"
            "                                      &${_rxmod_sym}_ReXModule_GetImageInfo});\n"
            "  }\n"
            "};\n"
            "Registrar g_registrar;\n"
            "}  // namespace\n")
        target_sources(${target_name} PRIVATE "${_rxmod_adaptor}")
        # Adaptor needs plain C++, not the module's PCH (fh2_pch.h).
        set_source_files_properties("${_rxmod_adaptor}" PROPERTIES
            SKIP_PRECOMPILE_HEADERS ON)
        target_compile_definitions(${target_name} PRIVATE
            "ReXModule_Register=${_rxmod_sym}_ReXModule_Register"
            "ReXModule_GetImageInfo=${_rxmod_sym}_ReXModule_GetImageInfo"
            # The module's per-image global data would otherwise collide with
            # the main recomp's identically-named globals (one strong def per
            # TU; all static-linked together on iOS). Rename per module.
            "PPCImageConfig=${_rxmod_sym}_PPCImageConfig"
            "PPCFuncMappings=${_rxmod_sym}_PPCFuncMappings"
        )
        # Prepend an override of DEFINE_REX_FUNC that makes `__imp__<name>`
        # weak, so the PPC helper definitions (`__savevmx_14`, ...) that the
        # codegen emits into every module do not collide on static link.
        # Thread it through target_precompile_headers so the extra include is
        # part of the PCH itself — adding it as -include on sources instead
        # produces a PCH-flag-hash mismatch and the PCH fails to load.
        target_precompile_headers(${target_name} PRIVATE
            "${CMAKE_CURRENT_FUNCTION_LIST_DIR}/../include/rex/ios_module_weak.h")
        # The PPC register save/restore helpers (__savegprlr_NN etc.) must stay
        # private to each module: the main recomp is generated with
        # REX_CONFIG_NON_VOLATILE_AS_LOCAL so its copies are no-ops, while the
        # module's copies really touch ctx.rNN. Rename them per module so the
        # static link can't let main's no-op shadow the module's working one.
        set(_rxmod_rename "${CMAKE_CURRENT_BINARY_DIR}/${target_name}_rename_helpers.h")
        # `xstart` is the codegen's name for every image's entry point: without
        # this the main exe's strong xstart wins and the module's DllMain jumps
        # into the game's own entry (re-runs title init, blocks forever).
        set(_rxmod_rename_body "// Auto-generated per-module PPC helper renames.\n#pragma once\n#define xstart ${_rxmod_sym}_xstart\n")
        foreach(_k gprlr fpr vmx)
            foreach(_n RANGE 14 31)
                string(APPEND _rxmod_rename_body
                    "#define __save${_k}_${_n} ${_rxmod_sym}___save${_k}_${_n}\n"
                    "#define __rest${_k}_${_n} ${_rxmod_sym}___rest${_k}_${_n}\n")
            endforeach()
        endforeach()
        foreach(_n RANGE 64 127)
            string(APPEND _rxmod_rename_body
                "#define __savevmx_${_n} ${_rxmod_sym}___savevmx_${_n}\n"
                "#define __restvmx_${_n} ${_rxmod_sym}___restvmx_${_n}\n")
        endforeach()
        file(WRITE "${_rxmod_rename}" "${_rxmod_rename_body}")
        target_precompile_headers(${target_name} PRIVATE "${_rxmod_rename}")
        # The host target may be declared after this call (dll_targets.cmake is
        # included before add_executable). Defer link_options and link_libraries
        # so they are applied once the host target exists.
        cmake_language(EVAL CODE
            "cmake_language(DEFER CALL target_link_options ${ARG_HOST} PRIVATE
                \"LINKER:-force_load,$<TARGET_FILE:${target_name}>\")")
        cmake_language(EVAL CODE
            "cmake_language(DEFER CALL target_link_libraries ${ARG_HOST} PRIVATE ${target_name})")
        set_target_properties(${target_name} PROPERTIES
            XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED "NO"
            XCODE_ATTRIBUTE_CODE_SIGN_IDENTITY ""
        )
        cmake_language(EVAL CODE
            "cmake_language(DEFER CALL add_dependencies ${ARG_HOST} ${target_name})")
    elseif(ARG_HOST)
        set_target_properties(${target_name} PROPERTIES
            LIBRARY_OUTPUT_DIRECTORY $<TARGET_FILE_DIR:${ARG_HOST}>
            RUNTIME_OUTPUT_DIRECTORY $<TARGET_FILE_DIR:${ARG_HOST}>
            ARCHIVE_OUTPUT_DIRECTORY $<TARGET_FILE_DIR:${ARG_HOST}>
        )
        # Defer add_dependencies so the host target may be declared after
        # this module call. Wrapping in EVAL CODE expands the variables now,
        # which DEFER CALL otherwise treats as literal argument text.
        cmake_language(EVAL CODE
            "cmake_language(DEFER CALL add_dependencies ${ARG_HOST} ${target_name})")
    elseif(CMAKE_RUNTIME_OUTPUT_DIRECTORY)
        set_target_properties(${target_name} PROPERTIES
            LIBRARY_OUTPUT_DIRECTORY ${CMAKE_RUNTIME_OUTPUT_DIRECTORY}
            RUNTIME_OUTPUT_DIRECTORY ${CMAKE_RUNTIME_OUTPUT_DIRECTORY}
            ARCHIVE_OUTPUT_DIRECTORY ${CMAKE_RUNTIME_OUTPUT_DIRECTORY}
        )
    endif()

    if(UNIX AND NOT APPLE)
        set_target_properties(${target_name} PROPERTIES
            INSTALL_RPATH "$ORIGIN"
            BUILD_WITH_INSTALL_RPATH ON
        )
    endif()

    rexglue_apply_target_settings(${target_name})
endfunction()

#==========================================================
# rexglue_embed_metadata(<target> DIRECTORY <dir> [PREFIX <relative-prefix>])
#
# Embeds files into the host executable as metadata assets. Runtime lookups use
# paths relative to the metadata root, so embedding metadata/icons with PREFIX
# icons makes "icons/foo.png" resolve without a loose sidecar file.
#==========================================================
function(rexglue_embed_metadata target_name)
    cmake_parse_arguments(ARG "" "DIRECTORY;PREFIX" "" ${ARGN})

    if(NOT TARGET ${target_name})
        message(FATAL_ERROR "rexglue_embed_metadata: target '${target_name}' does not exist")
    endif()
    if(NOT ARG_DIRECTORY)
        message(FATAL_ERROR "rexglue_embed_metadata: DIRECTORY is required")
    endif()
    if(NOT IS_DIRECTORY "${ARG_DIRECTORY}")
        message(FATAL_ERROR "rexglue_embed_metadata: '${ARG_DIRECTORY}' is not a directory")
    endif()

    file(GLOB_RECURSE _rexglue_metadata_files
        CONFIGURE_DEPENDS
        "${ARG_DIRECTORY}/*")

    set(_rexglue_regular_files)
    foreach(_rexglue_file IN LISTS _rexglue_metadata_files)
        if(NOT IS_DIRECTORY "${_rexglue_file}")
            list(APPEND _rexglue_regular_files "${_rexglue_file}")
        endif()
    endforeach()

    if(NOT _rexglue_regular_files)
        message(STATUS "rexglue_embed_metadata: no files found in ${ARG_DIRECTORY}")
        return()
    endif()

    string(MAKE_C_IDENTIFIER "${target_name}" _rexglue_target_id)
    set(_rexglue_output_dir "${CMAKE_CURRENT_BINARY_DIR}/rexglue_embedded_metadata")
    set(_rexglue_output "${_rexglue_output_dir}/${_rexglue_target_id}_embedded_metadata.cpp")
    file(MAKE_DIRECTORY "${_rexglue_output_dir}")

    set(_rexglue_content "// Auto-generated by rexglue_embed_metadata - DO NOT EDIT\n")
    string(APPEND _rexglue_content
        "#include <cstddef>\n"
        "#include <cstdint>\n"
        "#include <rex/embedded_metadata.h>\n\n"
        "namespace {\n\n")

    set(_rexglue_count 0)
    foreach(_rexglue_file IN LISTS _rexglue_regular_files)
        file(RELATIVE_PATH _rexglue_rel "${ARG_DIRECTORY}" "${_rexglue_file}")
        string(REPLACE "\\" "/" _rexglue_rel "${_rexglue_rel}")
        if(ARG_PREFIX)
            string(REPLACE "\\" "/" _rexglue_prefix "${ARG_PREFIX}")
            string(REGEX REPLACE "/$" "" _rexglue_prefix "${_rexglue_prefix}")
            set(_rexglue_asset_path "${_rexglue_prefix}/${_rexglue_rel}")
        else()
            set(_rexglue_asset_path "${_rexglue_rel}")
        endif()
        string(REPLACE "\"" "\\\"" _rexglue_asset_path "${_rexglue_asset_path}")

        string(MD5 _rexglue_asset_id "${_rexglue_asset_path}")
        file(READ "${_rexglue_file}" _rexglue_hex HEX)
        string(REGEX REPLACE "([0-9A-Fa-f][0-9A-Fa-f])" "0x\\1," _rexglue_bytes "${_rexglue_hex}")

        string(APPEND _rexglue_content
            "const std::uint8_t kAsset_${_rexglue_asset_id}[] = {${_rexglue_bytes}};\n"
            "const bool kRegistered_${_rexglue_asset_id} = "
            "::rex::RegisterEmbeddedMetadataAsset(\"${_rexglue_asset_path}\", "
            "kAsset_${_rexglue_asset_id}, sizeof(kAsset_${_rexglue_asset_id}));\n\n")
        math(EXPR _rexglue_count "${_rexglue_count} + 1")
    endforeach()

    string(APPEND _rexglue_content "}  // namespace\n")
    file(WRITE "${_rexglue_output}" "${_rexglue_content}")
    target_sources(${target_name} PRIVATE "${_rexglue_output}")
    message(STATUS "Embedded ${_rexglue_count} metadata asset(s) into ${target_name}")
endfunction()
