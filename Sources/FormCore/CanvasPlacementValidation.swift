import Foundation

/// Canvas layout is independent of authored geometry and shared resources. Keep
/// every other value exact so this classification can only reuse a validation
/// that already succeeded for the same document content.
enum CanvasPlacementValidation {
  static func withoutPlacement(_ object: ProductObject) -> ProductObject {
    var object = object
    object.canvasProjectionPositions = nil
    // The unframed workspace must remain at the origin. Retain its position so
    // changing it always reaches validateCanvasWorkspace's existing rule.
    if !object.isCanvasWorkspace { object.artwork?.canvasPosition = nil }
    object.paperConstruction?.insideArtwork?.canvasPosition = nil
    for index in object.surfaceArtworkBindings?.indices ?? 0..<0 {
      object.surfaceArtworkBindings?[index].artwork?.canvasPosition = nil
    }
    return object
  }

  static func sameContent(_ before: Project, _ after: Project) -> Bool {
    guard before.objects.count == after.objects.count else { return false }
    var previous = before, current = after
    previous.updatedAt = .distantPast; current.updatedAt = .distantPast
    previous.history = []; current.history = []
    // Unchanged artwork buffers remain shared. Do not rebuild detached story
    // snapshots through updateStoredArtworks: those contain authored typography.
    for index in previous.objects.indices where previous.objects[index] != current.objects[index] {
      previous.objects[index] = withoutPlacement(previous.objects[index])
      current.objects[index] = withoutPlacement(current.objects[index])
    }
    return previous == current
  }

  static func validatePositions(in project: Project) throws {
    func valid(_ point: Point2) -> Bool {
      point.x.isFinite && point.y.isFinite && abs(point.x) <= 100000 && abs(point.y) <= 100000
    }
    for object in project.objects {
      if let positions = object.canvasProjectionPositions {
        guard positions.count <= 256,
          positions.allSatisfy({ !$0.key.isEmpty && $0.key.utf8.count <= 512 && valid($0.value) })
        else {
          throw FormError.invalid("Canvas projection positions must have bounded identities and finite physical coordinates.")
        }
      }
      for artwork in object.storedArtworks {
        if let position = artwork.canvasPosition, !valid(position) {
          throw FormError.invalid("Invalid artwork canvas position.")
        }
      }
    }
  }
}
