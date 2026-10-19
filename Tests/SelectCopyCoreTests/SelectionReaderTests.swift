import ApplicationServices
import Foundation
import Testing

@testable import SelectCopyApp
@testable import SelectCopyCore

/// Immutable AX responses; no browser or Accessibility permission needed.
private struct BrowserAccessibility: AccessibilityReading, @unchecked Sendable {
  let attributes: [UInt: [String: CFTypeRef]]
  let parameters: [UInt: [String: CFTypeRef]]

  func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    attributes[CFHash(element)]?[name]
  }

  func parameterizedAttribute(_ element: AXUIElement, _ name: String, _ value: CFTypeRef)
    -> CFTypeRef?
  {
    parameters[CFHash(element)]?[name]
  }
}

struct SelectionReaderTests {
  private func reader(
    text: String = "Webpage 🌎 selection", length: Int? = nil, location: Int = 27,
    focusedAttributes: [String: CFTypeRef] = [:], depth: Int = 0
  ) -> SelectionReader {
    let app = AXUIElementCreateApplication(101)
    let nodes = (0...depth).map { AXUIElementCreateApplication(pid_t(200 + $0)) }
    var attributes: [UInt: [String: CFTypeRef]] = [
      CFHash(app): [kAXFocusedUIElementAttribute: nodes[0]]
    ]
    for (index, node) in nodes.enumerated() {
      attributes[CFHash(node)] = index == 0 ? focusedAttributes : [:]
      if index < depth {
        attributes[CFHash(node)]?[kAXParentAttribute] = nodes[index + 1]
      }
    }
    let webArea = nodes[depth]
    attributes[CFHash(webArea)]?["AXSelectedTextMarkerRange"] = "opaque range" as CFString
    let parameters: [UInt: [String: CFTypeRef]] = [
      CFHash(webArea): [
        "AXLengthForTextMarkerRange": NSNumber(value: length ?? text.utf16.count),
        "AXStringForTextMarkerRange": text as CFString,
        "AXStartTextMarkerForTextMarkerRange": "opaque start" as CFString,
        "AXIndexForTextMarker": NSNumber(value: location),
      ]
    ]
    return SelectionReader(
      accessibility: BrowserAccessibility(attributes: attributes, parameters: parameters))
  }

  @Test func readsGeckoWebpageMarkersWithoutOrdinarySelectedText() async {
    let reader = reader()
    guard case .selection(let selection) = await reader.read(processID: 101) else {
      Issue.record("Expected webpage marker selection")
      return
    }
    #expect(selection.text == "Webpage 🌎 selection")
    #expect(selection.rangeLocation == 27)
    #expect(selection.rangeLength == selection.text.utf16.count)
    var policy = CopyPolicy()
    #expect(policy.textToCopy(for: selection) == selection.text)
    guard case .selection(let repeated) = await reader.read(processID: 101) else {
      Issue.record("Expected repeat selection")
      return
    }
    #expect(policy.textToCopy(for: repeated) == nil)
  }

  @Test func findsMarkerSelectionBeyondThreeAncestors() async {
    let reader = reader(depth: 8)
    guard case .selection(let selection) = await reader.read(processID: 101) else {
      Issue.record("Expected marker selection in ancestor")
      return
    }
    #expect(selection.text == "Webpage 🌎 selection")
  }

  @Test func ordinaryEditableSelectionTakesPrecedenceOverPageMarkers() async {
    let reader = reader(focusedAttributes: [kAXSelectedTextAttribute: "editable" as CFString])
    guard case .selection(let selection) = await reader.read(processID: 101) else {
      Issue.record("Expected editable selection")
      return
    }
    #expect(selection.text == "editable")
  }

  @Test func collapsedEditableRangeDoesNotCopyStalePageMarkers() async {
    var range = CFRange(location: 2, length: 0)
    let reader = reader(focusedAttributes: [
      kAXSelectedTextRangeAttribute: AXValueCreate(.cfRange, &range)!
    ])
    guard case .deselected = await reader.read(processID: 101) else {
      Issue.record("Collapsed input must stop marker fallback")
      return
    }
  }

  @Test func secureFieldsAreSkippedBeforeReadingMarkers() async {
    let reader = reader(focusedAttributes: [
      kAXSubroleAttribute: kAXSecureTextFieldSubrole as CFString
    ])
    guard case .deselected = await reader.read(processID: 101) else {
      Issue.record("Secure field must not expose selection")
      return
    }
  }

  @Test func collapsedMarkerRangeResetsCopyPolicy() async {
    let reader = reader(text: "", length: 0)
    guard case .deselected = await reader.read(processID: 101) else {
      Issue.record("Collapsed marker must be deselected")
      return
    }
  }

  @Test func oversizedMarkerRangeIsIgnored() async {
    let reader = reader(length: 1_048_577)
    guard case .unavailable = await reader.read(processID: 101) else {
      Issue.record("Oversized selection must be ignored")
      return
    }
  }
}
