import AppKit
import FormCore
import FormGraphics
import SwiftUI

struct SewingLayoutCanvas: NSViewRepresentable {
  @ObservedObject var controller: SewingLayoutController
  func makeNSView(context: Context) -> NSScrollView {
    let scroll = NSScrollView()
    scroll.hasHorizontalScroller = true; scroll.hasVerticalScroller = true
    scroll.allowsMagnification = true; scroll.minMagnification = 0.02; scroll.maxMagnification = 12
    scroll.drawsBackground = true; scroll.backgroundColor = NSColor(hex: "#F2F2F2")
    let canvas = SewingLayoutCanvasView(frame: .init(x: 0, y: 0, width: 800, height: 700))
    canvas.controller = controller; scroll.documentView = canvas
    return scroll
  }
  func updateNSView(_ scroll: NSScrollView, context: Context) {
    guard let canvas = scroll.documentView as? SewingLayoutCanvasView else { return }
    canvas.controller = controller; canvas.synchronize()
  }
}

@MainActor final class SewingLayoutCanvasView: NSView {
  weak var controller: SewingLayoutController?
  private let ppm = TypographyEngine.pointsPerMM
  private let padding = 50.0
  private var extent = CGSize(width: 300, height: 700)
  private var fitted = false
  private var lastFitRequest = 0
  private var drag: (id: UUID, point: Point2, placement: SewingCutPlacement, epoch: Int)?
  private var resignObserver: NSObjectProtocol?
  override var isFlipped: Bool { true }
  override var acceptsFirstResponder: Bool { true }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  private var zoom: Double { Double(enclosingScrollView?.magnification ?? 1) }
  private var displayLength: Double {
    guard let c = controller else { return 600 }
    if c.layout.surface == .sheet, let length = c.layout.sheetLength, length.isFinite, length > 0, length <= 5000 { return length }
    return min(5000,max(600,c.previewPlacements.map { $0.bounds.maxY + c.layout.margin }.max() ?? 0))
  }
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if let resignObserver { NotificationCenter.default.removeObserver(resignObserver); self.resignObserver = nil }
    if let window {
      resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.cancelDrag() }
      }
    }
  }
  deinit { if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) } }
  func documentPoint(_ physical: Point2) -> CGPoint { .init(x: (physical.x + padding) * ppm, y: (physical.y + padding) * ppm) }
  func physicalPoint(_ document: CGPoint) -> Point2 { .init(document.x / ppm - padding, document.y / ppm - padding) }
  func synchronize() {
    guard let c = controller else { return }
    if let drag, drag.epoch != c.externalEpoch || !c.sourceAvailable { self.drag = nil }
    let poses = c.previewPlacements
    extent.width = min(3200,max(extent.width, (c.layout.workingWidth ?? 0) + padding * 2, (poses.map { $0.bounds.maxX }.max() ?? 0) + padding * 2))
    extent.height = min(5200,max(extent.height, displayLength + padding * 2))
    let size = CGSize(width: extent.width * ppm, height: extent.height * ppm)
    if frame.size != size { setFrameSize(size) }
    needsDisplay = true
    if !fitted || c.fitRequest != lastFitRequest {
      lastFitRequest = c.fitRequest
      DispatchQueue.main.async { [weak self] in self?.fit() }
    }
  }
  func fit() {
    guard let c = controller, let scroll = enclosingScrollView, scroll.contentSize.width > 0, scroll.contentSize.height > 0 else { return }
    let width = max(30, (c.layout.workingWidth ?? 200) + 30)
    let length = c.layout.surface == .sheet ? c.layout.sheetLength ?? 600 : (c.report?.requiredLength ?? 0) > 0 ? c.report!.requiredLength : 600
    let height = max(30, length + 30)
    scroll.magnify(toFit: .init(origin: documentPoint(.init(-15,-15)), size: .init(width:width*ppm,height:height*ppm)))
    fitted = true
  }
  private func path(_ points: [Point2], closed: Bool) -> CGPath {
    let path = CGMutablePath()
    if let first = points.first {
      path.move(to: .init(x: first.x, y: first.y))
      for p in points.dropFirst() { path.addLine(to: .init(x: p.x, y: p.y)) }
      if closed { path.closeSubpath() }
    }
    return path
  }
  override func draw(_ dirtyRect: NSRect) {
    guard let c = controller, let context = NSGraphicsContext.current?.cgContext else { return }
    NSColor(hex: "#F2F2F2").setFill(); dirtyRect.fill()
    let poses = c.previewPlacements, configuredWidth = c.layout.workingWidth ?? 0, height = displayLength
    let width = configuredWidth.isFinite && configuredWidth > 0 && configuredWidth <= 3000 ? configuredWidth : 0
    let unit = 1 / max(0.001, zoom * ppm)
    context.saveGState(); context.translateBy(x: padding * ppm, y: padding * ppm); context.scaleBy(x: ppm, y: ppm)
    if width > 0 {
      let stock = CGRect(x: 0, y: 0, width: width, height: height)
      context.setFillColor(NSColor.white.cgColor); context.fill(stock)
      context.saveGState(); context.clip(to: stock)
      let visibleA = physicalPoint(visibleRect.origin), visibleB = physicalPoint(.init(x: visibleRect.maxX, y: visibleRect.maxY))
      let step = zoom * ppm > 8 ? 10.0 : 100.0
      context.setStrokeColor(NSColor(hex: "#DDDDDD").cgColor); context.setLineWidth(0.5 * unit)
      for x in stride(from: max(0, floor(visibleA.x / step) * step), through: min(width, visibleB.x), by: step) { context.move(to: .init(x: x, y: 0)); context.addLine(to: .init(x: x, y: height)) }
      for y in stride(from: max(0, floor(visibleA.y / step) * step), through: min(height, visibleB.y), by: step) { context.move(to: .init(x: 0, y: y)); context.addLine(to: .init(x: width, y: y)) }
      context.strokePath()
      if c.showFabric, !poses.isEmpty {
        let clip = CGMutablePath(); for pose in poses { for contour in pose.materialContours { clip.addPath(path(contour,closed:true)) } }
        context.saveGState(); context.addPath(clip); context.clip(using:.evenOdd)
        let fabric = c.fabricReference()
        if let design = fabric.design { FabricPatternRenderer.drawPreview(design, assets: c.assets, width: width, height: height, fontRevision: GeometryFactory.fontRevision) }
        else { context.setFillColor(NSColor(hex: fabric.color).cgColor); context.fill(stock) }
        context.restoreGState()
      }
      context.restoreGState()
      context.setStrokeColor(NSColor(hex: "#999999").cgColor); context.setLineWidth(unit); context.stroke(stock)
      if c.layout.stock == .foldedPair {
        context.setStrokeColor(NSColor(hex: "#666666").cgColor); context.setLineDash(phase: 0, lengths: [8,4]); context.move(to: .init(x: 0,y: 0)); context.addLine(to: .init(x: 0,y: height)); context.strokePath(); context.setLineDash(phase: 0,lengths: [])
      }
      if c.layout.surface == .roll, let required = c.report?.requiredLength, required > 0 {
        context.setStrokeColor(Palette.accentNS.cgColor); context.setLineDash(phase: 0, lengths: [6,3])
        context.move(to: .init(x: 0,y: required)); context.addLine(to: .init(x: width,y: required)); context.strokePath(); context.setLineDash(phase: 0,lengths: [])
      }
    }
    let invalid = Set(c.report?.issues.flatMap(\.placements) ?? [])
    for pose in poses {
      let selected = pose.placement.id == c.selectedID, bad = invalid.contains(pose.placement.id)
      let cuts = SewingLayoutGeometry.cuttingPaths(pose)
      let region=CGMutablePath();for contour in pose.materialContours {region.addPath(path(contour,closed:true))}
      if !c.showFabric || width <= 0 {
        context.setFillColor(NSColor(hex: "#FFFFFF").cgColor); context.addPath(region); context.drawPath(using:.eoFill)
      }
      if bad { context.setFillColor(NSColor.black.withAlphaComponent(0.12).cgColor); context.addPath(region); context.drawPath(using:.eoFill) }
      context.setStrokeColor((selected ? Palette.accentNS : bad ? NSColor.black : NSColor(hex: "#111111")).cgColor)
      context.setLineWidth((selected ? 2 : 1) * unit); for cut in cuts {context.addPath(path(cut.points,closed:cut.closed))}; context.strokePath()
      context.setStrokeColor(NSColor(hex: "#666666").cgColor); context.setLineWidth(0.8 * unit)
      let grain = SewingPatternDrawing.grainline(pose.geometry).map(pose.transform.apply)
      context.addPath(path(grain,closed:false)); context.strokePath()
      let d = pose.grainDirection, n = Point2(-d.y,d.x)
      for (index, tip) in grain.enumerated() {
        if c.layout.grain == .directional && index == 0 { continue }
        let size = min(max(4,3*unit),min(pose.bounds.width,pose.bounds.height)/3), sign = index == 0 ? 1.0 : -1.0
        let back = Point2(tip.x+sign*d.x*size,tip.y+sign*d.y*size)
        context.addPath(path([.init(back.x+n.x*size/2,back.y+n.y*size/2),tip,.init(back.x-n.x*size/2,back.y-n.y*size/2)],closed:false)); context.strokePath()
      }
    }
    context.restoreGState()
    let labelStyle = NSMutableParagraphStyle(); labelStyle.lineBreakMode = .byTruncatingTail
    for pose in poses where pose.bounds.width * ppm * zoom >= 45 && pose.bounds.height * ppm * zoom >= 18 {
      let point = documentPoint(.init(pose.bounds.x + 2, pose.bounds.y + 2))
      let title = "Copy " + pose.placement.copies.map(String.init).joined(separator: ",") + " · " + pose.geometry.piece.name
      let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10 / zoom, weight: .medium), .foregroundColor: NSColor(hex: "#000000"), .backgroundColor: NSColor.white.withAlphaComponent(0.88), .paragraphStyle: labelStyle]
      (title as NSString).draw(in: .init(x: point.x,y: point.y,width: max(1,pose.bounds.width*ppm-4*ppm),height: 18/zoom),withAttributes: attributes)
    }
    if width <= 0 {
      ("Enter the usable stock width to show the material." as NSString).draw(at: documentPoint(.init(0,0)), withAttributes: [.font: NSFont.systemFont(ofSize: 12/zoom), .foregroundColor: NSColor.secondaryLabelColor])
    }
  }
  override func mouseDown(with event: NSEvent) {
    guard let c = controller, c.refreshContext() else { return }
    window?.makeFirstResponder(self)
    let p = physicalPoint(convert(event.locationInWindow,from:nil))
    guard let hit = c.previewPlacements.reversed().first(where: { SewingLayoutGeometry.containsMaterial(p,contours:$0.materialContours) }) else { c.selectedID = nil; needsDisplay = true; return }
    c.selectedID = hit.placement.id
    guard let epoch = c.beginDrag() else { return }
    drag = (hit.placement.id,p,hit.placement,epoch); needsDisplay = true
  }
  override func mouseDragged(with event: NSEvent) {
    guard let c = controller, let drag, c.refreshContext(), drag.epoch == c.externalEpoch else { self.drag = nil; return }
    let p = physicalPoint(convert(event.locationInWindow,from:nil))
    c.move(drag.id,x:drag.placement.x+p.x-drag.point.x,y:drag.placement.y+p.y-drag.point.y,epoch:drag.epoch)
    synchronize()
  }
  override func mouseUp(with event: NSEvent) { guard drag != nil else { return }; drag = nil; controller?.endDrag(); synchronize() }
  func cancelDrag() { drag = nil; controller?.endDrag() }
  override func keyDown(with event: NSEvent) {
    if event.keyCode == 53 { drag = nil; controller?.restoreDrag(); synchronize(); return }
    super.keyDown(with:event)
  }
}
