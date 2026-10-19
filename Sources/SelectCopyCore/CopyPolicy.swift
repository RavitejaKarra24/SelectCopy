import Foundation

public struct SelectionSnapshot: Equatable, Sendable {
  public let text: String
  public let processID: Int32
  public let elementID: UInt
  public let rangeLocation: Int?
  public let rangeLength: Int?

  public init(
    text: String, processID: Int32, elementID: UInt,
    rangeLocation: Int? = nil, rangeLength: Int? = nil
  ) {
    self.text = text
    self.processID = processID
    self.elementID = elementID
    self.rangeLocation = rangeLocation
    self.rangeLength = rangeLength
  }
}

public enum SelectionReadResult: Sendable {
  case selection(SelectionSnapshot)
  case deselected
  case unavailable
}

/// Don't repeatedly overwrite the clipboard for an unchanged selection.
/// A deselection resets the cache, allowing the same text to be selected again.
public struct CopyPolicy {
  private var previous: SelectionSnapshot?

  public init() {}

  public mutating func reset() { previous = nil }

  public mutating func textToCopy(after result: SelectionReadResult) -> String? {
    switch result {
    case .selection(let selection): return textToCopy(for: selection)
    case .deselected: return textToCopy(for: nil)
    case .unavailable: return nil  // A timeout is not evidence of deselection.
    }
  }

  public mutating func textToCopy(for selection: SelectionSnapshot?) -> String? {
    guard let selection, !selection.text.isEmpty,
      selection.text.utf8.count <= 1_048_576
    else {
      reset()
      return nil
    }
    guard selection != previous else { return nil }
    previous = selection
    return selection.text
  }
}
