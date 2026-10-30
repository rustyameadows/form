import AppKit

/// Transient pointer feedback; it never belongs to a project or undo snapshot.
enum CanvasPointerFeedback: Equatable {
  case arrow, hand, dragging, text, crosshair, move, frame, control, rotate
  case resize(Int)

  @MainActor var cursor: NSCursor {
    switch self {
    case .arrow: return .arrow
    case .hand, .move, .frame: return .openHand
    case .dragging: return .closedHand
    case .text: return .iBeam
    case .crosshair, .control: return .crosshair
    case .rotate: return Self.rotationCursor
    case .resize(let index):
      let positions: [NSCursor.FrameResizePosition] = [.topLeft, .top, .topRight, .right, .bottomRight, .bottom, .bottomLeft, .left]
      return NSCursor.frameResize(position: positions[max(0, min(7, index))], directions: .all)
    }
  }

  @MainActor private static let rotationCursor: NSCursor = {
    let image = NSImage(size: .init(width: 24, height: 24), flipped: false) { _ in
      let arc = NSBezierPath()
      arc.appendArc(withCenter: .init(x: 12, y: 12), radius: 7, startAngle: 35, endAngle: 310, clockwise: false)
      arc.lineCapStyle = .round
      NSColor.white.setStroke(); arc.lineWidth = 4; arc.stroke()
      NSColor.black.setStroke(); arc.lineWidth = 2; arc.stroke()
      let head = NSBezierPath()
      head.move(to: .init(x: 17.4, y: 6.1)); head.line(to: .init(x: 17.8, y: 11.3))
      head.line(to: .init(x: 12.7, y: 8.6)); head.close()
      NSColor.white.setStroke(); head.lineWidth = 2.5; head.stroke()
      NSColor.black.setFill(); head.fill()
      return true
    }
    return NSCursor(image: image, hotSpot: .init(x: 12, y: 12))
  }()
}
