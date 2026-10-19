import Darwin
import Foundation

public struct Settings: Codable, Equatable, Sendable {
  public var enabled: Bool
  public let revision: String

  public init(enabled: Bool = true, revision: String = UUID().uuidString) {
    self.enabled = enabled
    self.revision = revision
  }

  private enum CodingKeys: String, CodingKey { case enabled, revision }

  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    enabled = try values.decode(Bool.self, forKey: .enabled)
    revision = try values.decodeIfPresent(String.self, forKey: .revision) ?? "legacy"
  }
}

public struct SettingsStore: Sendable {
  public static let notificationName = "local.select-copy.settings-changed"
  public let directory: URL

  public init(directory: URL? = nil) {
    self.directory =
      directory
      ?? FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/SelectCopy", isDirectory: true)
  }

  public var settingsURL: URL { directory.appendingPathComponent("settings.json") }
  public var lockURL: URL { directory.appendingPathComponent("agent.lock") }

  public func load() throws -> Settings {
    do {
      return try JSONDecoder().decode(Settings.self, from: Data(contentsOf: settingsURL))
    } catch let error as NSError
      where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError
    {
      return Settings(revision: "default")
    }
  }

  public func save(_ settings: Settings) throws {
    try withControlLock {
      // Every save invalidates outstanding selection reads, including off → on.
      let data = try JSONEncoder().encode(Settings(enabled: settings.enabled))
      try data.write(to: settingsURL, options: .atomic)
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o600], ofItemAtPath: settingsURL.path)
    }
  }

  /// Serializes settings changes with the final settings-check/clipboard-write.
  /// Once an "off" command returns, an older read cannot write the clipboard.
  /// Do not call save() from inside this closure: flock is not recursive.
  public func withControlLock<T>(_ body: () throws -> T) throws -> T {
    try prepareDirectory()
    let path = directory.appendingPathComponent("control.lock").path
    let descriptor = Darwin.open(path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
    guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    defer { Darwin.close(descriptor) }
    while flock(descriptor, LOCK_EX) != 0 {
      if errno == EINTR { continue }
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    return try body()
  }

  public func prepareDirectory() throws {
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
  }
}

/// The descriptor stays open for the lifetime of the app. The lock file must not
/// be removed while the app runs (a replacement inode would allow two owners).
public final class InstanceLock {
  private let descriptor: Int32

  public init?(url: URL) throws {
    let descriptor = Darwin.open(url.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
    guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
      let code = errno
      Darwin.close(descriptor)
      if code == EWOULDBLOCK { return nil }
      throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }
    self.descriptor = descriptor
  }

  deinit { Darwin.close(descriptor) }

  public static func isRunning(url: URL) throws -> Bool {
    let descriptor = Darwin.open(url.path, O_RDWR | O_CLOEXEC)
    if descriptor < 0 {
      if errno == ENOENT { return false }
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    defer { Darwin.close(descriptor) }
    if flock(descriptor, LOCK_EX | LOCK_NB) == 0 { return false }
    if errno == EWOULDBLOCK { return true }
    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
  }
}
