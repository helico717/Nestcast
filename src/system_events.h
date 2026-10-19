// System event hooks: sleep/wake (IOKit power notifications) and Core Audio
// service restarts (coreaudiod crash/restart). Callbacks run on a private
// dispatch queue; the caller must hop to its own thread.

#ifndef NESTCAST_SYSTEM_EVENTS_H_
#define NESTCAST_SYSTEM_EVENTS_H_

#include <functional>

namespace nestcast {

class SystemEvents {
 public:
  struct Callbacks {
    // Called before sleep. The system waits (up to ~30 s) until `done` is
    // invoked, so the session can be stopped cleanly first.
    std::function<void(std::function<void()> done)> will_sleep;
    std::function<void()> did_wake;
    std::function<void()> audio_service_restarted;
  };

  explicit SystemEvents(Callbacks callbacks);
  ~SystemEvents();

  bool Start();

  struct Impl;

 private:
  Impl* impl_;
};

}  // namespace nestcast

#endif  // NESTCAST_SYSTEM_EVENTS_H_
