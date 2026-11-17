// fh2 - iOS on-screen touch gamepad (overlay: ios/fh2_touch_controls.mm).
#pragma once

#include <rex/runtime.h>

namespace fh2::toque {

// Wraps config.input_factory to add the touch pad as a user-0 device and
// installs the UIKit overlay. Call in OnPreSetup after the default factory.
void EnvolverEntrada(rex::RuntimeConfig& config);

}  // namespace fh2::toque
