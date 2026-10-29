import CryptoKit
import Foundation

/// A proof belongs to one immutable source value. Unchanged struct copies share
/// it; every source-property write gives the changed copy a fresh memo.
/// Nothing here is encoded, retained globally, or used to validate resources.
final class CADModelSourceMemo: @unchecked Sendable {
  private let lock = NSLock()
  private var strictOrder: [CADFeatureNode]?
  private var relaxedOrder: [CADFeatureNode]?
  private var fingerprint: String?

  func order(checkRequirements: Bool, build: () throws -> [CADFeatureNode]) rethrows -> [CADFeatureNode] {
    lock.lock()
    let cached = checkRequirements ? strictOrder : relaxedOrder
    lock.unlock()
    if let cached { return cached }
    // Validation is pure. Concurrent cold readers may compute the same proof;
    // failed validation never fills either success slot.
    let result = try build()
    lock.lock()
    if checkRequirements { strictOrder = result } else { relaxedOrder = result }
    lock.unlock()
    return result
  }

  func hash(build: () throws -> Data) rethrows -> String {
    lock.lock(); let cached = fingerprint; lock.unlock()
    if let cached { return cached }
    let result = SHA256.hash(data: try build()).map { String(format: "%02x", $0) }.joined()
    lock.lock(); fingerprint = result; lock.unlock()
    return result
  }
}
