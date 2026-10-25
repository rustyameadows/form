import AppKit
import PDFKit
import SwiftUI
import XCTest

@testable import FormApp
@testable import FormCore
@testable import FormGraphics

@MainActor final class PhysicalDocumentReviewTests: XCTestCase {
  @MainActor private struct Fixture {
    let window: NSWindow
    let view: PhysicalPDFView
    let controller: PhysicalDocumentController
    func close() {
      controller.detach()
      window.close()
    }
  }
  private func pdf(
    width: CGFloat = 1200, height: CGFloat = 1600, pages: Int = 1, detail: Bool = false
  ) throws -> Data {
    var box = CGRect(x: 0, y: 0, width: width, height: height)
    let data = NSMutableData()
    let context = try XCTUnwrap(
      CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &box, nil))
    for _ in 0..<pages {
      context.beginPDFPage(nil)
      context.setFillColor(NSColor.white.cgColor)
      context.fill(box)
      context.setStrokeColor(NSColor.black.cgColor)
      context.setLineWidth(detail ? 0.15 : 1)
      context.stroke(CGRect(x: 80, y: 80, width: width - 160, height: height - 160))
      if detail {
        for i in 0..<100 {
          let y = CGFloat(i) * 0.8 + height / 2
          context.move(to: .init(x: width / 2 - 20, y: y))
          context.addLine(to: .init(x: width / 2 + 20, y: y))
          context.strokePath()
        }
      }
      context.endPDFPage()
    }
    context.closePDF()
    return data as Data
  }
  private func fixture(_ data: Data, id: String = UUID().uuidString) -> Fixture {
    _ = NSApplication.shared
    let window = NSWindow(
      contentRect: .init(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let view = PhysicalPDFView(frame: .init(x: 0, y: 0, width: 800, height: 600))
    window.contentView = view
    let controller = PhysicalDocumentController()
    controller.attach(view)
    controller.load(data, identifier: id)
    window.contentView?.layoutSubtreeIfNeeded()
    view.layoutDocumentView()
    return .init(window: window, view: view, controller: controller)
  }
  private func event(_ type: NSEvent.EventType, _ point: CGPoint, in f: Fixture) -> NSEvent {
    NSEvent.mouseEvent(
      with: type, location: point, modifierFlags: [], timestamp: 0,
      windowNumber: f.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
  }
  private func assertCenter(
    _ a: PhysicalDocumentViewport?, _ b: PhysicalDocumentViewport?, accuracy: Double = 0.004,
    file: StaticString = #filePath, line: UInt = #line
  ) throws {
    let a = try XCTUnwrap(a, file: file, line: line)
    let b = try XCTUnwrap(b, file: file, line: line)
    XCTAssertEqual(a.center.x, b.center.x, accuracy: accuracy, file: file, line: line)
    XCTAssertEqual(a.center.y, b.center.y, accuracy: accuracy, file: file, line: line)
  }
  func testInitialFitThenExplicitZoomAndFitUseRealPDFKitPageBounds() throws {
    let f = fixture(try pdf())
    defer { f.close() }
    XCTAssertEqual(f.controller.pages, 1)
    XCTAssertTrue(f.view.autoScales)
    let page = try XCTUnwrap(f.view.currentPage)
    let rect = f.view.convert(page.bounds(for: .mediaBox), from: page)
    XCTAssertLessThanOrEqual(rect.width, f.view.bounds.width + 2)
    XCTAssertLessThanOrEqual(rect.height, f.view.bounds.height + 2)
    f.controller.zoom(to: 4)
    XCTAssertFalse(f.view.autoScales)
    XCTAssertEqual(f.view.scaleFactor, 4, accuracy: 0.0001)
    f.controller.fit()
    XCTAssertTrue(f.view.autoScales)
    XCTAssertLessThan(f.view.scaleFactor, 1)
    f.view.setFrameSize(.init(width: 1000, height: 300))
    let resized = f.view.convert(page.bounds(for: .mediaBox), from: page)
    XCTAssertTrue(f.view.autoScales)
    XCTAssertLessThanOrEqual(resized.height, 302)
    XCTAssertLessThanOrEqual(resized.width, 1002)
  }
  func testActualPrimaryMouseDragMovesPDFInAllFourDirectionsAndCancelledDragRestores() throws {
    let f = fixture(try pdf())
    defer { f.close() }
    f.controller.zoom(to: 2)
    for delta in [
      CGPoint(x: 60, y: 0), .init(x: -60, y: 0), .init(x: 0, y: 60), .init(x: 0, y: -60),
    ] {
      f.controller.restore(.init(fitted: false, scale: 2, page: 0, center: .init(x: 0.5, y: 0.5)))
      let clip = try XCTUnwrap(f.view.documentView?.enclosingScrollView?.contentView)
      let start = clip.bounds.origin
      let anchor = CGPoint(x: 400, y: 300)
      f.view.mouseDown(with: event(.leftMouseDown, anchor, in: f))
      f.view.mouseDragged(
        with: event(.leftMouseDragged, .init(x: anchor.x + delta.x, y: anchor.y + delta.y), in: f))
      XCTAssertEqual(clip.bounds.origin.x - start.x, -delta.x, accuracy: 0.1)
      XCTAssertEqual(
        clip.bounds.origin.y - start.y, clip.isFlipped ? delta.y : -delta.y, accuracy: 0.1)
      f.view.cancelOperation(nil)
      XCTAssertEqual(clip.bounds.origin.x, start.x, accuracy: 0.1)
      XCTAssertEqual(clip.bounds.origin.y, start.y, accuracy: 0.1)
      f.view.mouseDragged(with: event(.leftMouseDragged, .init(x: 900, y: 900), in: f))
      XCTAssertEqual(clip.bounds.origin, start)
    }
    XCTAssertTrue(f.view.acceptsFirstMouse(for: nil))
  }
  func testReleaseContentReplacementAndResizeRejectStaleMouseDrags() throws {
    let f = fixture(try pdf())
    defer { f.close() }
    f.controller.zoom(to: 2)
    let anchor = CGPoint(x: 350, y: 280)
    f.view.mouseDown(with: event(.leftMouseDown, anchor, in: f))
    f.view.mouseUp(with: event(.leftMouseUp, anchor, in: f))
    let first = f.controller.capture()
    f.view.mouseDragged(with: event(.leftMouseDragged, .init(x: 700, y: 500), in: f))
    try assertCenter(first, f.controller.capture())
    f.view.mouseDown(with: event(.leftMouseDown, anchor, in: f))
    f.controller.load(try pdf(detail: true), identifier: f.controller.identifier!)
    let replacement = f.controller.capture()
    f.view.mouseDragged(with: event(.leftMouseDragged, .init(x: 700, y: 500), in: f))
    try assertCenter(replacement, f.controller.capture())
    f.view.mouseDown(with: event(.leftMouseDown, anchor, in: f))
    f.view.setFrameSize(.init(width: 1000, height: 700))
    let resized = f.controller.capture()
    f.view.mouseDragged(with: event(.leftMouseDragged, .init(x: 700, y: 500), in: f))
    try assertCenter(resized, f.controller.capture())
    f.view.mouseDown(with: event(.leftMouseDown, anchor, in: f))
    f.controller.zoom(to: 3)
    let zoomed = f.controller.capture()
    f.view.mouseDragged(with: event(.leftMouseDragged, .init(x: 700, y: 500), in: f))
    try assertCenter(zoomed, f.controller.capture())
  }
  func testSourceRefreshAndResizePreserveZoomAndPhysicalLocation() throws {
    let id = UUID().uuidString
    let f = fixture(try pdf(), id: id)
    defer { f.close() }
    f.controller.restore(.init(fitted: false, scale: 3, page: 0, center: .init(x: 0.62, y: 0.38)))
    let before = f.controller.capture()
    f.controller.load(try pdf(detail: true), identifier: id)
    XCTAssertEqual(f.view.scaleFactor, 3, accuracy: 0.0001)
    try assertCenter(before, f.controller.capture())
    f.view.setFrameSize(.init(width: 1000, height: 720))
    XCTAssertEqual(f.view.scaleFactor, 3, accuracy: 0.0001)
    try assertCenter(before, f.controller.capture())
    let loads = f.controller.documentLoads
    let unchanged = try pdf(detail: true)
    f.controller.load(unchanged, identifier: id)
    let afterFirst = f.controller.documentLoads
    f.controller.load(unchanged, identifier: id)
    XCTAssertEqual(f.controller.documentLoads, afterFirst)
    XCTAssertGreaterThanOrEqual(afterFirst, loads)
  }
  func testSessionOnlyViewportCacheKeysProjectObjectAndKindAndIsBounded() throws {
    let data = try pdf()
    let project = UUID()
    let object = UUID()
    let id = PhysicalDocumentController.key(
      project: project, object: object, kind: "sewing-pattern")
    let f = fixture(data, id: id)
    f.controller.restore(.init(fitted: false, scale: 2, page: 0, center: .init(x: 0.6, y: 0.4)))
    let before = f.controller.capture()
    f.close()
    let same = fixture(data, id: id)
    defer { same.close() }
    XCTAssertFalse(same.view.autoScales)
    try assertCenter(before, same.controller.capture())
    let other = fixture(
      data,
      id: PhysicalDocumentController.key(project: project, object: object, kind: "cutting-layout"))
    XCTAssertTrue(other.view.autoScales)
    other.close()
    for i in 0..<(PhysicalDocumentController.maximumCachedViewports + 3) {
      same.controller.load(data, identifier: "\(UUID().uuidString)/\(i)/test")
    }
    same.controller.remember()
    XCTAssertLessThanOrEqual(
      PhysicalDocumentController.cachedViewportCount,
      PhysicalDocumentController.maximumCachedViewports)
  }
  func testPageNavigationAndInvalidDocumentNeverLeaveAStaleProof() throws {
    let f = fixture(try pdf(pages: 3))
    defer { f.close() }
    f.controller.zoom(to: 1.5)
    f.controller.goPage(1)
    XCTAssertEqual(f.controller.page, 2)
    XCTAssertEqual(f.view.scaleFactor, 1.5, accuracy: 0.001)
    f.controller.goPage(50)
    XCTAssertEqual(f.controller.page, 3)
    f.controller.load(Data("invalid".utf8), identifier: UUID().uuidString)
    XCTAssertNil(f.view.document)
    XCTAssertEqual(f.controller.pages, 0)
    XCTAssertFalse(f.controller.error.isEmpty)
  }
  func testRealCurvedSewingPDFRemainsPhysicalVectorAtIndependentExportDPI() throws {
    let template = try SewingPatternTemplates.roundedPouch()
    let original = template.artwork
    let output = try SewingPatternOutput(source: original)
    let assets = FileManager.default.temporaryDirectory
    let low = try output.pdf(assets: assets, dpi: 72)
    let high = try output.pdf(assets: assets, dpi: 600)
    for data in [low, high] {
      let doc = try XCTUnwrap(PDFDocument(data: data))
      let page = try XCTUnwrap(doc.page(at: 0))
      let box = page.bounds(for: .mediaBox)
      XCTAssertEqual(box.width, output.plan.frameSize.x * 72 / 25.4, accuracy: 0.02)
      XCTAssertEqual(box.height, output.plan.frameSize.y * 72 / 25.4, accuracy: 0.02)
      XCTAssertFalse(
        String(decoding: data, as: UTF8.self).contains("/Subtype /Image"),
        "Technical contours must stay vector.")
    }
    let f = fixture(low)
    defer { f.close() }
    f.controller.restore(.init(fitted: false, scale: 5, page: 0, center: .init(x: 0.45, y: 0.55)))
    let before = f.controller.capture()
    f.controller.load(high, identifier: f.controller.identifier!)
    XCTAssertEqual(f.view.scaleFactor, 5, accuracy: 0.001)
    try assertCenter(before, f.controller.capture())
    XCTAssertEqual(template.artwork, original)
    if let path = ProcessInfo.processInfo.environment["FORM_DOCUMENT37_PROOF_DIR"] {
      let folder = URL(fileURLWithPath: path)
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      try high.write(to: folder.appendingPathComponent("rounded-pouch-vector.pdf"))
      let page = try XCTUnwrap(f.view.currentPage)
      let image = page.thumbnail(of: .init(width: 1800, height: 2600), for: .mediaBox)
      if let rep = NSBitmapImageRep(data: image.tiffRepresentation!),
        let data = rep.representation(using: .png, properties: [:])
      {
        try data.write(to: folder.appendingPathComponent("rounded-pouch-vector.png"))
      }
    }
  }
  func testNativePatternSheetUsesVectorViewerAndUnrelatedRevisionsDoNotReloadOrResetIt()
    async throws
  {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = StudioStore(repository: try ProjectRepository(root: root), seedLibrary: false)
    var project = Project(name: "Vector sheet")
    var frame = try project.makeObject(
      recipeID: "artboard", parameters: ["width": 600, "depth": 800])
    frame.artwork = try SewingPatternTemplates.roundedPouch().artwork
    project.objects = [frame]
    store.engine.project = project
    store.artworkSession.objectID = frame.id
    let before = store.project!
    let host = NSHostingView(
      rootView: SewingPatternPreview(session: store.artworkSession).environmentObject(store))
    let window = NSWindow(
      contentRect: .init(x: 0, y: 0, width: 1000, height: 790), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    defer {
      window.close()
      store.engine.project = nil
      try? FileManager.default.removeItem(at: root)
    }
    func pdfs(_ view: NSView) -> [PhysicalPDFView] {
      (view as? PhysicalPDFView).map { [$0] } ?? view.subviews.flatMap { pdfs($0) }
    }
    for _ in 0..<20 {
      host.layoutSubtreeIfNeeded()
      if !pdfs(host).isEmpty { break }
      try await Task.sleep(for: .milliseconds(20))
    }
    let view = try XCTUnwrap(pdfs(host).first)
    let controller = try XCTUnwrap(view.controller)
    XCTAssertNotNil(view.document)
    XCTAssertGreaterThan(view.bounds.width, 500)
    controller.zoom(to: 4)
    let location = controller.capture()
    let loads = controller.documentLoads
    func fields(_ root: NSView) -> [NSTextField] {
      ([root as? NSTextField].compactMap { $0 }) + root.subviews.flatMap { fields($0) }
    }
    let dpi = try XCTUnwrap(
      fields(host).first { $0.isEditable && $0.placeholderString == "Export DPI" })
    window.makeFirstResponder(dpi)
    try await Task.sleep(for: .milliseconds(20))
    let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
    editor.selectAll(nil)
    editor.insertText("600", replacementRange: NSRange(location: NSNotFound, length: 0))
    window.makeFirstResponder(nil)
    try await Task.sleep(for: .milliseconds(30))
    XCTAssertEqual(dpi.stringValue, "600")
    XCTAssertEqual(controller.documentLoads, loads)
    XCTAssertEqual(view.scaleFactor, 4, accuracy: 0.001)
    store.revision += 1
    host.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(40))
    XCTAssertEqual(controller.documentLoads, loads)
    XCTAssertEqual(view.scaleFactor, 4, accuracy: 0.001)
    try assertCenter(location, controller.capture())
    XCTAssertEqual(store.project, before)
    XCTAssertTrue(store.engine.undoStack.isEmpty)
    if let path = ProcessInfo.processInfo.environment["FORM_DOCUMENT37_PROOF_DIR"] {
      controller.restore(.init(fitted: false, scale: 5, page: 0, center: .init(x: 0.10, y: 0.81)))
      host.layoutSubtreeIfNeeded()
      try await Task.sleep(for: .milliseconds(250))
      let image = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
      host.cacheDisplay(in: host.bounds, to: image)
      try XCTUnwrap(image.representation(using: .png, properties: [:])).write(
        to: URL(fileURLWithPath: path).appendingPathComponent("native-pattern-vector-review.png"))
    }
  }

  func testCutLayoutReviewUsesPhysicalStockPDFAndNavigationCannotMoveSourceCopies() throws {
    var panel = ArtworkElement(kind: "rectangle", x: 0, y: 0, width: 40, height: 50)
    panel.sewingPiece = .init(name: "Small cut panel")
    panel.sewingPiece!.cutQuantity = 2
    var source = Artwork(elements: [panel])
    var layout = SewingCutLayout(materialID: "flight-nylon", stockWidth: 200)
    layout.margin = 5
    layout.spacing = 5
    layout.grain = .unrestricted
    layout.placements = [
      .init(elementID: panel.id, copies: [1], x: 10, y: 10),
      .init(elementID: panel.id, copies: [2], x: 90, y: 10),
    ]
    source.sewingLayout = layout
    let before = source
    let output = try SewingLayoutOutput(layout: layout, source: source)
    let data = try output.pdf(assets: FileManager.default.temporaryDirectory)
    let f = fixture(data)
    defer { f.close() }
    let page = try XCTUnwrap(f.view.currentPage)
    XCTAssertEqual(page.bounds(for: .mediaBox).width, output.width * 72 / 25.4, accuracy: 0.02)
    XCTAssertEqual(page.bounds(for: .mediaBox).height, output.height * 72 / 25.4, accuracy: 0.02)
    f.controller.zoom(to: 8)
    f.controller.fit()
    XCTAssertEqual(source, before)
    XCTAssertEqual(source.sewingLayout!.placements, layout.placements)
  }

}
