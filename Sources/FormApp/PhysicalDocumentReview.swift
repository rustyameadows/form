import AppKit
import Combine
import PDFKit
import SwiftUI

/// Session-only navigation. The bounded cache retains scalar positions, never projects or PDFs.
struct PhysicalDocumentViewport: Equatable {
  var fitted: Bool
  var scale: CGFloat
  var page: Int
  var center: CGPoint
}

@MainActor final class PhysicalDocumentController: @preconcurrency ObservableObject {
  let objectWillChange = ObservableObjectPublisher()
  private var notificationPending = false
  // PDFKit can notify synchronously during an NSViewRepresentable layout/update.
  // Coalesce only the SwiftUI notification onto the next turn, keeping native state immediate.
  private func notify() {
    guard !notificationPending else { return }
    notificationPending = true
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.notificationPending = false
      self.objectWillChange.send()
    }
  }
  private(set) var scale: CGFloat = 1
  private(set) var fitted = true
  private(set) var page = 1
  private(set) var pages = 0
  private(set) var error = ""
  private(set) var documentLoads = 0
  private(set) var identifier: String?
  weak var view: PhysicalPDFView?
  private var bytes: Data?
  private var scaleObserver: NSObjectProtocol?
  private var pageObserver: NSObjectProtocol?
  private var updating = false
  private static var viewports: [String: PhysicalDocumentViewport] = [:]
  private static var recent: [String] = []
  static let maximumCachedViewports = 24
  static var cachedViewportCount: Int { viewports.count }

  static func key(project: UUID?, object: UUID?, kind: String) -> String {
    "\(project?.uuidString ?? "none")/\(object?.uuidString ?? "none")/\(kind)"
  }
  func attach(_ view: PhysicalPDFView) {
    self.view = view
    view.controller = self
    scaleObserver = NotificationCenter.default.addObserver(
      forName: .PDFViewScaleChanged, object: view, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.publish() }
    }
    pageObserver = NotificationCenter.default.addObserver(
      forName: .PDFViewPageChanged, object: view, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.publish() }
    }
  }
  func detach() {
    remember()
    if let scaleObserver { NotificationCenter.default.removeObserver(scaleObserver) }
    if let pageObserver { NotificationCenter.default.removeObserver(pageObserver) }
    scaleObserver = nil
    pageObserver = nil
    view?.cancelPan()
    view?.controller = nil
    view?.document = nil
    view = nil
    bytes = nil
  }
  func load(_ data: Data, identifier: String) {
    guard let view else { return }
    guard self.identifier != identifier || bytes != data else { return }
    let prior = self.identifier == identifier ? capture() : nil
    remember()
    view.cancelPan()
    self.identifier = identifier
    bytes = data
    updating = true
    guard let document = PDFDocument(data: data), document.pageCount > 0 else {
      view.document = nil
      updating = false
      pages = 0
      error = "This proof could not be read as a PDF document."
      notify()
      return
    }
    if !error.isEmpty {
      error = ""
      notify()
    }
    documentLoads += 1
    view.document = document
    view.layoutDocumentView()
    restore(
      prior ?? Self.viewports[identifier]
        ?? .init(fitted: true, scale: 1, page: 0, center: .init(x: 0.5, y: 0.5)))
    updating = false
    publish()
  }
  func capture() -> PhysicalDocumentViewport? {
    guard let view, let document = view.document, let current = view.currentPage else { return nil }
    let clip = view.documentView?.enclosingScrollView?.contentView
    let center =
      clip.map { view.convert(.init(x: $0.bounds.midX, y: $0.bounds.midY), from: $0) }
      ?? CGPoint(x: view.bounds.midX, y: view.bounds.midY)
    let point = view.convert(center, to: current)
    let box = current.bounds(for: .mediaBox)
    guard box.width > 0, box.height > 0 else { return nil }
    return .init(
      fitted: view.autoScales, scale: view.scaleFactor, page: document.index(for: current),
      center: .init(x: (point.x - box.minX) / box.width, y: (point.y - box.minY) / box.height))
  }
  func restore(_ state: PhysicalDocumentViewport) {
    guard let view, let document = view.document,
      let target = document.page(at: min(max(0, state.page), document.pageCount - 1))
    else { return }
    view.cancelPan()
    view.go(to: target)
    if state.fitted {
      fit()
      return
    }
    view.autoScales = false
    view.scaleFactor = min(view.maxScaleFactor, max(view.minScaleFactor, state.scale))
    view.layoutDocumentView()
    center(state.center, on: target)
    publish()
  }
  private func center(_ normalized: CGPoint, on page: PDFPage) {
    guard let view, let documentView = view.documentView,
      let scroll = documentView.enclosingScrollView
    else { return }
    let box = page.bounds(for: .mediaBox)
    let point = view.convert(
      .init(x: box.minX + normalized.x * box.width, y: box.minY + normalized.y * box.height),
      from: page)
    let location = documentView.convert(point, from: view)
    let clip = scroll.contentView
    var bounds = clip.bounds
    bounds.origin = .init(x: location.x - bounds.width / 2, y: location.y - bounds.height / 2)
    clip.scroll(to: clip.constrainBoundsRect(bounds).origin)
    scroll.reflectScrolledClipView(clip)
  }
  func fit() {
    guard let view, view.document != nil else { return }
    view.cancelPan()
    view.autoScales = true
    view.layoutDocumentView()
    publish()
  }
  func zoom(to scale: CGFloat) {
    guard scale.isFinite, scale > 0, var state = capture() else { return }
    state.fitted = false
    state.scale = scale
    restore(state)
  }
  func zoom(by multiplier: CGFloat) { zoom(to: scale * multiplier) }
  func goPage(_ delta: Int) {
    guard let view, let document = view.document,
      let target = document.page(at: min(max(0, page - 1 + delta), pages - 1))
    else { return }
    view.cancelPan()
    view.go(to: target)
    publish()
  }
  func remember() {
    guard let identifier, let state = capture() else { return }
    Self.viewports[identifier] = state
    Self.recent.removeAll { $0 == identifier }
    Self.recent.append(identifier)
    while Self.recent.count > Self.maximumCachedViewports {
      Self.viewports.removeValue(forKey: Self.recent.removeFirst())
    }
  }
  func publish() {
    guard !updating, let view else { return }
    let newScale = view.scaleFactor
    let newFitted = view.autoScales
    let newPages = view.document?.pageCount ?? 0
    let newPage = view.currentPage.flatMap { view.document?.index(for: $0) }.map { $0 + 1 } ?? 1
    guard scale != newScale || fitted != newFitted || pages != newPages || page != newPage else {
      return
    }
    if scale != newScale { view.cancelPan() }
    scale = newScale
    fitted = newFitted
    pages = newPages
    page = newPage
    notify()
  }

  deinit {
    if let scaleObserver { NotificationCenter.default.removeObserver(scaleObserver) }
    if let pageObserver { NotificationCenter.default.removeObserver(pageObserver) }
  }
}

/// One clear interaction for a technical proof: primary drag pans; PDFKit handles scroll/pinch.
@MainActor final class PhysicalPDFView: PDFView {
  weak var controller: PhysicalDocumentController?
  private var panStart: (window: CGPoint, bounds: CGRect)?
  private weak var panClip: NSClipView?
  private var resizing = false
  private var resignObserver: NSObjectProtocol?
  override init(frame: NSRect) {
    super.init(frame: frame)
    displayMode = .singlePage
    displayBox = .mediaBox
    displaysPageBreaks = true
    backgroundColor = NSColor(hex: "#D9D8D2")
    minScaleFactor = 0.01
    maxScaleFactor = 16
    autoScales = true
    setAccessibilityLabel("Physical vector document preview")
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    cancelPan()
    if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
    resignObserver = window.map {
      NotificationCenter.default.addObserver(
        forName: NSWindow.didResignKeyNotification, object: $0, queue: .main
      ) { [weak self] _ in MainActor.assumeIsolated { self?.cancelPan() } }
    }
  }
  override func setFrameSize(_ newSize: NSSize) {
    guard newSize != frame.size else { return }
    guard !resizing else {
      super.setFrameSize(newSize)
      return
    }
    resizing = true
    let state = controller?.capture()
    cancelPan()
    super.setFrameSize(newSize)
    layoutDocumentView()
    if let state { controller?.restore(state) }
    resizing = false
  }
  override func mouseDown(with event: NSEvent) {
    cancelPan()
    guard let clip = documentView?.enclosingScrollView?.contentView else { return }
    window?.makeFirstResponder(self)
    panClip = clip
    panStart = (event.locationInWindow, clip.bounds)
    NSCursor.closedHand.set()
  }
  override func mouseDragged(with event: NSEvent) {
    guard let start = panStart, let clip = panClip, let scroll = clip.enclosingScrollView else {
      return
    }
    var bounds = start.bounds
    bounds.origin.x -= event.locationInWindow.x - start.window.x
    let dy = event.locationInWindow.y - start.window.y
    bounds.origin.y += clip.isFlipped ? dy : -dy
    clip.scroll(to: clip.constrainBoundsRect(bounds).origin)
    scroll.reflectScrolledClipView(clip)
  }
  override func mouseUp(with event: NSEvent) {
    cancelPan()
    controller?.remember()
  }
  override func cancelOperation(_ sender: Any?) {
    if let start = panStart, let clip = panClip {
      clip.scroll(to: clip.constrainBoundsRect(start.bounds).origin)
      clip.enclosingScrollView?.reflectScrolledClipView(clip)
    }
    cancelPan()
  }
  func cancelPan() {
    let wasDragging = panStart != nil
    panStart = nil
    panClip = nil
    if wasDragging { NSCursor.openHand.set() }
  }
  deinit { if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) } }
}

struct PhysicalDocumentCanvas: NSViewRepresentable {
  @ObservedObject var controller: PhysicalDocumentController
  let data: Data
  let identifier: String
  func makeNSView(context: Context) -> PhysicalPDFView {
    let view = PhysicalPDFView(frame: .zero)
    controller.attach(view)
    controller.load(data, identifier: identifier)
    return view
  }
  func updateNSView(_ view: PhysicalPDFView, context: Context) {
    controller.load(data, identifier: identifier)
  }
  static func dismantleNSView(_ view: PhysicalPDFView, coordinator: ()) {
    view.controller?.detach()
  }
}

struct PhysicalDocumentNavigation: View {
  @ObservedObject var controller: PhysicalDocumentController
  var body: some View {
    HStack(spacing: 10) {
      Button {
        controller.zoom(by: 1 / 1.25)
      } label: {
        Image(systemName: "minus.magnifyingglass")
      }.accessibilityLabel("Zoom out")
      Menu {
        ForEach([25, 50, 100, 200, 400, 800, 1600], id: \.self) { value in
          Button("\(value)%") { controller.zoom(to: CGFloat(value) / 100) }
        }
      } label: {
        Text(String(format: "%.0f%%", controller.scale * 100)).monospacedDigit().frame(minWidth: 48)
      }.accessibilityLabel("Document zoom").accessibilityValue(String(format: "%.0f%%", controller.scale * 100))
      Button {
        controller.zoom(by: 1.25)
      } label: {
        Image(systemName: "plus.magnifyingglass")
      }.accessibilityLabel("Zoom in")
      Button("Fit page") { controller.fit() }.accessibilityLabel("Fit physical page")
      if controller.pages > 1 {
        Divider().frame(height: 16)
        Button {
          controller.goPage(-1)
        } label: {
          Image(systemName: "chevron.left")
        }.disabled(controller.page <= 1).accessibilityLabel("Previous proof page")
        Text("\(controller.page) / \(controller.pages)").monospacedDigit()
        Button {
          controller.goPage(1)
        } label: {
          Image(systemName: "chevron.right")
        }.disabled(controller.page >= controller.pages).accessibilityLabel("Next proof page")
      }
      Spacer()
      Text("Drag or scroll to pan · Pinch to zoom").foregroundStyle(Palette.secondary)
    }.font(.system(size: 10)).disabled(controller.pages == 0)
  }
}
