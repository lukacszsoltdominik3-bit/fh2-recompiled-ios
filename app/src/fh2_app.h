// fh2 - ReXGlue Recompiled Project
//
// Customize your app by overriding virtual hooks from rex::ReXApp.

#pragma once

#include <cstdio>
#include <filesystem>

#include <rex/cvar.h>
#include <rex/rex_app.h>

#include <rex/ui/presenter.h>

#include "fh2_captura.h"
#include "fh2_teste_entrada.h"
#if REX_PLATFORM_IOS
#include "fh2_touch_pad.h"
#endif
#include "nfsmw_ajustes_graficos.h"
#include "nfsmw_nativo_sistema.h"

#if REX_PLATFORM_ANDROID
// android/app/src/main/cpp/android_rendimiento.cpp: keeps the game threads off the slow cores.
extern "C" void fh2_android_nucleos_grandes_aplicar();
extern "C" void fh2_android_afinidade_iniciar();
#endif

void Fh2PerfilStart();  // fh2_perfil.cpp
void Fh2MundoAplicar(rex::Runtime* runtime);  // fh2_mundo.cpp

class Fh2App : public rex::ReXApp {
 public:
  using rex::ReXApp::ReXApp;

  static std::unique_ptr<rex::ui::WindowedApp> Create(
      rex::ui::WindowedAppContext& ctx) {
    return std::unique_ptr<Fh2App>(new Fh2App(ctx, "fh2",
        PPCImageConfig));
  }

  // Override virtual hooks for customization:
  // void OnPostInitLogging() override {}
  void OnPreSetup(rex::RuntimeConfig& config) override {
    // The game needs the console's cache partition: after the first race it creates
    // cache:\replay_stream (rewind / replays), and without the partition it hangs on the loading
    // screen reading a null pointer. Mounted on user/cache_partition.
    rex::cvar::SetFlagByName("mount_cache", "true");
#if REX_PLATFORM_IOS
    // iOS defaults: applied only when the config file (Documents/fh2/fh2.toml) doesn't set the
    // option, so each can still be changed there for tests.
    auto set_default = [](const char* name, const char* value) {
      if (!rex::cvar::HasNonDefaultValue(name)) {
        rex::cvar::SetFlagByName(name, value);
      }
    };
    // protect_zero left at its default (true) — the XMediaFacade null poll it once papered over
    // was the xstart symbol collision, now fixed; a readable page 0 hides real null reads.
    // FH2's world shaders reference vertex fetch slot 90 left as (00000001 00000000), the
    // "invalid vertex" type. Real Xenos tolerates it; the emulator otherwise drops the whole
    // draw, so gameplay renders the HUD over a black world.
    set_default("gpu_allow_invalid_fetch_constants", "true");
    // Phone config: draw MSAA targets with one sample so the scene fits one EDRAM tile and
    // fh2_uma_faixa replays it once instead of three times (~4200 -> ~1900 draws in a race).
    // Also avoids the 3-tile MSAA path, suspected of the black 3D world under MoltenVK.
    set_default("gpu_sin_msaa", "true");
    // The Autoshow (car select) convolves the environment cube map that lights the car paint
    // with pixel shader F757969C048876FB: tfetchCube inside nested 64x64 guest loops. At the full
    // count that draw hung the Apple GPU (device lost right after choosing a car); skipping it
    // left most paint colors black. Capping its loops at 16x16 samples keeps the lighting and
    // runs fine (confirmed 2026-11-13: car select, color select, races).
    set_default("gpu_limitar_lacos", "F757969C048876FB:16");
    // Auto exposure: the game reads the 32x32 float average luminance it resolves every frame
    // (1FCA6000, 4 KB) on the CPU. Without resolve readback the CPU sees a stale value and the
    // whole picture (most visibly the sky) is far too bright; with readback of everything the
    // 1280x720 targets stall every frame (~7 fps), and even all resolves up to 4 KB were ~40
    // GPU waits a frame (9 fps), and even that one alone with "full" waited 65 ms a frame.
    // Read back only that one (k_32_FLOAT, format 36, up to 4 KB), one frame late ("fast": no
    // wait; the exposure adapts over many frames anyway).
    set_default("readback_resolve", "fast");
    set_default("readback_resolve_max_bytes", "4096");
    set_default("readback_resolve_formato", "36");
    // Car reflection cube: the game redraws all 6 faces (and their mips) every frame. 2 faces
    // a frame refreshes the whole cube every 3 frames - measured ~10% faster on Android with
    // reflections looking the same (fh2_desempenho.cpp).
    set_default("fh2_reflexo_faces", "2");
    // Phone world detail (fh2_mundo.cpp; read from TrackSettings.xml at start): half the meshes
    // and distance in the live car reflection, and half the crowd - fewer draws for the game's
    // render thread, the command processor and MoltenVK alike. Level of detail and shadow
    // distance stay at the Xbox 360's (what the eye notices on the road).
    set_default("fh2_mundo_reflexos", "0.5");
    set_default("fh2_mundo_multidao", "0.5");
    // Anti-aliasing: MSAA is capped at one sample (gpu_sin_msaa) for speed, so smooth the edges
    // with FXAA on the final image instead (one compute pass at the swap; no measurable CPU cost).
    set_default("swap_post_effect", "fxaa");
    // Occlusion queries (sun / light visibility for flares) without a CPU-GPU sync: each one ended the
    // submission and waited for the whole GPU queue - ~40 ms a frame on the iPhone with the sun in view.
    // The game gets the previous result of the query (a frame late), vulkan/command_processor.cpp.
    set_default("occlusion_query_assincrono", "true");
    // Copies of guest memory the CPU changed (~360 a frame, ~15 MB) at the start of each submission instead of
    // each ending the render pass (vulkan/shared_memory.cpp; only pages no earlier command of the submission
    // touched, so every draw sees the same data as before).
    set_default("gpu_uploads_antecipados", "true");
    // A pipeline seen for the first time in play is built in the background and its draws are
    // skipped until then (vulkan/pipeline_cache.cpp, no synchronous placeholder): keep presenting
    // those frames - an object pops in a moment late instead of the picture freezing.
    set_default("vulkan_async_skip_incomplete_frames", "false");
    // Mute button of the touch overlay: its last choice (Documents/fh2/mudo) applies at start.
    {
      if (FILE* file = std::fopen("fh2/mudo", "rb")) {
        if (std::fgetc(file) == '1') {
          set_default("audio_mute", "true");
        }
        std::fclose(file);
      }
    }
    // Dropping a file named "clear_shaders" into Documents/fh2/ (devicectl copy to) wipes the
    // translated shader/pipeline storage on the next launch, so translator test options apply.
    {
      std::error_code ec;
      if (std::filesystem::exists("fh2/clear_shaders", ec)) {
        std::filesystem::remove_all("fh2/cache/shaders", ec);
        std::filesystem::remove("fh2/clear_shaders", ec);
        REXLOG_INFO("[fh2] shader storage cleared (fh2/clear_shaders)");
      }
    }
#endif
#if REX_PLATFORM_ANDROID
    fh2_android_nucleos_grandes_aplicar();
#endif
    // Native renderer (src/nativo, docs/renderizador_nativo.md): with nfsmw_renderizador = nativo the graphics
    // system is its own and the GPU emulation plugin is not loaded (ReXApp only loads it when config.graphics is
    // empty). The default is still the emulation.
    if (nfsmw::nativo::Activo()) {
      config.graphics = nfsmw::nativo::CrearSistemaGrafico();
      // FXAA (nfsmw_antialiasing) and the optional post-processing reach the output pass through these atomics.
      // NFSMW sets them up in its app; without this call the launcher's FXAA never switched on here.
      nfsmw::ajustes::VigilarAjustesEnVivo();
    }
    fh2::teste::EnvolverEntrada(config);
#if REX_PLATFORM_IOS
    fh2::toque::EnvolverEntrada(config);
#endif
  }
  // void OnLoadXexImage(std::string& xex_image) override {}
  // void OnPostLoadXexImage() override {}
  void OnPostSetup() override {
    Fh2PerfilStart();  // fh2_perfil.cpp, off unless fh2_perfil_s is set
    // Grass, objects, reflections, shadows and crowd at the launcher's factors (fh2_mundo_*), before the game runs.
    Fh2MundoAplicar(runtime());
#if REX_PLATFORM_ANDROID
    fh2_android_afinidade_iniciar();  // android_rendimiento.cpp, off unless fh2_android_afinidade is set
#endif
    // PNG captures of the game image for unattended tests (fh2_captura_cada_s; off by default).
    fh2::captura::Arrancar([this]() -> rex::ui::Presenter* {
      const auto* rt = runtime();
      const auto* graphics = rt ? rt->graphics_system() : nullptr;
      return graphics ? graphics->presenter() : nullptr;
    });
  }
  // void OnCreateDialogs(rex::ui::ImGuiDrawer* drawer) override {}
  // std::unique_ptr<rex::ui::ImGuiDialog> CreateAchievementsOverlay() override;
  // std::unique_ptr<rex::ui::AchievementNotificationDialog>
  // CreateAchievementNotificationDialog() override;
  void OnShutdown() override { fh2::captura::Parar(); }
  // void OnConfigurePaths(rex::PathConfig& paths) override {}
};
