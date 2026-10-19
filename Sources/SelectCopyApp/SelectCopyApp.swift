import AppKit
@preconcurrency import ApplicationServices
import SelectCopyCore

@main
struct SelectCopyApp {
  @MainActor
  static func main() {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) { app.run() }
  }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
  private let store = SettingsStore()
  private let reader = SelectionReader()
  private var instanceLock: InstanceLock?
  private var statusItem: NSStatusItem?
  private var timer: Timer?
  private var policy = CopyPolicy()
  private var enabled = false
  private var trusted = false
  private var settingsError: String?
  private var revision = 0
  private var reading = false
  private var menuOpen = false
  private var quitting = false
  private var displayedStatus: String?
  private var settingsRevision = ""

  private let stateItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
  private let toggleItem = NSMenuItem(title: "", action: #selector(toggle), keyEquivalent: "")
  private let permissionItem = NSMenuItem(
    title: "Grant Accessibility Access…", action: #selector(grantAccess), keyEquivalent: "")

  func applicationDidFinishLaunching(_ notification: Notification) {
    do {
      try store.prepareDirectory()
      guard let lock = try InstanceLock(url: store.lockURL) else {
        NSApp.terminate(nil)
        return
      }
      instanceLock = lock
    } catch {
      showError("Could not start SelectCopy", detail: error.localizedDescription)
      NSApp.terminate(nil)
      return
    }

    let menu = NSMenu()
    menu.delegate = self
    menu.autoenablesItems = false
    stateItem.isEnabled = false
    menu.addItem(stateItem)
    menu.addItem(.separator())
    toggleItem.target = self
    menu.addItem(toggleItem)
    permissionItem.target = self
    menu.addItem(permissionItem)
    menu.addItem(.separator())
    let quit = NSMenuItem(title: "Quit SelectCopy", action: #selector(quit), keyEquivalent: "q")
    quit.target = self
    menu.addItem(quit)

    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    item.menu = menu
    statusItem = item

    DistributedNotificationCenter.default().addObserver(
      self, selector: #selector(settingsChanged),
      name: Notification.Name(SettingsStore.notificationName), object: nil)

    let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
      Task { @MainActor [weak self] in self?.poll() }
    }
    timer.tolerance = 0.1
    RunLoop.main.add(timer, forMode: .common)
    self.timer = timer
    poll()
  }

  func applicationWillTerminate(_ notification: Notification) {
    timer?.invalidate()
    DistributedNotificationCenter.default().removeObserver(self)
  }

  func menuWillOpen(_ menu: NSMenu) {
    menuOpen = true
    revision += 1
    refreshSettings()
  }

  func menuDidClose(_ menu: NSMenu) { menuOpen = false }

  @objc private func settingsChanged(_ notification: Notification) { refreshSettings() }

  private func refreshSettings() {
    let next: Settings
    do {
      next = try store.load()
      settingsError = nil
    } catch {
      next = Settings(enabled: false, revision: "invalid")  // Fail closed.
      settingsError = error.localizedDescription
    }
    let nextTrusted = AXIsProcessTrusted()
    if next.enabled != enabled || next.revision != settingsRevision || trusted != nextTrusted {
      enabled = next.enabled
      settingsRevision = next.revision
      trusted = nextTrusted
      revision += 1
      policy.reset()
    }
    updateMenu()
  }

  private func updateMenu() {
    let status: String
    if settingsError != nil {
      status = "Paused — settings could not be read"
    } else if !enabled {
      status = "Auto-copy is off"
    } else if !trusted {
      status = "Accessibility permission needed"
    } else {
      status = "Auto-copy is on"
    }
    guard status != displayedStatus else { return }
    displayedStatus = status
    stateItem.title = status
    toggleItem.title = enabled ? "Turn Auto-Copy Off" : "Turn Auto-Copy On"
    permissionItem.isHidden = trusted
    statusItem?.button?.toolTip = "SelectCopy: \(status)"
    statusItem?.button?.setAccessibilityLabel("SelectCopy: \(status)")
    let symbol = enabled && trusted ? "doc.on.clipboard" : "doc.on.clipboard.fill"
    let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "SelectCopy")
    image?.isTemplate = true
    statusItem?.button?.image = image
    statusItem?.button?.appearsDisabled = !enabled || !trusted
  }

  private var userIsInteracting: Bool {
    NSEvent.pressedMouseButtons != 0
      || !NSEvent.modifierFlags.intersection([.command, .shift, .control, .option]).isEmpty
  }

  private func poll() {
    refreshSettings()
    guard enabled, trusted, !reading, !menuOpen, !quitting, !userIsInteracting else {
      return
    }
    guard let app = NSWorkspace.shared.frontmostApplication,
      app.processIdentifier != ProcessInfo.processInfo.processIdentifier
    else { return }

    let processID = app.processIdentifier
    let startedRevision = revision
    let clipboardChangeCount = NSPasteboard.general.changeCount
    reading = true
    Task { [weak self, reader] in
      let selection = await reader.read(processID: processID)
      guard let self else { return }
      self.reading = false
      do {
        try self.store.withControlLock {
          // The CLI shares this lock: no old result can write after "off" returns.
          self.refreshSettings()
          guard self.enabled, self.trusted, !self.menuOpen, !self.quitting,
            !self.userIsInteracting, self.revision == startedRevision,
            NSWorkspace.shared.frontmostApplication?.processIdentifier == processID
          else { return }
          guard let text = self.policy.textToCopy(after: selection) else { return }
          let pasteboard = NSPasteboard.general
          // Consume the selection but respect a newer manual Copy/Cut operation.
          guard pasteboard.changeCount == clipboardChangeCount else { return }
          // Preserve rich clipboard contents if it already contains the same text.
          guard pasteboard.string(forType: .string) != text else { return }
          pasteboard.clearContents()
          pasteboard.setString(text, forType: .string)
        }
      } catch {
        // A failed lock must never permit an uncoordinated clipboard write.
        self.settingsError = error.localizedDescription
        self.updateMenu()
      }
    }
  }

  @objc private func toggle() {
    do {
      refreshSettings()
      try store.save(Settings(enabled: !enabled))
      refreshSettings()
    } catch {
      showError("Could not update auto-copy", detail: error.localizedDescription)
    }
  }

  @objc private func grantAccess() {
    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
    _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
    if let url = URL(
      string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    {
      NSWorkspace.shared.open(url)
    }
  }

  @objc private func quit() {
    quitting = true
    policy.reset()
    // Unload for this login session so launchd doesn't immediately restart us.
    // The installed plist will still start the app at the next login.
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    process.arguments = [
      "bootout", "gui/\(getuid())/local.select-copy.agent",
    ]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    process.terminationHandler = { _ in
      Task { @MainActor in NSApp.terminate(nil) }
    }
    do { try process.run() } catch { NSApp.terminate(nil) }
  }

  private func showError(_ title: String, detail: String) {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = detail
    alert.alertStyle = .warning
    alert.runModal()
  }
}
