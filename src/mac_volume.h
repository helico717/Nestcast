// Watches the Mac's default output device volume and mute (what the volume
// keys change), following default-device changes. The callback runs on a
// private dispatch queue whenever either value changes.

#ifndef NESTCAST_MAC_VOLUME_H_
#define NESTCAST_MAC_VOLUME_H_

#include <functional>

namespace nestcast {

class MacVolume {
 public:
  using Callback = std::function<void(double level, bool muted)>;

  explicit MacVolume(Callback callback);
  ~MacVolume();

  bool Start();
  // Current values of the default output device.
  bool Read(double* level, bool* muted) const;
  // Sets the default output device's volume (what the slider/keys show).
  bool Write(double level) const;

  struct Impl;

 private:
  Impl* impl_;
};

}  // namespace nestcast

#endif  // NESTCAST_MAC_VOLUME_H_
