import Foundation

/// Bounded, inert source settings scoped to one editable layer. Never evaluated as
/// code or used to silently replace edits to the native artwork representation.
public struct ArtworkSourceMetadata: Codable, Equatable, Sendable {
  public var format: String
  public var nodeID: String
  public var properties: Data
  public var version: String?

  public init(format: String, nodeID: String, properties: Data, version: String? = nil) {
    self.format = format; self.nodeID = nodeID; self.properties = properties; self.version = version
  }

  public func validate() throws {
    guard !format.isEmpty, format.utf8.count <= 80, !nodeID.isEmpty, nodeID.utf8.count <= 500,
      (version?.utf8.count ?? 0) <= 100, properties.count <= 256 * 1024 else {
      throw FormError.invalid("Imported layer source settings exceed their metadata budget.")
    }
  }
}
