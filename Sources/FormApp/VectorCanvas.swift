import AppKit
import FormCore
import FormGraphics
import SwiftUI

struct VectorCanvas: NSViewRepresentable {
  @ObservedObject var session: ArtworkSession
  var revision: Int
  func makeCoordinator() -> Coordinator { Coordinator() }
  func makeNSView(context: Context) -> NSScrollView {
    let scroll = ArtworkScrollView()
    let view = VectorCanvasView()
    view.setAccessibilityElement(true)
    view.setAccessibilityRole(.group)
    view.setAccessibilityLabel("Artwork canvas")
    scroll.hasHorizontalScroller = true
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    scroll.drawsBackground = true
    scroll.backgroundColor = NSColor(hex: "#E7E7E1")
    scroll.allowsMagnification = true
    scroll.minMagnification = 0.08
    scroll.maxMagnification = 24
    scroll.documentView = view
    view.registerForDraggedTypes([.fileURL, .png, .tiff])
    view.session = session
    session.canvas = view
    scroll.hasHorizontalRuler = true
    scroll.hasVerticalRuler = true
    scroll.horizontalRulerView = ArtworkRuler(scrollView: scroll, orientation: .horizontalRuler)
    scroll.verticalRulerView = ArtworkRuler(scrollView: scroll, orientation: .verticalRuler)
    scroll.rulersVisible = true
    context.coordinator.observation = scroll.observe(\.magnification, options: [.new]) {
      [weak session, weak view] _, change in
      DispatchQueue.main.async {
        if let value = change.newValue {
          session?.zoom = Double(value)
          view?.needsDisplay = true
          scroll.horizontalRulerView?.needsDisplay = true
          scroll.verticalRulerView?.needsDisplay = true
        }
      }
    }
    return scroll
  }
  func updateNSView(_ scroll: NSScrollView, context: Context) {
    guard let view = scroll.documentView as? VectorCanvasView else { return }
    view.session = session
    session.canvas = view
    view.synchronize()
    scroll.horizontalRulerView?.needsDisplay = true
    scroll.verticalRulerView?.needsDisplay = true
  }
  final class Coordinator { var observation: NSKeyValueObservation? }
}

final class ArtworkScrollView: NSScrollView {
  override func layout() {
    super.layout()
    (documentView as? VectorCanvasView)?.fitWhenReady()
  }
}

final class ArtworkRuler: NSRulerView {
  private var guideID: UUID?
  override init(scrollView: NSScrollView?, orientation: NSRulerView.Orientation) {
    super.init(scrollView: scrollView, orientation: orientation)
    ruleThickness = 23
  }
  required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  override var isFlipped: Bool { true }
  override func drawHashMarksAndLabels(in rect: NSRect) {
    NSColor(hex: "#F6F5F0").setFill()
    bounds.fill()
    guard let canvas = scrollView?.documentView as? VectorCanvasView, let session = canvas.session,
      let frame = session.frames.first(where: { $0.id == session.objectID })
    else { return }
    let horizontal = orientation == .horizontalRuler
    let unit = session.unit
    let factor = TypographyEngine.pointsPerMM * (scrollView?.magnification ?? 1) * unit.millimeters
    let desired = 50 / max(factor, 0.001)
    let power = pow(10, floor(log10(desired)))
    let step = [1.0, 2.0, 5.0, 10.0].map { $0 * power }.first { $0 >= desired } ?? power * 10
    let visible = canvas.visibleCanvasRect
    let start = (horizontal ? visible.minX-frame.rect.minX : visible.minY-frame.rect.minY)/unit.millimeters
    let end = (horizontal ? visible.maxX-frame.rect.minX : visible.maxY-frame.rect.minY)/unit.millimeters
    for value in stride(from: floor(start / step) * step, through:end+step, by: step / 5) {
      let world = canvas.documentPoint(CGPoint(
        x: frame.rect.minX + (horizontal ? value * unit.millimeters : 0),
        y: frame.rect.minY + (horizontal ? 0 : value * unit.millimeters)))
      let p = convert(world, from: canvas)
      let position = horizontal ? p.x : p.y
      guard position >= 0, position <= (horizontal ? bounds.width : bounds.height) else { continue }
      let major = abs((value / step).rounded() - value / step) < 0.001
      let path = NSBezierPath()
      path.move(
        to: horizontal ? .init(x: position, y: bounds.maxY) : .init(x: bounds.maxX, y: position))
      path.line(
        to: horizontal
          ? .init(x: position, y: bounds.maxY - (major ? 9 : 4))
          : .init(x: bounds.maxX - (major ? 9 : 4), y: position))
      NSColor(hex: "#A5AAA5").setStroke()
      path.lineWidth = 0.5
      path.stroke()
      if major {
        let label = String(format: abs(value) < 0.0001 ? "0" : "%.3g", value)
        (label as NSString).draw(
          at: horizontal ? .init(x: position + 3, y: 2) : .init(x: 1, y: position + 2),
          withAttributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 8, weight: .regular),
            .foregroundColor: NSColor(hex: "#6D756F"),
          ])
      }
    }
  }
  override func mouseDown(with event: NSEvent) {
    guard let canvas = scrollView?.documentView as? VectorCanvasView, let s = canvas.session,
      let frame = s.frames.first(where: { $0.id == s.objectID })
    else { return }
    let point = canvas.canvasPoint(canvas.convert(event.locationInWindow, from: nil))
    let horizontal = orientation == .horizontalRuler
    s.beginGesture()
    s.addGuide(
      axis: horizontal ? "y" : "x",
      position: (horizontal ? point.y : point.x)
        - (horizontal ? frame.rect.minY : frame.rect.minX))
    guideID = s.art.guides?.last?.id
  }
  override func mouseDragged(with event: NSEvent) {
    guard let canvas = scrollView?.documentView as? VectorCanvasView, let s = canvas.session,
      let frame = s.frames.first(where: { $0.id == s.objectID }), let id = guideID
    else { return }
    let p = canvas.canvasPoint(canvas.convert(event.locationInWindow, from: nil))
    s.mutate { art in
      if let i = art.guides?.firstIndex(where: { $0.id == id }) {
        art.guides?[i].position =
          self.orientation == .horizontalRuler
          ? p.y - frame.rect.minY
          : p.x - frame.rect.minX
      }
    }
  }
  override func mouseUp(with event: NSEvent) {
    guideID = nil
    (scrollView?.documentView as? VectorCanvasView)?.session?.endGesture()
  }
}

final class CanvasTextView: NSTextView, NSTextStorageDelegate {
  var verticalOffset = 0.0
  var horizontalOffset = 0.0
  private var normalizingCase=false
  private var caseReference:NSAttributedString?
  private var storageSnapshot=NSAttributedString(string:"")
  private var sourceEdit:(NSAttributedString,NSRange)?
  private var composition:(NSAttributedString,NSRange)?
  private var glyphInsertion:(NSRange,NSAttributedString)?
  private var ownedStorage:NSTextStorage?
  override init(frame frameRect:NSRect,textContainer:NSTextContainer?=nil) {
    let container:NSTextContainer
    if let textContainer {container=textContainer}
    else {
      let storage=NSTextStorage(),layout=NSLayoutManager()
      container=NSTextContainer(size:NSSize(width:frameRect.width,height:100000))
      storage.addLayoutManager(layout);layout.addTextContainer(container);ownedStorage=storage
    }
    super.init(frame:frameRect,textContainer:container)
    textStorage?.delegate=self
  }
  required init?(coder:NSCoder) {fatalError("init(coder:) has not been implemented")}
  func textStorage(_ storage:NSTextStorage,didProcessEditing mask:NSTextStorageEditActions,range:NSRange,changeInLength delta:Int) {
    if mask.contains(.editedCharacters),storage.string != storageSnapshot.string {
      sourceEdit=(storageSnapshot,NSRange(location:range.location,length:max(0,range.length-delta)))
    }
    storageSnapshot=NSAttributedString(attributedString:storage)
  }
  override func setMarkedText(_ string:Any,selectedRange:NSRange,replacementRange:NSRange) {
    if !hasMarkedText() {
      composition=(NSAttributedString(attributedString:attributedString()),replacementRange.location==NSNotFound ? self.selectedRange() : replacementRange)
    }
    let marked:NSMutableAttributedString
    if let value=string as? NSAttributedString {marked=NSMutableAttributedString(attributedString:value)}
    else {marked=NSMutableAttributedString(string:string as? String ?? "",attributes:typingAttributes)}
    marked.removeAttribute(TextCase.sourceKey,range:NSRange(location:0,length:marked.length))
    for key in [GlyphEngine.overrideKey, .glyphInfo, GlyphEngine.renderKey] { marked.removeAttribute(key, range: NSRange(location:0,length:marked.length)) }
    super.setMarkedText(marked,selectedRange:selectedRange,replacementRange:replacementRange)
    let range=markedRange()
    if range.location != NSNotFound,NSMaxRange(range)<=(textStorage?.length ?? 0) {
      for key in [GlyphEngine.overrideKey,.glyphInfo,GlyphEngine.renderKey] { textStorage?.removeAttribute(key,range:range) }
    }
  }
  override func insertText(_ insertString: Any, replacementRange: NSRange) {
    caseReference=NSAttributedString(attributedString:attributedString())
    undoManager?.beginUndoGrouping()
    defer {glyphInsertion=nil;undoManager?.endUndoGrouping()}
    var input=insertString
    if let string=insertString as? String {
      var attrs=typingAttributes
      attrs.removeValue(forKey:TextCase.sourceKey)
      attrs.removeValue(forKey:GlyphEngine.overrideKey)
      attrs.removeValue(forKey:GlyphEngine.renderKey)
      attrs.removeValue(forKey:.glyphInfo)
      attrs.removeValue(forKey:TypographyEngine.pairKey)
      let key:NSAttributedString.Key=attrs[.tracking] != nil ? .tracking : .kern
      let adjustment=(attrs[TypographyEngine.spacingKey] as? NSNumber)?.doubleValue ?? 0
      attrs[key]=((attrs[key] as? NSNumber)?.doubleValue ?? 0)-adjustment
      attrs[TypographyEngine.spacingKey]=0.0
      input=TypographyEngine.displayingCase(NSAttributedString(string:string,attributes:attrs))
    }
    if let inserted=input as? NSAttributedString {
      let replaced=replacementRange.location==NSNotFound ? (hasMarkedText() ? markedRange():selectedRange()):replacementRange
      glyphInsertion=(NSRange(location:replaced.location,length:inserted.length),inserted)
    }
    super.insertText(input,replacementRange:replacementRange)
  }
  override func didChangeText() {
    if hasMarkedText() {super.didChangeText();return}
    if let (range,inserted)=glyphInsertion,range.location != NSNotFound,
      let storage=textStorage,NSMaxRange(range)<=storage.length {
      glyphInsertion=nil
      // AppKit can inherit custom attributes even from an attributed insertion that omits them.
      for key in [GlyphEngine.overrideKey,.glyphInfo,GlyphEngine.renderKey] { storage.removeAttribute(key,range:range) }
      inserted.enumerateAttribute(GlyphEngine.overrideKey,in:NSRange(location:0,length:inserted.length)) { raw,part,_ in
        if let raw { storage.addAttribute(GlyphEngine.overrideKey,value:raw,range:NSRange(location:range.location+part.location,length:part.length)) }
      }
    }
    if !normalizingCase {
      let before=attributedString(),source=TextCase.source(before,reference:composition?.0 ?? sourceEdit?.0 ?? caseReference,editedRange:composition?.1 ?? sourceEdit?.1)
      let normalized=GlyphEngine.normalizedNative(source.text)
      if !GlyphEngine.nativeEqual(normalized,before) {
        normalizingCase=true
        let range=source.sourceRange(selectedRange())
        let metadataOnly=normalized.string==before.string
        if metadataOnly || (undoManager?.isUndoing != true && undoManager?.isRedoing != true
          && shouldChangeText(in:NSRange(location:0,length:before.length),replacementString:normalized.string)) {
          textStorage?.setAttributedString(normalized)
          setSelectedRange(TextCase.source(normalized).displayRange(range))
        }
        normalizingCase=false
      }
    }
    caseReference=NSAttributedString(attributedString:attributedString())
    sourceEdit=nil
    composition=nil
    super.didChangeText()
  }
  override var textContainerOrigin: NSPoint {
    var origin = super.textContainerOrigin
    origin.y += verticalOffset
    origin.x += horizontalOffset
    return origin
  }
  func applyGlyph(_ glyph: FontGlyph?, sourceRange: NSRange) throws {
    guard !hasMarkedText() else { throw FormError.invalid("Finish the current text input before choosing a glyph.") }
    let before = attributedString(), source = TextCase.source(before).text
    let changed = try GlyphEngine.applying(glyph, range: sourceRange, to: source)
    guard !GlyphEngine.nativeEqual(before,changed) else { return }
    breakUndoCoalescing()
    undoManager?.beginUndoGrouping()
    defer { undoManager?.endUndoGrouping();breakUndoCoalescing() }
    guard shouldChangeText(in: NSRange(location:0,length:before.length), replacementString:nil) else { return }
    textStorage?.setAttributedString(changed)
    setSelectedRange(TextCase.source(changed).displayRange(sourceRange))
    didChangeText()
  }
}

final class VectorCanvasView: NSView, NSTextViewDelegate {
  weak var session: ArtworkSession?
  private let ppm = TypographyEngine.pointsPerMM
  private var frames: [CanvasFrame] = []
  private var projectID: UUID?
  private var fitted = false
  private(set) var canvasOrigin = CGPoint.zero
  private var canvasExtent = CGRect.null
  private var down = CGPoint.zero, windowDown = CGPoint.zero, panOrigin = CGPoint.zero
  private var snapshot = Artwork(), startSelection = Set<UUID>(), dragMode = "", handle = 0
  private var startNodes = Set<UUID>()
  private var downBounds = Rect2(0, 0, 1, 1), marquee: CGRect?
  private var snapLines: [(String, Double)] = []
  private var space = false
  private var textView: NSTextView?
  private var textHost: NativeAffineView?
  private var textClip: NativeAffineView?
  private var publishedInput: NSAttributedString?
  private var originalTextInput: NSAttributedString?
  private var originalTextElement: ArtworkElement?
  private var editingID: UUID?
  private var publishedText: ArtworkElement?
  private var pen: [BezierNode] = []
  private var penID: UUID?
  private var guideID: UUID?
  private var imageDropUpdates = 0, imageDropAttempts = 0
  private var dropFrameID: UUID?
  private var moveDropFrameID: UUID?
  private var moveDropPoint = CGPoint.zero
  private var hover = CGPoint.zero
  private var accessibilityItems: [ArtworkAccessibilityElement] = []
  private var accessibilityUpdates = 0
  private var frameDragOrigin = CGPoint.zero
  private var drawCount = 0, lastDrawMS = 0.0
  var diagnostics: [String: Any] {
    var result = TypographyEngine.diagnostics
    result["image_drag_starts"] = session?.imageDragStarts ?? 0
    result["image_drop_updates"] = imageDropUpdates
    result["image_drop_attempts"] = imageDropAttempts
    result["draw_count"] = drawCount
    result["last_draw_ms"] = lastDrawMS
    result["frames"] = frames.count
    result["accessibility_updates"] = accessibilityUpdates
    result["live_preview"] = session?.preview ?? false
    result["renders_continuously"] = false
    return result
  }
  override var isFlipped: Bool { true }
  override var acceptsFirstResponder: Bool { true }
  override var isOpaque: Bool { true }
  var zoom: Double { Double(enclosingScrollView?.magnification ?? 1) }
  var activeFrame: CanvasFrame? { frames.first { $0.id == session?.objectID } }
  func canvasPoint(_ point:CGPoint) -> CGPoint {
    .init(x:point.x/ppm+canvasOrigin.x,y:point.y/ppm+canvasOrigin.y)
  }
  func documentPoint(_ point:CGPoint) -> CGPoint {
    .init(x:(point.x-canvasOrigin.x)*ppm,y:(point.y-canvasOrigin.y)*ppm)
  }
  private func documentRect(_ rect:CGRect) -> CGRect {
    .init(origin:documentPoint(rect.origin),size:.init(width:rect.width*ppm,height:rect.height*ppm))
  }
  var visibleCanvasRect:CGRect {
    .init(origin:canvasPoint(visibleRect.origin),size:.init(width:visibleRect.width/ppm,height:visibleRect.height/ppm))
  }
  func frame(atCanvasPoint point:CGPoint) -> CanvasFrame? {
    frames.last { !$0.isWorkspace && $0.rect.contains(point) } ?? frames.first { $0.isWorkspace }
  }
  func contentBounds(all:Bool) -> CGRect {
    let chosen = all ? frames : activeFrame.map { [$0] } ?? []
    var result = CGRect.null
    for frame in chosen {
      if !frame.isWorkspace { result = result.union(frame.rect); continue }
      let masks = Set(frame.artwork.elements.compactMap(\.clipID))
      for element in frame.artwork.elements where element.parentID == nil && element.hidden != true && !masks.contains(element.id) {
        result = result.union(CGRect(frame.artwork.bounds(of:element)).offsetBy(dx:frame.rect.minX,dy:frame.rect.minY))
      }
    }
    return result.isNull ? CGRect(x:0,y:0,width:400,height:260) : result
  }
  private func expandCanvas(toInclude rect:CGRect) {
    let before = visibleCanvasRect.origin
    let requested = CGRect(x:floor(rect.minX/160)*160,y:floor(rect.minY/160)*160,
      width:(ceil(rect.maxX/160)-floor(rect.minX/160))*160,
      height:(ceil(rect.maxY/160)-floor(rect.minY/160))*160)
    let next = canvasExtent.isNull ? requested : canvasExtent.union(requested)
    guard next != canvasExtent else { return }
    canvasExtent = next
    canvasOrigin = next.origin
    setFrameSize(.init(width:max(600,next.width*ppm),height:max(500,next.height*ppm)))
    if let scroll = enclosingScrollView {
      scroll.tile()
      scroll.contentView.scroll(to:documentPoint(before))
      scroll.reflectScrolledClipView(scroll.contentView)
    }
  }
  func synchronize() {
    guard let session else { return }
    if projectID != session.store?.project?.id { canvasExtent = .null; canvasOrigin = .zero }
    frames = session.frames
    expandCanvas(toInclude:contentBounds(all:true).union(CGRect(x:0,y:0,width:400,height:260)).insetBy(dx:-180,dy:-180))
    if projectID != session.store?.project?.id {
      projectID = session.store?.project?.id
      fitted = false
      finishText()
      pen = []
      penID = nil
    }
    if !fitted, !frames.isEmpty {
      DispatchQueue.main.async { [weak self] in self?.fitWhenReady() }
    }
    if let id = editingID, let tv = textView,
      let e = session.art.elements.first(where: { $0.id == id }).map(session.colored), e != publishedText,
      !tv.hasMarkedText()
    {
      let range = TextCase.source(tv.attributedString()).sourceRange(tv.selectedRange())
      tv.textStorage?.setAttributedString(TypographyEngine.attributed(e, millimeters: false, preservingSource: true))
      publishedInput = NSAttributedString(attributedString: tv.attributedString())
      tv.setSelectedRange(TextCase.source(tv.attributedString()).displayRange(NSRange(location:min(range.location,e.text.utf16.count),length:0)))
      publishedText = e
    }
    if let id = editingID, let element = session.art.elements.first(where: { $0.id == id }) {
      positionTextHost(element)
    }
    needsDisplay = true
    updateAccessibilityItems()
  }
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    DispatchQueue.main.async { [weak self] in
      self?.fitWhenReady()
      self?.updateAccessibilityItems()
    }
  }
  func fitWhenReady() {
    guard !fitted, !frames.isEmpty, window != nil, let scroll = enclosingScrollView,
      scroll.contentSize.width > 100, scroll.contentSize.height > 100
    else { return }
    fitted = true
    fit(all: true)
  }
  func fit(all: Bool) {
    guard let scroll = enclosingScrollView else { return }
    guard scroll.contentSize.width > 100, scroll.contentSize.height > 100 else { return }
    fitted = true
    let rect = contentBounds(all:all)
    guard !rect.isNull, rect.width > 0 else { return }
    let horizontal = min(14, rect.width * 0.08 + 1)
    let vertical = min(18, rect.height * 0.08 + 1)
    scroll.magnify(
      toFit: documentRect(rect.insetBy(dx:-horizontal,dy:-vertical)))
    session?.zoom = Double(scroll.magnification)
    needsDisplay = true
  }
  func setZoom(_ value: Double) {
    guard let scroll = enclosingScrollView else { return }
    scroll.setMagnification(CGFloat(min(24, max(0.08, value))), centeredAt: visibleRect.center)
    session?.zoom = Double(scroll.magnification)
    needsDisplay = true
  }
  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    trackingAreas.forEach { removeTrackingArea($0) }
    addTrackingArea(
      .init(
        rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self,
        userInfo: nil))
  }
  override func draw(_ dirtyRect: NSRect) {
    let start = CFAbsoluteTimeGetCurrent()
    defer {
      drawCount += 1
      lastDrawMS = (CFAbsoluteTimeGetCurrent() - start) * 1000
    }
    NSColor(hex: "#E7E7E1").setFill()
    dirtyRect.fill()
    guard let context = NSGraphicsContext.current?.cgContext, let session else { return }
    context.saveGState()
    context.scaleBy(x: ppm, y: ppm)
    context.translateBy(x:-canvasOrigin.x,y:-canvasOrigin.y)
    let scale = ppm * zoom
    for f in frames
    where f.isWorkspace || dirtyRect.intersects(documentRect(f.rect.insetBy(dx:-12,dy:-12)))
    {
      if !f.isWorkspace {
      context.saveGState()
      context.setShadow(
        offset: .init(width: 0, height: 2 / scale), blur: 9 / scale,
        color: NSColor.black.withAlphaComponent(0.13).cgColor)
      context.setFillColor(NSColor.white.cgColor)
      context.fill(f.rect)
      context.restoreGState()
      let title = f.object.name.uppercased()
      let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 9 / scale, weight: .medium),
        .foregroundColor: NSColor(hex: "#69736C"),
      ]
      (title as NSString).draw(
        at: .init(x: f.rect.minX, y: f.rect.minY - 15 / scale), withAttributes: attributes)
      }
      context.saveGState()
      context.translateBy(x: f.rect.minX, y: f.rect.minY)
      if session.dieline, f.surfaceObject.recipeID == "sleeve", f.id == session.objectID {
        context.setFillColor(NSColor.white.cgColor)
        context.fill(.init(origin: .zero, size: f.rect.size))
        context.saveGState()
        context.translateBy(x: f.surfaceObject["width"] + f.surfaceObject["height"], y: 0)
        ArtworkRenderer.draw(
          f.artwork, width: f.surfaceObject["width"], height: f.rect.height, assets: session.assets)
        context.restoreGState()
        context.setStrokeColor(NSColor(hex: "#D45A37").cgColor)
        context.setLineWidth(1 / scale)
        context.stroke(.init(origin: .zero, size: f.rect.size))
        context.setStrokeColor(NSColor(hex: "#4589B0").cgColor)
        context.setLineDash(phase: 0, lengths: [4 / scale, 3 / scale])
        for x in Dieline.scores(f.surfaceObject) {
          context.move(to: .init(x: x, y: 0))
          context.addLine(to: .init(x: x, y: f.rect.height))
          context.strokePath()
        }
      } else {
        ArtworkRenderer.draw(
          f.artwork, width: f.rect.width, height: f.rect.height, assets: session.assets,
          production: false,
          excluding: f.id == session.objectID ? Set([editingID].compactMap { $0 }).union(
            dragMode == "move" && moveDropFrameID != nil ? session.art.descendants(of:startSelection) : []) : [],
          unbounded:f.isWorkspace)
        if f.id == session.objectID {
          drawOverlays(f, context: context, scale: scale)
          if editingID == nil && !(dragMode == "move" && moveDropFrameID != nil) { drawSelection(context: context, scale: scale) }
        }
      }
      context.restoreGState()
      if (dropFrameID == f.id || moveDropFrameID == f.id) && !f.isWorkspace {
        context.setStrokeColor(NSColor.systemBlue.cgColor)
        context.setLineWidth(3/scale)
        context.stroke(f.rect.insetBy(dx:-2/scale,dy:-2/scale))
      }
    }
    if dragMode == "move",moveDropFrameID != nil,let active = activeFrame,
      let exported = try? session.art.exporting(startSelection) {
      context.saveGState()
      context.translateBy(x:active.rect.minX+exported.bounds.x,y:active.rect.minY+exported.bounds.y)
      ArtworkRenderer.draw(exported.artwork,width:exported.bounds.width,height:exported.bounds.height,
        assets:session.assets,production:false,unbounded:true)
      context.restoreGState()
      context.saveGState(); context.translateBy(x:active.rect.minX,y:active.rect.minY)
      drawSelection(context:context,scale:scale); context.restoreGState()
      if let destination = frames.first(where: { $0.id == moveDropFrameID }) {
        let label = "Move to \(destination.isWorkspace ? "Canvas" : destination.object.name)"
        let attributes:[NSAttributedString.Key:Any] = [.font:NSFont.systemFont(ofSize:10/scale,weight:.medium),
          .foregroundColor:NSColor.systemBlue]
        let size = (label as NSString).size(withAttributes:attributes)
        let origin = CGPoint(x:moveDropPoint.x+12/scale,y:moveDropPoint.y+12/scale)
        context.setFillColor(NSColor.white.withAlphaComponent(0.95).cgColor)
        context.fill(CGRect(x:origin.x-4/scale,y:origin.y-3/scale,width:size.width+8/scale,height:size.height+6/scale))
        (label as NSString).draw(at:origin,withAttributes:attributes)
      }
    }
    context.restoreGState()
  }
  private func drawOverlays(_ f: CanvasFrame, context: CGContext, scale: Double) {
    guard let session else { return }
    let art = f.artwork
    context.saveGState()
    let region = f.isWorkspace ? visibleCanvasRect.offsetBy(dx:-f.rect.minX,dy:-f.rect.minY) : CGRect(origin:.zero,size:f.rect.size)
    context.clip(to:region)
    context.setLineWidth(0.5 / scale)
    if art.showGrid == true {
      let spacing = max(art.gridSpacing ?? 10, 5 / scale)
      context.setStrokeColor(NSColor(hex: "#A6ACA6").withAlphaComponent(0.3).cgColor)
      for x in stride(from: floor(region.minX/spacing)*spacing, through:region.maxX, by: spacing) {
        context.move(to: .init(x: x, y:region.minY))
        context.addLine(to: .init(x: x, y:region.maxY))
      }
      for y in stride(from: floor(region.minY/spacing)*spacing, through:region.maxY, by: spacing) {
        context.move(to: .init(x:region.minX, y:y))
        context.addLine(to: .init(x:region.maxX, y:y))
      }
      context.strokePath()
    }
    context.setStrokeColor(NSColor(hex: "#5B8DA9").withAlphaComponent(0.7).cgColor)
    context.setLineDash(phase: 0, lengths: [4 / scale, 3 / scale])
    for g in art.showGuides == false ? [] : art.guides ?? [] {
      context.move(to: g.axis == "x" ? .init(x:g.position,y:region.minY) : .init(x:region.minX,y:g.position))
      context.addLine(
        to: g.axis == "x"
          ? .init(x:g.position,y:region.maxY) : .init(x:region.maxX,y:g.position))
      context.strokePath()
    }
    context.setStrokeColor(NSColor(hex: "#B78D68").withAlphaComponent(0.5).cgColor)
    if art.bleed > 0 && !f.isWorkspace {
      context.stroke(CGRect(origin: .zero, size: f.rect.size).insetBy(dx: art.bleed, dy: art.bleed))
    }
    context.setLineDash(phase: 0, lengths: [])
    context.setStrokeColor(NSColor(hex: "#D45A37").cgColor)
    context.setLineWidth(1 / scale)
    for (axis, p) in snapLines {
      context.move(to: axis == "x" ? .init(x:p,y:region.minY) : .init(x:region.minX,y:p))
      context.addLine(
        to: axis == "x" ? .init(x:p,y:region.maxY) : .init(x:region.maxX,y:p))
      context.strokePath()
    }
    if let marquee {
      context.setFillColor(NSColor(hex: "#D45A37").withAlphaComponent(0.08).cgColor)
      context.fill(marquee)
      context.stroke(marquee)
    }
    context.restoreGState()
    if !pen.isEmpty {
      let p = CGMutablePath()
      p.move(to: .init(pen[0].anchor))
      for node in pen.dropFirst() { p.addLine(to: .init(node.anchor)) }
      p.addLine(to: hover)
      context.addPath(p)
      context.setStrokeColor(NSColor(hex: "#D45A37").cgColor)
      context.setLineWidth(1 / scale)
      context.strokePath()
    }
    if session.scopeID != nil {
      context.setStrokeColor(NSColor(hex: "#D45A37").withAlphaComponent(0.3).cgColor)
      context.setLineWidth(1 / scale)
      if let group = art.elements.first(where: { $0.id == session.scopeID }) {
        context.stroke(CGRect(art.bounds(of: group)))
        if group.booleanOperation != nil {
          context.saveGState()
          context.setLineDash(phase: 0, lengths: [4 / scale, 3 / scale])
          let masks = Set(art.elements.compactMap(\.clipID))
          for operand in art.elements
          where operand.parentID == group.id && operand.hidden != true
            && !masks.contains(operand.id)
          {
            let path =
              operand.kind == "group"
              ? (try? BooleanGeometry.path(operand, in: art)) : VectorGeometry.path(operand)
            if let path {
              var transform = art.worldTransform(operand).cg
              context.addPath(path.copy(using: &transform) ?? path)
              context.strokePath()
            }
          }
          context.restoreGState()
        }
      }
    }
  }
  private func handles(_ b: Rect2) -> [CGPoint] {
    [
      .init(x: b.x, y: b.y), .init(x: b.center.x, y: b.y), .init(x: b.maxX, y: b.y),
      .init(x: b.maxX, y: b.center.y), .init(x: b.maxX, y: b.maxY), .init(x: b.center.x, y: b.maxY),
      .init(x: b.x, y: b.maxY), .init(x: b.x, y: b.center.y),
    ]
  }
  private func dot(
    _ p: CGPoint, context: CGContext, scale: Double, circle: Bool = false, filled: Bool = false
  ) {
    let r = CGRect(x: p.x - 3 / scale, y: p.y - 3 / scale, width: 6 / scale, height: 6 / scale)
    context.setFillColor((filled ? NSColor(hex: "#D45A37") : NSColor.white).cgColor)
    let path = circle ? CGPath(ellipseIn: r, transform: nil) : CGPath(rect: r, transform: nil)
    context.addPath(path)
    context.drawPath(using: .fillStroke)
  }
  private func drawSelection(context: CGContext, scale: Double) {
    guard let s = session, let b = s.selectionBounds else { return }
    let art = s.art
    if let id = s.croppingImageID, let e = art.elements.first(where: { $0.id == id }) {
      context.saveGState()
      context.concatenate(art.worldTransform(e).cg)
      context.setStrokeColor(NSColor.systemBlue.cgColor)
      context.setLineWidth(1.2 / scale)
      context.stroke(CGRect(x:0,y:0,width:e.width,height:e.height))
      context.setLineDash(phase:0,lengths:[3/scale,3/scale])
      for value in [1.0/3,2.0/3] {
        context.move(to:.init(x:e.width*value,y:0)); context.addLine(to:.init(x:e.width*value,y:e.height))
        context.move(to:.init(x:0,y:e.height*value)); context.addLine(to:.init(x:e.width,y:e.height*value))
      }
      context.strokePath(); context.restoreGState()
      return
    }
    context.setStrokeColor(NSColor(hex: "#D45A37").cgColor)
    context.setLineWidth(1.2 / scale)
    context.stroke(CGRect(b))
    handles(b).forEach { dot($0, context: context, scale: scale) }
    let rotate = CGPoint(x: b.center.x, y: b.y - 18 / scale)
    context.move(to: .init(x: b.center.x, y: b.y))
    context.addLine(to: rotate)
    context.strokePath()
    dot(rotate, context: context, scale: scale, circle: true)
    if s.selection.count == 1, let pivot = s.transformOrigin {
      let p = CGPoint(pivot),r = 4.5/scale
      context.strokeEllipse(in:CGRect(x:p.x-r,y:p.y-r,width:r*2,height:r*2))
      context.move(to:.init(x:p.x-r*1.6,y:p.y)); context.addLine(to:.init(x:p.x+r*1.6,y:p.y))
      context.move(to:.init(x:p.x,y:p.y-r*1.6)); context.addLine(to:.init(x:p.x,y:p.y+r*1.6))
      context.strokePath()
    }
    if let e = s.primary, s.maskEditing?.maskID == e.id {
      context.addPath(VectorGeometry.worldPath(e,in:art))
      context.strokePath()
    }
    if s.tool == .direct {
      for e in s.elements {
        guard let path = e.path else { continue }
        let t = art.worldTransform(e).followed(
          by: .scale(e.width / path.width, e.height / path.height))
        for node in path.contours.flatMap(\.nodes) {
          let p = CGPoint(t.apply(node.anchor))
          if s.nodes.contains(node.id) {
            for h in [node.incoming, node.outgoing].compactMap({ $0 }) {
              let q = CGPoint(t.apply(h))
              context.move(to: p)
              context.addLine(to: q)
              context.strokePath()
              dot(q, context: context, scale: scale, circle: true)
            }
          }
          dot(p, context: context, scale: scale, filled: s.nodes.contains(node.id))
        }
      }
    }
    if s.selection.count == 1, s.maskEditing == nil, let e = s.primary, let axis = gradientHandles(e, in: art) {
      context.saveGState()
      context.move(to: axis.a); context.addLine(to: axis.b); context.strokePath()
      dot(axis.a, context: context, scale: scale, circle: true)
      dot(axis.b, context: context, scale: scale, circle: true)
      for item in axis.stops {
        let r = CGRect(x:item.point.x-4.5/scale,y:item.point.y-4.5/scale,width:9/scale,height:9/scale)
        context.setFillColor(NSColor(hex:item.stop.color).cgColor)
        context.fillEllipse(in:r)
        context.setStrokeColor((s.selectedGradientStopID == item.stop.id ? NSColor(hex:"#D45A37") : NSColor.white).cgColor)
        context.setLineWidth((s.selectedGradientStopID == item.stop.id ? 2 : 1)/scale)
        context.strokeEllipse(in:r)
      }
      context.restoreGState()
    }
    if let e = s.primary, e.kind == "text", TypographyEngine.overflows(e) {
      let r = CGRect(
        x: b.maxX - 8 / scale, y: b.maxY - 8 / scale, width: 8 / scale, height: 8 / scale)
      context.setFillColor(NSColor(hex: "#D45A37").cgColor)
      context.fill(r)
    }
  }
  private func point(_ event: NSEvent) -> CGPoint {
    let p = canvasPoint(convert(event.locationInWindow, from: nil))
    return .init(
      x:p.x-(activeFrame?.rect.minX ?? 0),y:p.y-(activeFrame?.rect.minY ?? 0))
  }
  private func gradientHandles(_ element: ArtworkElement, in art: Artwork)
    -> (a: CGPoint, b: CGPoint, stops: [(stop: GradientStop, point: CGPoint)])? {
    let e = session?.colored(element) ?? element
    guard let g = e.gradient else { return nil }
    let t = art.worldTransform(e).followed(by:g.transform ?? .init())
    let a = CGPoint(t.apply(.init(g.start.x*e.paintSize.x,g.start.y*e.paintSize.y)))
    let b = CGPoint(t.apply(.init(g.end.x*e.paintSize.x,g.end.y*e.paintSize.y)))
    let length = hypot(b.x-a.x,b.y-a.y)
    guard length > 1e-9 else { return (a,b,[]) }
    var repeated: [Double:Int] = [:]
    let stops = g.stops.map { stop -> (GradientStop,CGPoint) in
      let row = repeated[stop.offset,default:0]; repeated[stop.offset] = row+1
      let offset = Double(12+row*12)/(ppm*zoom)
      return (stop,.init(x:a.x+(b.x-a.x)*stop.offset-(b.y-a.y)/length*offset,
        y:a.y+(b.y-a.y)*stop.offset+(b.x-a.x)/length*offset))
    }
    return (a,b,stops)
  }
  private func gradientPosition(_ p: CGPoint, a: CGPoint, b: CGPoint) -> Double? {
    let dx = b.x-a.x, dy = b.y-a.y, square = dx*dx+dy*dy
    guard square > 1e-18 else { return nil }
    return ((p.x-a.x)*dx+(p.y-a.y)*dy)/square
  }
  private func hit(_ point: CGPoint, art: Artwork, scope: UUID?) -> ArtworkElement? {
    let masks = Set(art.elements.compactMap(\.clipID))
    for e in art.elements.reversed() where e.parentID == scope &&
      (session?.maskEditing.map { $0.maskID == e.id && !art.isLocked(e) } ?? (art.editable(e) && !masks.contains(e.id))) {
      let world = art.worldTransform(e)
      if e.kind == "group" {
        if CGRect(art.bounds(of: e)).contains(point) { return e }
        continue
      }
      guard let inv = world.inverse else { continue }
      let p = CGPoint(inv.apply(.init(point)))
      let path = VectorGeometry.path(e)
      if ["text", "image"].contains(e.kind),
        CGRect(x: 0, y: 0, width: e.width, height: e.height).contains(p)
      {
        return e
      }
      if e.fillEnabled != false || session?.maskEditing?.maskID == e.id,
        path.contains(p, using: e.path?.evenOdd == true ? .evenOdd : .winding)
      {
        return e
      }
      if path.copy(
        strokingWithWidth: max(e.stroke?.width ?? 0, 7 / (ppm * zoom)), lineCap: .round,
        lineJoin: .round, miterLimit: 10
      ).contains(p) {
        return e
      }
    }
    return nil
  }
  override func mouseDown(with event: NSEvent) {
    guard let s = session else { return }
    s.store?.activateDesignSurface(.artwork)
    let absolute = convert(event.locationInWindow, from: nil)
    let physical = canvasPoint(absolute)
    moveDropFrameID = nil
    if space || s.tool == .hand {
      dragMode = "pan"
      windowDown = event.locationInWindow
      panOrigin = visibleCanvasRect.origin
      NSCursor.closedHand.push()
      return
    }
    if let frame = frame(atCanvasPoint:physical), frame.id != s.objectID {
      finishText()
      s.activate(frame.id)
      frames = s.frames
    }
    if let f = frames.last(where: { !$0.isWorkspace &&
      CGRect(
        x: $0.rect.minX, y: $0.rect.minY - 16 / (ppm * zoom), width: $0.rect.width,
        height: 16 / (ppm * zoom)
      ).contains(physical)
    }) {
      finishText()
      s.activate(f.id)
      frames = s.frames
      frameDragOrigin = f.rect.origin
      down = physical
      snapshot = s.art
      dragMode = "frame"
      s.beginGesture()
      return
    }
    guard let f = activeFrame, !s.dieline else { return }
    let p = point(event)
    finishText()
    window?.makeFirstResponder(self)
    down = p
    snapshot = s.art
    startSelection = s.selection
    startNodes = s.nodes
    dragMode = ""
    snapLines = []
    s.beginGesture()
    if let id = s.croppingImageID, let e = s.art.elements.first(where:{$0.id == id}),
      let inverse = s.art.worldTransform(e).inverse {
      let local = inverse.apply(.init(p))
      if CGRect(x:0,y:0,width:e.width,height:e.height).contains(CGPoint(local)) {
        dragMode = "image_crop"
        return
      }
      s.croppingImageID = nil
    }
    if s.tool == .pen {
      penDown(p, event: event)
      return
    }
    if s.tool == .eyedropper {
      NSColorSampler().show { [weak s] color in
        if let color { DispatchQueue.main.async { s?.textColor(FormColor.hex(color)) } }
      }
      return
    }
    if [.select, .direct].contains(s.tool) {
      if s.tool == .direct, nodeHit(p, event: event) {
        if event.clickCount == 2 {
          s.editPath(
            s.elements.flatMap { $0.path?.contours.flatMap(\.nodes) ?? [] }.first(where: {
              s.nodes.contains($0.id)
            })?
            .effectiveMode == "corner" ? "smooth" : "corner")
          snapshot = s.art
        }
        needsDisplay = true
        return
      }
      if s.tool == .direct, event.clickCount == 2, let e = s.primary, let path = e.path,
        !s.art.isLocked(e),
        let segment = PathCommands.nearestSegment(
          path, to: .init(p),
          map: s.art.worldTransform(e).followed(
            by: .scale(e.width / path.width, e.height / path.height))),
        segment.distance < 7 / (ppm * zoom), segment.t > 0.001, segment.t < 0.999
      {
        s.nodes = [segment.nodeID]
        s.editPath("insert", ["t": segment.t])
        dragMode = ""
        return
      }
      if s.selection.count == 1, s.maskEditing == nil, let e = s.primary, !s.art.isLocked(e),
        let axis = gradientHandles(e,in:s.art) {
        if let item = axis.stops.last(where:{ hypot($0.point.x-p.x,$0.point.y-p.y) < 7/(ppm*zoom) }) {
          s.selectedGradientStopID = item.stop.id
          dragMode = "gradient_stop"
          return
        }
        for (i,h) in [axis.a,axis.b].enumerated() where hypot(h.x-p.x,h.y-p.y) < 7/(ppm*zoom) {
          dragMode = "gradient"; handle = i; return
        }
        if let offset = gradientPosition(p,a:axis.a,b:axis.b), (0...1).contains(offset),
          hypot(p.x-(axis.a.x+(axis.b.x-axis.a.x)*offset),p.y-(axis.a.y+(axis.b.y-axis.a.y)*offset)) < 6/(ppm*zoom) {
          if event.clickCount == 2 {
            s.paint("add_stop",["offset":offset]); snapshot = s.art
            dragMode = "gradient_stop"
          } else { dragMode = "gradient_axis" }
          return
        }
      }
      if let b = s.selectionBounds, !s.elements.contains(where: { s.art.isLocked($0) }) {
        downBounds = b
        let r = CGPoint(x: b.center.x, y: b.y - 18 / (ppm * zoom))
        if hypot(p.x - r.x, p.y - r.y) < 7 / (ppm * zoom) {
          dragMode = "rotate"
          return
        }
        if let i = handles(b).firstIndex(where: { hypot($0.x - p.x, $0.y - p.y) < 6 / (ppm * zoom) }
        ) {
          dragMode = "resize"
          handle = i
          return
        }
      }
      if let e = hit(p, art: s.art, scope: s.scopeID) {
        if s.tool == .direct, s.selection.contains(e.id), e.path != nil {
          if !event.modifierFlags.contains(.shift) { s.nodes = [] }
          dragMode = "node_marquee"
          marquee = CGRect(origin: p, size: .zero)
          return
        }
        if event.clickCount == 2, e.kind == "image" {
          s.choose([e.id]); s.croppingImageID = e.id
          needsDisplay = true
          return
        }
        if event.clickCount == 2, e.kind == "text" {
          s.choose([e.id])
          beginText(e)
          return
        }
        if event.clickCount == 2, e.kind == "group" {
          if e.component != nil {
            s.editComponentSource(e)
            return
          }
          s.scopeID = e.id
          s.choose([])
          needsDisplay = true
          return
        }
        if event.modifierFlags.contains(.shift) {
          if s.selection.contains(e.id) {
            s.selection.remove(e.id)
          } else {
            s.selection.insert(e.id)
          }
        } else if !s.selection.contains(e.id) {
          s.choose([e.id])
        }
        startSelection = s.selection
        snapshot = s.art
        downBounds = s.selectionBounds ?? .init(0, 0, 1, 1)
        dragMode = "move"
      } else {
        if s.tool == .direct, s.primary?.path != nil {
          if !event.modifierFlags.contains(.shift) { s.nodes = [] }
          dragMode = "node_marquee"
          marquee = CGRect(origin: p, size: .zero)
          return
        }
        if !event.modifierFlags.contains(.shift) { s.choose([]) }
        for g in s.art.showGuides == false ? [] : s.art.guides ?? [] where g.locked != true {
          if abs((g.axis == "x" ? p.x : p.y) - g.position) < 5 / (ppm * zoom) {
            guideID = g.id
            dragMode = "guide"
            return
          }
        }
        dragMode = "marquee"
        marquee = CGRect(origin: p, size: .zero)
      }
    } else if f.isWorkspace || CGRect(origin: .zero, size: f.rect.size).contains(p) {
      var e = ArtworkElement(
        kind: s.tool.rawValue, x: p.x, y: p.y, width: s.tool == .text ? 90 : 1,
        height: s.tool == .text ? 18 : 1, text: s.tool == .text ? "Text" : "", color: "#292D2C",
        fontSize: 24)
      e.parentID = s.scopeID
      if let parent = s.art.elements.first(where: { $0.id == s.scopeID }) {
        e.affine = s.art.worldTransform(parent).inverse
      }
      if s.tool == .text {
        var t = Typography()
        t.frameMode = "point"
        t.kerningMode = "metrics"
        e.typography = t
      }
      if s.tool == .line {
        e.stroke = .init(color: e.color, width: 0.5)
        e.fillEnabled = false
      }
      s.add([e])
      s.choose([e.id])
      snapshot = s.art
      dragMode = "create"
    }
    needsDisplay = true
  }
  override func mouseDragged(with event: NSEvent) {
    guard let s = session else { return }
    if dragMode == "pan" {
      let p = event.locationInWindow
      let proposed = CGPoint(x:panOrigin.x-(p.x-windowDown.x)/(zoom*ppm),y:panOrigin.y+(p.y-windowDown.y)/(zoom*ppm))
      let region = CGRect(origin:proposed,size:visibleCanvasRect.size)
      expandCanvas(toInclude:region.insetBy(dx:-80,dy:-80))
      enclosingScrollView?.contentView.scroll(
        to:documentPoint(region.origin))
      enclosingScrollView?.reflectScrolledClipView(enclosingScrollView!.contentView)
      return
    }
    let p = point(event)
    var value = snapshot
    if dragMode == "image_crop", let id = s.croppingImageID,
      let i = value.elements.firstIndex(where:{$0.id == id}),
      let inverse = snapshot.worldTransform(value.elements[i]).inverse {
      let a = inverse.apply(.init(down)), b = inverse.apply(.init(p))
      let crop = value.elements[i].imageCrop ?? .full
      value.elements[i].imageCrop = crop.moved(dx:-(b.x-a.x)/value.elements[i].width*crop.width,
        dy:-(b.y-a.y)/value.elements[i].height*crop.height)
      s.save(value)
      return
    }
    if dragMode == "frame" {
      let p = canvasPoint(convert(event.locationInWindow, from: nil))
      var art = snapshot
      art.canvasPosition = .init(
        frameDragOrigin.x+p.x-down.x,frameDragOrigin.y+p.y-down.y)
      s.save(art)
      return
    }
    if dragMode == "pen" {
      guard !pen.isEmpty else { return }
      let anchor = pen[pen.count - 1].anchor
      pen[pen.count - 1].outgoing = .init(p)
      if !event.modifierFlags.contains(.option) {
        pen[pen.count - 1].incoming = .init(2 * anchor.x - p.x, 2 * anchor.y - p.y)
      }
      needsDisplay = true
      return
    }
    if dragMode == "node_marquee" {
      let rect = CGRect(
        x: min(down.x, p.x), y: min(down.y, p.y), width: abs(p.x - down.x),
        height: abs(p.y - down.y))
      marquee = rect
      let ids = Set(
        snapshot.elements.filter { s.selection.contains($0.id) }.flatMap { e -> [UUID] in
          guard let path = e.path, !snapshot.isLocked(e) else { return [] }
          let t = snapshot.worldTransform(e).followed(
            by: .scale(e.width / path.width, e.height / path.height))
          return path.contours.flatMap(\.nodes).filter {
            rect.contains(CGPoint(t.apply($0.anchor)))
          }.map(\.id)
        })
      s.nodes = event.modifierFlags.contains(.shift) ? startNodes.union(ids) : ids
      needsDisplay = true
      return
    }
    if dragMode == "marquee" {
      let rect = CGRect(
        x: min(down.x, p.x), y: min(down.y, p.y), width: abs(p.x - down.x),
        height: abs(p.y - down.y))
      marquee = rect
      let ids = Set(
        value.elements.filter {
          $0.parentID == s.scopeID && value.editable($0)
            && rect.intersects(CGRect(value.bounds(of: $0)))
        }.map(\.id))
      s.selection = event.modifierFlags.contains(.shift) ? startSelection.union(ids) : ids
      needsDisplay = true
      return
    }
    if dragMode == "guide", let id = guideID,
      let i = value.guides?.firstIndex(where: { $0.id == id })
    {
      let axis = value.guides?[i].axis
      value.guides?[i].position = axis == "x" ? p.x : p.y
      s.save(value)
      return
    }
    if dragMode == "node" || dragMode == "incoming" || dragMode == "outgoing" {
      dragNodes(p, event: event)
      return
    }
    if dragMode == "gradient_axis", let e = s.primary,
      let i = value.elements.firstIndex(where:{$0.id == e.id}),
      let inverse = snapshot.worldTransform(e).followed(by:e.gradient?.transform ?? .init()).inverse,
      var gradient = value.elements[i].gradient {
      let a = inverse.apply(.init(down)), b = inverse.apply(.init(p))
      let dx = (b.x-a.x)/e.paintSize.x, dy = (b.y-a.y)/e.paintSize.y
      gradient.start.x += dx; gradient.start.y += dy
      gradient.end.x += dx; gradient.end.y += dy
      value.elements[i].gradient = gradient; s.save(value); return
    }
    if dragMode == "gradient_stop", let e = s.primary, let id = s.selectedGradientStopID,
      let axis = gradientHandles(e,in:snapshot), let offset = gradientPosition(p,a:axis.a,b:axis.b),
      let i = value.elements.firstIndex(where:{$0.id == e.id}),
      let stop = value.elements[i].gradient?.stops.firstIndex(where:{$0.id == id}) {
      value.elements[i].gradient?.stops[stop].offset = min(1,max(0,offset))
      value.elements[i].gradient?.sortStops()
      s.save(value)
      return
    }
    if dragMode == "gradient", let e = s.primary,
      let i = value.elements.firstIndex(where: { $0.id == e.id }),
      let inv = value.worldTransform(e).followed(by: e.gradient?.transform ?? .init()).inverse
    {
      let q = inv.apply(.init(p))
      if handle == 0 {
        value.elements[i].gradient?.start = .init(q.x / e.paintSize.x, q.y / e.paintSize.y)
      } else {
        value.elements[i].gradient?.end = .init(q.x / e.paintSize.x, q.y / e.paintSize.y)
      }
      s.save(value)
      return
    }
    if dragMode == "create", let id = s.selection.first,
      let i = value.elements.firstIndex(where: { $0.id == id })
    {
      var w = abs(p.x - down.x)
      var h = abs(p.y - down.y)
      if event.modifierFlags.contains(.shift) {
        let size = max(w, h)
        w = size
        h = size
      }
      value.elements[i].x = p.x < down.x ? down.x - w : down.x
      value.elements[i].y = p.y < down.y ? down.y - h : down.y
      value.elements[i].width = max(0.2, w)
      value.elements[i].height = max(0.2, h)
      if value.elements[i].kind == "line" {
        value.elements[i].flipX = p.x < down.x
        value.elements[i].flipY = p.y < down.y
      }
      if value.elements[i].kind == "text" {
        var t = value.elements[i].typography ?? .init()
        t.frameMode = "area"
        value.elements[i].typography = t
      }
      s.save(value)
      return
    }
    var delta = Affine2()
    if dragMode == "move" {
      moveDropPoint = canvasPoint(convert(event.locationInWindow,from:nil))
      let destination = frame(atCanvasPoint:moveDropPoint)
      moveDropFrameID = destination?.id == s.objectID ? nil : destination?.id
      var dx = p.x - down.x
      var dy = p.y - down.y
      if event.modifierFlags.contains(.shift) { if abs(dx) > abs(dy) { dy = 0 } else { dx = 0 } }
      let snapped = snap(dx: dx, dy: dy, event: event)
      delta = .translation(snapped.x, snapped.y)
    } else if dragMode == "rotate" {
      let c = ArtworkTransforms.selectionOrigin(in:snapshot,ids:startSelection) ?? downBounds.center
      var degrees = (atan2(p.y - c.y, p.x - c.x) - atan2(down.y - c.y, down.x - c.x)) * 180 / .pi
      if event.modifierFlags.contains(.shift) { degrees = (degrees / 15).rounded() * 15 }
      delta = .translation(c.x, c.y).followed(by: .rotation(degrees)).followed(
        by: .translation(-c.x, -c.y))
    } else if dragMode == "resize" {
      let b = downBounds
      let anchor = handles(b)[(handle + 4) % 8]
      var sx = 1.0
      var sy = 1.0
      if ![1, 5].contains(handle) {
        sx = max(0.001, (p.x - anchor.x) / ((handles(b)[handle].x - anchor.x)))
      }
      if ![3, 7].contains(handle) {
        sy = max(0.001, (p.y - anchor.y) / ((handles(b)[handle].y - anchor.y)))
      }
      if event.modifierFlags.contains(.shift) {
        let scale = abs(sx - 1) > abs(sy - 1) ? sx : sy
        sx = scale
        sy = scale
      }
      if startSelection.count == 1,
        let e = value.elements.first(where: { startSelection.contains($0.id) }), e.kind == "text",
        e.typography?.frameMode != "point", e.affine == nil, e.parentID == nil,
        (e.rotation ?? 0) == 0, let i = value.elements.firstIndex(where: { $0.id == e.id })
      {
        value.elements[i].width = max(0.1, e.width * sx)
        value.elements[i].height = max(0.1, e.height * sy)
        value.elements[i].x = anchor.x + (e.x - anchor.x) * sx
        value.elements[i].y = anchor.y + (e.y - anchor.y) * sy
        s.save(value)
        return
      }
      delta = .translation(anchor.x, anchor.y).followed(by: .scale(sx, sy)).followed(
        by: .translation(-anchor.x, -anchor.y))
    } else {
      return
    }
    for e in snapshot.selectionRoots(startSelection) {
      if let i = value.elements.firstIndex(where: { $0.id == e.id }) {
        value.elements[i] = s.transformed(e, delta: delta, in: snapshot)
      }
    }
    s.save(value)
  }
  override func mouseUp(with event: NSEvent) {
    if dragMode == "move",let s = session,let source = activeFrame,
      let destination = frame(atCanvasPoint:canvasPoint(convert(event.locationInWindow,from:nil))),
      destination.id != source.id,point(event) != down {
      let offset = Point2(source.rect.minX-destination.rect.minX,source.rect.minY-destination.rect.minY)
      if !s.transferSelection(to:destination.id,offset:offset) { s.save(snapshot) }
      synchronize()
    }
    if ["node", "incoming", "outgoing"].contains(dragMode), point(event) != down, let s = session {
      s.mutate { art in
        for i in art.elements.indices where s.selection.contains(art.elements[i].id) {
          if art.elements[i].path?.contours.flatMap(\.nodes).contains(where: {
            s.nodes.contains($0.id)
          }) == true {
            PathCommands.normalize(&art.elements[i])
          }
        }
      }
    }
    if dragMode == "pan" { NSCursor.pop() }
    if dragMode == "pen" { commitPen(closed: false) }
    if dragMode == "create", let s = session, let e = s.primary {
      if e.kind == "text" {
        beginText(e)
      } else if e.width < 1 && e.height < 1 {
        s.update {
          $0.width = 40
          $0.height = 40
        }
      }
      s.tool = .select
    }
    dragMode = ""
    moveDropFrameID = nil
    marquee = nil
    snapLines = []
    guideID = nil
    if editingID == nil { session?.endGesture() }
    needsDisplay = true
  }
  override func scrollWheel(with event: NSEvent) {
    if let s = session, let id = s.croppingImageID,
      let e = s.art.elements.first(where:{$0.id == id}), !s.art.isLocked(e),
      let inverse = s.art.worldTransform(e).inverse {
      let p = inverse.apply(.init(point(event)))
      let anchor = Point2(max(0,min(1,p.x/e.width)),max(0,min(1,p.y/e.height)))
      let precision = event.hasPreciseScrollingDeltas ? 0.35 : 1.0
      let delta = max(-24,min(24,event.scrollingDeltaY*precision))
      s.cropImage((e.imageCrop ?? .full).zoomed(exp(-delta*0.008),anchor:anchor))
      if event.phase == .ended { s.endGesture() }
      return
    }
    expandCanvas(toInclude:visibleCanvasRect.insetBy(dx:-180,dy:-180))
    super.scrollWheel(with:event)
  }
  private func droppedURLs(_ sender: NSDraggingInfo) -> [URL] {
    (sender.draggingPasteboard.readObjects(forClasses:[NSURL.self],options:[.urlReadingFileURLsOnly:true]) as? [URL]) ?? []
  }
  override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }
  override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
    imageDropUpdates += 1
    let p = convert(sender.draggingLocation,from:nil)
    let physical = canvasPoint(p)
    let old = dropFrameID
    dropFrameID = frame(atCanvasPoint:physical)?.id
    if old != dropFrameID { needsDisplay = true }
    let extensions = Set(["png","jpg","jpeg","tif","tiff","heic","heif","gif","bmp","webp","pdf","svg"])
    let supported = droppedURLs(sender).contains { extensions.contains($0.pathExtension.lowercased()) }
      || sender.draggingPasteboard.data(forType:.png) != nil || sender.draggingPasteboard.data(forType:.tiff) != nil
    return dropFrameID != nil && supported ? .copy : []
  }
  override func draggingExited(_ sender: NSDraggingInfo?) { dropFrameID = nil; needsDisplay = true }
  override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    imageDropAttempts += 1
    guard let s = session, let id = dropFrameID, let frame = frames.first(where:{$0.id == id}) else { return false }
    s.store?.activateDesignSurface(.artwork)
    finishText(); s.activate(id)
    let p = canvasPoint(convert(sender.draggingLocation,from:nil))
    var point = Point2(p.x-frame.rect.minX,p.y-frame.rect.minY)
    if let scope = s.scopeID, let group = s.art.elements.first(where:{$0.id == scope}),
      let inverse = s.art.worldTransform(group).inverse { point = inverse.apply(point) }
    var urls = droppedURLs(sender)
    var temporary: URL?
    if urls.isEmpty {
      let board = sender.draggingPasteboard
      if let bytes = board.data(forType:.png) ?? board.data(forType:.tiff) {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("FORM-drop-\(UUID().uuidString).\(board.data(forType:.png) != nil ? "png" : "tiff")")
        do { try bytes.write(to:file,options:.atomic); urls = [file]; temporary = file } catch { return false }
      }
    }
    defer { if let temporary { try? FileManager.default.removeItem(at:temporary) }; dropFrameID = nil; needsDisplay = true }
    guard !urls.isEmpty else { return false }
    return s.placeImages(urls,point:point)
  }
  override func mouseMoved(with event: NSEvent) {
    hover = point(event)
    if !pen.isEmpty { needsDisplay = true }
  }
  private func snap(dx: Double, dy: Double, event: NSEvent) -> CGPoint {
    guard let s = session, s.art.snapEnabled != false, !event.modifierFlags.contains(.option),
      let f = activeFrame
    else { return .init(x: dx, y: dy) }
    let b = downBounds
    let tolerance = 5 / (ppm * zoom)
    var xs = f.isWorkspace ? [] : [0.0, f.rect.width / 2, f.rect.width]
    var ys = f.isWorkspace ? [] : [0.0, f.rect.height / 2, f.rect.height]
    for g in snapshot.guides ?? [] {
      if g.axis == "x" { xs.append(g.position) } else { ys.append(g.position) }
    }
    for e in snapshot.elements
    where e.parentID == s.scopeID && !startSelection.contains(e.id) && snapshot.editable(e) {
      let q = snapshot.bounds(of: e)
      xs += [q.x, q.center.x, q.maxX]
      ys += [q.y, q.center.y, q.maxY]
    }
    var bestX = tolerance
    var bestY = tolerance
    var newX = dx
    var newY = dy
    var targetX: Double?
    var targetY: Double?
    snapLines = []
    for target in xs {
      for edge in [b.x, b.center.x, b.maxX] {
        let difference = target - edge - dx
        if abs(difference) < abs(bestX) {
          bestX = difference
          newX = dx + difference
          targetX = target
        }
      }
    }
    for target in ys {
      for edge in [b.y, b.center.y, b.maxY] {
        let difference = target - edge - dy
        if abs(difference) < abs(bestY) {
          bestY = difference
          newY = dy + difference
          targetY = target
        }
      }
    }
    if let targetX { snapLines.append(("x", targetX)) }
    if let targetY { snapLines.append(("y", targetY)) }
    if s.art.showGrid == true {
      let grid = s.art.gridSpacing ?? 10
      if abs(bestX) >= tolerance { newX = ((b.x + dx) / grid).rounded() * grid - b.x }
      if abs(bestY) >= tolerance { newY = ((b.y + dy) / grid).rounded() * grid - b.y }
    }
    return .init(x: newX, y: newY)
  }
  private func nodeHit(_ p: CGPoint, event: NSEvent) -> Bool {
    guard let s = session else { return false }
    let art = s.art
    let threshold = 7 / (ppm * zoom)
    let paths = art.elements.filter {
      $0.path != nil && (s.maskEditing == nil ? art.editable($0) : $0.id == s.maskEditing?.maskID && !art.isLocked($0))
        && (s.selection.contains($0.id) || $0.parentID == s.scopeID)
    }
    for e in paths.reversed() {
      let path = e.path!
      let t = art.worldTransform(e).followed(
        by: .scale(e.width / path.width, e.height / path.height))
      for node in path.contours.flatMap(\.nodes).reversed() {
        for (mode, q) in [("incoming", node.incoming), ("outgoing", node.outgoing)]
        where s.selection.contains(e.id) && s.nodes.contains(node.id) {
          if let q {
            let v = t.apply(q)
            if hypot(p.x - v.x, p.y - v.y) < threshold {
              dragMode = mode
              s.nodes = [node.id]
              return true
            }
          }
        }
        let q = t.apply(node.anchor)
        if hypot(p.x - q.x, p.y - q.y) < threshold {
          if !s.selection.contains(e.id) {
            if event.modifierFlags.contains(.shift) {
              s.selection.insert(e.id)
            } else {
              s.choose([e.id])
            }
          }
          if event.modifierFlags.contains(.shift) {
            if s.nodes.contains(node.id) {
              s.nodes.remove(node.id)
            } else {
              s.nodes.insert(node.id)
            }
          } else if !s.nodes.contains(node.id) {
            s.nodes = [node.id]
          }
          dragMode = "node"
          return true
        }
      }
    }
    return false
  }
  private func dragNodes(_ p: CGPoint, event: NSEvent) {
    guard let s = session else { return }
    var value = snapshot
    let paths = snapshot.elements.filter { s.selection.contains($0.id) && $0.path != nil }
    let counts = paths.flatMap { $0.path!.contours.flatMap(\.nodes).map(\.id) }
      .reduce(into: [UUID: Int]()) { $0[$1, default: 0] += 1 }
    guard s.nodes.allSatisfy({ counts[$0] == 1 }) else {
      s.store?.error =
        "These paths contain repeated node IDs. Combine them before selecting nodes together."
      dragMode = ""
      return
    }
    for e in paths where !snapshot.isLocked(e) {
      guard let i = value.elements.firstIndex(where: { $0.id == e.id }), let path = e.path,
        let inv = snapshot.worldTransform(e).followed(
          by: .scale(e.width / path.width, e.height / path.height)
        ).inverse
      else { continue }
      let a = inv.apply(.init(down))
      let b = inv.apply(.init(p))
      let delta = Affine2.translation(b.x - a.x, b.y - a.y)
      for c in path.contours.indices {
        for n in path.contours[c].nodes.indices where s.nodes.contains(path.contours[c].nodes[n].id)
        {
          let node = path.contours[c].nodes[n]
          if dragMode == "node" {
            value.elements[i].path?.contours[c].nodes[n] = PathCommands.transformed(node, by: delta)
          } else {
            let q = dragMode == "incoming" ? node.incoming : node.outgoing
            value.elements[i].path?.contours[c].nodes[n] = PathCommands.movingHandle(
              node, incoming: dragMode == "incoming", to: delta.apply(q ?? node.anchor),
              independent: event.modifierFlags.contains(.option))
          }
        }
      }
    }
    s.save(value)
  }
  private func penDown(_ p: CGPoint, event: NSEvent) {
    if pen.count >= 3, let first = pen.first,
      hypot(first.anchor.x - p.x, first.anchor.y - p.y) < 7 / (ppm * zoom)
    {
      commitPen(closed: true)
      pen = []
      penID = nil
      dragMode = ""
      needsDisplay = true
      return
    }
    if penID == nil { penID = UUID() }
    pen.append(.init(.init(p)))
    dragMode = "pen"
    if event.clickCount == 2 {
      commitPen(closed: false)
      pen = []
      penID = nil
      dragMode = ""
    }
    needsDisplay = true
  }
  private func commitPen(closed: Bool) {
    guard let s = session, pen.count >= 2 else { return }
    let path = CGMutablePath()
    path.move(to: CGPoint(pen[0].anchor))
    for i in 1..<pen.count {
      let a = pen[i - 1]
      let b = pen[i]
      if a.outgoing != nil || b.incoming != nil {
        path.addCurve(
          to: CGPoint(b.anchor), control1: CGPoint(a.outgoing ?? a.anchor),
          control2: CGPoint(b.incoming ?? b.anchor))
      } else {
        path.addLine(to: CGPoint(b.anchor))
      }
    }
    if closed {
      let a = pen[pen.count - 1]
      let b = pen[0]
      if a.outgoing != nil || b.incoming != nil {
        path.addCurve(
          to: CGPoint(b.anchor), control1: CGPoint(a.outgoing ?? a.anchor),
          control2: CGPoint(b.incoming ?? b.anchor))
      }
      path.closeSubpath()
    }
    do {
      var element = try VectorGeometry.element(
        from: path, color: "#292D2C", name: "Bézier path", parentID: s.scopeID)
      element.id = penID!
      if let parent = s.art.elements.first(where: { $0.id == s.scopeID }) {
        element.affine = s.art.worldTransform(parent).inverse
      }
      element.fillEnabled = closed
      element.stroke = .init(color: "#292D2C", width: 0.5)
      if let i = s.art.elements.firstIndex(where: { $0.id == element.id }) {
        s.mutate { $0.elements[i] = element }
      } else {
        s.add([element])
      }
      s.choose([element.id])
    } catch { s.store?.error = error.localizedDescription }
  }
  func finishPath() {
    if pen.count >= 2 { commitPen(closed: false) }
    pen = []
    penID = nil
    needsDisplay = true
  }
  func beginText(_ e: ArtworkElement) {
    guard let s = session, activeFrame != nil else { return }
    s.store?.activateDesignSurface(.artwork)
    originalTextElement = e
    let e = s.colored(e)
    s.dieline = false
    s.beginGesture()
    let tv = CanvasTextView(
      frame: .init(
        x: 0, y: 0, width: e.width * ppm, height: e.height * ppm))
    tv.isRichText = true
    tv.usesRuler = false
    tv.usesInspectorBar = false
    tv.importsGraphics = false
    tv.allowsUndo = true
    tv.drawsBackground = false
    tv.clipsToBounds = true
    tv.textContainerInset = .zero
    tv.textContainer?.lineFragmentPadding = 0
    tv.isVerticallyResizable = e.typography?.frameMode == "point"
    tv.isHorizontallyResizable = false
    tv.textContainer?.widthTracksTextView = true
    tv.autoresizingMask = []
    tv.insertionPointColor = NSColor(hex: e.color)
    tv.textStorage?.setAttributedString(TypographyEngine.attributed(e, millimeters: false, preservingSource: true))
    if let storage = tv.textStorage {
      TypographyEngine.refreshNativeMetadata(TypographyEngine.spans(from: TextCase.source(storage).text, fallback: e.typography ?? .init()), in: storage)
    }
    publishedInput = NSAttributedString(attributedString: tv.attributedString())
    originalTextInput = publishedInput
    tv.delegate = self
    tv.setAccessibilityLabel("Edit text on artwork canvas")
    textView = tv
    editingID = e.id
    publishedText = e
    s.editingText = true
    s.characterRange = .init(location: 0, length: e.text.utf16.count)
    let clip = NativeAffineView(frame: bounds)
    clip.clipsToBounds = true
    let host = NativeAffineView(frame: bounds)
    host.clipsToBounds = false
    textClip = clip
    textHost = host
    addSubview(clip)
    clip.addSubview(host)
    host.addSubview(tv)
    positionTextHost(e)
    window?.makeFirstResponder(tv)
    tv.setSelectedRange(NSRange(location:0,length:tv.string.utf16.count))
    needsDisplay = true
  }
  func finishText() {
    guard let tv = textView else { return }
    if tv.hasMarkedText() {tv.unmarkText();tv.didChangeText()}
    textDidChange(Notification(name: NSText.didChangeNotification, object: tv))
    tv.removeFromSuperview()
    textHost?.removeFromSuperview()
    textHost = nil
    textClip?.removeFromSuperview()
    textClip = nil
    tv.delegate = nil
    textView = nil
    editingID = nil
    publishedText = nil
    publishedInput = nil
    originalTextInput = nil
    originalTextElement = nil
    session?.editingText = false
    session?.endGesture()
    needsDisplay = true
  }
  private func positionTextHost(_ element: ArtworkElement) {
    guard let s = session, let f = activeFrame, let host = textHost, let clip = textClip else {
      return
    }
    let world = s.art.worldTransform(element)
    if let tv = textView as? CanvasTextView {
      tv.verticalOffset = TypographyEngine.verticalOffset(element, points: true)
      tv.horizontalOffset = TypographyEngine.horizontalOffset(element, points: true)
      if element.typography?.frameMode=="point" {
        tv.setFrameSize(.init(width:max(40,element.width*ppm),height:max(24,element.height*ppm)))
      }
      if let width=TypographyEngine.pointGlyphContainerWidth(element) {
        tv.textContainer?.widthTracksTextView=false
        tv.textContainer?.containerSize.width=width
      } else {tv.textContainer?.widthTracksTextView=true}
      tv.needsDisplay = true
    }
    clip.configure(frame:f.isWorkspace ? bounds : documentRect(f.rect),transform:.init())
    let workspaceOffset = f.isWorkspace ? documentPoint(f.rect.origin) : .zero
    host.configure(
      frame: clip.bounds,
      transform: .init(
        a: world.a, b: world.b, c: world.c, d: world.d,
        tx:world.tx*ppm+workspaceOffset.x,ty:world.ty*ppm+workspaceOffset.y))
  }
  func textDidChange(_ notification: Notification) {
    guard let s = session, let id = editingID, let tv = textView,
      let i = s.art.elements.firstIndex(where: { $0.id == id })
    else { return }
    if tv.hasMarkedText() {return}
    if let publishedInput, GlyphEngine.nativeEqual(tv.attributedString(),publishedInput) { return }
    publishedInput = NSAttributedString(attributedString: tv.attributedString())
    var value = s.art
    if let originalTextInput, let originalTextElement,
      GlyphEngine.nativeEqual(tv.attributedString(),originalTextInput) {
      value.elements[i] = originalTextElement
      publishedText = s.colored(originalTextElement)
      s.save(value)
      positionTextHost(originalTextElement)
      return
    }
    var e = value.elements[i]
    let source=TextCase.source(tv.attributedString()).text
    e.text = source.string
    let choices = GlyphEngine.overrides(from: source)
    e.glyphOverrides = choices.isEmpty ? nil : choices
    let runs = TypographyEngine.spans(
      from: source, fallback: e.typography ?? .init())
    if runs.count == 1, let run = runs.first, run.fontSize == e.fontSize, run.color == e.color,
      run.typography == (e.typography ?? .init()), run.swatchID == e.fillSwatchID,
      run.textStyle == e.textStyle, run.paragraphStyle == e.paragraphStyle
    {
      e.textRuns = nil
    } else {
      e.textRuns = runs
    }
    if e.typography?.frameMode == "point" {
      let size = TypographyEngine.measured(e)
      e.width = max(1, size.width + 0.5)
      e.height = max(e.fontSize / ppm * 1.4, size.height + 0.5)
      tv.setFrameSize(.init(width: max(40, e.width * ppm), height: max(24, e.height * ppm)))
    }
    value.elements[i] = e
    value = value.recordingTextStyleOverrides(from: s.art)
    e = value.elements[i]
    if let storage = tv.textStorage {
      TypographyEngine.refreshNativeMetadata(e.textRuns ?? [TextStyleCommands.span(e)], in: storage)
      publishedInput = NSAttributedString(attributedString: tv.attributedString())
    }
    publishedText = s.colored(e)
    s.save(value)
    positionTextHost(e)
  }
  func textViewDidChangeSelection(_ notification: Notification) {
    guard let tv = textView else { return }
    session?.characterRange = TextCase.source(tv.attributedString()).sourceRange(tv.selectedRange())
    session?.objectWillChange.send()
  }
  func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
    if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
      finishText()
      window?.makeFirstResponder(self)
      return true
    }
    return false
  }
  private func changeText(_ attributes: [NSAttributedString.Key: Any], removing: [NSAttributedString.Key] = []) -> Bool {
    guard let tv = textView else { return false }
    let range = GlyphEngine.expandedDisplayRange(tv.selectedRange(),in:tv.attributedString())
    tv.undoManager?.beginUndoGrouping()
    defer {tv.undoManager?.endUndoGrouping()}
    if range.length == 0 {
      tv.typingAttributes.merge(attributes) { _, new in new }
      for key in removing { tv.typingAttributes.removeValue(forKey: key) }
      session?.objectWillChange.send()
    } else if tv.shouldChangeText(in: range, replacementString: nil) {
      tv.textStorage?.beginEditing()
      for key in removing { tv.textStorage?.removeAttribute(key, range: range) }
      tv.textStorage?.addAttributes(attributes, range: range)
      tv.textStorage?.endEditing()
      tv.didChangeText()
    }
    return true
  }
  func applyGlyph(_ glyph: FontGlyph?, sourceRange: NSRange) throws -> Bool {
    guard let tv = textView as? CanvasTextView else { return false }
    try tv.applyGlyph(glyph, sourceRange: sourceRange)
    tv.window?.makeFirstResponder(tv)
    return true
  }
  func textInspection() -> TextSpan? {
    guard let tv = textView else { return nil }
    let range = tv.selectedRange()
    let attrs =
      range.length > 0 && range.location < (tv.textStorage?.length ?? 0)
      ? tv.textStorage?.attributes(at: range.location, effectiveRange: nil) ?? tv.typingAttributes
      : tv.typingAttributes
    return TypographyEngine.spans(
      from: NSAttributedString(string: "A", attributes: attrs),
      fallback: session?.primary?.typography ?? .init(), utf16Offset: TextCase.source(tv.attributedString()).sourceRange(range).location
    ).first
  }
  func textCaseTreatments()->Set<String>? {
    guard let tv=textView else{return nil}
    let range=tv.selectedRange()
    if range.length==0 {return [textInspection()?.typography.caseTreatment ?? "original"]}
    return TypographyEngine.caseTreatments(in:tv.attributedString(),range:range)
  }
  func textSwatchReferences() -> Set<UUID?>? {
    guard let tv = textView else { return nil }
    let range = tv.selectedRange()
    if range.length == 0 {
      return [(tv.typingAttributes[TypographyEngine.swatchKey] as? String).flatMap(UUID.init(uuidString:))]
    }
    var result = Set<UUID?>()
    tv.attributedString().enumerateAttribute(TypographyEngine.swatchKey, in: range) { value, _, _ in
      result.insert((value as? String).flatMap(UUID.init(uuidString:)))
    }
    return result
  }
  func textStyleReferences() -> Set<TextStyleReference?>? {
    guard let tv = textView else { return nil }
    func decode(_ raw: Any?) -> TextStyleReference? {
      (raw as? Data).flatMap { try? JSONDecoder.form.decode(TextStyleReference.self, from: $0) }
    }
    let range = tv.selectedRange()
    if range.length == 0 { return [decode(tv.typingAttributes[TypographyEngine.textStyleKey])] }
    var result = Set<TextStyleReference?>()
    tv.attributedString().enumerateAttribute(TypographyEngine.textStyleKey, in: range) { value, _, _ in result.insert(decode(value)) }
    return result
  }
  func applyTextReference(_ command: String, styleID: UUID?) -> Bool {
    guard let tv = textView, let project = session?.store?.project else { return false }
    tv.undoManager?.beginUndoGrouping()
    defer {tv.undoManager?.endUndoGrouping()}
    let styles = Dictionary(uniqueKeysWithValues: (project.textStyles ?? []).map { ($0.id, $0) })
    if command == "assign", styleID.flatMap({ styles[$0] }) == nil {
      session?.store?.error = "Text style not found."
      return true
    }
    let fallback = session?.primary?.typography ?? .init()
    let mapping=TextCase.source(tv.attributedString())
    let selected = tv.selectedRange()
    let partial = selected.location != 0 || selected.length != tv.string.utf16.count
    func attributes(_ raw: [NSAttributedString.Key: Any], at location: Int) -> [NSAttributedString.Key: Any] {
      let old = TypographyEngine.spans(from: NSAttributedString(string: "A", attributes: raw), fallback: fallback, utf16Offset: mapping.sourceRange(NSRange(location:location,length:0)).location)[0]
      let style = (command == "assign" ? styleID : old.textStyle?.styleID).flatMap { styles[$0] }
      let changed = command == "reset"
        ? TextStyleCommands.resetting(old, styles: styles, preservingParagraphs: partial)
        : TextStyleCommands.applying(old, style: style, detach: command == "detach", preservingParagraphs: partial)
      var result=TypographyEngine.attributes(changed.typography, size: changed.fontSize, color: changed.color,
        millimeters: false, swatchID: changed.swatchID, textStyle: changed.textStyle, paragraphStyle: changed.paragraphStyle)
      result[TextCase.sourceKey]=raw[TextCase.sourceKey]
      result[GlyphEngine.overrideKey]=raw[GlyphEngine.overrideKey]
      return result
    }
    let range = GlyphEngine.expandedDisplayRange(tv.selectedRange(),in:tv.attributedString())
    if range.length == 0 {
      tv.typingAttributes = attributes(tv.typingAttributes, at: range.location)
      session?.objectWillChange.send()
      return true
    }
    let undoRange = command == "reset" ? (tv.string as NSString).paragraphRange(for: range) : range
    guard tv.shouldChangeText(in: undoRange, replacementString: nil) else { return true }
    var replacements: [(NSRange, [NSAttributedString.Key: Any])] = []
    tv.attributedString().enumerateAttributes(in: range) { raw, part, _ in replacements.append((part, attributes(raw, at: part.location))) }
    tv.textStorage?.beginEditing()
    for (part, raw) in replacements { tv.textStorage?.setAttributes(raw, range: part) }
    if command == "reset" {
      // AppKit normalizes paragraph attributes across the whole paragraph.
      // Apply the reset there too, while retaining the character selection.
      for (part, raw) in replacements {
        if let paragraph = raw[.paragraphStyle] {
          tv.textStorage?.addAttribute(.paragraphStyle, value: paragraph,
            range: (tv.string as NSString).paragraphRange(for: part))
        }
      }
    }
    if let storage = tv.textStorage { TypographyEngine.updateSpacing(storage, range: range) }
    tv.textStorage?.endEditing()
    tv.didChangeText()
    return true
  }
  func applyTextStyle(_ body: (inout Typography) -> Void) -> Bool {
    guard let tv = textView else { return false }
    tv.undoManager?.beginUndoGrouping()
    defer {tv.undoManager?.endUndoGrouping()}
    var range = GlyphEngine.expandedDisplayRange(tv.selectedRange(),in:tv.attributedString())
    let fallback = session?.primary?.typography ?? .init()
    let mapping=TextCase.source(tv.attributedString())
    if let old = textInspection()?.typography {
      var changed = old; body(&changed)
      if TextStyleCommands.changesParagraphs(old, changed) { range = (tv.string as NSString).paragraphRange(for: range) }
    }
    if range.length == 0, let run = textInspection() {
      var t = run.typography
      body(&t)
      var changed = run; changed.typography = t
      changed = TextStyleCommands.recording(changed, from: run)
      tv.typingAttributes = TypographyEngine.attributes(
        t, size: run.fontSize, color: run.color, millimeters: false, swatchID: run.swatchID,
        textStyle: changed.textStyle, paragraphStyle: changed.paragraphStyle)
      session?.objectWillChange.send()
      return true
    }
    guard tv.shouldChangeText(in: range, replacementString: nil) else { return true }
    var replacements: [(NSRange, [NSAttributedString.Key: Any])] = []
    tv.attributedString().enumerateAttributes(in: range) { attributes, part, _ in
      if let run = TypographyEngine.spans(
        from: NSAttributedString(string: "A", attributes: attributes), fallback: fallback, utf16Offset: mapping.sourceRange(NSRange(location:part.location,length:0)).location
      ).first {
        var t = run.typography
        body(&t)
        var changed = run; changed.typography = t
        changed = TextStyleCommands.recording(changed, from: run)
        var attrs=TypographyEngine.attributes(t, size: run.fontSize, color: run.color, millimeters: false,
          swatchID: run.swatchID, textStyle: changed.textStyle, paragraphStyle: changed.paragraphStyle)
        attrs[TextCase.sourceKey]=attributes[TextCase.sourceKey]
        attrs[GlyphEngine.overrideKey]=attributes[GlyphEngine.overrideKey]
        replacements.append((part,attrs))
      }
    }
    tv.textStorage?.beginEditing()
    for (range, attrs) in replacements { tv.textStorage?.setAttributes(attrs, range: range) }
    if let storage = tv.textStorage { TypographyEngine.updateSpacing(storage, range: range) }
    tv.textStorage?.endEditing()
    tv.didChangeText()
    return true
  }
  func applyManualKerning(_ value: Double) -> Bool {
    guard let tv = textView else { return false }
    let range = tv.selectedRange()
    let initial=max(0,range.location-1)
    let index=max(0,NSMaxRange(TextCase.expandedDisplayRange(NSRange(location:initial,length:range.location>0 ? 1:0),in:tv.attributedString()))-1)
    guard index < (tv.textStorage?.length ?? 0) else { return true }
    let target = NSRange(location: index, length: 1)
    if tv.shouldChangeText(in: target, replacementString: nil) {
      if let storage = tv.textStorage { TypographyEngine.setManualPair(value, at: index, in: storage) }
      tv.didChangeText()
    }
    return true
  }
  func manualKerningInspection() -> Double? {
    guard let tv = textView else { return nil }
    let location=tv.selectedRange().location
    let index=max(0,NSMaxRange(TextCase.expandedDisplayRange(NSRange(location:max(0,location-1),length:location>0 ? 1:0),in:tv.attributedString()))-1)
    guard index < (tv.textStorage?.length ?? 0) else { return 0 }
    return (tv.textStorage?.attribute(TypographyEngine.pairKey, at: index, effectiveRange: nil) as? NSNumber)?.doubleValue ?? 0
  }
  func applyTextSize(_ size: Double) -> Bool {
    guard let tv = textView else { return false }
    let range = tv.selectedRange()
    let font =
      (range.location < (tv.textStorage?.length ?? 0)
      ? tv.textStorage?.attribute(.font, at: range.location, effectiveRange: nil)
      : tv.typingAttributes[.font]) as? NSFont ?? .systemFont(ofSize: size)
    return changeText([.font: NSFont(descriptor: font.fontDescriptor, size: size) ?? font])
  }
  func applyTextColor(_ color: String) -> Bool {
    changeText([.foregroundColor: FormColor.color(color)], removing: [TypographyEngine.swatchKey])
  }
  func applyTextSwatch(_ id: UUID?, color: String?) -> Bool {
    if let id, let color {
      return changeText([.foregroundColor: FormColor.color(color), TypographyEngine.swatchKey: id.uuidString])
    }
    return changeText([:], removing: [TypographyEngine.swatchKey])
  }
  func undoText() -> Bool {
    guard let tv = textView else { return false }
    if tv.undoManager?.canUndo == true { tv.undoManager?.undo() }
    return true
  }
  func redoText() -> Bool {
    guard let tv = textView else { return false }
    if tv.undoManager?.canRedo == true { tv.undoManager?.redo() }
    return true
  }
  var canUndoText: Bool { textView?.undoManager?.canUndo == true }
  var canRedoText: Bool { textView?.undoManager?.canRedo == true }
  @objc func copy(_ sender: Any?) { session?.copy() }
  @objc func paste(_ sender: Any?) { session?.paste() }
  @objc func cut(_ sender: Any?) {
    session?.copy()
    session?.execute("delete")
  }
  override func selectAll(_ sender: Any?) {
    guard let s = session else { return }
    s.choose(
      Set(s.art.elements.filter { $0.parentID == s.scopeID && s.art.editable($0) }.map(\.id)))
  }
  override func keyDown(with event: NSEvent) {
    guard let s = session else { return }
    let command = event.modifierFlags.contains(.command)
    if s.croppingImageID != nil, [36,53].contains(event.keyCode) {
      s.croppingImageID = nil; s.endGesture(); needsDisplay = true; return
    }
    if event.keyCode == 49 {
      if !space {
        space = true
        NSCursor.openHand.push()
      }
      return
    }
    if [123, 124, 125, 126].contains(event.keyCode) {
      s.beginGesture()
      let step = (s.art.nudge ?? 0.1) * (event.modifierFlags.contains(.shift) ? 10 : 1)
      let dx = event.keyCode == 123 ? -step : event.keyCode == 124 ? step : 0
      let dy = event.keyCode == 126 ? -step : event.keyCode == 125 ? step : 0
      if s.tool == .direct, !s.nodes.isEmpty {
        s.transformNodes(.translation(dx, dy))
      } else {
        s.translate(dx: dx, dy: dy)
      }
      return
    }
    if event.keyCode == 51 || event.keyCode == 117 {
      if let stop = s.selectedGradientStopID {
        s.paint("delete_stop",["stop_id":stop.uuidString])
      } else if s.tool == .direct, !s.nodes.isEmpty {
        s.editPath("delete")
      } else {
        s.execute("delete")
      }
      return
    }
    if event.keyCode == 53 {
      if !pen.isEmpty {
        pen = []
        penID = nil
      } else if s.selectedGradientStopID != nil {
        s.selectedGradientStopID = nil
      } else if s.maskEditing != nil {
        s.returnFromMask()
      } else if s.scopeID != nil {
        s.scopeID = s.art.elements.first { $0.id == s.scopeID }?.parentID
        s.choose([])
      } else {
        s.choose([])
      }
      needsDisplay = true
      return
    }
    if event.keyCode == 36, !pen.isEmpty {
      commitPen(closed: false)
      pen = []
      penID = nil
      needsDisplay = true
      return
    }
    let key = event.charactersIgnoringModifiers?.lowercased()
    if !command, let tool = ArtworkTool.allCases.first(where: { $0.shortcut.lowercased() == key }) {
      s.tool = tool
      return
    }
    if command, key == "=" || key == "+" {
      setZoom(zoom * 1.2)
      return
    }
    if command, key == "-" {
      setZoom(zoom / 1.2)
      return
    }
    super.keyDown(with: event)
  }
  override func keyUp(with event: NSEvent) {
    if editingID == nil,[123, 124, 125, 126].contains(event.keyCode) { session?.endGesture() }
    if event.keyCode == 49, space {
      space = false
      NSCursor.pop()
    } else {
      super.keyUp(with: event)
    }
  }
  override func resignFirstResponder() -> Bool {
    if session?.editingText != true { session?.endGesture() }
    if space {
      space = false
      NSCursor.pop()
    }
    return super.resignFirstResponder()
  }
  override func menu(for event: NSEvent) -> NSMenu? {
    let menu = NSMenu()
    for (title, action) in [
      ("Duplicate", #selector(duplicateAction)), ("Group", #selector(groupAction)),
      ("Ungroup", #selector(ungroupAction)), ("Convert text to outlines", #selector(outlineAction)),
      ("Delete", #selector(deleteAction)),
    ] {
      let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
      item.target = self
      menu.addItem(item)
    }
    return menu
  }
  @objc private func duplicateAction() { session?.execute("duplicate") }
  @objc private func groupAction() { session?.execute("group") }
  @objc private func ungroupAction() { session?.execute("ungroup") }
  @objc private func outlineAction() { session?.convert() }
  @objc private func deleteAction() { session?.execute("delete") }
  private func updateAccessibilityItems() {
    guard let s = session, let frame = activeFrame, let window else { return }
    let artwork = s.art
    let selection = s.selection
    let existing = Dictionary(
      uniqueKeysWithValues: accessibilityItems.compactMap { item in
        item.elementID.map { ($0, item) }
      })
    var next: [ArtworkAccessibilityElement] = []
    for element in artwork.elements where element.hidden != true {
      let bounds = artwork.bounds(of: element)
      let rect = documentRect(CGRect(x:frame.rect.minX+bounds.x,y:frame.rect.minY+bounds.y,
        width:bounds.width,height:bounds.height))
      let child = existing[element.id] ?? ArtworkAccessibilityElement()
      if child.elementID == nil {
        child.setAccessibilityElement(true)
        child.setAccessibilityEnabled(true)
        child.canvas = self
        child.elementID = element.id
        child.setAccessibilityRole(.button)
        child.setAccessibilityParent(self)
        child.setAccessibilityIdentifier(element.id.uuidString)
      }
      let label = "\(element.title), \(element.kind)"
      let screen = window.convertToScreen(convert(rect, to: nil))
      let value = selection.contains(element.id) ? "Selected" : ""
      var changed = false
      if child.cachedLabel != label {
        child.setAccessibilityLabel(label)
        child.cachedLabel = label
        changed = true
      }
      if child.cachedFrame != screen {
        child.setAccessibilityFrame(screen)
        child.cachedFrame = screen
        changed = true
      }
      if child.cachedValue != value {
        child.setAccessibilityValue(value)
        child.cachedValue = value
        changed = true
      }
      if changed { accessibilityUpdates += 1 }
      next.append(child)
    }
    accessibilityItems = next
  }
  override func accessibilityChildren() -> [Any]? {
    var result: [Any] = accessibilityItems
    if let textView { result.append(textView) }
    return result
  }
}

private final class ArtworkAccessibilityElement: NSAccessibilityElement {
  weak var canvas: VectorCanvasView?
  var elementID: UUID?
  var cachedLabel: String?
  var cachedFrame: CGRect?
  var cachedValue: String?
  override func accessibilityPerformPress() -> Bool {
    guard let id = elementID else { return false }
    Task { @MainActor [weak self] in
      guard let canvas = self?.canvas, let s = canvas.session else { return }
      s.choose([id])
      canvas.needsDisplay = true
    }
    return true
  }
}

extension CGPoint { fileprivate init(_ p: Point2) { self.init(x: p.x, y: p.y) } }
extension Point2 { fileprivate init(_ p: CGPoint) { self.init(p.x, p.y) } }
extension CGRect {
  fileprivate init(_ r: Rect2) { self.init(x: r.x, y: r.y, width: r.width, height: r.height) }
  fileprivate var center: CGPoint { .init(x: midX, y: midY) }
}
