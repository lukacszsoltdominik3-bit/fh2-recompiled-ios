// fh2 iOS touch controls: a racing-first UIKit overlay on top of SDL's view.
//
// Left thumb: floating steering stick (spawns under the thumb in the lower-left)
// plus a small D-pad for menus. Right thumb: large GAS (RT) and BRAKE (LT)
// pedals with the A/B/X/Y diamond above them. Shoulders/Back/Start along the
// top. Dragging on empty space elsewhere moves the camera (right stick).
// Touch capture and look-delta handling follow Theft4's overlay (itself adapted
// from XeniOS, BSD-3-Clause).
#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>
#include <math.h>
#include <string.h>
#include <atomic>
#include <mutex>

// Guest frame rate, refreshed every 0.5 s by the Vulkan command processor
// (sdk/src/graphics/vulkan/command_processor.cpp); -1 until the first frame.
extern "C" std::atomic<float> rex_fps_guest;

#include "fh2_touch_bridge.h"

// ---- bridge storage ---------------------------------------------------------
static std::mutex g_touch_mutex;
static fh2_touch_pad g_touch_state;
static uint32_t g_touch_packet = 1;

extern "C" void fh2_touch_store(fh2_touch_pad state) {
  std::lock_guard<std::mutex> lock(g_touch_mutex);
  if (memcmp(&state, &g_touch_state, sizeof(state)) != 0) {
    g_touch_state = state;
    ++g_touch_packet;
  }
}

extern "C" fh2_touch_pad fh2_touch_load(uint32_t* packet) {
  std::lock_guard<std::mutex> lock(g_touch_mutex);
  if (packet) *packet = g_touch_packet;
  return g_touch_state;
}

// ---- layout -----------------------------------------------------------------
// Normalised to the safe area: x/w are fractions of its width, y/h of its height.
enum ControlKind { kButton, kTrigger, kPedalGas, kPedalBrake };
typedef struct {
  const char* label;
  CGFloat x, y, w, h;
  uint16_t button;
  int kind;
  uint32_t tint;  // 0xRRGGBB border, 0 = white
} PadControl;

static const PadControl kControls[] = {
    // Right thumb: pedals and face buttons.
    {"GAS", .875, .44, .105, .48, 0, kPedalGas, 0x4CD964},
    {"BRAKE", .755, .60, .105, .32, 0, kPedalBrake, 0xFF3B30},
    {"Y", .785, .11, .060, .105, 0x8000, kButton, 0xFFCC00},
    {"X", .728, .245, .060, .105, 0x4000, kButton, 0x0A84FF},
    {"B", .842, .245, .060, .105, 0x2000, kButton, 0xFF3B30},
    {"A", .785, .38, .060, .105, 0x1000, kButton, 0x4CD964},
    // Shoulders and system buttons.
    {"LB", .020, .04, .090, .100, 0x0100, kButton, 0},
    {"RB", .890, .04, .090, .100, 0x0200, kButton, 0},
    {"BACK", .395, .035, .085, .095, 0x0020, kButton, 0},
    {"START", .520, .035, .085, .095, 0x0010, kButton, 0},
    {"L3", .125, .04, .055, .095, 0x0040, kButton, 0},
    {"R3", .655, .04, .055, .095, 0x0080, kButton, 0},
    // D-pad (menus, rewind, telemetry).
    {"▲", .185, .20, .055, .095, 0x0001, kButton, 0},
    {"▼", .185, .40, .055, .095, 0x0002, kButton, 0},
    {"◀", .130, .30, .055, .095, 0x0004, kButton, 0},
    {"▶", .240, .30, .055, .095, 0x0008, kButton, 0},
};
static const NSInteger kControlCount = sizeof(kControls) / sizeof(kControls[0]);

// Floating steering stick lives in this region (fractions of the safe area).
static const CGFloat kSteerMaxX = .45, kSteerMinY = .50;
// Stick radius as a fraction of the safe-area height.
static const CGFloat kStickRadius = .17;
static const NSInteger kCaptureLook = -1, kCaptureStick = -2;

static UIColor* Tint(uint32_t rgb, CGFloat alpha) {
  if (!rgb) return [UIColor colorWithWhite:1 alpha:alpha];
  return [UIColor colorWithRed:((rgb >> 16) & 0xFF) / 255.0
                         green:((rgb >> 8) & 0xFF) / 255.0
                          blue:(rgb & 0xFF) / 255.0
                         alpha:alpha];
}

@interface Fh2TouchControls : UIView
@end

@implementation Fh2TouchControls {
  NSMutableArray<UILabel*>* _labels;
  NSMapTable<UITouch*, NSNumber*>* _captures;
  UIView* _stickBase;
  UIView* _stickKnob;
  CGPoint _stickRest;    // resting centre (drawn when idle)
  CGPoint _stickCenter;  // centre of the active stick
  NSTimer* _timer;
  CGPoint _lookDelta;
  int16_t _lookX, _lookY;
  CFTimeInterval _lastTick;
  uint16_t _lastButtons;
  UIImpactFeedbackGenerator* _haptic;
  UILabel* _fps;
  CFTimeInterval _fpsShownAt;
  UILabel* _mute;  // game audio on/off (not a pad button)
}

- (instancetype)initWithFrame:(CGRect)frame {
  if ((self = [super initWithFrame:frame])) {
    self.multipleTouchEnabled = YES;
    self.backgroundColor = UIColor.clearColor;
    self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _captures = [NSMapTable strongToStrongObjectsMapTable];
    _labels = [NSMutableArray new];
    for (NSInteger i = 0; i < kControlCount; ++i) {
      const PadControl& c = kControls[i];
      UILabel* label = [UILabel new];
      label.text = [NSString stringWithUTF8String:c.label];
      label.textAlignment = NSTextAlignmentCenter;
      label.font = [UIFont systemFontOfSize:(c.kind == kButton ? 16 : 15)
                                     weight:UIFontWeightBold];
      label.adjustsFontSizeToFitWidth = YES;
      label.minimumScaleFactor = .5;
      label.textColor = [UIColor colorWithWhite:1 alpha:.9];
      label.backgroundColor = [UIColor colorWithWhite:0 alpha:.22];
      label.layer.borderColor = Tint(c.tint, .6).CGColor;
      label.layer.borderWidth = 2;
      label.layer.masksToBounds = YES;
      label.userInteractionEnabled = NO;
      [_labels addObject:label];
      [self addSubview:label];
    }
    _mute = [UILabel new];
    _mute.textAlignment = NSTextAlignmentCenter;
    _mute.font = [UIFont systemFontOfSize:18];
    _mute.backgroundColor = [UIColor colorWithWhite:0 alpha:.22];
    _mute.layer.borderColor = [UIColor colorWithWhite:1 alpha:.6].CGColor;
    _mute.layer.borderWidth = 2;
    _mute.layer.masksToBounds = YES;
    _mute.userInteractionEnabled = NO;
    _mute.text = fh2_audio_is_muted() ? @"🔇" : @"🔊";
    [self addSubview:_mute];
    _stickBase = [UIView new];
    _stickBase.userInteractionEnabled = NO;
    _stickBase.backgroundColor = [UIColor colorWithWhite:0 alpha:.18];
    _stickBase.layer.borderColor = [UIColor colorWithWhite:1 alpha:.45].CGColor;
    _stickBase.layer.borderWidth = 2;
    [self addSubview:_stickBase];
    _stickKnob = [UIView new];
    _stickKnob.userInteractionEnabled = NO;
    _stickKnob.backgroundColor = [UIColor colorWithWhite:1 alpha:.35];
    [self addSubview:_stickKnob];
    _haptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [_haptic prepare];
    _fps = [UILabel new];
    _fps.userInteractionEnabled = NO;
    _fps.textAlignment = NSTextAlignmentCenter;
    _fps.font = [UIFont monospacedDigitSystemFontOfSize:15 weight:UIFontWeightBold];
    _fps.textColor = UIColor.whiteColor;
    _fps.backgroundColor = [UIColor colorWithWhite:0 alpha:.45];
    _fps.layer.cornerRadius = 8;
    _fps.layer.masksToBounds = YES;
    _fps.text = @"-- FPS";
    [self addSubview:_fps];

    __weak Fh2TouchControls* weakSelf = self;
    _lastTick = CACurrentMediaTime();
    _timer = [NSTimer timerWithTimeInterval:1.0 / 60.0
                                    repeats:YES
                                      block:^(NSTimer*) { [weakSelf tick]; }];
    [NSRunLoop.mainRunLoop addTimer:_timer forMode:NSRunLoopCommonModes];
  }
  return self;
}

- (void)dealloc {
  [_timer invalidate];
}

- (CGRect)area {
  return UIEdgeInsetsInsetRect(self.bounds, self.safeAreaInsets);
}

- (CGFloat)stickRadius {
  return MAX(40, kStickRadius * self.area.size.height);
}

- (void)layoutSubviews {
  [super layoutSubviews];
  [self releaseAllTouches];
  CGRect a = self.area;
  for (NSInteger i = 0; i < kControlCount; ++i) {
    const PadControl& c = kControls[i];
    CGFloat w = MAX(40, c.w * a.size.width), h = MAX(40, c.h * a.size.height);
    if (c.kind == kButton && c.button >= 0x1000) w = h = MIN(w, h);  // round face buttons
    _labels[i].frame = CGRectMake(a.origin.x + c.x * a.size.width,
                                  a.origin.y + c.y * a.size.height, w, h);
    _labels[i].layer.cornerRadius =
        (c.kind == kButton && c.button >= 0x1000) ? w / 2 : MIN(w, h) / 4;
  }
  {
    // Mute button: top row, between L3 and BACK.
    CGFloat side = MAX(40, MIN(.060 * a.size.width, .095 * a.size.height));
    _mute.frame = CGRectMake(a.origin.x + .27 * a.size.width, a.origin.y + .035 * a.size.height,
                             side, side);
    _mute.layer.cornerRadius = side / 4;
  }
  CGFloat r = self.stickRadius;
  _stickRest = CGPointMake(a.origin.x + .045 * a.size.width + r,
                           a.origin.y + a.size.height - .06 * a.size.height - r);
  _stickBase.bounds = CGRectMake(0, 0, 2 * r, 2 * r);
  _stickBase.layer.cornerRadius = r;
  CGFloat k = r * .8;
  _stickKnob.bounds = CGRectMake(0, 0, k, k);
  _stickKnob.layer.cornerRadius = k / 2;
  [self placeStickAt:_stickRest knob:_stickRest];
  _fps.frame = CGRectMake(a.origin.x + .745 * a.size.width, a.origin.y + .045 * a.size.height,
                          MAX(78, .12 * a.size.width), MAX(26, .07 * a.size.height));
}

- (void)updateFps {
  CFTimeInterval now = CACurrentMediaTime();
  if (now - _fpsShownAt < 0.5) return;
  _fpsShownAt = now;
  float fps = rex_fps_guest.load(std::memory_order_relaxed);
  if (fps < 0) {
    _fps.text = @"-- FPS";
    _fps.textColor = UIColor.whiteColor;
    return;
  }
  _fps.text = [NSString stringWithFormat:@"%.0f FPS", fps];
  _fps.textColor = fps >= 50 ? Tint(0x4CD964, 1) : fps >= 30 ? Tint(0xFFCC00, 1) : Tint(0xFF3B30, 1);
}

- (void)placeStickAt:(CGPoint)center knob:(CGPoint)knob {
  _stickBase.center = center;
  _stickKnob.center = knob;
}

- (BOOL)inSteerZone:(CGPoint)p {
  CGRect a = self.area;
  CGFloat nx = (p.x - a.origin.x) / a.size.width, ny = (p.y - a.origin.y) / a.size.height;
  return nx < kSteerMaxX && ny > kSteerMinY;
}

- (BOOL)isCaptured:(NSInteger)capture {
  for (NSNumber* n in _captures.objectEnumerator) {
    if (n.integerValue == capture) return YES;
  }
  return NO;
}

- (void)releaseAllTouches {
  [_captures removeAllObjects];
  _lookDelta = CGPointZero;
  _lookX = _lookY = 0;
  _lastButtons = 0;
  fh2_touch_pad zero = {0};
  fh2_touch_store(zero);
  [self placeStickAt:_stickRest knob:_stickRest];
}

- (void)touchesBegan:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
  for (UITouch* touch in touches) {
    CGPoint p = [touch locationInView:self];
    if (CGRectContainsPoint(CGRectInset(_mute.frame, -6, -6), p)) {
      _mute.text = fh2_audio_toggle_mute() ? @"🔇" : @"🔊";
      [_haptic impactOccurred];
      continue;
    }
    NSInteger capture = kCaptureLook;
    for (NSInteger i = kControlCount - 1; i >= 0; --i) {
      if (CGRectContainsPoint(CGRectInset(_labels[i].frame, -6, -6), p)) {
        capture = i;
        break;
      }
    }
    if (capture == kCaptureLook && [self inSteerZone:p]) capture = kCaptureStick;
    // One steering thumb and one look thumb at a time; buttons are independent.
    if (capture < 0 && [self isCaptured:capture]) continue;
    if (capture == kCaptureStick) {
      _stickCenter = p;
      [self placeStickAt:p knob:p];
    }
    [_captures setObject:@(capture) forKey:touch];
  }
  [self publish];
}

- (void)touchesMoved:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
  for (UITouch* touch in touches) {
    NSNumber* capture = [_captures objectForKey:touch];
    if (capture && capture.integerValue == kCaptureLook) {
      CGPoint p = [touch locationInView:self], prev = [touch previousLocationInView:self];
      _lookDelta.x += p.x - prev.x;
      _lookDelta.y += p.y - prev.y;
    }
  }
  [self publish];
}

- (void)touchesEnded:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
  for (UITouch* touch in touches) {
    NSInteger capture = [[_captures objectForKey:touch] integerValue];
    if (capture == kCaptureLook) {
      _lookDelta = CGPointZero;
      _lookX = _lookY = 0;
    } else if (capture == kCaptureStick) {
      [self placeStickAt:_stickRest knob:_stickRest];
    }
    [_captures removeObjectForKey:touch];
  }
  [self publish];
}

- (void)touchesCancelled:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
  [self touchesEnded:touches withEvent:event];
}

- (fh2_touch_pad)currentState {
  fh2_touch_pad s = {0};
  for (NSInteger i = 0; i < kControlCount; ++i) {
    _labels[i].backgroundColor = [UIColor colorWithWhite:0 alpha:.22];
  }
  for (UITouch* touch in _captures) {
    NSInteger i = [[_captures objectForKey:touch] integerValue];
    CGPoint p = [touch locationInView:self];
    if (i == kCaptureStick) {
      CGFloat r = self.stickRadius;
      CGFloat x = (p.x - _stickCenter.x) / r, y = (_stickCenter.y - p.y) / r;
      CGFloat mag = hypot(x, y);
      // Small dead zone, full lock just inside the ring.
      CGFloat strength = MIN(1, MAX(0, (mag - .08) / .82));
      if (mag > 0) {
        x = x / mag * strength;
        y = y / mag * strength;
      }
      s.lx = (int16_t)lround(x * 32767);
      s.ly = (int16_t)lround(y * 32767);
      CGFloat shown = MIN(mag, 1.0) * r;
      CGFloat ang = atan2(_stickCenter.y - p.y, p.x - _stickCenter.x);
      _stickKnob.center =
          CGPointMake(_stickCenter.x + cos(ang) * shown, _stickCenter.y - sin(ang) * shown);
    } else if (i >= 0 && CGRectContainsPoint(CGRectInset(_labels[i].frame, -14, -14), p)) {
      const PadControl& c = kControls[i];
      s.buttons |= c.button;
      if (c.kind == kPedalGas) s.right_trigger = 255;
      if (c.kind == kPedalBrake) s.left_trigger = 255;
      _labels[i].backgroundColor = Tint(c.tint, .45);
    }
  }
  return s;
}

- (void)publish {
  fh2_touch_pad s = [self currentState];
  s.rx = _lookX;
  s.ry = _lookY;
  uint16_t pressed = (uint16_t)(s.buttons & ~_lastButtons);
  if (pressed) [_haptic impactOccurred];
  _lastButtons = s.buttons;
  fh2_touch_store(s);
}

- (void)tick {
  // Keep the overlay above SDL's view if UIKit reorders the window.
  if (self.superview && self.superview.subviews.lastObject != self) {
    [self.superview bringSubviewToFront:self];
  }
  [self updateFps];
  fh2_touch_pad s = [self currentState];
  CFTimeInterval now = CACurrentMediaTime();
  double elapsed = MAX(1.0 / 240.0, now - _lastTick);
  _lastTick = now;
  // Normalise swipe distance to a 60 Hz sample.
  double scale = 1.0 / (16.0 * elapsed * 60.0);
  s.rx = (int16_t)lround(MAX(-1.0, MIN(1.0, _lookDelta.x * scale)) * 32767);
  s.ry = (int16_t)lround(MAX(-1.0, MIN(1.0, -_lookDelta.y * scale)) * 32767);
  _lookX = s.rx;
  _lookY = s.ry;
  _lookDelta = CGPointZero;
  _lastButtons = s.buttons;
  fh2_touch_store(s);
}
@end

// ---- install ----------------------------------------------------------------
static Fh2TouchControls* g_overlay;

static UIWindow* Fh2FindWindow(void) {
  for (UIScene* scene in UIApplication.sharedApplication.connectedScenes) {
    if (![scene isKindOfClass:UIWindowScene.class]) continue;
    UIWindowScene* ws = (UIWindowScene*)scene;
    for (UIWindow* w in ws.windows) {
      if (w.isKeyWindow) return w;
    }
    if (ws.windows.count) return ws.windows.firstObject;
  }
  return nil;
}

static void Fh2TryInstall(void) {
  if (g_overlay) return;
  UIWindow* window = Fh2FindWindow();
  if (!window || !window.rootViewController) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ Fh2TryInstall(); });
    return;
  }
  g_overlay = [[Fh2TouchControls alloc] initWithFrame:window.bounds];
  [window addSubview:g_overlay];
  [window bringSubviewToFront:g_overlay];
  NSLog(@"[fh2 touch] overlay installed on %@", window);
}

extern "C" void fh2_touch_install(void) {
  dispatch_async(dispatch_get_main_queue(), ^{ Fh2TryInstall(); });
}
