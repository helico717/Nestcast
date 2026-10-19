#include "nestcast/live_sender.h"

#include <mach/mach_time.h>

#include <algorithm>
#include <chrono>
#include <cstring>
#include <utility>

#include "cast/standalone_sender/streaming_vpx_encoder.h"
#include "cast/streaming/public/sender.h"
#include "util/osp_logging.h"

namespace nestcast {

using openscreen::cast::SenderSession;
using openscreen::cast::StreamingOpusEncoder;
using openscreen::cast::StreamingVideoEncoder;
using openscreen::cast::StreamingVpxEncoder;
using std::chrono::milliseconds;

namespace {

constexpr milliseconds kDrainInterval(5);
// Video frame interval. The receiver lip-syncs audio to video, so a low
// frame rate can add latency; NESTCAST_VIDEO_FPS overrides (default 5).
milliseconds VideoFrameInterval() {
  static const milliseconds interval = [] {
    const char* fps = getenv("NESTCAST_VIDEO_FPS");
    const int f = fps ? atoi(fps) : 5;
    return milliseconds(1000 / std::clamp(f, 1, 60));
  }();
  return interval;
}
constexpr milliseconds kHealthInterval(500);
constexpr milliseconds kStatsInterval(30000);
// If the receiver stops acknowledging audio for this long, the session is
// considered dead and the caller reconnects.
constexpr milliseconds kDeadAfter(4000);
// More audio than this unacknowledged counts as "not healthy".
constexpr size_t kUnhealthyInFlightFrames = 20;  // 200 ms of 10 ms frames.

// The Nest Hub's panel is 1024x600; matching it avoids scaling/letterboxing.
constexpr int kVideoWidth = 1024;
constexpr int kVideoHeight = 600;
constexpr int kVideoBitrate = 100'000;

}  // namespace

LiveSender::LiveSender(openscreen::cast::Environment& env,
                       TapCapture& capture,
                       SenderSession::ConfiguredSenders senders,
                       ShutdownCallback on_dead,
                       bool show_clock)
    : env_(env),
      capture_(capture),
      on_dead_(std::move(on_dead)),
      drain_alarm_(env.now_function(), env.task_runner()),
      video_alarm_(env.now_function(), env.task_runner()),
      health_alarm_(env.now_function(), env.task_runner()) {
  mach_timebase_info_data_t tb;
  mach_timebase_info(&tb);
  ns_per_tick_ = static_cast<double>(tb.numer) / tb.denom;
  const auto now = env_.now();
  const auto host_ns = std::chrono::nanoseconds(
      static_cast<int64_t>(mach_absolute_time() * ns_per_tick_));
  clock_offset_ = now.time_since_epoch() -
                  std::chrono::duration_cast<Clock::duration>(host_ns);

  OSP_CHECK(senders.audio_sender);
  OSP_CHECK(senders.audio_config.codec == openscreen::cast::AudioCodec::kOpus);
  audio_sender_ = senders.audio_sender.get();
  audio_encoder_ = std::make_unique<StreamingOpusEncoder>(
      senders.audio_config.channels,
      StreamingOpusEncoder::kDefaultCastAudioFramesPerSecond,
      std::move(senders.audio_sender));
  audio_encoder_->UseHighQuality();
  OSP_LOG_INFO << "nestcast: audio " << audio_encoder_->num_channels()
               << "ch @ " << audio_encoder_->sample_rate()
               << " Hz, Opus bitrate " << audio_encoder_->GetBitrate()
               << ", playout delay "
               << std::chrono::duration_cast<milliseconds>(
                      audio_sender_->config().target_playout_delay)
                      .count()
               << " ms, max in-flight "
               << std::chrono::duration_cast<milliseconds>(
                      audio_sender_->GetMaxInFlightMediaDuration())
                      .count()
               << " ms";
  if (capture_.sample_rate() != audio_encoder_->sample_rate()) {
    OSP_LOG_ERROR << "nestcast: capture rate " << capture_.sample_rate()
                  << " != RTP rate " << audio_encoder_->sample_rate()
                  << "; audio will be mis-timed (resampling not implemented)";
  }

  if (senders.video_sender) {
    OSP_LOG_INFO << "nestcast: video playout delay "
                 << std::chrono::duration_cast<milliseconds>(
                        senders.video_sender->config().target_playout_delay)
                        .count()
                 << " ms";
    StreamingVideoEncoder::Parameters params;
    params.codec = senders.video_config.codec;
    params.num_encode_threads = 1;
    video_encoder_ = std::make_unique<StreamingVpxEncoder>(
        params, env_.task_runner(), std::move(senders.video_sender));
    video_encoder_->SetTargetBitrate(kVideoBitrate);
    const size_t y = kVideoWidth * kVideoHeight;
    black_frame_.reset(new uint8_t[y * 3 / 2]);
    std::memset(black_frame_.get(), 16, y);              // Y: black.
    std::memset(black_frame_.get() + y, 128, y / 2);     // U, V: neutral.
    if (show_clock) {
      status_screen_ =
          std::make_unique<StatusScreen>(kVideoWidth, kVideoHeight);
    }
    video_alarm_.Schedule([this] { SendVideoFrame(); },
                          openscreen::Alarm::kImmediately);
  }

  // Throw away anything captured before the session existed, so the first
  // frame is fresh.
  while (capture_.Peek()) {
    capture_.Release();
  }
  last_capture_time_ = last_healthy_time_ = last_stats_time_ = env_.now();
  drain_alarm_.Schedule([this] { DrainCapture(); },
                        openscreen::Alarm::kImmediately);
  health_alarm_.ScheduleFromNow([this] { CheckHealth(); }, kHealthInterval);
}

LiveSender::~LiveSender() = default;

Clock::time_point LiveSender::HostTimeToClock(uint64_t host_time) const {
  const auto host_ns = std::chrono::nanoseconds(
      static_cast<int64_t>(host_time * ns_per_tick_));
  return Clock::time_point(
      std::chrono::duration_cast<Clock::duration>(host_ns) + clock_offset_);
}

void LiveSender::DrainCapture() {
  static const bool debug_onset = getenv("NESTCAST_DEBUG_ONSET") != nullptr;
  while (const CaptureChunk* c = capture_.Peek()) {
    // Drop stale audio at session start: a receiver seeing the first frames
    // arrive ~100 ms "late" may size its buffer to that. Only fresh audio
    // starts the stream.
    if (frames_captured_ == 0) {
      const double age_ms =
          (mach_absolute_time() - c->host_time) * ns_per_tick_ / 1e6;
      if (age_ms > 40.0) {
        ++stale_chunks_dropped_;
        capture_.Release();
        continue;
      }
      if (stale_chunks_dropped_) {
        OSP_LOG_INFO << "nestcast: dropped " << stale_chunks_dropped_
                     << " stale startup chunk(s)";
      }
    }
    {
      // Queueing lag: how long the chunk waited between the tap's timestamp
      // and being handed to the encoder.
      const uint64_t now_host = mach_absolute_time();
      lag_sum_ms_ += (now_host - c->host_time) * ns_per_tick_ / 1e6;
      ++lag_count_;
    }
    if (debug_onset) {
      // Log the wall-clock time of each beep onset as the tap stamped it.
      for (int i = 0; i < c->frames; ++i) {
        const float v = c->data[2 * i] < 0 ? -c->data[2 * i] : c->data[2 * i];
        if (v > 0.3f && !in_beep_) {
          in_beep_ = true;
          const uint64_t host = c->host_time + static_cast<uint64_t>(
              i / capture_.sample_rate() * 1e9 / ns_per_tick_);
          const double age_s =
              (mach_absolute_time() - host) * ns_per_tick_ / 1e9;
          const double epoch =
              std::chrono::duration<double>(
                  std::chrono::system_clock::now().time_since_epoch())
                  .count() - age_s;
          OSP_LOG_INFO << "ONSET epoch_us=" << static_cast<long long>(epoch * 1e6)
                       << " chunk_frames=" << c->frames;
          quiet_frames_ = 0;
        } else if (v < 0.01f) {
          if (++quiet_frames_ > 4800) in_beep_ = false;
        } else {
          quiet_frames_ = 0;
        }
      }
    }
    // NESTCAST_REF_OFFSET_MS shifts reference times later by a fixed amount,
    // so frames reach the sender ~on time relative to them (the tap delivers
    // each buffer ~20 ms after its timestamp, plus chunking).
    static const Clock::duration ref_offset =
        std::chrono::duration_cast<Clock::duration>(milliseconds(
            getenv("NESTCAST_REF_OFFSET_MS") ? atoi(getenv("NESTCAST_REF_OFFSET_MS"))
                                             : 40));
    const Clock::time_point begin = HostTimeToClock(c->host_time) + ref_offset;
    const Clock::time_point end =
        begin + std::chrono::duration_cast<Clock::duration>(
                    std::chrono::duration<double>(c->frames /
                                                  capture_.sample_rate()));
    audio_encoder_->EncodeAndSend(c->data, c->frames, begin, end, begin);
    for (int i = 0; i < c->frames * kChannels; ++i) {
      const float v = c->data[i] < 0 ? -c->data[i] : c->data[i];
      if (v > peak_) peak_ = v;
    }
    if (frames_captured_ == 0) {
      OSP_LOG_INFO << "nestcast: first captured audio arrived";
    }
    frames_captured_ += c->frames;
    ++chunks_captured_;
    last_capture_time_ = env_.now();
    capture_.Release();
  }
  drain_alarm_.ScheduleFromNow([this] { DrainCapture(); }, kDrainInterval);
}

void LiveSender::SendVideoFrame() {
  const auto now = env_.now();
  if (status_screen_) {
    status_screen_->Update(black_frame_.get());  // Redraws once per minute.
  }
  StreamingVideoEncoder::VideoFrame frame;
  frame.width = kVideoWidth;
  frame.height = kVideoHeight;
  const size_t y = kVideoWidth * kVideoHeight;
  frame.yuv_planes[0] = black_frame_.get();
  frame.yuv_planes[1] = black_frame_.get() + y;
  frame.yuv_planes[2] = black_frame_.get() + y + y / 4;
  frame.yuv_strides[0] = kVideoWidth;
  frame.yuv_strides[1] = kVideoWidth / 2;
  frame.yuv_strides[2] = kVideoWidth / 2;
  frame.duration = VideoFrameInterval();
  frame.capture_begin_time = now;
  frame.capture_end_time = now;
  video_encoder_->EncodeAndSend(frame, now, {});
  video_alarm_.ScheduleFromNow([this] { SendVideoFrame(); },
                               VideoFrameInterval());
}

void LiveSender::CheckHealth() {
  const auto now = env_.now();
  const size_t in_flight = audio_sender_->GetInFlightFrameCount();
  if (in_flight < kUnhealthyInFlightFrames) {
    last_healthy_time_ = now;
  }
  if (now - last_capture_time_ > milliseconds(1000) &&
      now - last_no_capture_warning_ > milliseconds(5000)) {
    last_no_capture_warning_ = now;
    OSP_LOG_WARN << "nestcast: no captured audio for "
                 << std::chrono::duration_cast<milliseconds>(
                        now - last_capture_time_)
                        .count()
                 << " ms (IO callbacks=" << capture_.callbacks() << ")";
  }
  if (now - last_stats_time_ >= kStatsInterval) {
    last_stats_time_ = now;
    OSP_LOG_INFO << "nestcast: stats frames=" << frames_captured_
                 << " chunks=" << chunks_captured_
                 << " overruns=" << capture_.overruns()
                 << " peak=" << peak_
                 << " lag_ms=" << (lag_count_ ? lag_sum_ms_ / lag_count_ : 0)
                 << " lag_ms=" << (lag_count_ ? lag_sum_ms_ / lag_count_ : 0)
                 << " in_flight=" << in_flight << " rtt="
                 << std::chrono::duration_cast<milliseconds>(
                        audio_sender_->GetCurrentRoundTripTime())
                        .count()
                 << "ms";
    peak_ = 0;
    lag_sum_ms_ = 0;
    lag_count_ = 0;
  }
  if (now - last_healthy_time_ > kDeadAfter && !reported_dead_) {
    reported_dead_ = true;
    OSP_LOG_ERROR << "nestcast: receiver stopped acknowledging audio ("
                  << in_flight << " frames in flight for >"
                  << kDeadAfter.count() << " ms); restarting session";
    if (on_dead_) {
      // Defer: the callback may destroy this object.
      env_.task_runner().PostTask([cb = on_dead_] { cb(); });
    }
    return;
  }
  health_alarm_.ScheduleFromNow([this] { CheckHealth(); }, kHealthInterval);
}

}  // namespace nestcast
