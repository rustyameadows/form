import CoreGraphics
import FormCore
import Foundation

public struct FigmaImportIssue: Codable, Equatable, Sendable {
  public var severity: String, nodeID: String, feature: String, message: String
  public init(_ nodeID: String, _ feature: String, _ message: String, severity: String = "warning") {
    self.nodeID = nodeID; self.feature = feature; self.message = message; self.severity = severity
  }
}

public struct FigmaArtworkImportResult: Sendable {
  public var artwork: Artwork
  public var assets: [String: Data]
  public var selectedRootIDs: Set<UUID>
  public var issues: [FigmaImportIssue]
  public var sourceNodeIDs: [String: UUID]
  public var components: [ArtworkTransferComponent] = []
  public var bounds: Rect2
  public var hasWarnings: Bool { issues.contains { $0.severity != "info" } }
}

/// A value-only compatibility adapter. The supplied schema is already decoded;
/// no payload code is executed and no remote resources are requested here.
public enum FigmaArtworkImporter {
  public static let millimetersPerPixel = 25.4 / 96
  public static func read(_ document: FigmaClipboardDocument) throws -> FigmaArtworkImportResult {
    try FigmaSceneBuilder(document).build()
  }
  public static func sourceID(_ value: FigmaValue?) -> String? {
    if let string = value?.stringValue { return string }
    func integer(_ value: FigmaValue?) -> String? {
      switch value { case .uint(let n): return String(n); case .int(let n): return String(n)
      default: return value?.integerValue.map(String.init) }
    }
    guard let session = integer(value?["sessionID"]), let local = integer(value?["localID"]) else { return nil }
    return session + ":" + local
  }
}

struct FigmaVectorShape {
  var contours: [VectorContour]
  var evenOdd = false
  var styleID: Int?
}

final class FigmaSceneBuilder {
  let document: FigmaClipboardDocument
  let scale = FigmaArtworkImporter.millimetersPerPixel
  var nodes: [String: FigmaValue] = [:], children: [String: [String]] = [:]
  var order: [String: Int] = [:]
  var elements: [ArtworkElement] = [], assets: [String: Data] = [:]
  var sourceIDs: [String: UUID] = [:], issues: [FigmaImportIssue] = []
  var issueKeys = Set<String>(), pathNodes = 0, sourceBytes = 0, rasterPixels = 0
  var components: [ArtworkTransferComponent] = [], componentIDs: [String: UUID] = [:]
  var componentMaps: [String: [String: UUID]] = [:], buildingComponents = Set<String>()
  var geometryStyles: [UUID: Int] = [:]
  var materializedKeys: [String: String] = [:], materializedSources: [String: FigmaValue] = [:]
  var materializedGeometryScale: [String: Point2] = [:]
  var currentColorProfile = "SRGB", documentColorProfile = "SRGB"
  var emittedElements = 0, occurrenceWork = 0
  let maximumElements = 5000, maximumPathNodes = 200000
  init(_ document: FigmaClipboardDocument) { self.document = document }

  func issue(_ id: String, _ feature: String, _ message: String, severity: String = "warning") {
    let key = id + feature + message
    guard issueKeys.insert(key).inserted else { return }
    let issue=FigmaImportIssue(id,feature,message,severity:severity)
    if issues.count < 500 {issues.append(issue)}
    else if severity=="error",let index=issues.firstIndex(where:{$0.severity != "error"}) {issues[index]=issue}
  }
  func number(_ value: FigmaValue?, _ fallback: Double = 0) throws -> Double {
    guard let value else { return fallback }
    guard let n = value.numberValue, n.isFinite, abs(n) <= 1e8 else {
      throw FigmaClipboardError.invalid("Nonfinite or excessive scene coordinate.")
    }
    return n
  }
  func matrix(_ value: FigmaValue?, translationScale: Double = 1) throws -> Affine2 {
    .init(a: try number(value?["m00"], 1), b: try number(value?["m10"]),
      c: try number(value?["m01"]), d: try number(value?["m11"], 1),
      tx: try number(value?["m02"]) * translationScale, ty: try number(value?["m12"]) * translationScale)
  }
  func blob(_ value: FigmaValue?) throws -> Data {
    guard let index = value?.integerValue else { throw FigmaClipboardError.invalid("Missing geometry or image blob index.") }
    let base = document.message["blobBaseIndex"]?.integerValue ?? 0
    let blobs = document.message["blobs"]?.arrayValue ?? []
    guard index >= 0, base >= 0, index <= Int(UInt32.max), base <= Int(UInt32.max),
      index >= base, index - base < blobs.count,
      let bytes = blobs[index - base]["bytes"]?.dataValue else {
      throw FigmaClipboardError.invalid("Scene blob index is outside the clipboard blob table.")
    }
    return bytes
  }
  func append(_ element: ArtworkElement) throws {
    try Task.checkCancellation()
    guard emittedElements < maximumElements else { throw FigmaClipboardError.limit("5,000 expanded native layers") }
    emittedElements += 1
    pathNodes += element.path?.contours.reduce(0) { $0 + $1.nodes.count } ?? 0
    guard pathNodes <= maximumPathNodes else { throw FigmaClipboardError.limit("200,000 editable vector nodes") }
    elements.append(element)
  }
}
