import AppKit
import FormCore

/// Capacity of the actual compositor, in source UTF-16 units. A linked frame's
/// source range is global to its story; only the terminal frame owns its tail.
public struct TextFrameCapacity: Equatable, Sendable {
  public let sourceLength: Int
  public let displayLength: Int
  public let sourceRange: NSRange
  public let displayRange: NSRange
  public let oversetRange: NSRange
  public let widthOverflow: Bool
  public let available: Bool
  public var overflows: Bool { !available || oversetRange.length > 0 || widthOverflow }

  public init(sourceLength: Int, displayLength: Int, sourceRange: NSRange,
              displayRange: NSRange, oversetRange: NSRange, widthOverflow: Bool = false,
              available: Bool = true) {
    self.sourceLength = sourceLength; self.displayLength = displayLength
    self.sourceRange = sourceRange; self.displayRange = displayRange
    self.oversetRange = oversetRange; self.widthOverflow = widthOverflow; self.available = available
  }
}

extension TypographyEngine {
  /// Match the renderer's displayed range to authored characters, including
  /// locale case expansion. Most text needs no additional attributed snapshot.
  static func independentCapacity(_ element: ArtworkElement, display: NSAttributedString,
                                  visible: NSRange, widthOverflow: Bool) -> TextFrameCapacity {
    let bounded = NSIntersectionRange(visible, NSRange(location: 0, length: display.length))
    let source: NSRange
    if display.string == element.text { source = bounded }
    else {
      let mapping = TextCase.source(attributed(element, preservingSource: true))
      var mapped = mapping.sourceRange(bounded)
      let end = NSMaxRange(bounded)
      // A single authored character can expand into several display characters.
      // Consuming only the first S of uppercased ß has not consumed that source.
      if let partial = mapping.pieces.first(where: {
        $0.source.length != $0.display.length && end > $0.display.location && end < NSMaxRange($0.display)
      }) { mapped.length = max(0, partial.source.location - mapped.location) }
      source = mapped
    }
    let length = element.text.utf16.count, end = min(length, NSMaxRange(source))
    return .init(sourceLength: length, displayLength: display.length,
      sourceRange: source, displayRange: bounded,
      oversetRange: .init(location: end, length: max(0, length - end)), widthOverflow: widthOverflow)
  }
}
