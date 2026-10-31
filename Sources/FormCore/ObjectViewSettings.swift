import Foundation

/// The source and camera settings belonging to one placed object view.
public struct ObjectViewSettings: Codable, Equatable, Sendable {
  public var sourceID: UUID
  public var azimuth: Double
  public var elevation: Double
  public var style: String
  public var linked: Bool
  /// Longest edge of rendered captures; nil retains the default of 2048 pixels.
  public var pixels: Int?
  /// The saved image predates a source edit and must be regenerated.
  public var renderPending: Bool?
  /// Original camera frame, independent of later nonuniform placement scaling.
  /// Older documents derive it from the saved vector path or element frame.
  public var referenceAspect: Double?

  public func framingAspect(for element: ArtworkElement) -> Double {
    func valid(_ value: Double) -> Bool { value.isFinite && value >= 1e-9 && value <= 1e9 }
    if let referenceAspect, valid(referenceAspect) { return referenceAspect }
    if let path = element.path, path.width.isFinite, path.height.isFinite, path.height > 0 {
      let aspect = path.width / path.height
      if valid(aspect) { return aspect }
    }
    if element.width.isFinite, element.height.isFinite, element.height > 0 {
      let aspect = element.width / element.height
      if valid(aspect) { return aspect }
    }
    return 1
  }

  /// A virtual frame for generating replacement geometry; the actual element
  /// keeps its original frame and transforms, including nonuniform scaling.
  public func framingTarget(for element: ArtworkElement) -> ArtworkElement {
    var frame = element
    frame.width = framingAspect(for: element); frame.height = 1; frame.path = nil
    return frame
  }

  public init(sourceID: UUID, azimuth: Double = 0, elevation: Double = 0,
              style: String = "silhouette", linked: Bool = true) {
    self.sourceID = sourceID
    self.azimuth = azimuth
    self.elevation = elevation
    self.style = style
    self.linked = linked
  }
}
