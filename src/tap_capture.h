// Live system-audio capture via a Core Audio process tap (macOS 14.2+).
//
// A private tap + private aggregate device delivers the mixed output of the
// selected processes (or of all processes) as 48 kHz float32 stereo with
// host-clock timestamps. The real-time IO callback only copies into a
// lock-free single-producer/single-consumer ring; the consumer drains it from
// the Open Screen task runner.

#ifndef NESTCAST_TAP_CAPTURE_H_
#define NESTCAST_TAP_CAPTURE_H_

#include <sys/types.h>

#include <atomic>
#include <cstdint>
#include <memory>
#include <string>
#include <vector>

namespace nestcast {

inline constexpr int kChannels = 2;
inline constexpr int kMaxChunkFrames = 4096;

struct CaptureChunk {
  uint64_t host_time = 0;  // mach_absolute_time of the first frame.
  double sample_time = 0;  // Device sample time of the first frame.
  int frames = 0;
  float data[kMaxChunkFrames * kChannels];
};

class TapCapture {
 public:
  struct Options {
    // Processes to capture. Empty = capture all system audio (global tap,
    // excluding this process).
    std::vector<pid_t> include_pids;
    // Mute the tapped processes on the Mac's own output while capturing.
    bool mute = false;
    // If set, capture the input (loopback) side of this device instead of
    // using a process tap; e.g. the "Nest Hub (Cast)" virtual device.
    std::string device_uid;
  };

  TapCapture();
  ~TapCapture();

  // Returns false and fills `error` on failure.
  bool Start(const Options& options, std::string* error);
  void Stop();

  double sample_rate() const { return sample_rate_; }

  // Looks up a device by UID; returns 0 if not present.
  static uint32_t FindDevice(const std::string& uid);
  // The current default output device's UID ("" if unknown).
  static std::string DefaultOutputUID();

  // Consumer side (single thread). Returns nullptr if empty. The returned
  // chunk stays valid until Release() is called.
  const CaptureChunk* Peek();
  void Release();

  uint64_t overruns() const { return overruns_.load(); }
  uint64_t callbacks() const { return callbacks_.load(); }
  // mach_absolute_time of the most recent IO callback (0 = none yet).
  uint64_t last_io_host_time() const { return last_io_host_time_.load(); }

  // Producer side, called from the IO thread.
  void OnInput(uint64_t host_time,
               double sample_time,
               const void* const* buffers,
               const uint32_t* buffer_bytes,
               const uint32_t* buffer_channels,
               uint32_t num_buffers);

 private:
  bool StartDevice(const std::string& uid, std::string* error);

  static constexpr size_t kRingSize = 256;  // Power of two.

  std::unique_ptr<CaptureChunk[]> ring_;
  std::atomic<size_t> write_index_{0};
  std::atomic<size_t> read_index_{0};
  std::atomic<uint64_t> overruns_{0};
  std::atomic<uint64_t> callbacks_{0};
  std::atomic<uint64_t> last_io_host_time_{0};

  double sample_rate_ = 0;
  uint32_t tap_id_ = 0;        // AudioObjectID
  uint32_t aggregate_id_ = 0;  // AudioObjectID
  void* io_proc_id_ = nullptr; // AudioDeviceIOProcID
  // A silent IOProc on the built-in output keeps that device (the aggregate's
  // clock source) running; without it the tap delivers no IO while nothing
  // else is playing.
  uint32_t device_id_ = 0;  // Device mode: the captured device.
  uint32_t keepalive_device_ = 0;
  void* keepalive_proc_id_ = nullptr;
};

}  // namespace nestcast

#endif  // NESTCAST_TAP_CAPTURE_H_
