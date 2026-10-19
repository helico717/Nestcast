// Renders the picture shown on the Hub while streaming: a dark screen with a
// dim clock (HH:MM) and a small "Mac 오디오 재생 중" caption, as I420.

#ifndef NESTCAST_STATUS_SCREEN_H_
#define NESTCAST_STATUS_SCREEN_H_

#include <cstdint>
#include <memory>

namespace nestcast {

class StatusScreen {
 public:
  StatusScreen(int width, int height);
  ~StatusScreen();

  // Re-renders into `i420` (width*height*3/2 bytes) if the displayed minute
  // changed since the last call (or on first call). Returns true if updated.
  bool Update(uint8_t* i420);

 private:
  const int width_;
  const int height_;
  std::unique_ptr<uint8_t[]> rgba_;
  int last_minute_ = -1;
};

}  // namespace nestcast

#endif  // NESTCAST_STATUS_SCREEN_H_
