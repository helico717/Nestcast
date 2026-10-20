// Nestcast app: settings window (and optional menu bar icon) for the engine.
//
// The engine ("Nestcast Engine.app" inside this bundle, started by launchd)
// does all the streaming and keeps running when this app is closed or quit.
// The two talk through files in ~/Library/Application Support/nestcast:
//   enabled      0/1 — "Mac 오디오 전송" switch (written here)
//   hub          chosen speaker: Cast device ID, then name (written here)
//   refresh      touch to ask the engine for a fresh speaker list
//   status.json  engine state + speakers on the network (written by engine)
//
// Launched at login with --background: stays running only if the menu bar
// icon is enabled; otherwise exits (the engine is unaffected).
import AppKit
import CoreAudio
import SwiftUI

let kVirtualDeviceUID = "Nest Hub (Cast)_UID"
let kShowInMenuBarKey = "showInMenuBar"
let kPreviousOutputKey = "previousOutputUID"
let kShowWindowNotification = Notification.Name("local.nestcast.showWindow")

// MARK: - Files shared with the engine

let configDir = FileManager.default.homeDirectoryForCurrentUser
  .appendingPathComponent("Library/Application Support/nestcast")

struct Speaker: Decodable, Hashable, Identifiable {
  let name: String
  let model: String
  let id: String
}

struct EngineStatus: Decodable, Equatable {
  let state: String  // off | output_not_cast | sleeping | yielded | streaming | connecting
  let hub_id: String
  let hub_name: String
  let busy_app: String
  let problem: String
  let permission: String?  // "missing" when capture is silent while apps play
  let devices: [Speaker]
}

func readStatus() -> EngineStatus? {
  let url = configDir.appendingPathComponent("status.json")
  guard let data = try? Data(contentsOf: url),
        let status = try? JSONDecoder().decode(EngineStatus.self, from: data),
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
        let mtime = attrs[.modificationDate] as? Date,
        Date().timeIntervalSince(mtime) < 30 else { return nil }
  return status
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

func audioAddress(_ selector: AudioObjectPropertySelector,
                  _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
  AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

func allDevices() -> [AudioDeviceID] {
  var addr = audioAddress(kAudioHardwarePropertyDevices)
  var size: UInt32 = 0
  AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size)
  var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
  AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids)
  return ids
}

func deviceUID(_ dev: AudioDeviceID) -> String? {
  var uid: Unmanaged<CFString>?
  var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
  var addr = audioAddress(kAudioDevicePropertyDeviceUID)
  guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &uid) == noErr,
        let u = uid?.takeRetainedValue() else { return nil }
  return u as String
}

func deviceID(forUID uid: String) -> AudioDeviceID? {
  allDevices().first { deviceUID($0) == uid }
}

func defaultOutputDevice() -> AudioDeviceID {
  var dev = AudioDeviceID(kAudioObjectUnknown)
  var size = UInt32(MemoryLayout<AudioDeviceID>.size)
  var addr = audioAddress(kAudioHardwarePropertyDefaultOutputDevice)
  AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev)
  return dev
}

func builtInOutputDevice() -> AudioDeviceID? {
  allDevices().first { id in
    var transport: UInt32 = 0
    var tsize = UInt32(MemoryLayout<UInt32>.size)
    var taddr = audioAddress(kAudioDevicePropertyTransportType)
    AudioObjectGetPropertyData(id, &taddr, 0, nil, &tsize, &transport)
    var saddr = audioAddress(kAudioDevicePropertyStreams, kAudioDevicePropertyScopeOutput)
    var ssize: UInt32 = 0
    AudioObjectGetPropertyDataSize(id, &saddr, 0, nil, &ssize)
    return transport == kAudioDeviceTransportTypeBuiltIn && ssize > 0
  }
}

func setDefaultOutput(_ dev: AudioDeviceID) {
  var d = dev
  for selector in [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDefaultSystemOutputDevice] {
    var addr = audioAddress(selector)
    AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil,
                               UInt32(MemoryLayout<AudioDeviceID>.size), &d)
  }
}

func outputIsCast() -> Bool { deviceUID(defaultOutputDevice()) == kVirtualDeviceUID }

// Remembers the output used before switching to "Nest Hub (Cast)" and
// restores it when sending is switched off (else the built-in speakers).
func switchOutputToCast() {
  guard let cast = deviceID(forUID: kVirtualDeviceUID) else { return }
  let current = defaultOutputDevice()
  if current != cast, let uid = deviceUID(current) {
    UserDefaults.standard.set(uid, forKey: kPreviousOutputKey)
  }
  setDefaultOutput(cast)
}

func switchOutputAwayFromCast() {
  guard outputIsCast() else { return }
  if let uid = UserDefaults.standard.string(forKey: kPreviousOutputKey), let prev = deviceID(forUID: uid) {
    setDefaultOutput(prev)
  } else if let builtIn = builtInOutputDevice() {
    setDefaultOutput(builtIn)
  }
}

// MARK: - Model

final class Model: ObservableObject {
  @Published var status: EngineStatus? = readStatus()
  @Published var enabled = readEnabled()
  @Published var castOutput = outputIsCast()
  @Published var showInMenuBar = UserDefaults.standard.bool(forKey: kShowInMenuBarKey) {
    didSet {
      UserDefaults.standard.set(showInMenuBar, forKey: kShowInMenuBarKey)
      onMenuBarChange?(showInMenuBar)
    }
  }
  var onMenuBarChange: ((Bool) -> Void)?
  private var timer: Timer?

  init() {
    timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.poll() }
    writeConfig("refresh", "1\n")
  }

  func poll() {
    let s = readStatus()
    if s != status { status = s }
    let e = readEnabled()
    if e != enabled { enabled = e }
    let c = outputIsCast()
    if c != castOutput { castOutput = c }
  }

  var sending: Bool { enabled && castOutput }

  func setSending(_ on: Bool) {
    writeConfig("enabled", on ? "1\n" : "0\n")
    if on { switchOutputToCast() } else { switchOutputAwayFromCast() }
    poll()
  }

  func choose(_ s: Speaker) {
    writeConfig("hub", "\(s.id)\n\(s.name)\n")
  }

  func refreshSpeakers() { writeConfig("refresh", "1\n") }

  var statusText: String {
    guard let s = status else { return "Nestcast 엔진이 실행 중이 아닙니다" }
    let hub = s.hub_name.isEmpty ? "스피커" : "‘\(s.hub_name)’"
    switch s.state {
    case "streaming": return "\(hub)에서 재생 중"
    case "off": return "전송 꺼짐 — 소리는 Mac에서 나옵니다"
    case "output_not_cast": return "소리 출력이 ‘Nest Hub (Cast)’가 아닙니다"
    case "sleeping": return "Mac 잠자기 중"
    case "yielded":
      let app = s.busy_app.components(separatedBy: " (").first ?? ""
      return "다른 앱이 \(hub)를 사용 중" + (app.isEmpty ? "" : " (\(app))")
    default:
      if s.problem.contains("Nest Hubs found") { return "스피커를 선택해 주세요 (여러 대 발견)" }
      if s.problem.contains("no Nest Hub") { return "네트워크에서 Nest Hub를 찾지 못했습니다" }
      if s.problem.contains("not found") { return "선택한 스피커를 찾을 수 없습니다" }
      return "\(hub)에 연결 중…"
    }
  }

  var statusColor: Color {
    switch status?.state {
    case "streaming": return .green
    case "off", "output_not_cast", nil: return .secondary
    default: return .orange
    }
  }
}

func openAudioRecordingSettings() {
  // Privacy & Security → Screen & System Audio Recording.
  for url in ["x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture",
              "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
              "x-apple.systempreferences:com.apple.preference.security"] {
    if let u = URL(string: url), NSWorkspace.shared.open(u) { return }
  }
}

func openLog() {
  let log = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/nestcast.log")
  NSWorkspace.shared.open([log], withApplicationAt: URL(fileURLWithPath: "/System/Applications/Utilities/Console.app"),
                          configuration: NSWorkspace.OpenConfiguration())
}

// MARK: - Window

struct SettingsView: View {
  @ObservedObject var model: Model

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack(spacing: 10) {
        Image(systemName: model.sending ? "hifispeaker.fill" : "hifispeaker")
          .font(.system(size: 26)).foregroundStyle(.tint)
        VStack(alignment: .leading, spacing: 2) {
          Text("Nestcast").font(.title2.bold())
          HStack(spacing: 6) {
            Circle().fill(model.statusColor).frame(width: 7, height: 7)
            Text(model.statusText).font(.callout).foregroundStyle(.secondary)
          }
        }
      }

      if model.sending && model.status?.permission == "missing" {
        HStack(alignment: .top, spacing: 10) {
          Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
          VStack(alignment: .leading, spacing: 6) {
            Text("오디오 녹음 권한이 필요합니다").font(.headline)
            Text("Mac에서 소리가 재생되고 있지만 Nestcast가 소리를 받지 못하고 있습니다. 업데이트 후에는 macOS가 권한을 다시 확인할 수 있습니다. **화면 및 시스템 오디오 녹음**에서 Nestcast를 켜 주세요(이미 켜져 있다면 껐다가 다시 켜기).")
              .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button("시스템 설정 열기") { openAudioRecordingSettings() }
          }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.orange.opacity(0.35)))
      }

      GroupBox {
        VStack(alignment: .leading, spacing: 10) {
          Toggle(isOn: Binding(get: { model.sending }, set: { model.setSending($0) })) {
            VStack(alignment: .leading, spacing: 2) {
              Text("Mac 오디오 전송").font(.headline)
              Text("켜면 Mac 소리를 선택한 스피커로 보냅니다. 끄면 Mac에서 소리가 납니다.")
                .font(.caption).foregroundStyle(.secondary)
            }
          }
          .toggleStyle(.switch)
          HStack(alignment: .top, spacing: 8) {
            Image(systemName: "waveform.circle.fill").foregroundStyle(.purple)
            Text("켜져 있는 동안 메뉴 막대 오른쪽에 보라색 점과 **‘개인정보 보호 · Nestcast · 시스템 오디오 녹음’** 표시가 나타납니다. Mac 소리를 스피커로 보내고 있다는 뜻이며, 소리를 저장하지는 않습니다. 끄면 사라집니다.")
              .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
          }
          if model.enabled && !model.castOutput {
            Button("소리 출력을 ‘Nest Hub (Cast)’로 바꾸기") { model.setSending(true) }
          }
        }
        .padding(6)
      }

      GroupBox {
        VStack(alignment: .leading, spacing: 6) {
          HStack {
            Text("스피커").font(.headline)
            Spacer()
            Button { model.refreshSpeakers() } label: { Image(systemName: "arrow.clockwise") }
              .buttonStyle(.borderless).help("목록 새로고침")
          }
          let speakers = (model.status?.devices ?? [])
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
          if speakers.isEmpty {
            Text(model.status == nil ? "엔진 응답 없음" : "같은 네트워크에서 스피커를 찾는 중…")
              .font(.callout).foregroundStyle(.secondary)
          }
          ForEach(speakers) { s in
            Button { model.choose(s) } label: {
              HStack(spacing: 10) {
                Image(systemName: s.id == model.status?.hub_id ? "checkmark.circle.fill" : "circle")
                  .foregroundStyle(s.id == model.status?.hub_id ? Color.accentColor : .secondary)
                Image(systemName: s.model.contains("Hub") ? "tv" : "hifispeaker")
                  .frame(width: 18).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                  Text(s.name)
                  Text(s.model).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
              }
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.vertical, 2)
          }
        }
        .padding(6)
      }

      GroupBox {
        Toggle(isOn: $model.showInMenuBar) {
          VStack(alignment: .leading, spacing: 2) {
            Text("메뉴 막대에 아이콘 표시")
            Text("켜면 창을 닫아도 메뉴 막대에서 바로 조작할 수 있습니다.")
              .font(.caption).foregroundStyle(.secondary)
          }
        }
        .toggleStyle(.switch)
        .padding(6)
      }

      HStack {
        Button("로그 보기") { openLog() }
        Spacer()
        Text("창을 닫아도 전송은 계속됩니다 · v\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
          .font(.caption2).foregroundStyle(.tertiary)
      }
    }
    .padding(20)
    .frame(width: 420)
  }
}

// MARK: - Menu bar icon (optional)

final class MenuBarController: NSObject, NSMenuDelegate {
  let model: Model
  let openWindow: () -> Void
  var item: NSStatusItem?
  var timer: Timer?

  init(model: Model, openWindow: @escaping () -> Void) {
    self.model = model
    self.openWindow = openWindow
  }

  func setVisible(_ visible: Bool) {
    if visible && item == nil {
      item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
      let menu = NSMenu()
      menu.delegate = self
      item?.menu = menu
      timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.updateIcon() }
      updateIcon()
    } else if !visible, let i = item {
      NSStatusBar.system.removeStatusItem(i)
      item = nil
      timer?.invalidate()
    }
  }

  func updateIcon() {
    let name = model.status?.state == "streaming" ? "hifispeaker.fill" : (model.enabled ? "hifispeaker" : "speaker.slash")
    let img = NSImage(systemSymbolName: name, accessibilityDescription: "Nestcast")
    img?.isTemplate = true
    item?.button?.image = img
    item?.button?.toolTip = model.statusText
  }

  func menuWillOpen(_ menu: NSMenu) {
    model.refreshSpeakers()
    model.poll()
    menu.removeAllItems()
    let state = NSMenuItem(title: model.statusText, action: nil, keyEquivalent: "")
    state.isEnabled = false
    menu.addItem(state)
    menu.addItem(.separator())
    let send = NSMenuItem(title: "Mac 오디오 전송", action: #selector(toggleSending), keyEquivalent: "")
    send.target = self
    send.state = model.sending ? .on : .off
    menu.addItem(send)
    menu.addItem(.separator())
    let header = NSMenuItem(title: "스피커", action: nil, keyEquivalent: "")
    header.isEnabled = false
    menu.addItem(header)
    for s in (model.status?.devices ?? []).sorted(by: { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) {
      let mi = NSMenuItem(title: "\(s.name)  —  \(s.model)", action: #selector(choose(_:)), keyEquivalent: "")
      mi.target = self
      mi.representedObject = s
      mi.state = s.id == model.status?.hub_id ? .on : .off
      menu.addItem(mi)
    }
    menu.addItem(.separator())
    let open = NSMenuItem(title: "Nestcast 열기…", action: #selector(openApp), keyEquivalent: "")
    open.target = self
    menu.addItem(open)
  }

  @objc func toggleSending() { model.setSending(!model.sending) }
  @objc func choose(_ sender: NSMenuItem) {
    if let s = sender.representedObject as? Speaker { model.choose(s) }
  }
  @objc func openApp() { openWindow() }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
  let model = Model()
  var window: NSWindow?
  lazy var menuBar = MenuBarController(model: model) { [weak self] in self?.showWindow() }

  func applicationDidFinishLaunching(_ n: Notification) {
    // Single instance: if Nestcast is already running (e.g. started at login
    // for the menu bar icon), ask it to show its window and exit.
    let me = ProcessInfo.processInfo.processIdentifier
    if NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
      .contains(where: { $0.processIdentifier != me }) {
      if !CommandLine.arguments.contains("--background") {
        DistributedNotificationCenter.default().postNotificationName(
          kShowWindowNotification, object: nil, userInfo: nil, deliverImmediately: true)
      }
      NSApp.terminate(nil)
      return
    }
    DistributedNotificationCenter.default().addObserver(
      forName: kShowWindowNotification, object: nil, queue: .main) { [weak self] _ in self?.showWindow() }
    model.onMenuBarChange = { [weak self] on in
      self?.menuBar.setVisible(on)
    }
    menuBar.setVisible(model.showInMenuBar)
    // Right after installation the installer leaves `show_window`, so the
    // first (background) launch opens the window once.
    let showOnce = configDir.appendingPathComponent("show_window")
    let firstRun = FileManager.default.fileExists(atPath: showOnce.path)
    if firstRun { try? FileManager.default.removeItem(at: showOnce) }
    let background = CommandLine.arguments.contains("--background") && !firstRun
    if background {
      // Login launch: only the menu bar icon, if it's enabled.
      if !model.showInMenuBar {
        NSApp.terminate(nil)
        return
      }
      NSApp.setActivationPolicy(.accessory)
    } else {
      showWindow()
    }
  }

  func showWindow() {
    NSApp.setActivationPolicy(.regular)
    if window == nil {
      let w = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .miniaturizable],
                       backing: .buffered, defer: false)
      w.title = "Nestcast"
      w.contentView = NSHostingView(rootView: SettingsView(model: model))
      w.isReleasedWhenClosed = false
      w.delegate = self
      w.center()
      window = w
    }
    window?.makeKeyAndOrderFront(nil)
    NSApp.activate()
  }

  // Reopen from the Dock / Launchpad / Finder.
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    showWindow()
    return true
  }

  func windowWillClose(_ notification: Notification) {
    if model.showInMenuBar {
      NSApp.setActivationPolicy(.accessory)  // Keep only the menu bar icon.
    } else {
      DispatchQueue.main.async { NSApp.terminate(nil) }  // Engine keeps running.
    }
  }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
