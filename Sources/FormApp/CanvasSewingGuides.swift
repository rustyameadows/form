import FormCore
import Foundation

/// Derived display only. Editable contours and sewing metadata remain on their source elements.
@MainActor final class CanvasSewingGuideCache {
  struct Overlay {
    var artwork: Artwork
    var sourceStrokeIDs: Set<UUID>
    func interfaceArtwork(scale: Double) -> Artwork {
      var display = artwork
      let minimum = 1 / max(0.001, scale)
      for i in display.elements.indices where display.elements[i].stroke != nil {
        display.elements[i].stroke!.width = max(display.elements[i].stroke!.width, minimum)
      }
      return display
    }
  }
  private struct Entry { var source: Artwork; var overlay: Overlay? }
  private var entries: [UUID: Entry] = [:]
  private var order: [UUID] = []
  private(set) var builds = 0
  var count: Int { entries.count }

  func retain(_ frameIDs: Set<UUID>) {
    entries = entries.filter { frameIDs.contains($0.key) }
    order.removeAll { !frameIDs.contains($0) }
  }
  func clear() { entries = [:]; order = [] }
  func overlay(frameID: UUID, source: Artwork) -> Overlay? {
    guard source.showGuides != false, source.elements.contains(where: { $0.sewingPiece != nil }) else {
      entries.removeValue(forKey: frameID); order.removeAll { $0 == frameID }
      return nil
    }
    if let existing = entries[frameID], existing.source == source { return existing.overlay }
    builds += 1
    let overlay = (try? SewingPatternDrawing.plan(source, coordinates: .source)).map { plan in
      let roles = ArtworkProduction.effectiveRoles(in: source)
      // Technical source strokes remain selectable, but their derived stitch/cut
      // paths supply the display. Printed fills and artwork retain their appearance.
      let strokes = source.elements.filter {
        $0.sewingPiece != nil && $0.fillEnabled == false
          && ["rectangle", "polygon", "path"].contains($0.kind)
          && $0.asset == nil && $0.gradient == nil && $0.fillSwatchID == nil
          && roles[$0.id].map { [.cut, .stitch, .guide].contains($0) } == true
      }
      return Overlay(artwork: plan.artwork, sourceStrokeIDs: Set(strokes.map(\.id)))
    }
    entries[frameID] = .init(source: source, overlay: overlay)
    order.removeAll { $0 == frameID }; order.append(frameID)
    while order.count > 32 { entries.removeValue(forKey: order.removeFirst()) }
    return overlay
  }
}
