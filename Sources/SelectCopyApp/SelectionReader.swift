import AppKit
import ApplicationServices
import SelectCopyCore

/// Kept injectable so browser-specific selection responses can be regression tested.
protocol AccessibilityReading: Sendable {
  func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef?
  func parameterizedAttribute(_ element: AXUIElement, _ name: String, _ value: CFTypeRef)
    -> CFTypeRef?
}

struct SystemAccessibilityReader: AccessibilityReading {
  func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
      return nil
    }
    return value
  }

  func parameterizedAttribute(_ element: AXUIElement, _ name: String, _ value: CFTypeRef)
    -> CFTypeRef?
  {
    var result: CFTypeRef?
    guard
      AXUIElementCopyParameterizedAttributeValue(element, name as CFString, value, &result)
        == .success
    else { return nil }
    return result
  }
}

/// AX queries may block in unresponsive apps, so they never run on the UI actor.
actor SelectionReader {
  private let accessibility: any AccessibilityReading
  private let maximumSelectionLength = 1_048_576

  init(accessibility: any AccessibilityReading = SystemAccessibilityReader()) {
    self.accessibility = accessibility
    // A timeout on an application object would not cover its child elements.
    AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.12)
  }

  func read(processID: pid_t) -> SelectionReadResult {
    let application = AXUIElementCreateApplication(processID)
    guard let focused = elementAttribute(application, kAXFocusedUIElementAttribute) else {
      return .unavailable
    }

    var elements = [focused]
    // A deeply nested focused node may be many containers below its web area.
    for _ in 0..<32 {
      guard let last = elements.last,
        attribute(last, kAXRoleAttribute) as? String != kAXWindowRole,
        let parent = elementAttribute(last, kAXParentAttribute),
        !elements.contains(where: { CFEqual($0, parent) })
      else { break }
      elements.append(parent)
    }

    // Check ancestors before reading text; never inspect a secure text field.
    for element in elements {
      if attribute(element, kAXSubroleAttribute) as? String == kAXSecureTextFieldSubrole {
        return .deselected
      }
      if attribute(element, NSAccessibility.Attribute.containsProtectedContent.rawValue) as? Bool
        == true
      {
        return .deselected
      }
    }

    for element in elements {
      let range = selectedRange(element)
      if let range, range.length == 0 { return .deselected }
      var text = attribute(element, kAXSelectedTextAttribute) as? String

      if text == nil, var range, range.length > 0, range.length <= maximumSelectionLength,
        let value = AXValueCreate(.cfRange, &range)
      {
        text =
          accessibility.parameterizedAttribute(
            element, kAXStringForRangeParameterizedAttribute, value) as? String
      }

      if let text {
        guard !text.isEmpty else { return .deselected }
        return .selection(
          SelectionSnapshot(
            text: text, processID: processID, elementID: CFHash(element),
            rangeLocation: range?.location, rangeLength: range?.length))
      }

      // Gecko (Zen/Firefox) exposes document selections through text markers,
      // even when the focused web area has no AXSelectedText/CFRange support.
      // Ask the same element for the marker's string: markers are opaque and
      // must not be decoded, or interpreted as ordinary character ranges.
      if let selection = markerSelection(element, processID: processID) {
        return selection
      }
    }
    return .unavailable
  }

  private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    accessibility.attribute(element, name)
  }

  private func markerSelection(_ element: AXUIElement, processID: pid_t) -> SelectionReadResult? {
    guard let markers = attribute(element, "AXSelectedTextMarkerRange") else { return nil }
    let length =
      (accessibility.parameterizedAttribute(
        element, "AXLengthForTextMarkerRange", markers) as? NSNumber)?.intValue
    if let length {
      guard length >= 0, length <= maximumSelectionLength else { return .unavailable }
      if length == 0 { return .deselected }
    }
    guard
      let text = accessibility.parameterizedAttribute(
        element, "AXStringForTextMarkerRange", markers) as? String
    else { return nil }
    guard !text.isEmpty else { return .deselected }
    guard text.utf8.count <= maximumSelectionLength else { return .unavailable }

    // Retain the position for duplicate detection, including identical words
    // selected at different places. Never hash a newly allocated marker object.
    var location: Int?
    if let start = accessibility.parameterizedAttribute(
      element, "AXStartTextMarkerForTextMarkerRange", markers)
    {
      location =
        (accessibility.parameterizedAttribute(
          element, "AXIndexForTextMarker", start) as? NSNumber)?.intValue
    }
    return .selection(
      SelectionSnapshot(
        text: text, processID: processID, elementID: CFHash(element),
        rangeLocation: location, rangeLength: length ?? text.utf16.count))
  }

  private func elementAttribute(_ element: AXUIElement, _ name: String) -> AXUIElement? {
    guard let value = attribute(element, name),
      CFGetTypeID(value) == AXUIElementGetTypeID()
    else { return nil }
    // Core Foundation types cannot be conditionally cast; the type ID is checked above.
    return (value as! AXUIElement)
  }

  private func selectedRange(_ element: AXUIElement) -> CFRange? {
    guard let value = attribute(element, kAXSelectedTextRangeAttribute),
      CFGetTypeID(value) == AXValueGetTypeID()
    else { return nil }
    let axValue = value as! AXValue
    guard AXValueGetType(axValue) == .cfRange else { return nil }
    var range = CFRange(location: 0, length: 0)
    guard AXValueGetValue(axValue, .cfRange, &range),
      range.location >= 0, range.length >= 0
    else { return nil }
    return range
  }
}
