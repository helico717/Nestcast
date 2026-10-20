// nestcast: stream the Mac's live audio to a Google Cast receiver (Nest Hub)
// using Cast Streaming (mirroring), and keep it streaming: reconnects on any
// failure, re-discovers the Hub by name each time, survives sleep/wake and
// coreaudiod restarts, and rebuilds the audio tap if it stalls.
//
// usage: nestcast [options] [cast_name | ip[:port]]
//   With no receiver given, the speaker saved in
//   ~/Library/Application Support/nestcast/hub (Cast device ID) is used; if
//   none is saved, a Nest Hub is used only if it is the only one around.
//   --list         print the Cast devices (name, model, ID) and exit
//   --playout MS   target playout delay (default 300)
//   --pid PID      capture only this process (repeatable); default: all audio
//   --mute         mute captured audio on the Mac's own output
//   --screen MODE  what the Hub shows: "clock" (default) or "black"
//   -v             verbose logging

#include <mach/mach_time.h>
#include <unistd.h>

#include <csignal>
#include <fstream>
#include <cstdlib>
#include <cstring>
#include <functional>
#include <iostream>
#include <memory>
#include <optional>
#include <string>
#include <thread>
#include <vector>

#include "cast/common/public/trust_store.h"
#include "cast/standalone_sender/connection_settings.h"
#include "cast/standalone_sender/file_sender.h"
#include "cast/standalone_sender/looping_file_cast_agent.h"
#include "nestcast/discovery.h"
#include "nestcast/live_sender.h"
#include "nestcast/mac_volume.h"
#include "nestcast/system_events.h"
#include "nestcast/tap_capture.h"
#include "platform/api/time.h"
#include "platform/base/ip_address.h"
#include "platform/impl/logging.h"
#include "platform/impl/platform_client_posix.h"
#include "platform/impl/task_runner.h"

namespace nestcast {
namespace {

using openscreen::Clock;
using openscreen::IPEndpoint;
using openscreen::TaskRunnerImpl;
using openscreen::cast::CastTrustStore;
using openscreen::cast::ConnectionSettings;
using openscreen::cast::FileSender;
using openscreen::cast::LoopingFileCastAgent;
using openscreen::cast::SenderSession;
using std::chrono::milliseconds;
using std::chrono::seconds;

constexpr int kDefaultCastPort = 8009;
// UID of the "Nest Hub (Cast)" virtual output device (see driver/).
constexpr char kVirtualDeviceUID[] = "Nest Hub (Cast)_UID";
constexpr milliseconds kMinBackoff(1000);
constexpr milliseconds kMaxBackoff(10000);
constexpr milliseconds kDiscoveryTimeout(6000);
// A connection attempt that hasn't produced a streaming session by then is
// abandoned and retried.
constexpr seconds kConnectTimeout(20);
// Rebuild the tap if its IO callbacks stop for this long.
constexpr seconds kCaptureStallTimeout(3);
constexpr seconds kFirstIoTimeout(15);
// While another app is casting to the Hub, check this often whether it's idle.
constexpr seconds kBusyPollInterval(5);
// After wake, give Wi-Fi/Ethernet a moment before reconnecting.
constexpr seconds kWakeSettleTime(3);

std::string HubConfigPath() {
  const char* home = getenv("HOME");
  return std::string(home ? home : "") +
         "/Library/Application Support/nestcast/hub";
}

// The config file holds the chosen speaker's unique Cast ID on line 1 and its
// friendly name (for display only) on line 2. A file with just a name on
// line 1 (older versions) is upgraded to an ID on first successful connect.
std::string Trim(std::string v) {
  while (!v.empty() && (v.back() == '\n' || v.back() == '\r' || v.back() == ' ')) {
    v.pop_back();
  }
  return v;
}

std::string LoadHubIdOrName() {
  std::ifstream in(HubConfigPath());
  std::string line;
  std::getline(in, line);
  return Trim(line);
}

void SaveHub(const std::string& id, const std::string& name) {
  const std::string path = HubConfigPath();
  system(("mkdir -p \"" + path.substr(0, path.rfind('/')) + "\"").c_str());
  std::ofstream(path) << id << "\n" << name << "\n";
}

bool IsNestHub(const CastDevice& d) {
  return d.model.find("Nest Hub") != std::string::npos;
}

void Usage(const char* argv0) {
  std::cerr << "usage: " << argv0
            << " [--list] [--playout MS] [--pid PID]... [--mute] [--screen clock|black] [-v] "
               "[cast_name | ip[:port]]\n";
}

class Supervisor {
 public:
  Supervisor(TaskRunnerImpl& runner,
             std::string target,
             int playout_ms,
             TapCapture::Options capture_options,
             bool show_clock)
      : runner_(runner),
        target_(std::move(target)),
        playout_ms_(playout_ms),
        capture_options_(std::move(capture_options)),
        show_clock_(show_clock) {}

  bool Start() {
    mode_ = DesiredMode();
    LogMode();
    if (mode_ == Mode::kPaused) {
      paused_ = true;
    } else {
      std::string error;
      if (!capture_.Start(OptionsFor(mode_), &error)) {
        OSP_LOG_ERROR << "nestcast: audio capture failed: " << error;
        return false;
      }
      LogCaptureStarted();
    }

    FileSender::SetFactoryOverride(
        [this](openscreen::cast::Environment& env, ConnectionSettings,
               const SenderSession*, SenderSession::ConfiguredSenders senders,
               FileSender::ShutdownCallback shutdown)
            -> std::unique_ptr<FileSender> {
          OSP_LOG_INFO << "nestcast: session established, streaming";
          backoff_ = kMinBackoff;
          streaming_ = true;
          runner_.PostTask([this] { BeginVolumeTracking(); });
          if (!busy_app_.empty()) {
            OSP_LOG_INFO << "nestcast: Hub is idle again; resumed";
            busy_app_.clear();
          }
          return std::make_unique<LiveSender>(env, capture_, std::move(senders),
                                              std::move(shutdown), show_clock_);
        });

    events_ = std::make_unique<SystemEvents>(SystemEvents::Callbacks{
        .will_sleep =
            [this](std::function<void()> done) {
              runner_.PostTask([this, done] { OnWillSleep(done); });
            },
        .did_wake = [this] { runner_.PostTask([this] { OnDidWake(); }); },
        .audio_service_restarted =
            [this] {
              runner_.PostTask([this] {
                OSP_LOG_WARN << "nestcast: coreaudiod restarted";
                RestartCapture();
              });
            },
    });
    if (!events_->Start()) {
      OSP_LOG_WARN << "nestcast: could not register for sleep/wake events";
    }

    LoadSavedHubVolume();
    mac_volume_ = std::make_unique<MacVolume>([this](double, bool) {
      runner_.PostTask([this] { OnMacVolumeChanged(); });
    });
    if (!mac_volume_->Start()) {
      OSP_LOG_WARN << "nestcast: could not watch the Mac volume";
    }

    runner_.PostTask([this] { Tick(); });
    const int gen = generation_;
    runner_.PostTask([this, gen] { Connect(gen); });
    return true;
  }

  // Graceful stop: tells the receiver to STOP (completes within ~500 ms).
  void Stop() {
    stopping_ = true;
    ++generation_;
    RestoreHubVolume("shutting down");
    if (agent_) {
      agent_->RequestStop();
    }
  }

  void Destroy() {
    agent_.reset();
    retiring_.clear();
    events_.reset();
    mac_volume_.reset();
    capture_.Stop();
  }

 private:
  // --- Capture source mode ---
  // kTap:    driver not installed: capture all system audio via a process tap.
  // kDevice: "Nest Hub (Cast)" is the default output: capture its loopback.
  //          (The Mac speakers are naturally silent, and players see its
  //          reported latency, keeping video lip-synced.)
  // kPaused: the driver is installed but the user picked another output
  //          (e.g. the Mac speakers): hand the Hub back and wait.
  enum class Mode { kTap, kDevice, kPaused };

  static Mode DesiredMode() {
    if (!TapCapture::FindDevice(kVirtualDeviceUID)) {
      return Mode::kTap;
    }
    return TapCapture::DefaultOutputUID() == kVirtualDeviceUID ? Mode::kDevice
                                                               : Mode::kPaused;
  }

  TapCapture::Options OptionsFor(Mode) const {
    // Even in device mode, audio is captured with the system-audio tap: a
    // process tap sees apps' output whichever device it goes to. The virtual
    // device's job is to be the silent, latency-reporting output that keeps
    // video lip-synced (it has no input side to read).
    return capture_options_;
  }

  void LogMode() {
    OSP_LOG_INFO << "nestcast: mode "
                 << (mode_ == Mode::kTap      ? "tap (system audio)"
                     : mode_ == Mode::kDevice ? "device (Nest Hub (Cast) output)"
                                              : "paused (Mac output is not Nest Hub (Cast))");
  }

  void CheckMode() {
    if (sleeping_ || stopping_) {
      return;
    }
    const Mode want = DesiredMode();
    if (want == mode_) {
      return;
    }
    const Mode old = mode_;
    mode_ = want;
    LogMode();
    capture_.Stop();
    if (want == Mode::kPaused) {
      paused_ = true;
      RestoreHubVolume("Mac output switched away from Nest Hub (Cast)");
      ++generation_;
      streaming_ = false;
      connecting_ = false;
      RetireAgent();
      return;
    }
    std::string error;
    if (!capture_.Start(OptionsFor(want), &error)) {
      OSP_LOG_ERROR << "nestcast: audio capture failed: " << error;
    } else {
      LogCaptureStarted();
    }
    if (old == Mode::kPaused) {
      paused_ = false;
      backoff_ = kMinBackoff;
      const int gen = ++generation_;
      Connect(gen);
    }
  }

  // --- Volume: Mac volume keys control the Hub; the Hub's own volume is
  // saved first and restored whenever we hand the Hub back. ---

  static std::string SavedVolumePath() {
    const char* home = getenv("HOME");
    return std::string(home ? home : "") +
           "/Library/Application Support/nestcast/hub_volume";
  }

  void LoadSavedHubVolume() {
    std::ifstream in(SavedVolumePath());
    double level = 0;
    int muted = 0;
    if (in >> level >> muted) {
      saved_hub_volume_ = std::make_pair(level, muted != 0);
      OSP_LOG_INFO << "nestcast: pending Hub volume to restore: " << level
                   << (muted ? " (muted)" : "");
    }
  }

  void PersistSavedHubVolume() {
    const std::string path = SavedVolumePath();
    if (!saved_hub_volume_) {
      std::remove(path.c_str());
      return;
    }
    system(("mkdir -p \"" + path.substr(0, path.rfind('/')) + "\"").c_str());
    std::ofstream out(path);
    out << saved_hub_volume_->first << " " << (saved_hub_volume_->second ? 1 : 0)
        << "\n";
  }

  // Every RECEIVER_STATUS volume. The first one an agent sees arrives before
  // we LAUNCH (reply to GET_STATUS), i.e. it is the Hub's own volume.
  void OnHubVolume(double level, bool muted) {
    hub_volume_ = std::make_pair(level, muted);
    if (!saved_hub_volume_ && !streaming_) {
      saved_hub_volume_ = hub_volume_;
      PersistSavedHubVolume();
      OSP_LOG_INFO << "nestcast: saved Hub volume " << level
                   << (muted ? " (muted)" : "");
    }
  }

  void OnMacVolumeChanged() {
    CheckMode();  // The callback also fires when the default output changes.
    if (volume_push_pending_) {
      return;
    }
    volume_push_pending_ = true;
    // Debounce key-repeat bursts.
    runner_.PostTaskWithDelay(
        [this] {
          volume_push_pending_ = false;
          PushMacVolume(/*force=*/false);
        },
        milliseconds(60));
  }

  // Relative control: the Hub keeps its own level when a session starts
  // (the Mac is often at 100% because its speaker is muted), and each Mac
  // volume-key step moves the Hub by the same amount. Mute is mirrored.
  void BeginVolumeTracking() {
    double level = 0;
    bool muted = false;
    if (!mac_volume_ || !mac_volume_->Read(&level, &muted)) {
      mac_base_.reset();
      return;
    }
    mac_base_ = level;
    hub_base_ = hub_volume_ ? hub_volume_->first : 0.5;
    last_pushed_ = std::make_pair(hub_base_, muted);
  }

  void PushMacVolume(bool force) {
    double level = 0;
    bool muted = false;
    if (!streaming_ || !agent_ || !mac_volume_ || !mac_base_ ||
        !mac_volume_->Read(&level, &muted)) {
      return;
    }
    double hub = std::clamp(hub_base_ + (level - *mac_base_), 0.0, 1.0);
    // Re-anchor at the ends, so after hitting 0 or 1 the next step responds.
    if (hub == 0.0 || hub == 1.0) {
      mac_base_ = level;
      hub_base_ = hub;
    }
    if (!force && last_pushed_ && last_pushed_->first == hub &&
        last_pushed_->second == muted) {
      return;
    }
    last_pushed_ = std::make_pair(hub, muted);
    agent_->SetReceiverVolume(hub, muted);
    OSP_LOG_INFO << "nestcast: Hub volume " << hub << (muted ? " (muted)" : "")
                 << " (Mac " << level << ")";
  }

  void RestoreHubVolume(const char* why) {
    last_pushed_.reset();
    if (!saved_hub_volume_ || !agent_) {
      return;
    }
    agent_->SetReceiverVolume(saved_hub_volume_->first,
                              saved_hub_volume_->second);
    OSP_LOG_INFO << "nestcast: restored Hub volume " << saved_hub_volume_->first
                 << (saved_hub_volume_->second ? " (muted)" : "") << " ("
                 << why << ")";
    saved_hub_volume_.reset();
    PersistSavedHubVolume();
  }

  void LogCaptureStarted() {
    OSP_LOG_INFO << "nestcast: capturing "
                 << (capture_options_.include_pids.empty()
                         ? std::string("all system audio")
                         : std::to_string(capture_options_.include_pids.size()) +
                               " process(es)")
                 << " at " << capture_.sample_rate() << " Hz"
                 << (capture_options_.mute ? " (muted locally)" : "");
  }

  // Runs every 20 ms: drains the ring while idle and watches the capture.
  void Tick() {
    const auto now = Clock::now();
    if (!streaming_) {
      while (capture_.Peek()) {
        capture_.Release();
      }
    }
    if (++ticks_ % 50 == 0) {
      CheckMode();  // ~1 s: also notices the driver being (un)installed.
    }
    if (!sleeping_ && !stopping_ && !paused_) {
      // Measured on the IO thread's own clock, so a busy task runner can't
      // fake a stall.
      const double idle_s =
          (mach_absolute_time() - capture_.last_io_host_time()) * ns_per_tick_ /
          1e9;
      // A fresh tap may take a while to deliver its first buffer (e.g. while
      // macOS shows the audio-recording permission prompt), so only a tap
      // that has run and then stopped is rebuilt quickly.
      const double limit = capture_.callbacks() > 0
                               ? kCaptureStallTimeout.count()
                               : kFirstIoTimeout.count();
      if (idle_s > limit) {
        OSP_LOG_WARN << "nestcast: audio tap stalled (no IO for " << idle_s
                     << " s, callbacks so far " << capture_.callbacks()
                     << "); rebuilding";
        RestartCapture();
      }
      if (connecting_ && !streaming_ &&
          now - connect_started_ > kConnectTimeout) {
        OSP_LOG_WARN << "nestcast: no session after "
                     << kConnectTimeout.count() << " s; retrying";
        OnAgentDown(generation_);
      }
    }
    runner_.PostTaskWithDelay([this] { Tick(); }, milliseconds(20));
  }

  void RestartCapture() {
    capture_.Stop();
    std::string error;
    if (paused_) {
      return;
    }
    if (!capture_.Start(OptionsFor(mode_), &error)) {
      OSP_LOG_ERROR << "nestcast: audio capture restart failed: " << error;
      return;  // Tick() retries after the stall timeout.
    }
    LogCaptureStarted();
  }

  void Connect(int gen) {
    if (gen != generation_ || sleeping_ || stopping_ || paused_) {
      return;
    }
    retiring_.clear();  // Their STOP handshakes (<=500 ms) are long done.
    connecting_ = true;
    streaming_ = false;
    connect_started_ = Clock::now();

    std::string addr = target_;
    if (addr.find(':') == std::string::npos) {
      addr += ":" + std::to_string(kDefaultCastPort);
    }
    openscreen::ErrorOr<IPEndpoint> ep = IPEndpoint::Parse(addr);
    if (ep) {
      StartAgent(gen, ep.value());
      return;
    }
    // A Cast device ID or name: resolve it fresh via mDNS, off the runner.
    // With nothing configured, use a Nest Hub only if it is the ONLY one on
    // the network: on a shared network (office, dorm, rental) the first Hub
    // found could be a stranger's, which would then play this Mac's audio.
    const std::string wanted = target_;
    std::thread([this, gen, wanted] {
      std::optional<CastDevice> dev;
      std::string problem;
      if (wanted.empty()) {
        std::vector<CastDevice> hubs;
        for (const CastDevice& d : ListCastDevices(kDiscoveryTimeout)) {
          if (IsNestHub(d)) {
            hubs.push_back(d);
          }
        }
        if (hubs.size() == 1) {
          dev = hubs[0];
        } else if (hubs.empty()) {
          problem = "no Nest Hub found on the network";
        } else {
          problem = std::to_string(hubs.size()) +
                    " Nest Hubs found; choose one with \"Nestcast 스피커 선택\"";
        }
      } else {
        dev = FindCastDevice(wanted, kDiscoveryTimeout);
        if (!dev) {
          problem = "the chosen speaker was not found on the network";
        }
      }
      runner_.PostTask([this, gen, dev, problem] {
        if (gen != generation_) {
          return;
        }
        if (!dev) {
          OSP_LOG_WARN << "nestcast: " << problem;
          OnAgentDown(gen);
          return;
        }
        openscreen::ErrorOr<IPEndpoint> found = IPEndpoint::Parse(
            dev->address + ":" + std::to_string(dev->port));
        if (!found || dev->id.empty()) {
          OnAgentDown(gen);
          return;
        }
        OSP_LOG_INFO << "nestcast: found \"" << dev->friendly_name << "\" ("
                     << dev->model << ") at " << found.value();
        if (target_ != dev->id) {
          // First use, or upgrading a name-only config: remember the ID.
          if (target_.empty()) {
            OSP_LOG_INFO << "nestcast: the only Nest Hub on the network is \""
                         << dev->friendly_name << "\"; using it";
          }
          target_ = dev->id;
          SaveHub(dev->id, dev->friendly_name);
        }
        StartAgent(gen, found.value());
      });
    }).detach();
  }

  void StartAgent(int gen, const IPEndpoint& endpoint) {
    agent_ = std::make_unique<LoopingFileCastAgent>(
        runner_, CastTrustStore::Create(), [this, gen] { OnAgentDown(gen); });
    agent_->on_receiver_volume = [this](double level, bool muted) {
      OnHubVolume(level, muted);
    };
    agent_->on_yielding = [this] { RestoreHubVolume("yielding to another app"); };
    ConnectionSettings settings;
    settings.receiver_endpoint = endpoint;
    settings.max_bitrate = 2'000'000;
    settings.should_include_video = true;
    settings.should_include_audio = true;
    settings.use_android_rtp_hack = false;
    settings.should_loop_video = false;
    settings.codec = openscreen::cast::VideoCodec::kVp8;
    settings.enable_dscp = true;
    settings.yield_to_other_apps = true;
    if (busy_app_.empty()) {
      OSP_LOG_INFO << "nestcast: connecting to " << endpoint << " (playout "
                   << playout_ms_ << " ms)";
    }
    agent_->Connect(std::move(settings));
  }

  // Any end of a connection attempt or session: retire the agent and retry.
  void OnAgentDown(int gen) {
    if (gen != generation_) {
      return;  // Stale notification from an agent already replaced.
    }
    const int next = ++generation_;
    streaming_ = false;
    connecting_ = false;
    // If another app (e.g. YouTube cast from a phone) is using the Hub, don't
    // take it over: poll until the Hub is idle again, then resume.
    const std::string busy = agent_ ? agent_->busy_app() : std::string();
    runner_.PostTask([this, next, busy] {
      RetireAgent();
      if (sleeping_ || stopping_ || paused_ || next != generation_) {
        return;
      }
      if (!busy.empty()) {
        if (busy != busy_app_) {
          OSP_LOG_INFO << "nestcast: Hub is in use by " << busy
                       << "; yielding, will resume when it is idle";
        }
        busy_app_ = busy;
        backoff_ = kMinBackoff;
        runner_.PostTaskWithDelay([this, next] { Connect(next); },
                                  kBusyPollInterval);
        return;
      }
      if (!busy_app_.empty()) {
        OSP_LOG_INFO << "nestcast: Hub is idle again; resuming";
        busy_app_.clear();
      }
      OSP_LOG_INFO << "nestcast: reconnecting in " << backoff_.count()
                   << " ms";
      runner_.PostTaskWithDelay([this, next] { Connect(next); }, backoff_);
      backoff_ = std::min(backoff_ * 2, kMaxBackoff);
    });
  }

  void RetireAgent() {
    if (agent_) {
      agent_->RequestStop();
      retiring_.push_back(std::move(agent_));
    }
  }

  void OnWillSleep(std::function<void()> done) {
    OSP_LOG_INFO << "nestcast: system going to sleep; stopping session";
    RestoreHubVolume("going to sleep");
    sleeping_ = true;
    ++generation_;
    streaming_ = false;
    connecting_ = false;
    RetireAgent();
    // Let the STOP reach the Hub, then release the tap and allow sleep.
    runner_.PostTaskWithDelay(
        [this, done] {
          capture_.Stop();
          done();
        },
        milliseconds(700));
  }

  void OnDidWake() {
    OSP_LOG_INFO << "nestcast: system woke up; resuming in "
                 << kWakeSettleTime.count() << " s";
    const int gen = ++generation_;
    runner_.PostTaskWithDelay(
        [this, gen] {
          if (gen != generation_) {
            return;
          }
          sleeping_ = false;
          RestartCapture();
          backoff_ = kMinBackoff;
          Connect(gen);
        },
        kWakeSettleTime);
  }

  TaskRunnerImpl& runner_;
  // Cast device ID (or legacy name / IP). Empty: use the only Nest Hub.
  std::string target_;
  const int playout_ms_;
  const TapCapture::Options capture_options_;
  const bool show_clock_;

  TapCapture capture_;
  std::unique_ptr<SystemEvents> events_;
  std::unique_ptr<LoopingFileCastAgent> agent_;
  std::vector<std::unique_ptr<LoopingFileCastAgent>> retiring_;

  std::string busy_app_;  // Non-empty while yielding to another app.
  std::unique_ptr<MacVolume> mac_volume_;
  std::optional<std::pair<double, bool>> saved_hub_volume_;  // To restore.
  std::optional<std::pair<double, bool>> hub_volume_;        // Last reported.
  std::optional<std::pair<double, bool>> last_pushed_;
  bool volume_push_pending_ = false;
  std::optional<double> mac_base_;  // Mac level when tracking began.
  double hub_base_ = 0.5;           // Hub level when tracking began.
  int generation_ = 0;
  milliseconds backoff_ = kMinBackoff;
  bool streaming_ = false;
  bool connecting_ = false;
  bool sleeping_ = false;
  bool paused_ = false;
  Mode mode_ = Mode::kTap;
  uint64_t ticks_ = 0;
  bool stopping_ = false;
  Clock::time_point connect_started_{};
  const double ns_per_tick_ = [] {
    mach_timebase_info_data_t tb;
    mach_timebase_info(&tb);
    return static_cast<double>(tb.numer) / tb.denom;
  }();
};

int Main(int argc, char* argv[]) {
  int playout_ms = 300;
  bool verbose = false;
  bool show_clock = true;
  TapCapture::Options capture_options;
  std::string target;
  for (int i = 1; i < argc; ++i) {
    std::string a = argv[i];
    if (a == "--playout" && i + 1 < argc) {
      playout_ms = std::atoi(argv[++i]);
    } else if (a == "--pid" && i + 1 < argc) {
      capture_options.include_pids.push_back(std::atoi(argv[++i]));
    } else if (a == "--mute") {
      capture_options.mute = true;
    } else if (a == "--screen" && i + 1 < argc) {
      show_clock = std::string(argv[++i]) != "black";
    } else if (a == "--list") {
      for (const CastDevice& d : ListCastDevices(milliseconds(4000))) {
        std::cout << d.friendly_name << "\t" << d.model << "\t" << d.id
                  << "\n";
      }
      return 0;
    } else if (a == "-v") {
      verbose = true;
    } else if (!a.empty() && a[0] != '-' && target.empty()) {
      target = a;
    } else {
      Usage(argv[0]);
      return 1;
    }
  }
  if (target.empty()) {
    target = LoadHubIdOrName();  // May stay empty: see Connect().
  }
  if (playout_ms < 50 || playout_ms > 5000) {
    Usage(argv[0]);
    return 1;
  }
  // Consumed by the (patched) LoopingFileCastAgent when building the OFFER.
  setenv("CAST_PLAYOUT_MS", std::to_string(playout_ms).c_str(), 1);
  openscreen::SetLogLevel(verbose ? openscreen::LogLevel::kVerbose
                                  : openscreen::LogLevel::kInfo);

  auto* const runner = new TaskRunnerImpl(&Clock::now);
  openscreen::PlatformClientPosix::Create(
      milliseconds(50), std::unique_ptr<TaskRunnerImpl>(runner));

  auto supervisor = std::make_unique<Supervisor>(*runner, target, playout_ms,
                                                 capture_options, show_clock);
  if (!supervisor->Start()) {
    openscreen::PlatformClientPosix::ShutDown();
    return 2;
  }
  runner->RunUntilSignaled();

  OSP_LOG_INFO << "nestcast: shutting down...";
  runner->PostTask([&] {
    supervisor->Stop();
    runner->PostTaskWithDelay([&] { runner->RequestStopSoon(); },
                              milliseconds(700));
  });
  runner->RunUntilStopped();
  runner->PostTask([&] {
    supervisor->Destroy();
    runner->RequestStopSoon();
  });
  runner->RunUntilStopped();
  supervisor.reset();
  openscreen::PlatformClientPosix::ShutDown();
  OSP_LOG_INFO << "nestcast: bye";
  return 0;
}

}  // namespace
}  // namespace nestcast

int main(int argc, char* argv[]) {
  std::signal(SIGPIPE, SIG_IGN);
  return nestcast::Main(argc, argv);
}
