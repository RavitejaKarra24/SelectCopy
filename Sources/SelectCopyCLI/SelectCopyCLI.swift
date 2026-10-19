import AppKit
import Darwin
import SelectCopyCore

@main
struct SelectCopyCLI {
  static func main() {
    let arguments = Array(CommandLine.arguments.dropFirst())
    if arguments == ["--help"] || arguments == ["-h"] {
      print("Usage: select_copy on | off | status")
      return
    }
    guard arguments.count == 1, let command = arguments.first,
      ["on", "off", "status"].contains(command)
    else {
      fail("Usage: select_copy on | off | status", code: 64)
    }

    let store = SettingsStore()
    do {
      if command == "status" {
        let settings = try store.load()
        let running = try InstanceLock.isRunning(url: store.lockURL)
        print("Auto-copy: \(settings.enabled ? "on" : "off")")
        print("Background app: \(running ? "running" : "not running")")
        print("Accessibility: check the SelectCopy menu-bar icon.")
      } else {
        try store.save(Settings(enabled: command == "on"))
        DistributedNotificationCenter.default().postNotificationName(
          Notification.Name(SettingsStore.notificationName),
          object: nil, userInfo: nil, deliverImmediately: true)
        print("Auto-copy: \(command)")
        if !(try InstanceLock.isRunning(url: store.lockURL)) {
          print("App is not running. Run scripts/install.sh or open SelectCopy.app.")
        }
      }
    } catch {
      fail("select_copy: \(error.localizedDescription)", code: 1)
    }
  }

  private static func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
  }
}
