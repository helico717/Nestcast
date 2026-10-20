#include "nestcast/mac_volume.h"

#import <AudioToolbox/AudioServices.h>
#import <CoreAudio/AudioHardware.h>
#include <dispatch/dispatch.h>

namespace nestcast {

namespace {

constexpr AudioObjectPropertyAddress kDefaultOutput = {
    kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal,
    kAudioObjectPropertyElementMain};
constexpr AudioObjectPropertyAddress kVolume = {
    kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
    kAudioDevicePropertyScopeOutput, kAudioObjectPropertyElementMain};
constexpr AudioObjectPropertyAddress kMute = {kAudioDevicePropertyMute,
                                              kAudioDevicePropertyScopeOutput,
                                              kAudioObjectPropertyElementMain};

AudioDeviceID DefaultOutputDevice() {
  AudioDeviceID id = kAudioObjectUnknown;
  UInt32 size = sizeof(id);
  AudioObjectGetPropertyData(kAudioObjectSystemObject, &kDefaultOutput, 0,
                             nullptr, &size, &id);
  return id;
}

}  // namespace

struct MacVolume::Impl {
  Callback callback;
  dispatch_queue_t queue = nullptr;
  AudioDeviceID device = kAudioObjectUnknown;
  AudioObjectPropertyListenerBlock device_listener = nil;
  AudioObjectPropertyListenerBlock value_listener = nil;

  void Notify() {
    double level = 0;
    bool muted = false;
    if (ReadDevice(device, &level, &muted) && callback) {
      callback(level, muted);
    }
  }

  static bool ReadDevice(AudioDeviceID dev, double* level, bool* muted) {
    if (dev == kAudioObjectUnknown) {
      return false;
    }
    Float32 v = 0;
    UInt32 size = sizeof(v);
    if (AudioObjectGetPropertyData(dev, &kVolume, 0, nullptr, &size, &v) !=
        noErr) {
      return false;  // Device has no volume control (e.g. HDMI).
    }
    UInt32 m = 0;
    size = sizeof(m);
    if (AudioObjectGetPropertyData(dev, &kMute, 0, nullptr, &size, &m) !=
        noErr) {
      m = 0;
    }
    *level = v;
    *muted = m != 0;
    return true;
  }

  void Attach(AudioDeviceID dev) {
    if (device != kAudioObjectUnknown) {
      AudioObjectRemovePropertyListenerBlock(device, &kVolume, queue,
                                             value_listener);
      AudioObjectRemovePropertyListenerBlock(device, &kMute, queue,
                                             value_listener);
    }
    device = dev;
    if (device != kAudioObjectUnknown) {
      AudioObjectAddPropertyListenerBlock(device, &kVolume, queue,
                                          value_listener);
      AudioObjectAddPropertyListenerBlock(device, &kMute, queue,
                                          value_listener);
    }
  }
};

MacVolume::MacVolume(Callback callback) : impl_(new Impl) {
  impl_->callback = std::move(callback);
}

MacVolume::~MacVolume() {
  if (impl_->device_listener) {
    AudioObjectRemovePropertyListenerBlock(kAudioObjectSystemObject,
                                           &kDefaultOutput, impl_->queue,
                                           impl_->device_listener);
  }
  impl_->Attach(kAudioObjectUnknown);
  delete impl_;
}

bool MacVolume::Start() {
  impl_->queue = dispatch_queue_create("nestcast.volume", DISPATCH_QUEUE_SERIAL);
  Impl* impl = impl_;
  impl_->value_listener = ^(UInt32, const AudioObjectPropertyAddress*) {
    impl->Notify();
  };
  impl_->device_listener = ^(UInt32, const AudioObjectPropertyAddress*) {
    impl->Attach(DefaultOutputDevice());
    impl->Notify();
  };
  dispatch_sync(impl_->queue, ^{
    impl->Attach(DefaultOutputDevice());
  });
  return AudioObjectAddPropertyListenerBlock(
             kAudioObjectSystemObject, &kDefaultOutput, impl_->queue,
             impl_->device_listener) == noErr;
}

bool MacVolume::Write(double level) const {
  const AudioDeviceID dev = DefaultOutputDevice();
  if (dev == kAudioObjectUnknown) {
    return false;
  }
  Float32 v = static_cast<Float32>(level < 0 ? 0 : (level > 1 ? 1 : level));
  // The "virtual main volume" is implemented by AudioToolbox, so it has to
  // be set through AudioHardwareService rather than AudioObject.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
  return AudioHardwareServiceSetPropertyData(dev, &kVolume, 0, nullptr,
                                             sizeof(v), &v) == noErr;
#pragma clang diagnostic pop
}

bool MacVolume::Read(double* level, bool* muted) const {
  return Impl::ReadDevice(DefaultOutputDevice(), level, muted);
}

}  // namespace nestcast
