// A FileSender replacement that streams live captured audio (plus a minimal
// black video track, which the Nest Hub's mirroring receiver requires).

#ifndef NESTCAST_LIVE_SENDER_H_
#define NESTCAST_LIVE_SENDER_H_

#include <memory>

#include "cast/standalone_sender/file_sender.h"
#include "cast/standalone_sender/streaming_opus_encoder.h"
#include "cast/standalone_sender/streaming_video_encoder.h"
#include "cast/streaming/public/environment.h"
#include "nestcast/status_screen.h"
#include "nestcast/tap_capture.h"
#include "util/alarm.h"

namespace nestcast {

using openscreen::Clock;

class LiveSender final : public openscreen::cast::FileSender {
 public:
  LiveSender(openscreen::cast::Environment& env,
             TapCapture& capture,
             openscreen::cast::SenderSession::ConfiguredSenders senders,
             ShutdownCallback on_dead,
             bool show_clock);
  ~LiveSender() override;

  void SetPlaybackRate(double rate) override {}
  void OnInputMessage(openscreen::cast::InputMessage message) override {}

 private:
  void DrainCapture();
  void SendVideoFrame();
  void CheckHealth();
  Clock::time_point HostTimeToClock(uint64_t host_time) const;

  openscreen::cast::Environment& env_;
  TapCapture& capture_;
  ShutdownCallback on_dead_;

  openscreen::cast::Sender* audio_sender_ = nullptr;  // Owned by encoder.
  std::unique_ptr<openscreen::cast::StreamingOpusEncoder> audio_encoder_;
  std::unique_ptr<openscreen::cast::StreamingVideoEncoder> video_encoder_;

  openscreen::Alarm drain_alarm_;
  openscreen::Alarm video_alarm_;
  openscreen::Alarm health_alarm_;

  // mach_absolute_time -> Clock conversion.
  double ns_per_tick_ = 1.0;
  Clock::duration clock_offset_{};

  std::unique_ptr<uint8_t[]> black_frame_;
  std::unique_ptr<StatusScreen> status_screen_;  // Null: plain black.

  // Health / stats.
  Clock::time_point last_capture_time_{};
  Clock::time_point last_healthy_time_{};
  Clock::time_point last_stats_time_{};
  Clock::time_point last_no_capture_warning_{};
  uint64_t frames_captured_ = 0;
  uint64_t chunks_captured_ = 0;
  float peak_ = 0;
  int stale_chunks_dropped_ = 0;
  double lag_sum_ms_ = 0;
  uint64_t lag_count_ = 0;
  bool in_beep_ = false;
  int quiet_frames_ = 0;
  bool reported_dead_ = false;
};

}  // namespace nestcast

#endif  // NESTCAST_LIVE_SENDER_H_
