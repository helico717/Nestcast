// Nestcast menu bar app: a remote control for the Nestcast engine.
//
// The engine (Nestcast.app, started by launchd) does all the streaming and
// keeps running when this app quits. The two talk through files in
// ~/Library/Application Support/nestcast:
//   enabled      0/1 — "Mac 오디오 전송" switch (written here)
//   hub          chosen speaker: Cast device ID, then name (written here)
//   refresh      touch to ask the engine for a fresh speaker list
//   status.json  engine state + speakers on the network (written by engine)
import AppKit
import CoreAudio

let kVirtualDeviceUID = "Nest Hub (Cast)_UID"

// MARK: - Files shared with the engine

let configDir = FileManager.default.homeDirectoryForCurrentUser
  .appendingPathComponent("Library/Application Support/nestcast")

struct Speaker: Decodable {
  let name: String
  let model: String
  let id: String
}

struct EngineStatus: Decodable {
  let state: String  // off | output_not_cast | sleeping | yielded | streaming | connecting
  let hub_id: String
  let hub_name: String
  let busy_app: String
  let problem: String
  let devices: [Speaker]
}

func readStatus() -> (EngineStatus, Date)? {
  let url = configDir.appendingPathComponent("status.json")
  guard let data = try? Data(contentsOf: url),
        let status = try? JSONDecoder().decode(EngineStatus.self, from: data),
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
        let mtime = attrs[.modificationDate] as? Date else { return nil }
  return (status, mtime)
}

func writeConfig(_ name: String, _ contents: String) {
  try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
  try? contents.write(to: configDir.appendingPathComponent(name), atomically: true, encoding: .utf8)
}

func readEnabled() -> Bool {
  let v = (try? String(contentsOf: configDir.appendingPathComponent("enabled"), encoding: .utf8)) ?? "1"
  return v.trimmingCharacters(in: .whitespacesAndNewlines) != "0"
}

// MARK: - Core Audio output switching

func deviceID(forUID uid: String) -> AudioDeviceID? {
  var cfUID = uid as CFString
  var dev = AudioDeviceID(kAudioObjectUnknown)
  var size = UInt32(MemoryLayout<AudioValueTranslation>.size)
  var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDeviceForUID,
                                        mScope: kAudioObjectPropertyScopeGlobal,
                                        mElement: kAudioObjectPropertyElementMain)
  let status = withUnsafeMutablePointer(to: &cfUID) { uidPtr in
    withUnsafeMutablePointer(to: &dev) { devPtr in
      var t = AudioValueTranslation(mInputData: uidPtr, mInputDataSize: UInt32(MemoryLayout<CFString>.size),
                                    mOutputData: devPtr, mOutputDataSize: UInt32(MemoryLayout<AudioDeviceID>.size))
      return AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &t)
    }
  }
  return status == noErr && dev != kAudioObjectUnknown ? dev : nil
}

func defaultOutputDevice() -> AudioDeviceID {
  var dev = AudioDeviceID(kAudioObjectUnknown)
  var size = UInt32(MemoryLayout<AudioDeviceID>.size)
  var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                        mScope: kAudioObjectPropertyScopeGlobal,
                                        mElement: kAudioObjectPropertyElementMain)
  AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev)
  return dev
}

func deviceUID(_ dev: AudioDeviceID) -> String? {
  var uid: Unmanaged<CFString>?
  var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
  var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID,
                                        mScope: kAudioObjectPropertyScopeGlobal,
                                        mElement: kAudioObjectPropertyElementMain)
  guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &uid) == noErr,
        let u = uid?.takeRetainedValue() else { return nil }
  return u as String
}

func builtInOutputDevice() -> AudioDeviceID? {
  var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                        mScope: kAudioObjectPropertyScopeGlobal,
                                        mElement: kAudioObjectPropertyElementMain)
  var size: UInt32 = 0
  AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size)
  var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
  AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids)
  for id in ids {
    var transport: UInt32 = 0
    var tsize = UInt32(MemoryLayout<UInt32>.size)
    var taddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType,
                                           mScope: kAudioObjectPropertyScopeGlobal,
                                           mElement: kAudioObjectPropertyElementMain)
    AudioObjectGetPropertyData(id, &taddr, 0, nil, &tsize, &transport)
    var saddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                           mScope: kAudioDevicePropertyScopeOutput,
                                           mElement: kAudioObjectPropertyElementMain)
    var ssize: UInt32 = 0
    AudioObjectGetPropertyDataSize(id, &saddr, 0, nil, &ssize)
    if transport == kAudioDeviceTransportTypeBuiltIn && ssize > 0 { return id }
  }
  return nil
}

func setDefaultOutput(_ dev: AudioDeviceID) {
  var d = dev
  for selector in [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDefaultSystemOutputDevice] {
    var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                          mElement: kAudioObjectPropertyElementMain)
    AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil,
                               UInt32(MemoryLayout<AudioDeviceID>.size), &d)
  }
}

// Output used before switching to "Nest Hub (Cast)", restored when sending is
// switched off (falls back to the built-in speakers).
let previousOutputKey = "previousOutputUID"

func switchOutputToCast() {
  guard let cast = deviceID(forUID: kVirtualDeviceUID) else { return }
  let current = defaultOutputDevice()
  if current != cast, let uid = deviceUID(current) {
    UserDefaults.standard.set(uid, forKey: previousOutputKey)
  }
  setDefaultOutput(cast)
}

func switchOutputAwayFromCast() {
  guard let cast = deviceID(forUID: kVirtualDeviceUID), defaultOutputDevice() == cast else { return }
  if let uid = UserDefaults.standard.string(forKey: previousOutputKey), let prev = deviceID(forUID: uid) {
    setDefaultOutput(prev)
  } else if let builtIn = builtInOutputDevice() {
    setDefaultOutput(builtIn)
  }
}

func outputIsCast() -> Bool {
  deviceUID(defaultOutputDevice()) == kVirtualDeviceUID
}

// MARK: - Menu

final class SwitchView: NSView {
  let toggle = NSSwitch()
  let label = NSTextField(labelWithString: "Mac 오디오 전송")
  var onChange: ((Bool) -> Void)?

  init() {
    super.init(frame: NSRect(x: 0, y: 0, width: 300, height: 30))
    label.font = .systemFont(ofSize: 13, weight: .semibold)
    label.translatesAutoresizingMaskIntoConstraints = false
    toggle.translatesAutoresizingMaskIntoConstraints = false
    toggle.controlSize = .small
    toggle.target = self
    toggle.action = #selector(changed)
    addSubview(label)
    addSubview(toggle)
    NSLayoutConstraint.activate([
      label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
      label.centerYAnchor.constraint(equalTo: centerYAnchor),
      toggle.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
      toggle.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])
  }
  required init?(coder: NSCoder) { fatalError() }
  @objc func changed() { onChange?(toggle.state == .on) }
}

final class NoteView: NSView {
  init(symbol: String, tint: NSColor, text: String, width: CGFloat = 300) {
    super.init(frame: .zero)
    let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
    icon.contentTintColor = tint
    icon.translatesAutoresizingMaskIntoConstraints = false
    let label = NSTextField(wrappingLabelWithString: text)
    label.font = .systemFont(ofSize: 11)
    label.textColor = .secondaryLabelColor
    label.preferredMaxLayoutWidth = width - 48
    label.translatesAutoresizingMaskIntoConstraints = false
    addSubview(icon)
    addSubview(label)
    NSLayoutConstraint.activate([
      icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
      icon.topAnchor.constraint(equalTo: topAnchor, constant: 3),
      icon.widthAnchor.constraint(equalToConstant: 14),
      label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
      label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
      label.topAnchor.constraint(equalTo: topAnchor, constant: 2),
      label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
      widthAnchor.constraint(equalToConstant: width),
    ])
  }
  required init?(coder: NSCoder) { fatalError() }
}

final class App: NSObject, NSApplicationDelegate, NSMenuDelegate {
  let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
  let menu = NSMenu()
  let switchView = SwitchView()
  var timer: Timer?

  func applicationDidFinishLaunching(_ n: Notification) {
    menu.delegate = self
    item.menu = menu
    switchView.onChange = { [weak self] on in self?.setSending(on) }
    timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.updateIcon() }
    updateIcon()
    // Ask the engine for a fresh speaker list soon after login.
    writeConfig("refresh", "1\n")
  }

  func status() -> EngineStatus? {
    guard let (s, mtime) = readStatus(), Date().timeIntervalSince(mtime) < 30 else { return nil }
    return s
  }

  func updateIcon() {
    let s = status()
    let sending = s?.state == "streaming"
    let name = sending ? "hifispeaker.fill" : (readEnabled() ? "hifispeaker" : "speaker.slash")
    let img = NSImage(systemSymbolName: name, accessibilityDescription: "Nestcast")
    img?.isTemplate = true
    item.button?.image = img
    item.button?.toolTip = statusText(s)
  }

  func statusText(_ s: EngineStatus?) -> String {
    guard let s = s else { return "Nestcast 엔진이 실행 중이 아닙니다" }
    let hub = s.hub_name.isEmpty ? "스피커" : "‘\(s.hub_name)’"
    switch s.state {
    case "streaming": return "\(hub)에서 재생 중"
    case "off": return "전송 꺼짐 — 소리는 Mac에서 나옵니다"
    case "output_not_cast": return "소리 출력이 ‘Nest Hub (Cast)’가 아닙니다"
    case "sleeping": return "Mac 잠자기 중"
    case "yielded": return "다른 앱이 \(hub)를 사용 중" + (s.busy_app.isEmpty ? "" : " (\(s.busy_app.components(separatedBy: " (").first ?? ""))")
    default:
      return s.problem.isEmpty ? "\(hub)에 연결 중…" : problemText(s.problem)
    }
  }

  func problemText(_ p: String) -> String {
    if p.contains("Nest Hubs found") { return "스피커를 선택해 주세요 (여러 대 발견)" }
    if p.contains("no Nest Hub") { return "네트워크에서 Nest Hub를 찾지 못했습니다" }
    if p.contains("not found") { return "선택한 스피커를 찾을 수 없습니다" }
    return p
  }

  func menuWillOpen(_ m: NSMenu) {
    writeConfig("refresh", "1\n")
    rebuild()
  }

  func rebuild() {
    menu.removeAllItems()
    let s = status()

    let title = NSMenuItem(title: "Nestcast", action: nil, keyEquivalent: "")
    title.isEnabled = false
    menu.addItem(title)
    let state = NSMenuItem(title: statusText(s), action: nil, keyEquivalent: "")
    state.isEnabled = false
    menu.addItem(state)
    menu.addItem(.separator())

    // 1) Sending switch + what the purple indicator means.
    switchView.toggle.state = readEnabled() && outputIsCast() ? .on : .off
    let sw = NSMenuItem()
    sw.view = switchView
    menu.addItem(sw)
    let note = NSMenuItem()
    note.view = NoteView(symbol: "waveform.circle.fill", tint: .systemPurple,
                         text: "켜져 있는 동안 메뉴 막대 오른쪽에 보라색 점과 ‘개인정보 보호 · Nestcast · 시스템 오디오 녹음’ 표시가 나타납니다. Mac 소리를 스피커로 보내고 있다는 뜻이며, 소리를 저장하지는 않습니다.")
    menu.addItem(note)
    if readEnabled() && !outputIsCast() {
      let fix = NSMenuItem(title: "소리 출력을 ‘Nest Hub (Cast)’로 바꾸기", action: #selector(useCastOutput), keyEquivalent: "")
      fix.target = self
      menu.addItem(fix)
    }
    menu.addItem(.separator())

    // 2) Speaker choice: every Google Cast speaker on the network.
    let header = NSMenuItem(title: "스피커", action: nil, keyEquivalent: "")
    header.isEnabled = false
    menu.addItem(header)
    let devices = (s?.devices ?? []).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    if devices.isEmpty {
      let none = NSMenuItem(title: s == nil ? "엔진 응답 없음" : "검색 중…", action: nil, keyEquivalent: "")
      none.isEnabled = false
      menu.addItem(none)
    }
    for d in devices {
      let mi = NSMenuItem(title: d.name, action: #selector(chooseSpeaker(_:)), keyEquivalent: "")
      mi.target = self
      mi.representedObject = d
      mi.state = d.id == s?.hub_id ? .on : .off
      mi.image = NSImage(systemSymbolName: d.model.contains("Hub") ? "tv" : "hifispeaker",
                         accessibilityDescription: nil)
      let sub = NSAttributedString(string: "\n" + d.model, attributes: [
        .font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.secondaryLabelColor])
      let full = NSMutableAttributedString(string: d.name, attributes: [.font: NSFont.menuFont(ofSize: 13)])
      full.append(sub)
      mi.attributedTitle = full
      menu.addItem(mi)
    }
    menu.addItem(.separator())

    let log = NSMenuItem(title: "로그 보기", action: #selector(openLog), keyEquivalent: "")
    log.target = self
    menu.addItem(log)
    let quit = NSMenuItem(title: "메뉴 막대에서 닫기 (전송은 계속됨)", action: #selector(quit), keyEquivalent: "q")
    quit.target = self
    menu.addItem(quit)
  }

  func setSending(_ on: Bool) {
    writeConfig("enabled", on ? "1\n" : "0\n")
    if on { switchOutputToCast() } else { switchOutputAwayFromCast() }
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
      self?.updateIcon()
      self?.rebuild()
    }
  }

  @objc func useCastOutput() {
    switchOutputToCast()
    rebuild()
  }

  @objc func chooseSpeaker(_ sender: NSMenuItem) {
    guard let d = sender.representedObject as? Speaker else { return }
    writeConfig("hub", "\(d.id)\n\(d.name)\n")
  }

  @objc func openLog() {
    let log = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/nestcast.log")
    NSWorkspace.shared.open([log], withApplicationAt: URL(fileURLWithPath: "/System/Applications/Utilities/Console.app"),
                            configuration: NSWorkspace.OpenConfiguration())
  }

  @objc func quit() { NSApp.terminate(nil) }
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
