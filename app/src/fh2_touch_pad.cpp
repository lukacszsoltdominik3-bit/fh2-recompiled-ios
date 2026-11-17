// fh2 - iOS on-screen touch gamepad: an input driver that exposes the UIKit
// overlay's state (ios/fh2_touch_controls.mm, via fh2_touch_bridge.h) as one
// more user-0 pad. The input system merges it with any real controller.

#include "fh2_touch_pad.h"

#include <rex/input/input.h>
#include <rex/input/input_driver.h>
#include <rex/input/input_system.h>
#include <rex/logging.h>

#include <cstdio>
#include <cstring>
#include <string>

#include <rex/cvar.h>
#include <deque>
#include <mutex>

#include "fh2_touch_bridge.h"

namespace fh2::toque {
namespace {

using rex::X_RESULT;
using rex::X_STATUS;
namespace in = rex::input;

constexpr in::DeviceId kTouchPad = in::DeviceId(0x4648325450414400ull);  // "FH2TPAD"

struct Key {
  uint16_t bit;
  uint16_t vk;
};
constexpr Key kKeys[] = {
    {0x1000, 0x5800}, {0x2000, 0x5801}, {0x4000, 0x5802}, {0x8000, 0x5803},
    {0x0200, 0x5804}, {0x0100, 0x5805}, {0x0001, 0x5810}, {0x0002, 0x5811},
    {0x0004, 0x5812}, {0x0008, 0x5813}, {0x0010, 0x5814}, {0x0020, 0x5815},
    {0x0040, 0x5816}, {0x0080, 0x5817},
};

class TouchPad final : public in::InputDriver {
 public:
  TouchPad() : InputDriver(nullptr, 0) {}

  X_STATUS Setup() override { return X_STATUS_SUCCESS; }

  void EnumerateDevices(std::vector<in::DeviceInfo>& out) override {
    in::DeviceInfo info;
    info.id = kTouchPad;
    info.name = "Touch controls";
    info.synthetic = true;
    out.push_back(info);
  }

  X_RESULT GetDeviceState(in::DeviceId id, in::X_INPUT_STATE* out) override {
    if (id != kTouchPad) return X_ERROR_DEVICE_NOT_CONNECTED;
    uint32_t packet = 0;
    const fh2_touch_pad s = Poll(packet);
    if (out) {
      std::memset(out, 0, sizeof(*out));
      out->packet_number = packet;
      out->gamepad.buttons = s.buttons;
      out->gamepad.left_trigger = s.left_trigger;
      out->gamepad.right_trigger = s.right_trigger;
      out->gamepad.thumb_lx = s.lx;
      out->gamepad.thumb_ly = s.ly;
      out->gamepad.thumb_rx = s.rx;
      out->gamepad.thumb_ry = s.ry;
    }
    return X_ERROR_SUCCESS;
  }

  X_RESULT GetDeviceCapabilities(in::DeviceId id, uint32_t, in::X_INPUT_CAPABILITIES* caps) override {
    if (id != kTouchPad) return X_ERROR_DEVICE_NOT_CONNECTED;
    if (caps) {
      std::memset(caps, 0, sizeof(*caps));
      caps->type = 0x01;
      caps->sub_type = 0x01;
      caps->gamepad.buttons = 0xFFFF;
      caps->gamepad.left_trigger = 0xFF;
      caps->gamepad.right_trigger = 0xFF;
      caps->gamepad.thumb_lx = static_cast<int16_t>(0x7FFF);
      caps->gamepad.thumb_ly = static_cast<int16_t>(0x7FFF);
      caps->gamepad.thumb_rx = static_cast<int16_t>(0x7FFF);
      caps->gamepad.thumb_ry = static_cast<int16_t>(0x7FFF);
    }
    return X_ERROR_SUCCESS;
  }

  X_RESULT SetDeviceVibration(in::DeviceId id, in::X_INPUT_VIBRATION*) override {
    return id == kTouchPad ? X_ERROR_SUCCESS : X_ERROR_DEVICE_NOT_CONNECTED;
  }

  X_RESULT GetDeviceKeystroke(in::DeviceId id, uint32_t, in::X_INPUT_KEYSTROKE* out) override {
    if (id != kTouchPad) return X_ERROR_DEVICE_NOT_CONNECTED;
    uint32_t packet = 0;
    Poll(packet);
    std::lock_guard<std::mutex> lock(mutex_);
    if (keys_.empty()) return X_ERROR_EMPTY;
    if (out) *out = keys_.front();
    keys_.pop_front();
    return X_ERROR_SUCCESS;
  }

 private:
  // Reads the overlay state and queues keystrokes for button edges (menus
  // that use XInputGetKeystroke instead of polling).
  fh2_touch_pad Poll(uint32_t& packet) {
    const fh2_touch_pad s = fh2_touch_load(&packet);
    std::lock_guard<std::mutex> lock(mutex_);
    if (s.buttons != last_buttons_) {
      for (const Key& k : kKeys) {
        const bool before = (last_buttons_ & k.bit) != 0, now = (s.buttons & k.bit) != 0;
        if (before == now) continue;
        in::X_INPUT_KEYSTROKE key{};
        key.virtual_key = k.vk;
        key.flags = uint16_t(now ? in::X_INPUT_KEYSTROKE_KEYDOWN : in::X_INPUT_KEYSTROKE_KEYUP);
        if (keys_.size() < 64) keys_.push_back(key);
      }
      last_buttons_ = s.buttons;
    }
    return s;
  }

  std::mutex mutex_;
  uint16_t last_buttons_ = 0;
  std::deque<in::X_INPUT_KEYSTROKE> keys_;
};

}  // namespace

void EnvolverEntrada(rex::RuntimeConfig& config) {
  if (!config.input_factory) return;
  auto base = config.input_factory;
  config.input_factory = [base](bool tool_mode) -> std::unique_ptr<rex::system::IInputSystem> {
    auto system = base(tool_mode);
    if (system && !tool_mode) {
      static_cast<in::InputSystem*>(system.get())->AddDriver(std::make_unique<TouchPad>());
      fh2_touch_install();
      REXLOG_INFO("[toque] touch gamepad added");
    }
    return system;
  };
}

}  // namespace fh2::toque


// Overlay mute button (ios/fh2_touch_controls.mm): flips audio_mute, which the SDL audio driver
// reads on every callback, and remembers the choice for the next start (fh2_app.h reads it).
extern "C" int fh2_audio_is_muted(void) {
  return rex::cvar::GetFlagByName("audio_mute") == "true" ? 1 : 0;
}

extern "C" int fh2_audio_toggle_mute(void) {
  const int muted = fh2_audio_is_muted() ? 0 : 1;
  rex::cvar::SetFlagByName("audio_mute", muted ? "true" : "false");
  if (FILE* file = std::fopen("fh2/mudo", "wb")) {
    std::fputc(muted ? '1' : '0', file);
    std::fclose(file);
  }
  REXLOG_INFO("[fh2] audio {}", muted ? "muted" : "on");
  return muted;
}
