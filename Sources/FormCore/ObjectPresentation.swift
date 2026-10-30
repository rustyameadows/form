import Foundation

extension ProductObject {
  /// Presentation only. Canonical source ownership and Canvas editing remain unchanged.
  /// Historical objects have no flag and retain their original Table presence.
  public var hasTablePresentation:Bool {!isCanvasWorkspace && canvasSourceOnly != true}
}
