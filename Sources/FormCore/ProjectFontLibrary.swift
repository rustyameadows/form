import Foundation

/// Portable choices, independent of the fonts installed on this computer.
/// Only exact face names are saved; font files and license data are not copied.
public struct ProjectFontLibrary: Codable, Equatable, Sendable {
  public static let maximumFaces = 1024
  public static let maximumFaceNameBytes = 1_200
  public var faceNames: [String]
  public init(faceNames: [String] = []) { self.faceNames = faceNames }

  public static func validFaceName(_ name: String) -> Bool {
    name.utf8.count <= maximumFaceNameBytes
      && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && name.count <= 300
      && name.rangeOfCharacter(from: .controlCharacters) == nil
  }
  public func validate() throws {
    guard faceNames.count <= Self.maximumFaces, Set(faceNames).count == faceNames.count,
      faceNames.allSatisfy(Self.validFaceName) else {
      throw FormError.invalid("A project font collection supports up to 1,024 unique face names, each up to 300 characters.")
    }
  }
  public mutating func setSaved(_ name: String, saved: Bool) throws {
    guard Self.validFaceName(name) else { throw FormError.invalid("Choose a valid exact font face name.") }
    var next = self
    if saved {
      if !next.faceNames.contains(name) { next.faceNames.append(name) }
    } else { next.faceNames.removeAll { $0 == name } }
    try next.validate(); self = next
  }
}
