// fh2 iOS touch controls: the C bridge between the UIKit overlay
// (ios/fh2_touch_controls.mm) and the virtual gamepad input driver
// (src/fh2_touch_pad.cpp). Host-endian XInput-style values.
#pragma once
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct fh2_touch_pad {
  uint16_t buttons;  // XINPUT_GAMEPAD_* bits
  uint8_t left_trigger, right_trigger;
  int16_t lx, ly, rx, ry;
} fh2_touch_pad;

// Overlay side (main thread).
void fh2_touch_store(fh2_touch_pad state);
// Driver side (any thread). Returns the state and a packet number that
// changes whenever the state does.
fh2_touch_pad fh2_touch_load(uint32_t* packet);
// Adds the overlay to the app window once it exists (safe to call early,
// from any thread; retries until UIKit has a window).
void fh2_touch_install(void);
// Game audio on/off for the overlay's mute button (audio_mute, live). The choice
// is remembered in Documents/fh2/mudo and applied at the next start.
int fh2_audio_is_muted(void);
int fh2_audio_toggle_mute(void);  // returns the new state (1 = muted)

#ifdef __cplusplus
}
#endif
