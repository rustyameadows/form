import AppKit
import FormCore
import FormGraphics
import SwiftUI

struct VectorCanvas: NSViewRepresentable {
  @ObservedObject var session: ArtworkSession
  var revision: Int
  var fittingInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
  func makeCoordinator() -> Coordinator { Coordinator() }
  func makeNSView(context: Context) -> NSScrollView {
    let scroll = ArtworkScrollView()
    let view = VectorCanvasView()
    // The document fills the workspace under the floating controls. Keep its
    // drawing clipped during live resize without reserving native chrome bands.
    scroll.clipsToBounds = true
    scroll.contentView.clipsToBounds = true
    view.clipsToBounds = true
    view.setAccessibilityElement(true)
    view.setAccessibilityRole(.group)
    view.setAccessibilityLabel("Artwork canvas")
    scroll.hasHorizontalScroller = true
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    scroll.scrollerStyle = .overlay
    scroll.horizontalScrollElasticity = .none
    scroll.verticalScrollElasticity = .none
    scroll.usesPredominantAxisScrolling = false
    scroll.borderType = .noBorder
    scroll.automaticallyAdjustsContentInsets = false
    scroll.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
    scroll.drawsBackground = true
    scroll.backgroundColor = Palette.canvasBackgroundNS
    scroll.allowsMagnification = true
    scroll.minMagnification = 0.08
    scroll.maxMagnification = 24
    scroll.documentView = view
    view.registerForDraggedTypes([.fileURL, .png, .tiff])
    view.session = session
    view.fittingInsets = fittingInsets
    if session.canvas == nil || session.canvas?.window == nil { session.canvas = view }
    scroll.hasHorizontalRuler = false
    scroll.hasVerticalRuler = false
    scroll.rulersVisible = false
    context.coordinator.observation = scroll.observe(\.magnification, options: [.new]) {
      [weak session, weak view, weak scroll] _, change in
      DispatchQueue.main.async {
        if let value = change.newValue {
          view?.ensureViewportCoverage()
          session?.zoom = view?.zoom ?? Double(value)
          view?.needsDisplay = true
          scroll?.horizontalRulerView?.needsDisplay = true
          scroll?.verticalRulerView?.needsDisplay = true
        }
      }
    }
    return scroll
  }
  func updateNSView(_ scroll: NSScrollView, context: Context) {
    guard let view = scroll.documentView as? VectorCanvasView else { return }
    view.session = session
    view.fittingInsets = fittingInsets
    if view.window != nil, !view.isHiddenOrHasHiddenAncestor { session.canvas = view }
    view.synchronize()
    scroll.horizontalRulerView?.needsDisplay = true
    scroll.verticalRulerView?.needsDisplay = true
  }
  final class Coordinator { var observation: NSKeyValueObservation? }
}

final class ArtworkScrollView: NSScrollView {
  override func setFrameSize(_ newSize: NSSize) {
    let canvas = documentView as? VectorCanvasView
    let anchor = canvas?.viewportLayoutAnchor
    super.setFrameSize(newSize)
    canvas?.ensureViewportCoverage(preserving: anchor)
  }
  override func layout() {
    let canvas = documentView as? VectorCanvasView
    let anchor = canvas?.viewportLayoutAnchor
    super.layout()
    canvas?.ensureViewportCoverage(preserving: anchor)
    canvas?.fitWhenReady()
  }
}

final class ArtworkRuler: NSRulerView {
  private var guideID: UUID?
  override init(scrollView: NSScrollView?, orientation: NSRulerView.Orientation) {
    super.init(scrollView: scrollView, orientation: orientation)
    ruleThickness = 23
    clipsToBounds = true
  }
  required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  override var isFlipped: Bool { true }
  override func drawHashMarksAndLabels(in rect: NSRect) {
    NSColor(hex: "#FFFFFF").setFill()
    bounds.fill()
    guard let canvas = scrollView?.documentView as? VectorCanvasView, let session = canvas.session,
      let frame = session.activeCanvasFrame
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
      NSColor(hex: "#AAAAAA").setStroke()
      path.lineWidth = 0.5
      path.stroke()
      if major {
        let label = String(format: abs(value) < 0.0001 ? "0" : "%.3g", value)
        (label as NSString).draw(
          at: horizontal ? .init(x: position + 3, y: 2) : .init(x: 1, y: position + 2),
          withAttributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 8, weight: .regular),
            .foregroundColor: NSColor(hex: "#666666"),
          ])
      }
    }
  }
  override func mouseDown(with event: NSEvent) {
    guard let canvas = scrollView?.documentView as? VectorCanvasView, let s = canvas.session,
      let frame = s.activeCanvasFrame, frame.projection == nil
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
      let frame = s.activeCanvasFrame, let id = guideID
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
  var sharedUndoManager:UndoManager?
  weak var sharedSourceDelegate:NSTextStorageDelegate?
  var prepareSource:((NSAttributedString)->NSAttributedString)?
  var onBecomeActive:(()->Void)?
  var onCharacterPosition:((CharacterPosition)->Void)?
  override var undoManager:UndoManager? {sharedUndoManager ?? super.undoManager}
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
      let storage=PublicationTextStorage(),layout=PublicationLayoutManager()
      container=NSTextContainer(size:NSSize(width:frameRect.width,height:100000))
      storage.addLayoutManager(layout);layout.addTextContainer(container);ownedStorage=storage
    }
    super.init(frame:frameRect,textContainer:container)
    selectedTextAttributes = [.backgroundColor: Palette.accentNS.withAlphaComponent(0.18)]
    textStorage?.delegate=self
  }
  required init?(coder:NSCoder) {fatalError("init(coder:) has not been implemented")}
  func resetSourceTracking() {
    storageSnapshot=NSAttributedString(attributedString:attributedString());caseReference=storageSnapshot
    if !hasMarkedText() {sourceEdit=nil;composition=nil}
  }
  func captureSharedSourceEdit(_ previous:NSAttributedString,range:NSRange) {
    sourceEdit=(previous,range);storageSnapshot=NSAttributedString(attributedString:attributedString())
  }
  override func becomeFirstResponder()->Bool {
    let result=super.becomeFirstResponder()
    if result {textStorage?.delegate=sharedSourceDelegate ?? self;resetSourceTracking();onBecomeActive?()}
    return result
  }
  override func superscript(_ sender:Any?) {onCharacterPosition?(.superscript)}
  override func `subscript`(_ sender:Any?) {onCharacterPosition?(.subscript)}
  override func unscript(_ sender:Any?) {onCharacterPosition?(.normal)}
  override func insertNewline(_ sender:Any?) {
    if handleListReturn() {return};super.insertNewline(sender)
  }
  override func insertTab(_ sender:Any?) {
    if handleListIndent(outdent:false) {return};super.insertTab(sender)
  }
  override func insertBacktab(_ sender:Any?) {
    if handleListIndent(outdent:true) {return};super.insertBacktab(sender)
  }
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
      let raw=normalizeListTyping(source.text)
      let normalized=GlyphEngine.normalizedNative(prepareSource?(raw) ?? raw)
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
  // Visual points occupied by floating controls; never document/content insets.
  var fittingInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
  private let ppm = TypographyEngine.pointsPerMM
  private var frames: [CanvasFrame] = []
  private struct FrameSnapshotKey: Equatable {
    var projectID: UUID?, updatedAt: Date?, revision: Int?, activeFrameID: UUID?
  }
  private var frameSnapshotKey: FrameSnapshotKey?
  private var projectID: UUID?
  private var fitted = false
  private(set) var canvasOrigin = CGPoint.zero
  private var canvasExtent = CGRect.null
  private var growingCanvas = false
  private var navigatingViewport = false
  private var down = CGPoint.zero, windowDown = CGPoint.zero, panOrigin = CGPoint.zero
  private var snapshot = Artwork(), startSelection = Set<UUID>(), dragMode = "", handle = 0
  private var gestureToken: UUID?
  private var gestureFrameID: UUID?
  private var gestureSelection = Set<UUID>(), gestureNodes = Set<UUID>()
  private var dragDidMove = false
  private var dragDuplicated = false
  private var cursorTool: ArtworkTool?
  private var windowFocusObservation: NSObjectProtocol?
  private var edgeScrollTimer: Timer?
  private var dragEvent: NSEvent?
  private var edgeScrollTime = 0.0
  private var startNodes = Set<UUID>()
  private var downBounds = Rect2(0, 0, 1, 1), marquee: CGRect?
  private var snapLines: [(String, Double)] = []
  private var space = false
  private var numericTextUndoManager:UndoManager?
  private var numericTextUndoToken:UUID?
  private var textView: NSTextView?
  func refreshInterfaceAccent(_ color: NSColor) {
    textView?.selectedTextAttributes = [.backgroundColor: color.withAlphaComponent(0.18)]
    needsDisplay = true
  }
  private var publicationEditor:PublicationEditingController?
  var hasMarkedTextInput:Bool {textView?.hasMarkedText() ?? false}
  var activeStoryView:CanvasTextView? {publicationEditor == nil ? nil:textView as? CanvasTextView}
  var storyEditor:PublicationEditingController? {publicationEditor}
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
  private(set) var pointerFeedback: CanvasPointerFeedback = .arrow
  private(set) var hoveredElementID: UUID?
  private(set) var hoveredControlPoint: CGPoint?
  private var hoveredFrameID: UUID?
  private var hoverOutline: CGPath?
  private var lastHoverLookupMS = 0.0
  private struct HoverPickKey: Hashable {
    var frameID: UUID, scope: UUID?, mask: UUID?, excluded: Set<UUID>
  }
  private var hoverPickers: [HoverPickKey: ArtworkHitTesting.Picker] = [:]
  private var physicalPickingClips: [UUID: CGPath] = [:]
  private var overlayAccent: NSColor { activeFrame?.isWorkspace == true ? Palette.canvasAccentNS : Palette.accentNS }
  private var accessibilityItems: [ArtworkAccessibilityElement] = []
  private var accessibilityUpdates = 0
  private var frameDragOrigin = CGPoint.zero
  private var drawCount = 0, lastDrawMS = 0.0
  private var fitRequests = 0
  private var lastFitDiagnostics: [String: Any]?
  private let sewingGuides = CanvasSewingGuideCache()
  private let physicalArtworkGuides = CanvasPhysicalArtworkGuideCache()
  var diagnostics: [String: Any] {
    var result = TypographyEngine.diagnostics
    result["image_drag_starts"] = session?.imageDragStarts ?? 0
    result["image_drop_updates"] = imageDropUpdates
    result["image_drop_attempts"] = imageDropAttempts
    result["draw_count"] = drawCount
    result["last_draw_ms"] = lastDrawMS
    result["last_hover_lookup_ms"] = lastHoverLookupMS
    result["group_scope_id"] = (session?.scopeID?.uuidString as Any?) ?? NSNull()
    result["selected_element_ids"] = session?.selection.map(\.uuidString).sorted() ?? []
    result["pointer_gesture"] = dragMode
    result["sewing_guide_builds"] = sewingGuides.builds
    result["sewing_guide_entries"] = sewingGuides.count
    result["physical_guide_builds"] = physicalArtworkGuides.builds
    result["physical_guide_entries"] = physicalArtworkGuides.count
    result["frames"] = frames.count
    result["accessibility_updates"] = accessibilityUpdates
    result["live_preview"] = session?.preview ?? false
    result["renders_continuously"] = false
    result["viewport"] = viewportDiagnostics
    if let lastFitDiagnostics { result["last_fit"] = lastFitDiagnostics }
    return result
  }
  private func geometry(_ rect: CGRect) -> [String: Any] {
    func number(_ value: CGFloat) -> Any { value.isFinite ? Double(value) as Any : NSNull() }
    return ["x": number(rect.origin.x), "y": number(rect.origin.y),
      "width": number(rect.width), "height": number(rect.height)]
  }
  private var viewportDiagnostics: [String: Any] {
    var report: [String: Any] = ["version": 1, "view_identity": String(describing: ObjectIdentifier(self)),
      "window_number": window?.windowNumber ?? 0, "is_session_canvas": session?.canvas === self,
      "magnification": zoom, "canvas_frame_points": geometry(frame), "canvas_bounds_points": geometry(bounds),
      "canvas_visible_points": geometry(visibleRect), "visible_canvas_mm": geometry(visibleCanvasRect),
      "content_bounds_mm": geometry(contentBounds(all: true)),
      "canvas_origin_mm": ["x": canvasOrigin.x, "y": canvasOrigin.y],
      "fitting_insets_visual_points": ["top": fittingInsets.top, "left": fittingInsets.left,
        "bottom": fittingInsets.bottom, "right": fittingInsets.right],
      "frames": frames.filter { !$0.isWorkspace }.map { ["id": $0.id.uuidString, "rect_mm": geometry($0.rect)] }]
    if let scroll = enclosingScrollView {
      let clip = scroll.contentView
      report["scroll_frame_points"] = geometry(scroll.frame)
      report["scroll_bounds_points"] = geometry(scroll.bounds)
      report["scroll_visible_points"] = geometry(scroll.visibleRect)
      report["scroll_content_size_points"] = ["width": scroll.contentSize.width, "height": scroll.contentSize.height]
      report["clip_frame_points"] = geometry(clip.frame)
      report["clip_bounds_points"] = geometry(clip.bounds)
      report["clip_visible_points"] = geometry(clip.visibleRect)
      report["clip_document_visible_points"] = geometry(clip.documentVisibleRect)
      report["full_clip_in_canvas_points"] = geometry(convert(clip.bounds, from: clip))
      report["unobscured_clip_points"] = geometry(fittingViewport(in: scroll))
      report["content_insets_points"] = ["top": scroll.contentInsets.top, "left": scroll.contentInsets.left,
        "bottom": scroll.contentInsets.bottom, "right": scroll.contentInsets.right]
      report["rulers_visible"] = scroll.rulersVisible
      func ruler(_ ruler: NSRulerView?) -> [String: Any] {
        guard let ruler else { return [:] }
        return ["frame_points": geometry(ruler.frame), "visible_points": geometry(ruler.visibleRect),
          "in_clip_points": geometry(clip.convert(ruler.bounds, from: ruler)),
          "hidden": ruler.isHidden, "thickness_points": ruler.ruleThickness]
      }
      report["horizontal_ruler"] = ruler(scroll.horizontalRulerView)
      report["vertical_ruler"] = ruler(scroll.verticalRulerView)
    }
    var ancestors: [[String: Any]] = [], next = superview
    while let view = next, ancestors.count < 20 {
      ancestors.append(["type": String(describing: type(of: view)), "frame_points": geometry(view.frame),
        "bounds_points": geometry(view.bounds), "visible_points": geometry(view.visibleRect),
        "clips_to_bounds": view.clipsToBounds])
      next = view.superview
    }
    report["ancestors"] = ancestors
    return report
  }
  private func fittingViewport(in scroll: NSScrollView) -> CGRect {
    let clip = scroll.contentView
    var viewport = clip.visibleRect
    // Native rulers may overlay the clip view rather than reducing its bounds.
    // NSView.visibleRect excludes ancestor clips, but not these opaque siblings.
    if scroll.rulersVisible {
      for ruler in [scroll.horizontalRulerView, scroll.verticalRulerView].compactMap({ $0 })
      where !ruler.isHiddenOrHasHiddenAncestor {
      let overlap = clip.convert(ruler.visibleRect, from: ruler).intersection(viewport)
      guard !overlap.isNull, overlap.width > 0, overlap.height > 0 else { continue }
      let epsilon: CGFloat = 0.001
      if ruler.orientation == .horizontalRuler {
        if overlap.minY <= viewport.minY + epsilon {
          viewport = CGRect(x: viewport.minX, y: overlap.maxY, width: viewport.width,
            height: max(0, viewport.maxY - overlap.maxY))
        } else if overlap.maxY >= viewport.maxY - epsilon {
          viewport.size.height = max(0, overlap.minY - viewport.minY)
        }
      } else {
        if overlap.minX <= viewport.minX + epsilon {
          viewport = CGRect(x: overlap.maxX, y: viewport.minY,
            width: max(0, viewport.maxX - overlap.maxX), height: viewport.height)
        } else if overlap.maxX >= viewport.maxX - epsilon {
          viewport.size.width = max(0, overlap.minX - viewport.minX)
        }
      }
      }
    }
    // Convert visual points through AppKit at the current magnification. Pan,
    // events, drops and document coordinates continue to use the whole clip.
    let unit = clip.convert(CGRect(x: 0, y: 0, width: 1, height: 1), from: scroll)
    func inset(_ value: CGFloat, scale: CGFloat) -> CGFloat {
      value.isFinite && value > 0 && scale.isFinite ? value * abs(scale) : 0
    }
    var left = inset(fittingInsets.left, scale: unit.width)
    var right = inset(fittingInsets.right, scale: unit.width)
    var top = inset(fittingInsets.top, scale: unit.height)
    var bottom = inset(fittingInsets.bottom, scale: unit.height)
    // Opposing panels must not consume a narrow Split viewport completely.
    let horizontal = left + right, vertical = top + bottom
    if horizontal > viewport.width * 0.75, horizontal > 0 {
      let reduction = max(0, viewport.width) * 0.75 / horizontal
      left *= reduction; right *= reduction
    }
    if vertical > viewport.height * 0.75, vertical > 0 {
      let reduction = max(0, viewport.height) * 0.75 / vertical
      top *= reduction; bottom *= reduction
    }
    return CGRect(x: viewport.minX + left,
      y: viewport.minY + (clip.isFlipped ? top : bottom),
      width: max(0, viewport.width - left - right),
      height: max(0, viewport.height - top - bottom))
  }
  private func magnifyToFit(_ rect: CGRect, mode: String) {
    guard let scroll = enclosingScrollView else { return }
    let clip = scroll.contentView, before = viewportDiagnostics
    let target = clip.convert(documentRect(rect), from: self), viewport = fittingViewport(in: scroll)
    guard target.width > 0, target.height > 0, viewport.width > 0, viewport.height > 0 else { return }
    navigatingViewport = true
    defer { navigatingViewport = false }
    fitRequests += 1
    let magnification = scroll.magnification * min(viewport.width / target.width, viewport.height / target.height)
    scroll.setMagnification(magnification, centeredAt: target.center)
    // Recompute the native clip region after scaling. Custom hosts with visible
    // rulers still center within their unobscured viewport.
    for _ in 0..<2 {
      let fitted = clip.convert(documentRect(rect), from: self), available = fittingViewport(in: scroll)
      let desired = CGRect(x: clip.bounds.minX + fitted.midX - available.midX,
        y: clip.bounds.minY + fitted.midY - available.midY,
        width: clip.bounds.width, height: clip.bounds.height)
      let required = canvasRect(convert(desired, from: clip)).insetBy(dx: -80, dy: -80)
      if !expandCanvas(toInclude: required) { break }
    }
    let fittedTarget = clip.convert(documentRect(rect), from: self), available = fittingViewport(in: scroll)
    clip.scroll(to: CGPoint(x: clip.bounds.minX + fittedTarget.midX - available.midX,
      y: clip.bounds.minY + fittedTarget.midY - available.midY))
    scroll.reflectScrolledClipView(clip)
    expandCanvas(toInclude: visibleCanvasRect.insetBy(dx: -80, dy: -80))
    viewportCoordinatesChanged()
    lastFitDiagnostics = ["request": fitRequests, "mode": mode,
      "requested_canvas_rect_mm": geometry(rect), "target_clip_points": geometry(target),
      "before": before, "after": viewportDiagnostics]
  }
  override var isFlipped: Bool { true }
  override var acceptsFirstResponder: Bool { true }
  override var isOpaque: Bool { true }
  var zoom: Double { Double(enclosingScrollView?.magnification ?? 1) }
  var activeFrame: CanvasFrame? {
    frames.first { $0.id == session?.activeFrameID }
      ?? frames.first { $0.projection?.sourceID == session?.objectID && $0.projection?.isProof == true }
  }
  func canvasPoint(_ point:CGPoint) -> CGPoint {
    .init(x:point.x/ppm+canvasOrigin.x,y:point.y/ppm+canvasOrigin.y)
  }
  func documentPoint(_ point:CGPoint) -> CGPoint {
    .init(x:(point.x-canvasOrigin.x)*ppm,y:(point.y-canvasOrigin.y)*ppm)
  }
  private func documentRect(_ rect:CGRect) -> CGRect {
    .init(origin:documentPoint(rect.origin),size:.init(width:rect.width*ppm,height:rect.height*ppm))
  }
  private func canvasRect(_ rect: CGRect) -> CGRect {
    .init(origin: canvasPoint(rect.origin),
      size: .init(width: rect.width / ppm, height: rect.height / ppm))
  }
  var visibleCanvasRect:CGRect {
    if let clip = enclosingScrollView?.contentView {
      return canvasRect(convert(clip.bounds, from: clip))
    }
    return canvasRect(visibleRect)
  }
  func frame(atCanvasPoint point:CGPoint) -> CanvasFrame? {
    frames.last { !$0.isWorkspace && $0.contains(point) } ?? frames.first { $0.isWorkspace }
  }
  private func physicalGuideReport(for frame:CanvasFrame,attempted:inout Set<UUID>,
    reports:inout [UUID:PhysicalArtworkIntentReport]) -> PhysicalArtworkIntentReport? {
    guard frame.artwork.showGuides != false,
      !PaperConstruction.isPaper(frame.physicalGuideObject) || session?.store?.paperShowingGuides == true,
      let project=session?.store?.project else{return nil}
    let id=frame.physicalGuideObject.id
    if attempted.insert(id).inserted {reports[id]=physicalArtworkGuides.report(for:frame.physicalGuideObject,in:project)}
    return reports[id]
  }
  func contentBounds(all:Bool) -> CGRect {
    let chosen = all ? frames : activeFrame.map { [$0] } ?? []
    return contentBounds(in:chosen)
  }
  private func contentBounds(in chosen:[CanvasFrame])->CGRect {
    var result = CGRect.null
    var reports:[UUID:PhysicalArtworkIntentReport]=[:],attempted=Set<UUID>()
    for frame in chosen {
      let report=physicalGuideReport(for:frame,attempted:&attempted,reports:&reports)
      if !frame.isWorkspace {
        if let report {
          result=result.union(frame.physicalGuideBounds(report:report,scale:max(0.001,ppm*zoom)))
        } else {result=result.union(frame.rect)}
        continue
      }
      let masks = Set(frame.artwork.elements.compactMap(\.clipID))
      for element in frame.artwork.elements where element.parentID == nil && element.hidden != true && !masks.contains(element.id) {
        result = result.union(CGRect(frame.artwork.bounds(of:element)).offsetBy(dx:frame.rect.minX,dy:frame.rect.minY))
      }
      if let report {
        result=result.union(frame.physicalGuideBounds(report:report,scale:max(0.001,ppm*zoom)))
      }
    }
    return result.isNull ? CGRect(x:0,y:0,width:400,height:260) : result
  }
  private func centerViewport(on world: CGPoint, in scroll: NSScrollView) {
    let clip = scroll.contentView, point = clip.convert(documentPoint(world), from: self)
    let desired = CGPoint(x: clip.bounds.minX + point.x - clip.bounds.midX,
      y: clip.bounds.minY + point.y - clip.bounds.midY)
    guard abs(desired.x - clip.bounds.minX) > 1e-7 || abs(desired.y - clip.bounds.minY) > 1e-7 else { return }
    clip.scroll(to: desired)
    scroll.reflectScrolledClipView(clip)
  }
  private func viewportCoordinatesChanged() {
    updateAccessibilityItems()
    textView?.inputContext?.invalidateCharacterCoordinates()
    needsDisplay = true
  }
  var viewportLayoutAnchor: CGPoint? {
    guard !growingCanvas, !navigatingViewport, !canvasExtent.isNull else { return nil }
    return visibleCanvasRect.center
  }
  func ensureViewportCoverage(preserving center: CGPoint? = nil) {
    guard !growingCanvas, !navigatingViewport, !canvasExtent.isNull,
      let scroll = enclosingScrollView else { return }
    let current = visibleCanvasRect
    guard current.width > 0, current.height > 0 else { return }
    let anchor = center ?? current.center
    let desired = CGRect(x: anchor.x - current.width / 2, y: anchor.y - current.height / 2,
      width: current.width, height: current.height)
    let grew = expandCanvas(toInclude: current.union(desired).insetBy(dx: -80, dy: -80),
      preserving: anchor)
    if !grew, center != nil { centerViewport(on: anchor, in: scroll) }
    if grew || visibleCanvasRect != current { viewportCoordinatesChanged() }
  }
  @discardableResult private func expandCanvas(toInclude rect:CGRect,
    preserving center: CGPoint? = nil) -> Bool {
    guard !growingCanvas, !rect.isNull, rect.width.isFinite, rect.height.isFinite,
      rect.minX.isFinite, rect.minY.isFinite else { return false }
    let anchor = center ?? visibleCanvasRect.center
    // Avoid roundoff-driven growth at an exact 160 mm document boundary.
    let minX = floor(rect.minX / 160 + 1e-9), minY = floor(rect.minY / 160 + 1e-9)
    let maxX = ceil(rect.maxX / 160 - 1e-9), maxY = ceil(rect.maxY / 160 - 1e-9)
    let requested = CGRect(x: minX * 160, y: minY * 160,
      width: (maxX - minX) * 160, height: (maxY - minY) * 160)
    let next = canvasExtent.isNull ? requested : canvasExtent.union(requested)
    guard next != canvasExtent else { return false }
    growingCanvas = true
    defer { growingCanvas = false }
    canvasExtent = next
    canvasOrigin = next.origin
    setFrameSize(.init(width:max(600,next.width*ppm),height:max(500,next.height*ppm)))
    if let scroll = enclosingScrollView {
      scroll.tile()
      centerViewport(on: anchor, in: scroll)
    }
    if let editor = publicationEditor { editor.reposition() }
    else if let id = editingID, let element = session?.art.elements.first(where: { $0.id == id }) {
      positionTextHost(element, layoutOnly: true)
    }
    needsDisplay = true
    return true
  }
  private func refreshFrameSnapshots(force: Bool = false) {
    guard let session else { return }
    let key = FrameSnapshotKey(projectID: session.store?.project?.id,
      updatedAt: session.store?.project?.updatedAt, revision: session.store?.revision,
      activeFrameID: session.activeFrameID)
    guard force || key != frameSnapshotKey else { return }
    // Native input can follow Group, Undo, or an agent edit before SwiftUI's
    // next representable update. Picking and hover must use the same current
    // hierarchy as the source, without refitting or interrupting a held gesture.
    frames = session.frames
    frameSnapshotKey = key
    clearHoverFeedback()
    hoverPickers.removeAll(keepingCapacity: true)
    physicalPickingClips.removeAll(keepingCapacity: true)
    needsDisplay = true
  }
  func synchronize() {
    guard let session else { return }
    if projectID != session.store?.project?.id {
      clearPointerGesture(); space = false
      canvasExtent = .null; canvasOrigin = .zero; sewingGuides.clear();physicalArtworkGuides.clear()
    }
    refreshFrameSnapshots(force: true)
    sewingGuides.retain(Set(frames.map(\.id)))
    physicalArtworkGuides.retain(Set(frames.map{$0.physicalGuideObject.id}))
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
    if publicationEditor==nil {
    if let id = editingID, let tv = textView,
      let e = session.art.elements.first(where: { $0.id == id }).map(session.colored), e != publishedText,
      !tv.hasMarkedText()
    {
      let previous = TextCase.source(tv.attributedString())
      let range = previous.sourceRange(tv.selectedRange())
      tv.textStorage?.setAttributedString(TypographyEngine.attributed(e, millimeters: false, preservingSource: true))
      publishedInput = NSAttributedString(attributedString: tv.attributedString())
      let location=min(range.location,e.text.utf16.count)
      // A formatting/source-metadata refresh keeps the same words and must not
      // collapse the user's selection or change the character inspector target.
      let length=previous.text.string==e.text ? min(range.length,e.text.utf16.count-location):0
      tv.setSelectedRange(TextCase.source(tv.attributedString()).displayRange(NSRange(location:location,length:length)))
      publishedText = e
    }
    if let id = editingID, let element = session.art.elements.first(where: { $0.id == id }) {
      positionTextHost(element)
    }
    } else {publicationEditor?.reposition()}
    needsDisplay = true
    if cursorTool != session.tool {
      cursorTool = session.tool
      window?.invalidateCursorRects(for: self)
    }
    updateAccessibilityItems()
  }
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if let observer = windowFocusObservation { NotificationCenter.default.removeObserver(observer) }
    windowFocusObservation = nil
    if let window {
      windowFocusObservation = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification,
        object: window, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated {
          self?.cancelPointerGesture()
          self?.space = false
          self?.clearHoverFeedback()
          if let self { self.window?.invalidateCursorRects(for: self) }
        }
      }
    } else {
      cancelPointerGesture(); space = false
    }
    if window != nil, !isHiddenOrHasHiddenAncestor {
      session?.canvas = self
      session?.zoom = zoom
    }
    DispatchQueue.main.async { [weak self] in
      guard self?.window != nil else { return }
      self?.fitWhenReady()
      self?.fitPaperPanelWhenRequested()
      self?.updateAccessibilityItems()
    }
  }
  deinit {
    edgeScrollTimer?.invalidate()
    if let observer = windowFocusObservation { NotificationCenter.default.removeObserver(observer) }
  }
  func fitWhenReady() {
    guard !growingCanvas, !navigatingViewport, !fitted, !frames.isEmpty, window != nil, let scroll = enclosingScrollView,
      scroll.contentSize.width > 100, scroll.contentSize.height > 100
    else { return }
    fitted = true
    fit(all: true)
  }
  func fit(all: Bool) {
    _ = fit(rect:contentBounds(all:all),mode:all ? "all":"active")
  }
  /// Fit existing representations together without changing the active source.
  @discardableResult func fit(frameIDs:Set<UUID>)->Bool {
    refreshFrameSnapshots()
    let selected=frames.filter{frameIDs.contains($0.id)}
    guard !selected.isEmpty else{return false}
    return fit(rect:contentBounds(in:selected),mode:"frames")
  }
  @discardableResult private func fit(rect:CGRect,mode:String)->Bool {
    guard let scroll = enclosingScrollView else { return false }
    guard scroll.contentSize.width > 100, scroll.contentSize.height > 100 else { return false }
    fitted = true
    guard !rect.isNull, rect.width > 0 else { return false }
    let horizontal = min(14, rect.width * 0.08 + 1)
    let vertical = min(18, rect.height * 0.08 + 1)
    // AppKit expects clip-view coordinates, which differ from the document's
    // when its frame origin shifts during native layout or scrolling.
    magnifyToFit(rect.insetBy(dx:-horizontal,dy:-vertical),mode:mode)
    session?.zoom = Double(scroll.magnification)
    needsDisplay = true
    return true
  }
  private func fitPaperPanelWhenRequested() {
    guard let session,let id=session.paperFocusPanelID,let paper=session.paperContext,
      let net=try? PaperConstruction.definition(for:paper).net(),let panel=net.panels.first(where:{$0.id==id}),
      let frame=activeFrame,let scroll=enclosingScrollView,scroll.contentSize.width>100 else{return}
    if PaperSideLabels.isFlatSheet(net),let projection=frame.projection {
      let ids=Set(frames.filter{$0.projection?.constructionID==paper.id && $0.projection?.panelID==projection.panelID}.map(\.id))
      if fit(frameIDs:ids) {session.paperFocusPanelID=nil}
      return
    }
    session.paperFocusPanelID=nil
    let b=panel.bounds
    let rect = frame.projection?.panelID == id ? contentBounds(all:false)
      : CGRect(x:frame.rect.minX+b.x,y:frame.rect.minY+b.y,width:b.width,height:b.height)
    magnifyToFit(rect.insetBy(dx:-8,dy:-8),mode:"paper_panel")
    session.zoom=Double(scroll.magnification);needsDisplay=true
  }
  func setZoom(_ value: Double, atCanvasPoint point: CGPoint? = nil) {
    guard value.isFinite, value > 0, let scroll = enclosingScrollView else { return }
    let viewport = visibleCanvasRect, anchor = point ?? viewport.center
    guard viewport.width > 0, viewport.height > 0, anchor.x.isFinite, anchor.y.isFinite else { return }
    let fraction = CGPoint(x: (anchor.x - viewport.minX) / viewport.width,
      y: (anchor.y - viewport.minY) / viewport.height)
    let magnification = CGFloat(min(24, max(0.08, value)))
    let ratio = scroll.magnification / magnification
    navigatingViewport = true
    defer { navigatingViewport = false }
    let required = CGRect(x: anchor.x - viewport.width * ratio * fraction.x,
      y: anchor.y - viewport.height * ratio * fraction.y,
      width: viewport.width * ratio, height: viewport.height * ratio)
    expandCanvas(toInclude: required.insetBy(dx: -80, dy: -80), preserving: anchor)
    let center = scroll.contentView.convert(documentPoint(anchor), from: self)
    scroll.setMagnification(magnification, centeredAt: center)
    let actual = visibleCanvasRect
    let desired = CGRect(x: anchor.x - actual.width * fraction.x,
      y: anchor.y - actual.height * fraction.y, width: actual.width, height: actual.height)
    expandCanvas(toInclude: desired.insetBy(dx: -80, dy: -80), preserving: desired.center)
    centerViewport(on: desired.center, in: scroll)
    session?.zoom = Double(scroll.magnification)
    viewportCoordinatesChanged()
  }
  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    trackingAreas.forEach { removeTrackingArea($0) }
    addTrackingArea(
      .init(
        rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self,
        userInfo: nil))
  }
  override func resetCursorRects() {
    addCursorRect(visibleRect, cursor: effectivePointerFeedback.cursor)
  }
  override func draw(_ dirtyRect: NSRect) {
    let start = CFAbsoluteTimeGetCurrent()
    defer {
      drawCount += 1
      lastDrawMS = (CFAbsoluteTimeGetCurrent() - start) * 1000
    }
    guard let context = NSGraphicsContext.current?.cgContext else { return }
    context.saveGState()
    defer { context.restoreGState() }
    context.clip(to: bounds)
    Palette.canvasBackgroundNS.setFill()
    bounds.fill()
    guard let session else { return }
    context.scaleBy(x: ppm, y: ppm)
    context.translateBy(x:-canvasOrigin.x,y:-canvasOrigin.y)
    let scale = ppm * zoom
    var reports:[UUID:PhysicalArtworkIntentReport]=[:],attempted=Set<UUID>()
    for f in frames {
      let guideReport=physicalGuideReport(for:f,attempted:&attempted,reports:&reports)
      var drawingBounds=guideReport.map{f.physicalGuideBounds(report:$0,scale:max(0.001,scale))} ?? f.rect
      if !f.isWorkspace { drawingBounds = drawingBounds.union(CanvasFrameChrome.headerRect(for: f, scale: scale)) }
      guard f.isWorkspace || dirtyRect.intersects(documentRect(drawingBounds.insetBy(dx:-12,dy:-12))) else{continue}
      let frameColor = InterfaceAppearance.shared.frameColor(for: f.role)
      if !f.isWorkspace {
      context.saveGState()
      context.setShadow(
        offset: .init(width: 0, height: 2 / scale), blur: 9 / scale,
        color: NSColor.black.withAlphaComponent(0.13).cgColor)
      context.setFillColor(NSColor.white.cgColor)
      context.fill(f.rect)
      context.restoreGState()
      CanvasFrameChrome.drawHeader(f, context: context, scale: scale)
      }
      context.saveGState()
      context.translateBy(x: f.rect.minX, y: f.rect.minY)
      if session.dieline, f.surfaceObject.recipeID == "sleeve", f.id == activeFrame?.id {
        context.setFillColor(NSColor.white.cgColor)
        context.fill(.init(origin: .zero, size: f.rect.size))
        context.saveGState()
        context.translateBy(x: f.surfaceObject["width"] + f.surfaceObject["height"], y: 0)
        ArtworkRenderer.draw(
          f.artwork, width: f.surfaceObject["width"], height: f.rect.height, assets: session.assets)
        context.restoreGState()
        context.setStrokeColor(frameColor.cgColor)
        context.setLineWidth(1 / scale)
        context.stroke(.init(origin: .zero, size: f.rect.size))
        context.setStrokeColor(NSColor(hex: "#666666").cgColor)
        context.setLineDash(phase: 0, lengths: [4 / scale, 3 / scale])
        for x in Dieline.scores(f.surfaceObject) {
          context.move(to: .init(x: x, y: 0))
          context.addLine(to: .init(x: x, y: f.rect.height))
          context.strokePath()
        }
      } else {
        let paperNet = PaperConstruction.isPaper(f.surfaceObject) && f.projection?.panelID == nil
          ? try? PaperConstruction.definition(for:f.surfaceObject).net() : nil
        let sewing = sewingGuides.overlay(frameID: f.id, source: f.artwork)
        context.saveGState()
        if let projection = f.projection, !projection.isProof {
          context.addPath(projection.clipPath); context.clip(using:.evenOdd)
        }
        if let paperNet {
          var transform = CGAffineTransform(a:f.projection?.sourceToLocal.a ?? 1,b:f.projection?.sourceToLocal.b ?? 0,
            c:f.projection?.sourceToLocal.c ?? 0,d:f.projection?.sourceToLocal.d ?? 1,
            tx:f.projection?.sourceToLocal.tx ?? 0,ty:f.projection?.sourceToLocal.ty ?? 0)
          context.addPath(PaperOutput.clipPath(paperNet).copy(using:&transform)!); context.clip()
        }
        if PaperConstruction.isPaper(f.surfaceObject),let project=session.store?.project,
          let paper=try? PaperConstruction.definition(for:f.surfaceObject) {
          let face=PaperGeometry.faceAppearance(for:f.surfaceObject,stock:paper.stock,project:project,inside:f.projection?.inside == true)
          context.setFillColor(FormColor.color(face.resolvedColor).withAlphaComponent(face.profile.opacity).cgColor)
          context.fill(CGRect(origin:.zero,size:f.rect.size))
        }
        ArtworkRenderer.draw(
          f.artwork, width: f.rect.width, height: f.rect.height, assets: session.assets,
          production: false,
          excluding: (f.id == activeFrame?.id ? Set([editingID].compactMap { $0 }).union(
            dragMode == "move" && moveDropFrameID != nil ? session.art.descendants(of:startSelection) : []) : [])
            .union(ArtworkProduction.hiddenIDs(in:f.artwork,roles:session.hiddenProductionRoles))
            .union(sewing?.sourceStrokeIDs ?? [])
            .union(publicationEditor?.excluded(in:f.id) ?? []),
          unbounded:f.isWorkspace)
        context.restoreGState()
        if let guideReport {
          drawPhysicalArtworkGuides(f,report:guideReport,context:context,scale:scale,active:f.id==activeFrame?.id)
        }
        if let paperNet, session.store?.paperShowingGuides == true {
          context.saveGState()
          if let transform=f.projection?.sourceToLocal {
            context.concatenate(.init(a:transform.a,b:transform.b,c:transform.c,d:transform.d,tx:transform.tx,ty:transform.ty))
          }
          PaperOutput.drawStructure(paperNet,context:context,lineWidth:1/scale,interface:true,
            interfaceCutColor:f.role == .construction ? frameColor:nil)
          context.restoreGState()
        }
        if let sewing {
          context.saveGState()
          if let projection = f.projection, !projection.isProof {
            context.addPath(projection.clipPath); context.clip(using:.evenOdd)
          }
          ArtworkRenderer.draw(sewing.interfaceArtwork(scale: scale), width: f.rect.width, height: f.rect.height,
            assets: session.assets, production: false,
            excluding: ArtworkProduction.hiddenIDs(in: sewing.artwork, roles: session.hiddenProductionRoles), unbounded: true)
          context.restoreGState()
        }
        if !f.isWorkspace {
          context.saveGState()
          if let projection = f.projection, !projection.isProof { context.addPath(projection.clipPath) }
          else { context.addRect(.init(origin: .zero, size: f.rect.size)) }
          context.setStrokeColor(frameColor.cgColor)
          context.setLineWidth((f.id == activeFrame?.id ? 1.5 : 1) / scale)
          context.strokePath()
          context.restoreGState()
        }
        if f.id == activeFrame?.id && f.editable {
          drawOverlays(f, context: context, scale: scale)
          if editingID == nil && !(dragMode == "move" && moveDropFrameID != nil) { drawSelection(context: context, scale: scale) }
        }
        drawHoverOutline(in: f, context: context, scale: scale)
      }
      context.restoreGState()
      if (dropFrameID == f.id || moveDropFrameID == f.id) && !f.isWorkspace {
        context.setStrokeColor(Palette.accentNS.cgColor)
        context.setLineWidth(3/scale)
        context.stroke(f.rect.insetBy(dx:-2/scale,dy:-2/scale))
      }
    }
    if dragMode == "move",moveDropFrameID != nil,let active = activeFrame, active.projection == nil,
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
          .foregroundColor:Palette.accentNS]
        let size = (label as NSString).size(withAttributes:attributes)
        let origin = CGPoint(x:moveDropPoint.x+12/scale,y:moveDropPoint.y+12/scale)
        context.setFillColor(NSColor.white.withAlphaComponent(0.95).cgColor)
        context.fill(CGRect(x:origin.x-4/scale,y:origin.y-3/scale,width:size.width+8/scale,height:size.height+6/scale))
        (label as NSString).draw(at:origin,withAttributes:attributes)
      }
    }
  }
  private func drawOverlays(_ f: CanvasFrame, context: CGContext, scale: Double) {
    guard let session else { return }
    let art = f.artwork
    context.saveGState()
    let region = f.isWorkspace ? visibleCanvasRect.offsetBy(dx:-f.rect.minX,dy:-f.rect.minY) : CGRect(origin:.zero,size:f.rect.size)
    let pageGuides = !f.isWorkspace && f.object.recipeID=="artboard" && f.object.artworkSourceID==nil && art.boundary==nil
    let guideRegion=pageGuides ? region.insetBy(dx:-art.bleed-1/scale,dy:-art.bleed-1/scale):region
    context.clip(to:guideRegion)
    context.setLineWidth(0.5 / scale)
    if art.showGrid == true {
      let spacing = max(art.gridSpacing ?? 10, 5 / scale)
      context.setStrokeColor((f.isWorkspace ? Palette.canvasGridNS : NSColor(hex: "#AAAAAA").withAlphaComponent(0.3)).cgColor)
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
    context.setStrokeColor((f.isWorkspace ? Palette.canvasGuideNS : NSColor(hex: "#777777").withAlphaComponent(0.7)).cgColor)
    context.setLineDash(phase: 0, lengths: [4 / scale, 3 / scale])
    for g in art.showGuides == false ? [] : art.guides ?? [] {
      context.move(to: g.axis == "x" ? .init(x:g.position,y:region.minY) : .init(x:region.minX,y:g.position))
      context.addLine(
        to: g.axis == "x"
          ? .init(x:g.position,y:region.maxY) : .init(x:region.maxX,y:g.position))
      context.strokePath()
    }
    if pageGuides && art.showGuides != false {
      context.setStrokeColor(NSColor(hex:"#000000").withAlphaComponent(0.7).cgColor)
      if art.bleed>0 {context.stroke(region.insetBy(dx:-art.bleed,dy:-art.bleed))}
      if let safe=art.safeInset,safe>0,region.width>2*safe,region.height>2*safe {
        context.setStrokeColor(NSColor(hex:"#666666").withAlphaComponent(0.7).cgColor);context.stroke(region.insetBy(dx:safe,dy:safe))
      }
    }
    context.setLineDash(phase: 0, lengths: [])
    context.setStrokeColor(overlayAccent.cgColor)
    context.setLineWidth(1 / scale)
    for (axis, p) in snapLines {
      context.move(to: axis == "x" ? .init(x:p,y:region.minY) : .init(x:region.minX,y:p))
      context.addLine(
        to: axis == "x" ? .init(x:p,y:region.maxY) : .init(x:region.maxX,y:p))
      context.strokePath()
    }
    if let marquee {
      context.setFillColor(overlayAccent.withAlphaComponent(0.08).cgColor)
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
      context.setStrokeColor(overlayAccent.cgColor)
      context.setLineWidth(1 / scale)
      context.strokePath()
    }
    if session.scopeID != nil {
      context.setStrokeColor(overlayAccent.withAlphaComponent(0.3).cgColor)
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
  private func visibleResizeHandles(_ b: Rect2) -> [Int] {
    let width = b.width * ppm * zoom, height = b.height * ppm * zoom
    // Leave small artwork a usable interior; overlapping side handles otherwise
    // turn a normal grab into an accidental resize.
    return (0..<8).filter { index in
      if [1, 5].contains(index) { return width >= 24 && height >= 18 }
      if [3, 7].contains(index) { return height >= 24 && width >= 18 }
      return width >= 10 || height >= 10
    }
  }
  private func selectionHandle(at p: CGPoint) -> (mode: String, index: Int)? {
    guard let s = session, [.select, .direct].contains(s.tool),
      let b = s.selectionBounds, !s.elements.contains(where: { s.art.isLocked($0) }) else { return nil }
    let scale = ppm * zoom
    let rotation = CGPoint(x: b.center.x, y: b.y - 18 / scale)
    if hypot(p.x - rotation.x, p.y - rotation.y) < 7 / scale { return ("rotate", 0) }
    if min(b.width, b.height) * scale < 18, CGRect(b).contains(p) { return nil }
    let points = handles(b)
    if let index = visibleResizeHandles(b).min(by: {
      hypot(points[$0].x-p.x, points[$0].y-p.y) < hypot(points[$1].x-p.x, points[$1].y-p.y)
    }), hypot(points[index].x-p.x, points[index].y-p.y) < 6 / scale {
      return ("resize", index)
    }
    return nil
  }
  private func hasEditingControl(at p: CGPoint) -> Bool { editingControlPoint(at: p) != nil }
  private func editingControlPoint(at p: CGPoint) -> CGPoint? {
    guard let s = session, [.select, .direct].contains(s.tool) else { return nil }
    let tolerance = 7 / (ppm * zoom)
    func near(_ q: CGPoint) -> Bool { hypot(q.x-p.x, q.y-p.y) < tolerance }
    if s.tool == .direct {
      for e in s.elements.reversed() where !s.art.isLocked(e) {
        guard let path = e.path else { continue }
        let transform = s.art.worldTransform(e).followed(by: .scale(e.width/path.width, e.height/path.height))
        for node in path.contours.flatMap(\.nodes).reversed() {
          if s.nodes.contains(node.id), let q = [node.incoming, node.outgoing].compactMap({ $0 })
            .map({ CGPoint(transform.apply($0)) }).first(where: near) { return q }
          let anchor = CGPoint(transform.apply(node.anchor))
          if near(anchor) { return anchor }
        }
      }
    }
    if s.selection.count == 1, s.maskEditing == nil, let e = s.primary, !s.art.isLocked(e),
      let axis = gradientHandles(e, in: s.art) {
      if let stop = axis.stops.last(where: { near($0.point) }) { return stop.point }
      if near(axis.a) { return axis.a }; if near(axis.b) { return axis.b }
      if let offset = gradientPosition(p, a: axis.a, b: axis.b), (0...1).contains(offset) {
        let q = CGPoint(x: axis.a.x+(axis.b.x-axis.a.x)*offset, y: axis.a.y+(axis.b.y-axis.a.y)*offset)
        if hypot(p.x-q.x, p.y-q.y) < 6/(ppm*zoom) { return q }
      }
    }
    return nil
  }
  private func dot(
    _ p: CGPoint, context: CGContext, scale: Double, circle: Bool = false, filled: Bool = false
  ) {
    let r = CGRect(x: p.x - 3 / scale, y: p.y - 3 / scale, width: 6 / scale, height: 6 / scale)
    context.setFillColor((filled ? overlayAccent : NSColor.white).cgColor)
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
      context.setStrokeColor(overlayAccent.cgColor)
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
    context.setStrokeColor(overlayAccent.cgColor)
    context.setLineWidth(1.2 / scale)
    context.stroke(CGRect(b))
    let points = handles(b)
    visibleResizeHandles(b).forEach { dot(points[$0], context: context, scale: scale) }
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
        context.setStrokeColor((s.selectedGradientStopID == item.stop.id ? overlayAccent : NSColor.white).cgColor)
        context.setLineWidth((s.selectedGradientStopID == item.stop.id ? 2 : 1)/scale)
        context.strokeEllipse(in:r)
      }
      context.restoreGState()
    }
    if let e = s.primary, e.kind == "text", TypographyEngine.overflows(e) {
      let r = CGRect(
        x: b.maxX - 8 / scale, y: b.maxY - 8 / scale, width: 8 / scale, height: 8 / scale)
      context.setFillColor(overlayAccent.cgColor)
      context.fill(r)
    }
    if let point = hoveredControlPoint, dragMode.isEmpty {
      context.setStrokeColor(overlayAccent.cgColor)
      context.setLineWidth(2 / scale)
      context.strokeEllipse(in: CGRect(x: point.x - 6 / scale, y: point.y - 6 / scale,
        width: 12 / scale, height: 12 / scale))
    }
  }
  private func point(_ event: NSEvent) -> CGPoint {
    let p = canvasPoint(convert(event.locationInWindow, from: nil))
    // Native view/ruler transforms can leave inverse-roundtrip noise such as
    // -50.00000000000006 mm. Keep pointer-authored coordinates stable at a
    // billionth of a millimeter; raw source/API geometry retains its precision.
    func physical(_ value: CGFloat) -> CGFloat {
      guard value.isFinite, abs(value) < 1_000_000 else { return value }
      return (value * 1_000_000_000).rounded() / 1_000_000_000
    }
    return .init(
      x:physical(p.x-(activeFrame?.rect.minX ?? 0)),y:physical(p.y-(activeFrame?.rect.minY ?? 0)))
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
  /// The renderer clips projected artwork to actual stock. Picking uses that
  /// same material region in frame-local coordinates, including reverse faces.
  func physicalPickingClip(for frame: CanvasFrame) -> CGPath? {
    guard let projection = frame.projection else { return nil }
    if let clip = physicalPickingClips[frame.id] { return clip }
    let clip: CGPath
    if projection.isProof {
      if let net = try? PaperConstruction.definition(for: frame.surfaceObject).net() {
        var transform = CGAffineTransform(a: projection.sourceToLocal.a, b: projection.sourceToLocal.b,
          c: projection.sourceToLocal.c, d: projection.sourceToLocal.d,
          tx: projection.sourceToLocal.tx, ty: projection.sourceToLocal.ty)
        clip = PaperOutput.clipPath(net).normalized(using: .evenOdd).copy(using: &transform) ?? CGMutablePath()
      } else { clip = CGMutablePath() }
    } else { clip = projection.clipPath.normalized(using: .evenOdd) }
    physicalPickingClips[frame.id] = clip
    return clip
  }
  private func hit(_ point: CGPoint, art: Artwork, scope: UUID?) -> ArtworkElement? {
    let hiddenRoles = ArtworkProduction.hiddenIDs(in:activeFrame?.artwork ?? art,roles:session?.hiddenProductionRoles ?? [])
    return ArtworkHitTesting.hit(at: point, in: art, scope: scope,
      tolerance: 3.5 / (ppm * zoom), excluding: hiddenRoles,
      editingMask: session?.maskEditing?.maskID, renderedArtwork: activeFrame?.artwork,
      outerClip: activeFrame.flatMap { physicalPickingClip(for: $0) })
  }
  /// Resolve a painted sibling in the nearest enclosing scope, skipping the
  /// branch we are already editing. The same resolver drives hover and clicks.
  func externalGroupTarget(at point: CGPoint, in art: Artwork, frame: CanvasFrame,
    cached: Bool = false) -> ArtworkElement? {
    guard let s = session, s.maskEditing == nil, var branch = s.scopeID else { return nil }
    let byID = Dictionary(uniqueKeysWithValues: art.elements.map { ($0.id, $0) })
    let hidden = ArtworkProduction.hiddenIDs(in: frame.artwork, roles: s.hiddenProductionRoles)
    var visited = Set<UUID>()
    while let group = byID[branch], visited.insert(branch).inserted {
      let excluded = hidden.union([branch])
      let key = HoverPickKey(frameID: frame.id, scope: group.parentID, mask: nil, excluded: excluded)
      let picker: ArtworkHitTesting.Picker
      if cached, let existing = hoverPickers[key] { picker = existing }
      else {
        picker = ArtworkHitTesting.Picker(in: art, scope: group.parentID,
          excluding: excluded, renderedArtwork: frame.artwork, outerClip: physicalPickingClip(for: frame))
        if cached { hoverPickers[key] = picker }
      }
      if let target = picker.hit(at: point, tolerance: 3.5 / (ppm * zoom)) { return target }
      guard let parent = group.parentID else { break }
      branch = parent
    }
    return nil
  }
  override func mouseDown(with event: NSEvent) {
    guard let s = session else { return }
    refreshFrameSnapshots()
    clearHoverFeedback()
    defer { window?.invalidateCursorRects(for: self) }
    if let token = gestureToken { s.store?.engine.endInteraction(ifGeneration: token) }
    clearPointerGesture()
    s.store?.activateDesignSurface(.artwork)
    let absolute = convert(event.locationInWindow, from: nil)
    let physical = canvasPoint(absolute)
    moveDropFrameID = nil
    windowDown = event.locationInWindow
    dragDidMove = false
    gestureToken = nil
    gestureSelection = s.selection
    gestureNodes = s.nodes
    if space || s.tool == .hand {
      finishText()
      window?.makeFirstResponder(self)
      dragMode = "pan"
      panOrigin = visibleCanvasRect.origin
      NSCursor.closedHand.set()
      window?.invalidateCursorRects(for: self)
      return
    }
    // Selected controls can sit outside their frame. Resolve them before a
    // blank-canvas click changes the active source.
    let existingHandle = activeFrame?.editable == true ? selectionHandle(at: point(event)) : nil
    let preserveSource = existingHandle != nil || (activeFrame?.editable == true && hasEditingControl(at: point(event)))
    if !preserveSource, let frame = frame(atCanvasPoint:physical), frame.id != activeFrame?.id {
      finishText()
      s.activate(frame.id)
      frames = s.frames
    }
    if !preserveSource, [.select, .direct].contains(s.tool),
      let f = frames.last(where: { !$0.isWorkspace && $0.editable &&
      CanvasFrameChrome.headerRect(for: $0, scale: ppm * zoom).contains(physical)
    }) {
      finishText()
      window?.makeFirstResponder(self)
      s.activate(f.id)
      frames = s.frames
      frameDragOrigin = f.rect.origin
      down = physical
      snapshot = s.art
      dragMode = "frame"
      gestureToken = s.beginGesture()
      gestureFrameID = s.activeFrameID
      return
    }
    guard let f = activeFrame, !s.dieline, f.editable else { return }
    let p = point(event)
    finishText()
    window?.makeFirstResponder(self)
    down = p
    snapshot = s.art
    startSelection = s.selection
    startNodes = s.nodes
    dragMode = ""
    snapLines = []
    gestureToken = s.beginGesture()
    gestureFrameID = s.activeFrameID
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
      if let control = existingHandle ?? selectionHandle(at: p), let b = s.selectionBounds {
        downBounds = b
        dragMode = control.mode
        handle = control.index
        return
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
        if event.clickCount > 0, event.clickCount.isMultiple(of: 2), e.kind == "group" {
          s.enterGroup(e.id)
          return
        }
        if event.modifierFlags.contains(.shift) {
          if s.selection.contains(e.id) {
            s.selection.remove(e.id)
            // Removing one member is a selection gesture, never a request to
            // drag the other selected artwork from this now-unselected item.
            needsDisplay = true
            return
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
        if !event.modifierFlags.contains(.shift), s.scopeID != nil, s.maskEditing == nil {
          if let target = externalGroupTarget(at: p, in: s.art, frame: f) {
            s.navigateGroup(to: target.parentID, selection: [target.id])
            // A click-drag on an external sibling should continue directly into
            // moving it, with a fresh transaction belonging to its new scope.
            snapshot = s.art; startSelection = s.selection; startNodes = []
            gestureSelection = s.selection; gestureNodes = []
            gestureToken = s.beginGesture(); gestureFrameID = s.activeFrameID
            downBounds = s.selectionBounds ?? .init(0, 0, 1, 1)
            dragMode = "move"
            return
          }
          if let group = s.art.elements.first(where: { $0.id == s.scopeID }),
            (event.clickCount > 0 && event.clickCount.isMultiple(of: 2)
              || !CGRect(s.art.bounds(of: group)).insetBy(dx: -3.5/(ppm*zoom), dy: -3.5/(ppm*zoom)).contains(p)) {
            s.leaveGroup()
            return
          }
        }
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
      if let scroll = enclosingScrollView { centerViewport(on: region.center, in: scroll) }
      viewportCoordinatesChanged()
      return
    }
    if let token = gestureToken,
      s.store?.engine.isInteracting(withGeneration: token) != true || gestureFrameID != s.activeFrameID {
      s.store?.engine.endInteraction(ifGeneration: token)
      clearPointerGesture()
      return
    }
    guard !dragMode.isEmpty else { return }
    if !dragDidMove {
      let distance = hypot(event.locationInWindow.x-windowDown.x, event.locationInWindow.y-windowDown.y)
      guard distance >= 3 else { return }
      dragDidMove = true
    }
    var duplicatedNow = false
    if dragMode == "move", s.maskEditing == nil, !dragDuplicated, event.modifierFlags.contains(.option) {
      do {
        // Clone the gesture's untouched starting artwork, even if Option was
        // pressed after movement began. The original stays at its start point.
        var copied = snapshot
        let copies = try ArtworkCommands.apply("duplicate", to: &copied, ids: startSelection,
          duplicateOffset: .init())
        guard !copies.isEmpty else { return }
        snapshot = copied; startSelection = copies
        s.choose(copies)
        dragDuplicated = true; duplicatedNow = true
      } catch {
        s.store?.error = error.localizedDescription
        cancelPointerGesture()
        return
      }
    }
    updateEdgeScrolling(with: event)
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
      s.moveCanvasFrame(to: .init(
        frameDragOrigin.x+p.x-down.x,frameDragOrigin.y+p.y-down.y))
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
        s.selectionCandidates(in: value).filter {
          rect.intersects(CGRect(value.bounds(of: $0)))
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
      moveDropFrameID = activeFrame?.projection == nil && destination?.projection == nil
        && destination?.id != activeFrame?.id ? destination?.id : nil
      var dx = p.x - down.x
      var dy = p.y - down.y
      if event.modifierFlags.contains(.shift) { if abs(dx) > abs(dy) { dy = 0 } else { dx = 0 } }
      var snapped = snap(dx: dx, dy: dy, event: event)
      if event.modifierFlags.contains(.shift) {
        if abs(p.x-down.x) > abs(p.y-down.y) {
          snapped.y = 0; snapLines.removeAll { $0.0 == "y" }
        } else {
          snapped.x = 0; snapLines.removeAll { $0.0 == "x" }
        }
      }
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
    if duplicatedNow, !startSelection.isSubset(of: Set(s.art.elements.map(\.id))) {
      // A rejected write must not leave a phantom copy selected or an active
      // drag that could subsequently overwrite a different accepted edit.
      cancelPointerGesture()
    }
  }
  override func mouseUp(with event: NSEvent) {
    if let token = gestureToken,
      session?.store?.engine.isInteracting(withGeneration: token) != true || gestureFrameID != session?.activeFrameID {
      session?.store?.engine.endInteraction(ifGeneration: token)
      clearPointerGesture()
      return
    }
    if dragMode == "move",dragDidMove,let s = session,let source = activeFrame,
      let destination = frame(atCanvasPoint:canvasPoint(convert(event.locationInWindow,from:nil))),
      destination.id != source.id, source.projection == nil, destination.projection == nil, point(event) != down {
      let offset = Point2(source.rect.minX-destination.rect.minX,source.rect.minY-destination.rect.minY)
      if !s.transferSelection(to:destination.id,offset:offset) {
        if dragDuplicated { cancelPointerGesture(); return }
        s.save(snapshot)
      }
      synchronize()
    }
    if ["node", "incoming", "outgoing"].contains(dragMode), dragDidMove, let s = session {
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
    if dragMode == "pen" { commitPen(closed: false) }
    if dragMode == "create", let s = session, let e = s.primary {
      if e.kind == "text" {
        dragMode = ""
        beginText(e)
      } else if e.width < 1 && e.height < 1 {
        s.update {
          $0.width = 40
          $0.height = 40
        }
      }
      s.tool = .select
    }
    if editingID == nil, let token = gestureToken { session?.store?.engine.endInteraction(ifGeneration: token) }
    clearPointerGesture()
  }
  private func clearPointerGesture() {
    edgeScrollTimer?.invalidate(); edgeScrollTimer = nil; dragEvent = nil
    dragMode = ""
    moveDropFrameID = nil
    marquee = nil
    snapLines = []
    guideID = nil
    gestureToken = nil
    gestureFrameID = nil
    dragDidMove = false
    dragDuplicated = false
    clearHoverFeedback()
    window?.invalidateCursorRects(for: self)
    needsDisplay = true
  }
  func prepareForGroupNavigation() {
    cancelPointerGesture()
    if let token = gestureToken { session?.store?.engine.endInteraction(ifGeneration: token) }
    clearPointerGesture()
  }
  private func edgeScrollOffset(for event: NSEvent, elapsed: TimeInterval) -> CGPoint {
    // Window coordinates are visual points and +Y up. Convert the resulting
    // offset to the Canvas's +Y-down physical coordinates only when applying it.
    let viewport = convert(documentRect(visibleCanvasRect), to: nil)
    return CanvasEdgeScrolling.offset(pointer: event.locationInWindow, viewport: viewport, elapsed: elapsed)
  }
  private func updateEdgeScrolling(with event: NSEvent) {
    guard ["move", "resize", "create", "node", "incoming", "outgoing", "marquee", "node_marquee", "guide", "frame"].contains(dragMode),
      edgeScrollOffset(for: event, elapsed: 1.0/60) != .zero else {
      edgeScrollTimer?.invalidate(); edgeScrollTimer = nil; dragEvent = nil
      return
    }
    dragEvent = event
    guard edgeScrollTimer == nil else { return }
    edgeScrollTime = ProcessInfo.processInfo.systemUptime
    let timer = Timer(timeInterval: 1.0/60, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.continueEdgeScrolling() }
    }
    edgeScrollTimer = timer
    RunLoop.main.add(timer, forMode: .common)
  }
  private func continueEdgeScrolling() {
    guard let event = dragEvent, let scroll = enclosingScrollView, window != nil,
      let token = gestureToken, session?.store?.engine.isInteracting(withGeneration: token) == true,
      gestureFrameID == session?.activeFrameID else {
      edgeScrollTimer?.invalidate(); edgeScrollTimer = nil; dragEvent = nil
      return
    }
    let now = ProcessInfo.processInfo.systemUptime
    let delta = edgeScrollOffset(for: event, elapsed: now-edgeScrollTime)
    edgeScrollTime = now
    guard delta != .zero else { return }
    let region = visibleCanvasRect.offsetBy(dx: delta.x/(ppm*zoom), dy: -delta.y/(ppm*zoom))
    expandCanvas(toInclude: region.insetBy(dx: -80, dy: -80))
    centerViewport(on: region.center, in: scroll)
    viewportCoordinatesChanged()
    mouseDragged(with: event)
  }
  private func cancelPointerGesture() {
    guard !dragMode.isEmpty, let s = session else { return }
    if dragMode == "pan", let scroll = enclosingScrollView {
      centerViewport(on: CGRect(origin: panOrigin, size: visibleCanvasRect.size).center, in: scroll)
    }
    if let token = gestureToken, gestureFrameID == s.activeFrameID,
      s.store?.engine.cancelInteraction(ifGeneration: token) == true {
      let ids = Set(s.art.elements.map(\.id))
      s.choose(gestureSelection.intersection(ids))
      s.nodes = gestureNodes
      s.store?.changed()
    } else if let token = gestureToken {
      s.store?.engine.endInteraction(ifGeneration: token)
    }
    if dragMode == "pen" { pen = []; penID = nil }
    clearPointerGesture()
    synchronize()
  }
  override func scrollWheel(with event: NSEvent) {
    if event.modifierFlags.contains(.command) {
      let precision = event.hasPreciseScrollingDeltas ? 0.01 : 0.06
      setZoom(zoom * exp(max(-1, min(1, event.scrollingDeltaY * precision))),
        atCanvasPoint: canvasPoint(convert(event.locationInWindow, from: nil)))
      return
    }
    if let s = session, let id = s.croppingImageID,
      let e = s.art.elements.first(where:{$0.id == id}), !s.art.isLocked(e),
      let inverse = s.art.worldTransform(e).inverse {
      let p = inverse.apply(.init(point(event)))
      if event.phase == .ended || event.phase == .cancelled || event.momentumPhase == .ended || event.momentumPhase == .cancelled { s.endGesture() }
      if CGRect(x: 0, y: 0, width: e.width, height: e.height).contains(CGPoint(p)) {
        let anchor = Point2(max(0,min(1,p.x/e.width)),max(0,min(1,p.y/e.height)))
        let precision = event.hasPreciseScrollingDeltas ? 0.35 : 1.0
        let delta = max(-24,min(24,event.scrollingDeltaY*precision))
        s.cropImage((e.imageCrop ?? .full).zoomed(exp(-delta*0.008),anchor:anchor))
        if event.phase == .ended || event.phase == .cancelled || event.momentumPhase == .ended || event.momentumPhase == .cancelled { s.endGesture() }
        return
      }
    }
    expandCanvas(toInclude:visibleCanvasRect.insetBy(dx:-180,dy:-180))
    super.scrollWheel(with:event)
    viewportCoordinatesChanged()
  }
  override func magnify(with event: NSEvent) {
    setZoom(zoom * max(0.01, 1 + event.magnification),
      atCanvasPoint: canvasPoint(convert(event.locationInWindow, from: nil)))
  }
  private func droppedURLs(_ sender: NSDraggingInfo) -> [URL] {
    (sender.draggingPasteboard.readObjects(forClasses:[NSURL.self],options:[.urlReadingFileURLsOnly:true]) as? [URL]) ?? []
  }
  override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }
  override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
    refreshFrameSnapshots()
    imageDropUpdates += 1
    let p = convert(sender.draggingLocation,from:nil)
    let physical = canvasPoint(p)
    let old = dropFrameID
    dropFrameID = frame(atCanvasPoint:physical).flatMap { $0.editable ? $0.id : nil }
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
    refreshFrameSnapshots()
    hover = point(event)
    if !pen.isEmpty { needsDisplay = true }
    updateHoverFeedback(with: event)
  }
  override func mouseEntered(with event: NSEvent) { updateHoverFeedback(with: event) }
  override func mouseExited(with event: NSEvent) { clearHoverFeedback() }
  private var effectivePointerFeedback: CanvasPointerFeedback {
    if ["pan", "move", "frame", "image_crop"].contains(dragMode) { return .dragging }
    if dragMode == "resize" { return .resize(handle) }
    if dragMode == "rotate" { return .rotate }
    if space || session?.tool == .hand { return .hand }
    if session?.tool == .text { return .text }
    if let tool = session?.tool, ![.select, .direct].contains(tool) { return .crosshair }
    return pointerFeedback
  }
  private func clearHoverFeedback() {
    let changed = hoveredElementID != nil || hoveredControlPoint != nil || pointerFeedback != .arrow
    hoveredElementID = nil; hoveredFrameID = nil; hoveredControlPoint = nil; hoverOutline = nil
    pointerFeedback = .arrow
    if changed { needsDisplay = true; window?.invalidateCursorRects(for: self) }
  }
  private func updateHoverFeedback(with event: NSEvent) {
    guard dragMode.isEmpty, let s = session, let window, let root = window.contentView else { return }
    refreshFrameSnapshots()
    let hitView = root.hitTest(root.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow)
    // Tracking areas include floating cards and live text views. Feedback belongs
    // only to a pointer that actually reaches the native drawing surface.
    guard hitView === self else { clearHoverFeedback(); return }
    let start = CFAbsoluteTimeGetCurrent()
    defer { lastHoverLookupMS = (CFAbsoluteTimeGetCurrent() - start) * 1000 }
    let previousFeedback = pointerFeedback, previousElement = hoveredElementID
    let previousFrame = hoveredFrameID, previousControl = hoveredControlPoint
    hoveredElementID = nil; hoveredFrameID = nil; hoveredControlPoint = nil
    pointerFeedback = .arrow
    let world = canvasPoint(convert(event.locationInWindow, from: nil)), local = point(event)
    if space || s.tool == .hand { pointerFeedback = .hand }
    else if s.tool == .text { pointerFeedback = .text }
    else if ![.select, .direct].contains(s.tool) { pointerFeedback = .crosshair }
    else if activeFrame?.editable == true, !s.dieline, s.croppingImageID == nil,
      let control = editingControlPoint(at: local) {
      pointerFeedback = .control; hoveredControlPoint = control
    } else if activeFrame?.editable == true, !s.dieline, s.croppingImageID == nil,
      let control = selectionHandle(at: local), let bounds = s.selectionBounds {
      pointerFeedback = control.mode == "rotate" ? .rotate : .resize(control.index)
      hoveredControlPoint = control.mode == "rotate"
        ? CGPoint(x: bounds.center.x, y: bounds.y - 18 / (ppm * zoom)) : handles(bounds)[control.index]
    } else if frames.contains(where: { !$0.isWorkspace && $0.editable &&
      CanvasFrameChrome.headerRect(for: $0, scale: ppm*zoom).contains(world) }) { pointerFeedback = .frame }
    else if !s.dieline, let frame = frame(atCanvasPoint: world), frame.editable {
      let active = frame.id == activeFrame?.id
      let art = active ? s.art : frame.artwork
      let excluded = ArtworkProduction.hiddenIDs(in: frame.artwork, roles: s.hiddenProductionRoles)
      let key = HoverPickKey(frameID: frame.id, scope: active ? s.scopeID : nil,
        mask: active ? s.maskEditing?.maskID : nil, excluded: excluded)
      let picker: ArtworkHitTesting.Picker
      if let cached = hoverPickers[key] { picker = cached }
      else {
        picker = ArtworkHitTesting.Picker(in: art, scope: key.scope, excluding: excluded,
          editingMask: key.mask, renderedArtwork: frame.artwork, outerClip: physicalPickingClip(for: frame))
        hoverPickers[key] = picker
      }
      let p = CGPoint(x: world.x-frame.rect.minX, y: world.y-frame.rect.minY)
      if let element = picker.hit(at: p, tolerance: 3.5/(ppm*zoom))
        ?? (active && !event.modifierFlags.contains(.shift)
          ? externalGroupTarget(at: p, in: art, frame: frame, cached: true) : nil) {
        if active && s.selection.contains(element.id) { pointerFeedback = .move }
        else { hoveredElementID = element.id; hoveredFrameID = frame.id }
      }
    }
    if previousElement != hoveredElementID || previousFrame != hoveredFrameID {
      hoverOutline = nil
      if let frame = frames.first(where: { $0.id == hoveredFrameID }),
        let id = hoveredElementID, let element = frame.artwork.elements.first(where: { $0.id == id }) {
        hoverOutline = element.kind == "group" ? CGPath(rect: CGRect(frame.artwork.bounds(of: element)), transform: nil)
          : VectorGeometry.worldPath(element, in: frame.artwork)
      }
    }
    if previousFeedback != pointerFeedback || previousElement != hoveredElementID
      || previousFrame != hoveredFrameID || previousControl != hoveredControlPoint {
      needsDisplay = true
      window.invalidateCursorRects(for: self)
    }
    effectivePointerFeedback.cursor.set()
  }
  private func drawHoverOutline(in frame: CanvasFrame, context: CGContext, scale: Double) {
    guard dragMode.isEmpty, frame.id == hoveredFrameID, let id = hoveredElementID,
      let path = hoverOutline, let element = frame.artwork.elements.first(where: { $0.id == id }) else { return }
    context.saveGState(); defer { context.restoreGState() }
    if let clip = physicalPickingClip(for: frame) { context.addPath(clip); context.clip() }
    // Respect visible clipping while outlining a nested target.
    var current: ArtworkElement? = element, seen = Set<UUID>()
    while let item = current, seen.insert(item.id).inserted {
      if let maskID = item.clipID, let mask = frame.artwork.elements.first(where: { $0.id == maskID }) {
        context.addPath(VectorGeometry.worldPath(mask, in: frame.artwork))
        context.clip(using: mask.path?.evenOdd == true ? .evenOdd : .winding)
      }
      current = item.parentID.flatMap { parent in frame.artwork.elements.first(where: { $0.id == parent }) }
    }
    context.setStrokeColor((frame.isWorkspace ? Palette.canvasAccentNS : Palette.accentNS).withAlphaComponent(0.65).cgColor)
    context.setLineWidth(1 / scale); context.addPath(path); context.strokePath()
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
  func attachStoryText(_ text:CanvasTextView,frame:CanvasFrame,element:ArtworkElement)->NSView {
    let clip=NativeAffineView(frame:bounds),host=NativeAffineView(frame:bounds)
    clip.clipsToBounds=true;host.clipsToBounds=false;addSubview(clip);clip.addSubview(host);host.addSubview(text)
    positionStoryText(text,host:clip,frame:frame,element:element);return clip
  }
  func positionStoryText(_ text:CanvasTextView,host clip:NSView,frame:CanvasFrame,element:ArtworkElement) {
    guard let clip=clip as? NativeAffineView,let host=clip.subviews.first as? NativeAffineView else{return}
    let transform=frame.artwork.worldTransform(element)
    clip.configure(frame:documentRect(frame.rect),transform:.init())
    host.configure(frame:clip.bounds,transform:.init(a:transform.a,b:transform.b,c:transform.c,d:transform.d,tx:transform.tx*ppm,ty:transform.ty*ppm))
    text.setFrameSize(.init(width:element.width*ppm,height:element.height*ppm))
    var hidden=element.hidden==true,parent=element.parentID,visited=Set<UUID>()
    while let id=parent,visited.insert(id).inserted,let ancestor=frame.artwork.elements.first(where:{$0.id==id}) {hidden = hidden || ancestor.hidden==true;parent=ancestor.parentID}
    hidden = hidden || ArtworkProduction.hiddenIDs(in:frame.artwork,roles:session?.hiddenProductionRoles ?? []).contains(element.id)
    clip.isHidden=hidden
  }
  func activateStoryText(_ text:CanvasTextView,frame:StoryFrameID?) {
    textView=text;editingID=frame?.elementID
    configureCharacterPositionAction(text)
    if let frame {session?.objectID=frame.objectID;session?.selection=[frame.elementID]}
    session?.editingText=true;session?.characterRange=TextCase.source(text.attributedString()).sourceRange(text.selectedRange())
    needsDisplay=true
  }
  func beginStoryText(_ element:ArtworkElement) {
    guard let session,let project=session.store?.project,let id=element.storyFrame?.storyID,let context=project.resolvedTextStory(id),let owner=session.objectID else{return}
    let frame=element.storyFrame?.frame ?? StoryFrameID(objectID:owner,elementID:element.id)
    if let publicationEditor,publicationEditor.storyID==id {publicationEditor.focus(frame);return}
    finishText();session.store?.activateDesignSurface(.artwork);session.dieline=false
    let editor=PublicationEditingController(canvas:self,session:session,context:context)
    publicationEditor=editor;session.editingText=true;editor.focus(frame);needsDisplay=true
  }
  func showStorySource() {publicationEditor?.showOverflow()}
  func openStorySource(_ id:UUID) {
    if let publicationEditor,publicationEditor.storyID==id {publicationEditor.showOverflow();return}
    guard let session,let context=session.store?.project?.resolvedTextStory(id) else{return}
    finishText();let editor=PublicationEditingController(canvas:self,session:session,context:context)
    publicationEditor=editor;session.editingText=true;editor.showOverflow()
  }
  func revealStoryPage(_ id:UUID) {
    synchronize()
    if let frame=frames.first(where:{$0.id==id}) {_ = scrollToVisible(documentRect(frame.rect).insetBy(dx:-18,dy:-18))}
  }
  func beginText(_ e: ArtworkElement) {
    guard let s = session, activeFrame != nil else { return }
    if e.storyFrame != nil {beginStoryText(e);return}
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
    if let item=e.listItems?.first(where:{$0.location==e.text.utf16.count}),e.text.isEmpty || e.text.last?.isNewline == true {
      tv.restoreListTyping(item,base:TypographyEngine.attributes(e.typography ?? .init(),size:e.fontSize,color:e.color,millimeters:false))
    }
    if let storage = tv.textStorage {
      TypographyEngine.refreshNativeMetadata(TypographyEngine.spans(from: TextCase.source(storage).text, fallback: e.typography ?? .init()), in: storage)
    }
    publishedInput = NSAttributedString(attributedString: tv.attributedString())
    originalTextInput = publishedInput
    tv.delegate = self
    tv.setAccessibilityLabel("Edit text on artwork canvas")
    textView = tv
    configureCharacterPositionAction(tv)
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
    endNumericTextInteraction()
    if let editor=publicationEditor {
      editor.finish();publicationEditor=nil;textView=nil;editingID=nil;publishedText=nil;publishedInput=nil
      originalTextInput=nil;originalTextElement=nil;session?.editingText=false;needsDisplay=true;return
    }
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
  private func positionTextHost(_ element: ArtworkElement, layoutOnly: Bool = false) {
    guard let s = session, let f = activeFrame, let host = textHost, let clip = textClip else {
      return
    }
    let element=element.inheritingLanguage(s.art.language)
    let world = s.art.worldTransform(element)
    if !layoutOnly, let tv = textView as? CanvasTextView {
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
    if let publicationEditor {publicationEditor.textDidChange(notification);return}
    guard let s = session, let id = editingID, let tv = textView,
      let i = s.art.elements.firstIndex(where: { $0.id == id })
    else { return }
    if tv.hasMarkedText() {return}
    let source=TextCase.source(tv.attributedString()).text
    let listItems=PublicationLists.items(from:source,trailingAttributes:tv.typingAttributes)
    if let publishedInput, GlyphEngine.nativeEqual(tv.attributedString(),publishedInput),listItems==s.art.elements[i].listItems { return }
    publishedInput = NSAttributedString(attributedString: tv.attributedString())
    var value = s.art
    if let originalTextInput, let originalTextElement,
      GlyphEngine.nativeEqual(tv.attributedString(),originalTextInput),listItems==originalTextElement.listItems {
      value.elements[i] = originalTextElement
      publishedText = s.colored(originalTextElement)
      s.save(value)
      positionTextHost(originalTextElement)
      return
    }
    var e = value.elements[i]
    e.text = source.string
    e.listItems=listItems
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
      let size = TypographyEngine.measured(e.inheritingLanguage(s.art.language))
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
    let resolved=s.colored(e)
    if let storage=tv.textStorage,resolved.listItems?.isEmpty == false {
      PublicationLists.apply(resolved.listItems!,to:storage)
      if let item=resolved.listItems?.first(where:{$0.location==e.text.utf16.count}),e.text.isEmpty || e.text.last?.isNewline == true {
        (tv as? CanvasTextView)?.restoreListTyping(item)
      }
      publishedInput=NSAttributedString(attributedString:tv.attributedString())
    }
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
  func applyList(_ arguments:[String:Any])->Bool {
    guard let text=textView as? CanvasTextView else{return false}
    do {try text.applyParagraphList(arguments)}catch{session?.store?.error=error.localizedDescription}
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
      var type=changed.typography;type.inheritedLanguage=raw[LanguageHyphenation.inheritedLanguageKey] as? String
      var result=TypographyEngine.attributes(type, size: changed.fontSize, color: changed.color,
        millimeters: false, swatchID: changed.swatchID, textStyle: changed.textStyle, paragraphStyle: changed.paragraphStyle)
      result[TextCase.sourceKey]=raw[TextCase.sourceKey]
      result[GlyphEngine.overrideKey]=raw[GlyphEngine.overrideKey]
      result[PublicationLists.key]=raw[PublicationLists.key]
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
  @discardableResult func beginNumericTextInteraction()->UUID? {
    endNumericTextInteraction()
    guard let manager=textView?.undoManager else{return nil}
    let token=UUID();manager.beginUndoGrouping();numericTextUndoManager=manager;numericTextUndoToken=token;return token
  }
  func endNumericTextInteraction(ifToken token:UUID?) {
    guard let token,numericTextUndoToken==token else{return};endNumericTextInteraction()
  }
  func endNumericTextInteraction() {
    let manager=numericTextUndoManager;numericTextUndoManager=nil;numericTextUndoToken=nil
    if let manager,manager.groupingLevel>0 {manager.endUndoGrouping()}
  }
  private func configureCharacterPositionAction(_ view:CanvasTextView) {
    view.onCharacterPosition={ [weak self,weak view] value in
      guard let self,let view,self.textView === view else{return}
      do {_ = try self.applyCharacterPosition(value)}catch{self.session?.store?.error=error.localizedDescription}
    }
  }
  func smallCapInspection()->[SmallCapsTypography.Report]? {
    guard let tv=textView else{return nil}
    let range=tv.selectedRange();return SmallCapsTypography.reports(in:tv.attributedString(),range:range.length>0 ? range:nil)
  }
  func characterPositionInspection()->[CharacterTypography.Resolution]? {
    guard let tv=textView else{return nil}
    let range=tv.selectedRange()
    guard range.length>0 else {
      if range.location<tv.attributedString().length,let record=CharacterTypography.resolution(tv.attributedString().attributes(at:range.location,effectiveRange:nil)){return[record]}
      return []
    }
    return CharacterTypography.records(in:tv.attributedString()).filter{NSIntersectionRange($0.0,range).length>0}.map(\.1)
  }
  func applyCharacterPosition(_ value:CharacterPosition?)throws->Bool {
    guard let tv=textView else{return false}
    guard !hasMarkedTextInput else{throw FormError.invalid("Finish marked text input before changing character position.")}
    let range=GlyphEngine.expandedDisplayRange(tv.selectedRange(),in:tv.attributedString()),mapping=TextCase.source(tv.attributedString()),sourceRange=mapping.sourceRange(range)
    guard CharacterPositionCommands.isCompleteRange(sourceRange,in:mapping.text.string,allowCaret:true) else{throw FormError.invalid("Character position needs complete graphemes; the selection was preserved.")}
    return applyTextStyle{$0.characterPosition=value}
  }
  func opticalSizingInspection()->[Typography]? {
    guard let tv=textView else{return nil}
    let range=tv.selectedRange(),fallback=session?.primary?.typography ?? .init()
    if range.length==0 {return [textInspection()?.typography ?? fallback]}
    var result:[Typography]=[]
    tv.attributedString().enumerateAttributes(in:range) {raw,_,_ in
      if let type=TypographyEngine.spans(from:NSAttributedString(string:"A",attributes:raw),fallback:fallback).first?.typography {result.append(type)}
    }
    return result
  }
  func applyOpticalSizing(_ value:OpticalSizing?)throws->Bool {
    guard let tv=textView else{return false}
    guard !hasMarkedTextInput else{throw FormError.invalid("Finish the current text input before changing optical sizing.")}
    let range=GlyphEngine.expandedDisplayRange(tv.selectedRange(),in:tv.attributedString()),fallback=session?.primary?.typography ?? .init()
    if range.length==0 {
      if let type=textInspection()?.typography {try OpticalTypography.validateEdit(value,fontName:type.fontName)}
    }else {
      var failure:Error?
      tv.attributedString().enumerateAttributes(in:range) {raw,_,stop in
        do {
          let type=TypographyEngine.spans(from:NSAttributedString(string:"A",attributes:raw),fallback:fallback).first!.typography
          try OpticalTypography.validateEdit(value,fontName:type.fontName)
        }catch {failure=error;stop.pointee=true}
      }
      if let failure {throw failure}
    }
    return applyTextStyle{$0.setOpticalSizing(value)}
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
      t.inheritedLanguage=tv.typingAttributes[LanguageHyphenation.inheritedLanguageKey] as? String
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
        t.inheritedLanguage=attributes[LanguageHyphenation.inheritedLanguageKey] as? String
        var changed = run; changed.typography = t
        changed = TextStyleCommands.recording(changed, from: run)
        var attrs=TypographyEngine.attributes(t, size: run.fontSize, color: run.color, millimeters: false,
          swatchID: run.swatchID, textStyle: changed.textStyle, paragraphStyle: changed.paragraphStyle)
        attrs[TextCase.sourceKey]=attributes[TextCase.sourceKey]
        attrs[GlyphEngine.overrideKey]=attributes[GlyphEngine.overrideKey]
        attrs[PublicationLists.key]=attributes[PublicationLists.key]
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
    if opticalSizingInspection()?.contains(where:{$0.opticalSizing != nil || $0.characterPosition != nil})==true {return applyOpticalTextSize(size)}
    let range = tv.selectedRange()
    let font =
      (range.location < (tv.textStorage?.length ?? 0)
      ? tv.textStorage?.attribute(.font, at: range.location, effectiveRange: nil)
      : tv.typingAttributes[.font]) as? NSFont ?? .systemFont(ofSize: size)
    return changeText([.font: NSFont(descriptor: font.fontDescriptor, size: size) ?? font])
  }
  private func applyOpticalTextSize(_ size:Double)->Bool {
    guard let tv=textView else{return false}
    let range=GlyphEngine.expandedDisplayRange(tv.selectedRange(),in:tv.attributedString()),fallback=session?.primary?.typography ?? .init()
    let mapping=TextCase.source(tv.attributedString())
    func resized(_ raw:[NSAttributedString.Key:Any],at location:Int)->[NSAttributedString.Key:Any] {
      let run=TypographyEngine.spans(from:NSAttributedString(string:"A",attributes:raw),fallback:fallback,utf16Offset:mapping.sourceRange(.init(location:location,length:0)).location)[0]
      var changed=run;changed.fontSize=size;changed=TextStyleCommands.recording(changed,from:run)
      var type=changed.typography;type.inheritedLanguage=raw[LanguageHyphenation.inheritedLanguageKey] as? String
      var attrs=TypographyEngine.attributes(type,size:size,color:changed.color,millimeters:false,swatchID:changed.swatchID,textStyle:changed.textStyle,paragraphStyle:changed.paragraphStyle)
      if type.opticalSizing==nil,type.characterPosition==nil,let old=raw[.font] as? NSFont {attrs[.font]=NSFont(descriptor:old.fontDescriptor,size:size) ?? old}
      for key in [TextCase.sourceKey,GlyphEngine.overrideKey,PublicationLists.key] {attrs[key]=raw[key]}
      return attrs
    }
    tv.undoManager?.beginUndoGrouping();defer{tv.undoManager?.endUndoGrouping()}
    if range.length==0 {tv.typingAttributes=resized(tv.typingAttributes,at:range.location);session?.objectWillChange.send();return true}
    guard tv.shouldChangeText(in:range,replacementString:nil) else{return true}
    var replacements:[(NSRange,[NSAttributedString.Key:Any])]=[]
    tv.attributedString().enumerateAttributes(in:range) {raw,part,_ in replacements.append((part,resized(raw,at:part.location)))}
    tv.textStorage?.beginEditing();for (part,attrs) in replacements {tv.textStorage?.setAttributes(attrs,range:part)}
    if let storage=tv.textStorage {TypographyEngine.updateSpacing(storage,range:range)}
    tv.textStorage?.endEditing();tv.didChangeText();return true
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
    session?.cutArtwork()
  }
  override func selectAll(_ sender: Any?) {
    session?.selectAllInActiveFrame()
  }
  override func keyDown(with event: NSEvent) {
    guard let s = session else { return }
    let command = event.modifierFlags.contains(.command)
    if event.keyCode == 53, !dragMode.isEmpty {
      cancelPointerGesture()
      return
    }
    if s.croppingImageID != nil, [36,53].contains(event.keyCode) {
      s.croppingImageID = nil; s.endGesture(); needsDisplay = true; return
    }
    if event.keyCode == 49 {
      if !space {
        space = true
        clearHoverFeedback()
        window?.invalidateCursorRects(for: self)
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
        s.leaveGroup()
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
      clearHoverFeedback()
      window?.invalidateCursorRects(for: self)
    } else {
      super.keyUp(with: event)
    }
  }
  override func resignFirstResponder() -> Bool {
    if !dragMode.isEmpty { cancelPointerGesture() }
    if session?.editingText != true { session?.endGesture() }
    if space {
      space = false
      window?.invalidateCursorRects(for: self)
    }
    return super.resignFirstResponder()
  }
  override func menu(for event: NSEvent) -> NSMenu? {
    makeCanvasContextMenu(for: event)
  }
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
