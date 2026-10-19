// refbeep: play 2 kHz / 50 ms beeps on the Mac's built-in speaker at
// T0 + n seconds (n = first..last), where T0 is a Unix-epoch microsecond
// timestamp read from a file written by cast_sender (CAST_SYNC_FILE).
// Usage: refbeep <sync_file | @epoch_us> [first=1] [last=30] [freq_hz=2000] [default]
import AVFoundation
import CoreAudio
import Foundation

func builtInOutputDevice() -> AudioDeviceID? {
  var addr = AudioObjectPropertyAddress(
    mSelector: kAudioHardwarePropertyDevices,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain)
  var size: UInt32 = 0
  AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size)
  var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
  AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids)
  for id in ids {
    var t: UInt32 = 0
    var tsize = UInt32(MemoryLayout<UInt32>.size)
    var taddr = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyTransportType,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    AudioObjectGetPropertyData(id, &taddr, 0, nil, &tsize, &t)
    var saddr = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyStreams,
      mScope: kAudioDevicePropertyScopeOutput,
      mElement: kAudioObjectPropertyElementMain)
    var ssize: UInt32 = 0
    AudioObjectGetPropertyDataSize(id, &saddr, 0, nil, &ssize)
    if t == kAudioDeviceTransportTypeBuiltIn && ssize > 0 { return id }
  }
  return nil
}

let args = CommandLine.arguments
guard args.count >= 2 else {
  print("usage: refbeep <sync_file> [first] [last]")
  exit(2)
}
let syncPath = args[1]
let first = args.count > 2 ? Int(args[2])! : 1
let last = args.count > 3 ? Int(args[3])! : 30
let freq = args.count > 4 ? Double(args[4])! : 2000.0
let useDefaultOutput = args.count > 5 && args[5] == "default"
setvbuf(stdout, nil, _IOLBF, 0)

let engine = AVAudioEngine()
if useDefaultOutput {
  print("refbeep: output device = system default")
} else if let dev = builtInOutputDevice() {
  var d = dev
  let err = AudioUnitSetProperty(
    engine.outputNode.audioUnit!, kAudioOutputUnitProperty_CurrentDevice,
    kAudioUnitScope_Global, 0, &d, UInt32(MemoryLayout<AudioDeviceID>.size))
  print("refbeep: output device = built-in (id \(dev)), set err=\(err)")
} else {
  print("refbeep: WARNING built-in output not found, using default output")
}
let player = AVAudioPlayerNode()
engine.attach(player)
let fmt = engine.outputNode.outputFormat(forBus: 0)
let monoFmt = AVAudioFormat(standardFormatWithSampleRate: fmt.sampleRate, channels: fmt.channelCount)!
engine.connect(player, to: engine.mainMixerNode, format: monoFmt)

let sr = fmt.sampleRate
let n = AVAudioFrameCount(sr * 0.05)
let buf = AVAudioPCMBuffer(pcmFormat: monoFmt, frameCapacity: n)!
buf.frameLength = n
for ch in 0..<Int(monoFmt.channelCount) {
  let p = buf.floatChannelData![ch]
  for i in 0..<Int(n) { p[i] = 0.8 * Float(sin(2.0 * Double.pi * freq * Double(i) / sr)) }
}

try engine.start()
player.play()
let outLatency = engine.outputNode.presentationLatency
print("refbeep: sample rate \(sr), output presentationLatency \(Int(outLatency * 1000)) ms (compensated)")

// Wait for the sync file.
print("refbeep: waiting for \(syncPath) ...")
var t0us: Int64 = 0
if syncPath.hasPrefix("@") { t0us = Int64(syncPath.dropFirst())! }
while t0us == 0 {
  if let s = try? String(contentsOfFile: syncPath, encoding: .utf8),
     let v = Int64(s.trimmingCharacters(in: .whitespacesAndNewlines)) { t0us = v; break }
  usleep(2000)
}
var tb = mach_timebase_info_data_t()
mach_timebase_info(&tb)
func epochToHost(_ epochSec: Double) -> UInt64 {
  let nowEpoch = Date().timeIntervalSince1970
  let nowHost = mach_absolute_time()
  let dtNs = (epochSec - nowEpoch) * 1e9
  return UInt64(Double(nowHost) + dtNs * Double(tb.denom) / Double(tb.numer))
}
let t0 = Double(t0us) / 1e6
print("refbeep: \(Int(freq)) Hz, T0 = \(t0us) us; scheduling beeps at T0+\(first)s .. T0+\(last)s")
for k in first...last {
  let target = t0 + Double(k) - outLatency
  let when = AVAudioTime(hostTime: epochToHost(target))
  player.scheduleBuffer(buf, at: when, options: [], completionHandler: nil)
}
let endEpoch = t0 + Double(last) + 1.0
while Date().timeIntervalSince1970 < endEpoch { usleep(100_000) }
print("refbeep: done")
