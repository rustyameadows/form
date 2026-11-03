import AppKit
import FormCore

/// Accessibility geometry is document-space data. Scrolling changes its screen
/// conversion, not every vector/group bound in the document.
@MainActor final class CanvasAccessibilitySnapshot {
  private var source: Artwork?
  private var elements: [UUID: ArtworkElement] = [:]
  private var geometry: [UUID: Rect2] = [:]
  private(set) var builds = 0
  private(set) var boundsBuilds = 0

  @discardableResult func update(_ artwork: Artwork) -> Bool {
    var local = artwork
    local.canvasPosition = nil
    guard source != local else { return false }
    source = local
    elements = Dictionary(uniqueKeysWithValues: local.elements.map { ($0.id, $0) })
    geometry.removeAll(keepingCapacity: true)
    builds += 1
    return true
  }
  func clear() { source = nil; elements = [:]; geometry = [:] }
  func bounds(of id: UUID) -> Rect2? {
    if let cached = geometry[id] { return cached }
    guard let source, let element = elements[id] else { return nil }
    let value = source.bounds(of: element)
    geometry[id] = value
    boundsBuilds += 1
    return value
  }
}
