import Dispatch
import Foundation
import Testing

@testable import SelectCopyCore

struct CopyPolicyTests {
  private func snapshot(
    _ text: String = "hello", processID: Int32 = 12,
    elementID: UInt = 1, location: Int = 0
  ) -> SelectionSnapshot {
    SelectionSnapshot(
      text: text, processID: processID, elementID: elementID,
      rangeLocation: location, rangeLength: text.utf16.count)
  }

  @Test func copiesOnceForAnUnchangedSelection() {
    var policy = CopyPolicy()
    #expect(policy.textToCopy(for: snapshot()) == "hello")
    #expect(policy.textToCopy(for: snapshot()) == nil)
  }

  @Test func deselectionAllowsSameTextToBeCopiedAgain() {
    var policy = CopyPolicy()
    _ = policy.textToCopy(for: snapshot())
    #expect(policy.textToCopy(for: nil) == nil)
    #expect(policy.textToCopy(for: snapshot()) == "hello")
  }

  @Test func newRangeAppOrElementCountsAsNewSelection() {
    var policy = CopyPolicy()
    _ = policy.textToCopy(for: snapshot())
    #expect(policy.textToCopy(for: snapshot(location: 10)) == "hello")
    #expect(policy.textToCopy(for: snapshot(processID: 42)) == "hello")
    #expect(policy.textToCopy(for: snapshot(elementID: 2)) == "hello")
  }

  @Test func resetAllowsCopyAfterReenabling() {
    var policy = CopyPolicy()
    _ = policy.textToCopy(for: snapshot())
    policy.reset()
    #expect(policy.textToCopy(for: snapshot()) == "hello")
  }

  @Test func transientReadFailureDoesNotRecopyTheSameSelection() {
    var policy = CopyPolicy()
    #expect(policy.textToCopy(after: .selection(snapshot())) == "hello")
    #expect(policy.textToCopy(after: .unavailable) == nil)
    #expect(policy.textToCopy(after: .selection(snapshot())) == nil)
    #expect(policy.textToCopy(after: .deselected) == nil)
    #expect(policy.textToCopy(after: .selection(snapshot())) == "hello")
  }

  @Test func preservesWhitespaceAndUnicode() {
    var policy = CopyPolicy()
    #expect(policy.textToCopy(for: snapshot("  hello 🌎\n")) == "  hello 🌎\n")
    #expect(policy.textToCopy(for: snapshot("  ")) == "  ")
  }

  @Test func emptyAndOversizedSelectionsAreIgnored() {
    var policy = CopyPolicy()
    #expect(policy.textToCopy(for: snapshot("")) == nil)
    #expect(policy.textToCopy(for: snapshot(String(repeating: "a", count: 1_048_577))) == nil)
    #expect(policy.textToCopy(for: snapshot(String(repeating: "🌎", count: 262_145))) == nil)
    #expect(policy.textToCopy(for: snapshot()) == "hello")
  }
}

struct SettingsStoreTests {
  private func withStore(_ body: (SettingsStore) throws -> Void) throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try body(SettingsStore(directory: directory))
  }

  @Test func missingSettingsDefaultsToOnWithoutCreatingAFile() throws {
    try withStore { store in
      let settings = try store.load()
      #expect(settings.enabled)
      #expect(!FileManager.default.fileExists(atPath: store.settingsURL.path))
    }
  }

  @Test func offOnPersistsAcrossStoreInstances() throws {
    try withStore { store in
      try store.save(Settings(enabled: false))
      #expect(try !SettingsStore(directory: store.directory).load().enabled)
      try store.save(Settings(enabled: true))
      #expect(try store.load().enabled)
      let attributes = try FileManager.default.attributesOfItem(atPath: store.settingsURL.path)
      #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }
  }

  @Test func malformedSettingsThrowsInsteadOfEnablingCopying() throws {
    try withStore { store in
      try store.prepareDirectory()
      try Data("invalid json".utf8).write(to: store.settingsURL)
      #expect(throws: (any Error).self) { try store.load() }
    }
  }

  @Test func canRepairInvalidSettingsWithExplicitCommand() throws {
    try withStore { store in
      try store.prepareDirectory()
      try Data("{}".utf8).write(to: store.settingsURL)
      #expect(throws: (any Error).self) { try store.load() }
      try store.save(Settings(enabled: false))
      #expect(try !store.load().enabled)
    }
  }

  @Test func revisionsStayStableOnReadAndChangeWithEverySave() throws {
    try withStore { store in
      let initial = try store.load()
      #expect(try store.load().revision == initial.revision)
      try store.save(Settings(enabled: false))
      let off = try store.load()
      #expect(try store.load().revision == off.revision)
      try store.save(Settings(enabled: true))
      #expect(try store.load().revision != off.revision)
      let on = try store.load()
      try store.save(on)
      #expect(try store.load().revision != on.revision)
    }
  }

  @Test func legacySettingsAreReadableWithAStableRevision() throws {
    try withStore { store in
      try store.prepareDirectory()
      try Data(#"{"enabled":false}"#.utf8).write(to: store.settingsURL)
      let first = try store.load()
      #expect(!first.enabled)
      #expect(try store.load() == first)
    }
  }

  @Test func controlLockSerializesOffWithClipboardCriticalSection() throws {
    try withStore { store in
      let started = DispatchSemaphore(value: 0)
      let finished = DispatchSemaphore(value: 0)
      try store.withControlLock {
        DispatchQueue.global().async {
          started.signal()
          defer { finished.signal() }
          try? store.save(Settings(enabled: false))
        }
        #expect(started.wait(timeout: .now() + 5) == .success)
        #expect(finished.wait(timeout: .now() + 0.05) == .timedOut)
      }
      #expect(finished.wait(timeout: .now() + 5) == .success)
      #expect(try !store.load().enabled)
    }
  }

  @Test func instanceLockPreventsDuplicatesAndReleasesOnExit() throws {
    try withStore { store in
      try store.prepareDirectory()
      #expect(try !InstanceLock.isRunning(url: store.lockURL))
      var lock = try InstanceLock(url: store.lockURL)
      #expect(lock != nil)
      #expect(try InstanceLock.isRunning(url: store.lockURL))
      #expect(try InstanceLock(url: store.lockURL) == nil)
      withExtendedLifetime(lock) {}
      lock = nil
      #expect(try !InstanceLock.isRunning(url: store.lockURL))
      #expect(try InstanceLock(url: store.lockURL) != nil)
    }
  }
}
