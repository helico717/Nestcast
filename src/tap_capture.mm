#include "nestcast/tap_capture.h"

#import <AudioToolbox/AudioToolbox.h>
#import <CoreAudio/AudioHardware.h>
#import <CoreAudio/AudioHardwareTapping.h>
#import <CoreAudio/CATapDescription.h>
#import <Foundation/Foundation.h>
#include <mach/mach_time.h>
#include <unistd.h>

#include <algorithm>
#include <cstring>

namespace nestcast {
namespace {

std::string StatusString(OSStatus s) {
  char c[5] = {static_cast<char>((s >> 24) & 0xff),
               static_cast<char>((s >> 16) & 0xff),
               static_cast<char>((s >> 8) & 0xff), static_cast<char>(s & 0xff),
               0};
  for (int i = 0; i < 4; ++i) {
    if (c[i] < 32 || c[i] > 126) {
      return std::to_string(s);
    }
  }
  return std::string("'") + c + "' (" + std::to_string(s) + ")";
}

AudioObjectID ProcessObjectForPid(pid_t pid) {
  AudioObjectPropertyAddress addr = {
      kAudioHardwarePropertyTranslatePIDToProcessObject,
      kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
  AudioObjectID obj = kAudioObjectUnknown;
  UInt32 size = sizeof(obj);
  if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &addr, sizeof(pid),
                                 &pid, &size, &obj) != noErr) {
    return kAudioObjectUnknown;
  }
  return obj;
}

// The built-in output device is used as the aggregate's clock source: it is
// always present and its clock is stable.
NSString* BuiltInOutputUID(AudioDeviceID* out_id = nullptr) {
  AudioObjectPropertyAddress addr = {kAudioHardwarePropertyDevices,
                                     kAudioObjectPropertyScopeGlobal,
                                     kAudioObjectPropertyElementMain};
  UInt32 size = 0;
  AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &addr, 0, nullptr,
                                 &size);
  std::vector<AudioDeviceID> ids(size / sizeof(AudioDeviceID));
  AudioObjectGetPropertyData(kAudioObjectSystemObject, &addr, 0, nullptr,
                             &size, ids.data());
  for (AudioDeviceID id : ids) {
    UInt32 transport = 0;
    UInt32 tsize = sizeof(transport);
    AudioObjectPropertyAddress taddr = {kAudioDevicePropertyTransportType,
                                        kAudioObjectPropertyScopeGlobal,
                                        kAudioObjectPropertyElementMain};
    AudioObjectGetPropertyData(id, &taddr, 0, nullptr, &tsize, &transport);
    AudioObjectPropertyAddress saddr = {kAudioDevicePropertyStreams,
                                        kAudioDevicePropertyScopeOutput,
                                        kAudioObjectPropertyElementMain};
    UInt32 ssize = 0;
    AudioObjectGetPropertyDataSize(id, &saddr, 0, nullptr, &ssize);
    if (transport != kAudioDeviceTransportTypeBuiltIn || ssize == 0) {
      continue;
    }
    CFStringRef uid = nullptr;
    UInt32 usize = sizeof(uid);
    AudioObjectPropertyAddress uaddr = {kAudioDevicePropertyDeviceUID,
                                        kAudioObjectPropertyScopeGlobal,
                                        kAudioObjectPropertyElementMain};
    if (AudioObjectGetPropertyData(id, &uaddr, 0, nullptr, &usize, &uid) ==
            noErr &&
        uid) {
      if (out_id) {
        *out_id = id;
      }
      return (__bridge_transfer NSString*)uid;
    }
  }
  return nil;
}

}  // namespace

TapCapture::TapCapture() : ring_(new CaptureChunk[kRingSize]) {}

TapCapture::~TapCapture() {
  Stop();
}

// static
uint32_t TapCapture::FindDevice(const std::string& uid) {
  CFStringRef cf = CFStringCreateWithCString(nullptr, uid.c_str(),
                                             kCFStringEncodingUTF8);
  AudioObjectID dev = kAudioObjectUnknown;
  AudioValueTranslation t = {&cf, sizeof(cf), &dev, sizeof(dev)};
  UInt32 size = sizeof(t);
  AudioObjectPropertyAddress addr = {kAudioHardwarePropertyDeviceForUID,
                                     kAudioObjectPropertyScopeGlobal,
                                     kAudioObjectPropertyElementMain};
  AudioObjectGetPropertyData(kAudioObjectSystemObject, &addr, 0, nullptr,
                             &size, &t);
  CFRelease(cf);
  return dev;
}

// static
std::string TapCapture::DefaultOutputUID() {
  AudioObjectPropertyAddress addr = {kAudioHardwarePropertyDefaultOutputDevice,
                                     kAudioObjectPropertyScopeGlobal,
                                     kAudioObjectPropertyElementMain};
  AudioDeviceID dev = kAudioObjectUnknown;
  UInt32 size = sizeof(dev);
  if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &addr, 0, nullptr,
                                 &size, &dev) != noErr) {
    return {};
  }
  CFStringRef uid = nullptr;
  size = sizeof(uid);
  AudioObjectPropertyAddress uaddr = {kAudioDevicePropertyDeviceUID,
                                      kAudioObjectPropertyScopeGlobal,
                                      kAudioObjectPropertyElementMain};
  if (AudioObjectGetPropertyData(dev, &uaddr, 0, nullptr, &size, &uid) !=
          noErr ||
      !uid) {
    return {};
  }
  char buf[512] = {};
  CFStringGetCString(uid, buf, sizeof(buf), kCFStringEncodingUTF8);
  CFRelease(uid);
  return buf;
}

bool TapCapture::StartDevice(const std::string& uid, std::string* error) {
  const AudioDeviceID dev = FindDevice(uid);
  if (dev == kAudioObjectUnknown) {
    *error = "device not found: " + uid;
    return false;
  }
  Float64 rate = 0;
  UInt32 size = sizeof(rate);
  AudioObjectPropertyAddress raddr = {kAudioDevicePropertyNominalSampleRate,
                                      kAudioObjectPropertyScopeGlobal,
                                      kAudioObjectPropertyElementMain};
  AudioObjectGetPropertyData(dev, &raddr, 0, nullptr, &size, &rate);
  sample_rate_ = rate;
  TapCapture* self = this;
  AudioDeviceIOProcID proc_id = nullptr;
  OSStatus st = AudioDeviceCreateIOProcIDWithBlock(
      &proc_id, dev, nullptr,
      ^(const AudioTimeStamp*, const AudioBufferList* in_data,
        const AudioTimeStamp* in_time, AudioBufferList*,
        const AudioTimeStamp*) {
        if (!in_data || in_data->mNumberBuffers == 0) {
          return;
        }
        const void* bufs[4];
        uint32_t bytes[4];
        uint32_t chans[4];
        const uint32_t n = std::min<uint32_t>(in_data->mNumberBuffers, 4);
        for (uint32_t i = 0; i < n; ++i) {
          bufs[i] = in_data->mBuffers[i].mData;
          bytes[i] = in_data->mBuffers[i].mDataByteSize;
          chans[i] = in_data->mBuffers[i].mNumberChannels;
        }
        self->OnInput(in_time->mHostTime, in_time->mSampleTime, bufs, bytes,
                      chans, n);
      });
  if (st != noErr) {
    *error = "AudioDeviceCreateIOProcIDWithBlock(device) failed: " +
             StatusString(st);
    return false;
  }
  io_proc_id_ = reinterpret_cast<void*>(proc_id);
  device_id_ = dev;
  st = AudioDeviceStart(dev, proc_id);
  if (st != noErr) {
    *error = "AudioDeviceStart(device) failed: " + StatusString(st);
    Stop();
    return false;
  }
  return true;
}

bool TapCapture::Start(const Options& options, std::string* error) {
  last_io_host_time_.store(mach_absolute_time());
  callbacks_.store(0);
  if (!options.device_uid.empty()) {
    return StartDevice(options.device_uid, error);
  }
  @autoreleasepool {
    CATapDescription* desc = nil;
    if (options.include_pids.empty()) {
      // This process is deliberately NOT excluded: its keepalive output (pure
      // silence) is what keeps the tap delivering IO when nothing else plays.
      desc = [[CATapDescription alloc]
          initStereoGlobalTapButExcludeProcesses:@[]];
    } else {
      NSMutableArray<NSNumber*>* include = [NSMutableArray array];
      for (pid_t pid : options.include_pids) {
        AudioObjectID obj = ProcessObjectForPid(pid);
        if (obj == kAudioObjectUnknown) {
          *error = "no Core Audio process object for pid " +
                   std::to_string(pid) +
                   " (has it opened an audio output yet?)";
          return false;
        }
        [include addObject:@(obj)];
      }
      desc = [[CATapDescription alloc] initStereoMixdownOfProcesses:include];
    }
    desc.name = @"nestcast tap";
    desc.privateTap = YES;
    desc.muteBehavior = options.mute ? CATapMutedWhenTapped : CATapUnmuted;

    AudioObjectID tap = kAudioObjectUnknown;
    OSStatus st = AudioHardwareCreateProcessTap(desc, &tap);
    if (st != noErr) {
      *error = "AudioHardwareCreateProcessTap failed: " + StatusString(st);
      return false;
    }
    tap_id_ = tap;

    AudioStreamBasicDescription fmt = {};
    UInt32 size = sizeof(fmt);
    AudioObjectPropertyAddress faddr = {kAudioTapPropertyFormat,
                                        kAudioObjectPropertyScopeGlobal,
                                        kAudioObjectPropertyElementMain};
    st = AudioObjectGetPropertyData(tap, &faddr, 0, nullptr, &size, &fmt);
    if (st != noErr) {
      *error = "reading tap format failed: " + StatusString(st);
      Stop();
      return false;
    }
    if (fmt.mFormatID != kAudioFormatLinearPCM ||
        !(fmt.mFormatFlags & kAudioFormatFlagIsFloat) ||
        fmt.mBitsPerChannel != 32 || fmt.mChannelsPerFrame != kChannels) {
      *error = "unexpected tap format (need float32 stereo)";
      Stop();
      return false;
    }
    sample_rate_ = fmt.mSampleRate;

    AudioDeviceID builtin_id = 0;
    NSString* main_uid = BuiltInOutputUID(&builtin_id);
    if (!main_uid) {
      *error = "built-in output device not found";
      Stop();
      return false;
    }
    NSString* agg_uid = [[NSUUID UUID] UUIDString];
    NSDictionary* agg = @{
      @kAudioAggregateDeviceNameKey : @"nestcast capture",
      @kAudioAggregateDeviceUIDKey : agg_uid,
      @kAudioAggregateDeviceMainSubDeviceKey : main_uid,
      @kAudioAggregateDeviceIsPrivateKey : @YES,
      @kAudioAggregateDeviceIsStackedKey : @NO,
      @kAudioAggregateDeviceTapAutoStartKey : @YES,
      @kAudioAggregateDeviceSubDeviceListKey :
          @[ @{@kAudioSubDeviceUIDKey : main_uid} ],
      @kAudioAggregateDeviceTapListKey : @[ @{
        @kAudioSubTapDriftCompensationKey : @YES,
        @kAudioSubTapUIDKey : [desc.UUID UUIDString],
      } ],
    };
    AudioObjectID agg_id = kAudioObjectUnknown;
    st = AudioHardwareCreateAggregateDevice((__bridge CFDictionaryRef)agg,
                                            &agg_id);
    if (st != noErr) {
      *error = "AudioHardwareCreateAggregateDevice failed: " + StatusString(st);
      Stop();
      return false;
    }
    aggregate_id_ = agg_id;

    TapCapture* self = this;
    AudioDeviceIOProcID proc_id = nullptr;
    st = AudioDeviceCreateIOProcIDWithBlock(
        &proc_id, agg_id, nullptr,
        ^(const AudioTimeStamp* in_now, const AudioBufferList* in_data,
          const AudioTimeStamp* in_time, AudioBufferList* out_data,
          const AudioTimeStamp* out_time) {
          if (!in_data || in_data->mNumberBuffers == 0) {
            return;
          }
          const void* bufs[4];
          uint32_t bytes[4];
          uint32_t chans[4];
          const uint32_t n = std::min<uint32_t>(in_data->mNumberBuffers, 4);
          for (uint32_t i = 0; i < n; ++i) {
            bufs[i] = in_data->mBuffers[i].mData;
            bytes[i] = in_data->mBuffers[i].mDataByteSize;
            chans[i] = in_data->mBuffers[i].mNumberChannels;
          }
          self->OnInput(in_time->mHostTime, in_time->mSampleTime, bufs, bytes,
                        chans, n);
        });
    if (st != noErr) {
      *error = "AudioDeviceCreateIOProcIDWithBlock failed: " + StatusString(st);
      Stop();
      return false;
    }
    io_proc_id_ = reinterpret_cast<void*>(proc_id);
    st = AudioDeviceStart(agg_id, proc_id);
    if (st != noErr) {
      *error = "AudioDeviceStart failed: " + StatusString(st);
      Stop();
      return false;
    }

    // Keep the built-in output running with silence (output buffers are
    // pre-zeroed by the HAL; this process is excluded from the global tap).
    AudioDeviceIOProcID keepalive = nullptr;
    if (AudioDeviceCreateIOProcIDWithBlock(
            &keepalive, builtin_id, nullptr,
            ^(const AudioTimeStamp*, const AudioBufferList*,
              const AudioTimeStamp*, AudioBufferList*,
              const AudioTimeStamp*) {
            }) == noErr &&
        AudioDeviceStart(builtin_id, keepalive) == noErr) {
      keepalive_device_ = builtin_id;
      keepalive_proc_id_ = reinterpret_cast<void*>(keepalive);
    }
  }
  return true;
}

void TapCapture::Stop() {
  if (keepalive_device_ && keepalive_proc_id_) {
    auto proc = reinterpret_cast<AudioDeviceIOProcID>(keepalive_proc_id_);
    AudioDeviceStop(keepalive_device_, proc);
    AudioDeviceDestroyIOProcID(keepalive_device_, proc);
  }
  keepalive_device_ = 0;
  keepalive_proc_id_ = nullptr;
  if (aggregate_id_ && io_proc_id_) {
    auto proc = reinterpret_cast<AudioDeviceIOProcID>(io_proc_id_);
    AudioDeviceStop(aggregate_id_, proc);
    AudioDeviceDestroyIOProcID(aggregate_id_, proc);
  }
  if (device_id_ && io_proc_id_) {
    auto proc = reinterpret_cast<AudioDeviceIOProcID>(io_proc_id_);
    AudioDeviceStop(device_id_, proc);
    AudioDeviceDestroyIOProcID(device_id_, proc);
  }
  device_id_ = 0;
  io_proc_id_ = nullptr;
  if (aggregate_id_) {
    AudioHardwareDestroyAggregateDevice(aggregate_id_);
    aggregate_id_ = 0;
  }
  if (tap_id_) {
    AudioHardwareDestroyProcessTap(tap_id_);
    tap_id_ = 0;
  }
}

void TapCapture::OnInput(uint64_t host_time,
                         double sample_time,
                         const void* const* buffers,
                         const uint32_t* buffer_bytes,
                         const uint32_t* buffer_channels,
                         uint32_t num_buffers) {
  callbacks_.fetch_add(1, std::memory_order_relaxed);
  last_io_host_time_.store(mach_absolute_time(), std::memory_order_relaxed);
  // Interleaved stereo in one buffer, or one mono buffer per channel.
  int frames = 0;
  if (num_buffers == 1 && buffer_channels[0] == kChannels) {
    frames = buffer_bytes[0] / (sizeof(float) * kChannels);
  } else if (num_buffers >= 2) {
    frames = buffer_bytes[0] / sizeof(float);
  } else {
    return;
  }
  frames = std::min(frames, kMaxChunkFrames);

  const size_t w = write_index_.load(std::memory_order_relaxed);
  const size_t r = read_index_.load(std::memory_order_acquire);
  if (w - r >= kRingSize) {
    overruns_.fetch_add(1, std::memory_order_relaxed);
    return;
  }
  CaptureChunk& c = ring_[w & (kRingSize - 1)];
  c.host_time = host_time;
  c.sample_time = sample_time;
  c.frames = frames;
  if (num_buffers == 1) {
    std::memcpy(c.data, buffers[0], frames * sizeof(float) * kChannels);
  } else {
    const float* l = static_cast<const float*>(buffers[0]);
    const float* rr = static_cast<const float*>(buffers[1]);
    for (int i = 0; i < frames; ++i) {
      c.data[2 * i] = l[i];
      c.data[2 * i + 1] = rr[i];
    }
  }
  write_index_.store(w + 1, std::memory_order_release);

  float peak = 0;
  for (int i = 0; i < frames * kChannels; ++i) {
    const float v = c.data[i] < 0 ? -c.data[i] : c.data[i];
    if (v > peak) peak = v;
  }
  uint32_t bits;
  memcpy(&bits, &peak, sizeof(bits));
  uint32_t prev = peak_bits_.load(std::memory_order_relaxed);
  while (bits > prev &&
         !peak_bits_.compare_exchange_weak(prev, bits, std::memory_order_relaxed)) {
  }
}

// static
bool TapCapture::OtherProcessesPlaying() {
  AudioObjectPropertyAddress addr = {kAudioHardwarePropertyProcessObjectList,
                                     kAudioObjectPropertyScopeGlobal,
                                     kAudioObjectPropertyElementMain};
  UInt32 size = 0;
  if (AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &addr, 0,
                                     nullptr, &size) != noErr) {
    return false;
  }
  std::vector<AudioObjectID> procs(size / sizeof(AudioObjectID));
  AudioObjectGetPropertyData(kAudioObjectSystemObject, &addr, 0, nullptr,
                             &size, procs.data());
  const pid_t self = getpid();
  for (AudioObjectID p : procs) {
    pid_t pid = 0;
    UInt32 psize = sizeof(pid);
    AudioObjectPropertyAddress paddr = {kAudioProcessPropertyPID,
                                        kAudioObjectPropertyScopeGlobal,
                                        kAudioObjectPropertyElementMain};
    AudioObjectGetPropertyData(p, &paddr, 0, nullptr, &psize, &pid);
    UInt32 running = 0;
    UInt32 rsize = sizeof(running);
    AudioObjectPropertyAddress raddr = {kAudioProcessPropertyIsRunningOutput,
                                        kAudioObjectPropertyScopeGlobal,
                                        kAudioObjectPropertyElementMain};
    AudioObjectGetPropertyData(p, &raddr, 0, nullptr, &rsize, &running);
    if (pid != self && running) {
      return true;
    }
  }
  return false;
}

const CaptureChunk* TapCapture::Peek() {
  const size_t r = read_index_.load(std::memory_order_relaxed);
  const size_t w = write_index_.load(std::memory_order_acquire);
  if (r == w) {
    return nullptr;
  }
  return &ring_[r & (kRingSize - 1)];
}

void TapCapture::Release() {
  read_index_.fetch_add(1, std::memory_order_release);
}

}  // namespace nestcast
