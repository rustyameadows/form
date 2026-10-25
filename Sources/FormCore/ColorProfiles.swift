import Foundation

/// An immutable, portable output profile. Editable artwork colors remain sRGB.
public struct ArtworkOutputProfile: Codable, Equatable, Sendable {
  public var name: String
  public var asset: String
  public var sha256: String
  public var model: String
  public init(name: String, asset: String, sha256: String, model: String) {
    self.name = name; self.asset = asset; self.sha256 = sha256; self.model = model
  }
  public func validate() throws {
    guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.utf8.count <= 512,
      ["RGB", "CMYK"].contains(model), sha256.count == 64,
      sha256.allSatisfy({ "0123456789abcdef".contains($0) }),
      asset == "icc-" + sha256 + ".icc"
    else { throw FormError.invalid("The output profile reference is invalid. Reimport its ICC file.") }
  }
}
