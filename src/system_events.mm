#include "nestcast/system_events.h"

#import <CoreAudio/AudioHardware.h>
#import <Foundation/Foundation.h>
#include <IOKit/IOMessage.h>
#include <IOKit/pwr_mgt/IOPMLib.h>
#include <dispatch/dispatch.h>

namespace nestcast {

struct SystemEvents::Impl {
  Callbacks callbacks;
  dispatch_queue_t queue = nullptr;
  io_connect_t root_port = MACH_PORT_NULL;
  IONotificationPortRef notify_port = nullptr;
  io_object_t notifier = 0;
  AudioObjectPropertyListenerBlock restart_listener = nil;
};

namespace {

void PowerCallback(void* refcon, io_service_t, natural_t type, void* arg) {
  auto* impl = static_cast<SystemEvents::Impl*>(refcon);
  const intptr_t token = reinterpret_cast<intptr_t>(arg);
  switch (type) {
    case kIOMessageCanSystemSleep:
      IOAllowPowerChange(impl->root_port, token);
      break;
    case kIOMessageSystemWillSleep:
      if (impl->callbacks.will_sleep) {
        io_connect_t port = impl->root_port;
        impl->callbacks.will_sleep(
            [port, token] { IOAllowPowerChange(port, token); });
      } else {
        IOAllowPowerChange(impl->root_port, token);
      }
      break;
    case kIOMessageSystemHasPoweredOn:
      if (impl->callbacks.did_wake) {
        impl->callbacks.did_wake();
      }
      break;
    default:
      break;
  }
}

}  // namespace

SystemEvents::SystemEvents(Callbacks callbacks) : impl_(new Impl) {
  impl_->callbacks = std::move(callbacks);
}

SystemEvents::~SystemEvents() {
  if (impl_->restart_listener) {
    AudioObjectPropertyAddress addr = {kAudioHardwarePropertyServiceRestarted,
                                       kAudioObjectPropertyScopeGlobal,
                                       kAudioObjectPropertyElementMain};
    AudioObjectRemovePropertyListenerBlock(kAudioObjectSystemObject, &addr,
                                           impl_->queue,
                                           impl_->restart_listener);
  }
  if (impl_->notifier) {
    IODeregisterForSystemPower(&impl_->notifier);
  }
  if (impl_->notify_port) {
    IONotificationPortDestroy(impl_->notify_port);
  }
  if (impl_->root_port != MACH_PORT_NULL) {
    IOServiceClose(impl_->root_port);
  }
  delete impl_;
}

bool SystemEvents::Start() {
  impl_->queue =
      dispatch_queue_create("nestcast.system_events", DISPATCH_QUEUE_SERIAL);
  impl_->root_port = IORegisterForSystemPower(impl_, &impl_->notify_port,
                                              PowerCallback, &impl_->notifier);
  if (impl_->root_port == MACH_PORT_NULL) {
    return false;
  }
  IONotificationPortSetDispatchQueue(impl_->notify_port, impl_->queue);

  Impl* impl = impl_;
  impl_->restart_listener =
      ^(UInt32, const AudioObjectPropertyAddress*) {
        if (impl->callbacks.audio_service_restarted) {
          impl->callbacks.audio_service_restarted();
        }
      };
  AudioObjectPropertyAddress addr = {kAudioHardwarePropertyServiceRestarted,
                                     kAudioObjectPropertyScopeGlobal,
                                     kAudioObjectPropertyElementMain};
  AudioObjectAddPropertyListenerBlock(kAudioObjectSystemObject, &addr,
                                      impl_->queue, impl_->restart_listener);
  return true;
}

}  // namespace nestcast
