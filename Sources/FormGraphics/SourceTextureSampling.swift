import Foundation
import FormCore

/// A derived viewing budget. It never changes physical dimensions or output pixels.
public struct SourceTextureRasterPlan: Codable, Equatable, Sendable {
  public var maximumEdge: Int
  public var maximumPixels: Int
  public init(maximumEdge: Int, maximumPixels: Int) {
    self.maximumEdge = maximumEdge; self.maximumPixels = maximumPixels
  }
  public func rasterSize(width: Double, height: Double) throws -> (width: Int, height: Int) {
    guard width.isFinite, height.isFinite, width > 0, height > 0,
      (1...SourceTextureSampling.maximumEdge).contains(maximumEdge),
      (1...SourceTextureSampling.maximumPixels).contains(maximumPixels) else {
      throw FormError.invalid("Source texture sampling needs finite positive physical dimensions and a bounded pixel budget.")
    }
    // Normalize first: neither physical area nor a width*height product can overflow.
    let longest = max(width, height), u = width / longest, v = height / longest
    guard u > 0, v > 0, (u * v).isFinite, u * v > 0 else {
      throw FormError.invalid("The source texture aspect exceeds the finite sampling domain.")
    }
    let edge = min(Double(maximumEdge), sqrt(Double(maximumPixels) / (u * v)))
    var w = max(1, Int(floor(u * edge))), h = max(1, Int(floor(v * edge)))
    // Extreme aspect ratios still allocate one pixel on the short axis.
    if w * h > maximumPixels {
      if w >= h { w = max(1, maximumPixels / h) }
      else { h = max(1, maximumPixels / w) }
    }
    return (w, h)
  }
}

/// Per-object immutable appearance plan, optionally split into physical surfaces.
public struct SourceTextureSamplingPlan: Codable, Equatable, Sendable {
  public var raster: SourceTextureRasterPlan
  public var surfaces: [String: SourceTextureRasterPlan]
  public var isFinalCapture: Bool
  public init(raster: SourceTextureRasterPlan, surfaces: [String: SourceTextureRasterPlan] = [:],
    isFinalCapture: Bool = false) {
    self.raster = raster; self.surfaces = surfaces; self.isFinalCapture = isFinalCapture
  }
  public static func paperFace(_ panelID: String, inside: Bool) -> String {
    "paper:" + panelID + (inside ? ":inside" : ":outside")
  }
  public static func clothPanel(_ index: Int) -> String { "cloth:" + String(index) }
}

public struct SourceTextureSamplingTarget: Equatable, Sendable {
  public var id: String
  public var sourceWidth: Double
  public var sourceHeight: Double
  /// Longest source edge required by its projected material-coordinate derivatives.
  public var projectedEdgePixels: Double
  /// Visible, viewport-clipped pixel area. Zero retains only a small fallback.
  public var visibleWeight: Double
  public init(id: String, sourceWidth: Double, sourceHeight: Double,
    projectedEdgePixels: Double, visibleWeight: Double) {
    self.id = id; self.sourceWidth = sourceWidth; self.sourceHeight = sourceHeight
    self.projectedEdgePixels = projectedEdgePixels; self.visibleWeight = visibleWeight
  }
}

/// Deterministic water-filling across the whole capture, not 8K for every face.
public enum SourceTextureSampling {
  public static let maximumEdge = 8192
  /// Charged source allocation for one capture, not a process resident-memory limit.
  /// Framework/output buffers, temporary raster work and warm caches add memory.
  public static let maximumSourceBytes = 384 * 1024 * 1024
  // Stock fields (20B) + composited maps/relief (20B) + GPU material maps (16B).
  // Count shared channels conservatively; this does not promise a peak RSS bound.
  public static let chargedBytesPerPixel = 56
  public static let maximumPixels = maximumSourceBytes / chargedBytesPerPixel
  public static let maximumTargets = 4096

  public static func allocate(_ supplied: [SourceTextureSamplingTarget],
    maximumEdge edgeLimit: Int = maximumEdge, pixelBudget: Int = maximumPixels
  ) throws -> [String: SourceTextureRasterPlan] {
    guard (1...maximumEdge).contains(edgeLimit), (1...maximumPixels).contains(pixelBudget),
      supplied.count <= maximumTargets, Set(supplied.map(\.id)).count == supplied.count else {
      throw FormError.invalid("Final source sampling exceeds its edge, source-allocation or surface-count budget.")
    }
    let targets = supplied.sorted { $0.id < $1.id }
    guard targets.allSatisfy({ !$0.id.isEmpty && $0.sourceWidth.isFinite && $0.sourceHeight.isFinite
      && $0.sourceWidth > 0 && $0.sourceHeight > 0 && $0.projectedEdgePixels.isFinite
      && $0.projectedEdgePixels >= 0 && $0.visibleWeight.isFinite && $0.visibleWeight >= 0 }) else {
      throw FormError.invalid("Final source sampling requires finite physical surfaces and projected coverage.")
    }
    var requested = [Int](), edges = [Int](), allocated = [Int]()
    for target in targets {
      let requestedEdge = target.visibleWeight == 0 ? min(8, edgeLimit)
        : max(1, Int(ceil(min(Double(edgeLimit), target.projectedEdgePixels * 1.15))))
      let proposed = SourceTextureRasterPlan(maximumEdge: requestedEdge, maximumPixels: pixelBudget)
      let size = try proposed.rasterSize(width: target.sourceWidth, height: target.sourceHeight)
      let pixels = size.width * size.height
      requested.append(pixels); edges.append(requestedEdge); allocated.append(min(64, pixels))
    }
    var remaining = pixelBudget - allocated.reduce(0, +)
    guard remaining >= 0 else { throw FormError.invalid("The capture cannot retain its minimum surface samples within the source-allocation budget.") }
    var active = targets.indices.filter { allocated[$0] < requested[$0] && targets[$0].visibleWeight > 0 }
    while remaining > 0, !active.isEmpty {
      // Normalize the weights to avoid overflow even for very large projected bounds.
      let largest = active.map { targets[$0].visibleWeight }.max()!
      let weight = active.reduce(0.0) { $0 + targets[$1].visibleWeight / largest }
      let available = remaining
      for index in active where remaining > 0 {
        let share = max(1, Int(floor(Double(available) * (targets[index].visibleWeight / largest) / weight)))
        let grant = min(remaining, requested[index] - allocated[index], share)
        allocated[index] += grant; remaining -= grant
      }
      active.removeAll { allocated[$0] >= requested[$0] }
    }
    return Dictionary(uniqueKeysWithValues: targets.indices.map {
      (targets[$0].id, SourceTextureRasterPlan(maximumEdge: edges[$0], maximumPixels: allocated[$0]))
    })
  }
}
