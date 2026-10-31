import Foundation
import FormCore

/// Nested masks and effects share one capture budget. Per-image caps alone do
/// not bound the live buffers retained by a recursively rendered scene.
@MainActor enum ArtworkRasterBudget {
  struct Reservation {let bytes:Int;let failure:UInt64}
  static let maximumBytes=128_000_000,maximumDepth=16
  private static var bytes=0,depth=0,failure:UInt64=0
  static func failed(){failure &+= 1}
  static func reserve(_ requested:Int)throws->Reservation {
    guard requested>0,requested<=maximumBytes-bytes,depth<maximumDepth else {
      failed();throw FormError.invalid("Nested masks and effects exceed the shared 128 MB / 16-capture rendering budget.")
    }
    bytes+=requested;depth+=1
    return .init(bytes:requested,failure:failure)
  }
  static func release(_ reservation:Reservation){bytes-=reservation.bytes;depth-=1}
  static func check(_ reservation:Reservation)throws {
    try Task.checkCancellation()
    guard failure==reservation.failure else{throw FormError.invalid("A nested mask or effect could not render within its resource budget.")}
  }
}
