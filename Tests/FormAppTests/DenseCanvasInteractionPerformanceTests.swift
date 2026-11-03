import AppKit
import CryptoKit
import FormCore
import FormGraphics
import XCTest
@testable import FormApp

/// Optional native-view measurements against an external read-only package.
/// All edits and generated resources belong to an isolated temporary repository.
@MainActor final class DenseCanvasInteractionPerformanceTests: XCTestCase {
  private func fingerprint(_ package: URL) throws -> String {
    let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: package,
      includingPropertiesForKeys: [.isRegularFileKey]))
    let files = try enumerator.compactMap { $0 as? URL }.filter {
      try $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
    }.sorted { $0.path < $1.path }
    var digest = SHA256()
    for file in files {
      digest.update(data: Data(file.path.dropFirst(package.path.count).utf8))
      digest.update(data: Data([0]))
      let handle = try FileHandle(forReadingFrom: file)
      defer { try? handle.close() }
      while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty { digest.update(data: data) }
    }
    return digest.finalize().map { String(format: "%02x", $0) }.joined()
  }
  func testExternalNativeCanvasDrawPanZoomAndFrameDrag() throws {
    let environment = ProcessInfo.processInfo.environment
    guard let path = environment["FORM_DENSE_PROJECT_PATH"], !path.isEmpty else {
      throw XCTSkip("Set FORM_DENSE_PROJECT_PATH for optional native Canvas performance measurements.")
    }
    let input = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
    let before = try fingerprint(input)
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("native-canvas-benchmark-"+UUID().uuidString)
    let repository = try ProjectRepository(root: temporary)
    defer { try? FileManager.default.removeItem(at: temporary) }
    let project = try repository.load(url: input)
    try repository.save(project)
    let sourceAssets = input.appendingPathComponent("Assets")
    let isolatedAssets = repository.url(for: project.id).appendingPathComponent("Assets")
    if FileManager.default.fileExists(atPath: sourceAssets.path) {
      for file in try FileManager.default.contentsOfDirectory(at: sourceAssets, includingPropertiesForKeys: nil) {
        try FileManager.default.copyItem(at: file, to: isolatedAssets.appendingPathComponent(file.lastPathComponent))
      }
    }
    _ = NSApplication.shared
    let store = StudioStore(repository: repository, seedLibrary: false)
    store.engine.project = project; store.showingHome = false; store.mode = .artwork
    store.linkedObjectViews = LinkedObjectViewRenderer(store: store) { _, _, _, _, _, _, _ in throw CancellationError() }
    let session = store.artworkSession
    let initialFrames = session.frames
    let target = try XCTUnwrap(initialFrames.filter { !$0.isWorkspace && $0.editable && $0.projection == nil }
      .max { $0.artwork.elements.count < $1.artwork.elements.count })
    session.activate(target.id)
    let window = NSWindow(contentRect: .init(x: -10000, y: -10000, width: 1280, height: 900),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let scroll = ArtworkScrollView(frame: window.contentView!.bounds)
    scroll.allowsMagnification = true; scroll.minMagnification = 0.08; scroll.maxMagnification = 24
    let canvas = VectorCanvasView(frame: scroll.bounds); canvas.session = session; session.canvas = canvas
    scroll.documentView = canvas; window.contentView = scroll
    defer {
      window.contentView = nil; window.close(); store.linkedObjectViews.reset(); store.solids.reset()
      store.engine.project = nil
    }
    var samples: [String: [Double]] = [:], stages: [String] = [], diagnostics: [String: Any] = [:]
    func counters() -> [String: Any] {
      // Full viewport diagnostics include every frame rectangle. Keep the
      // benchmark readable and avoid duplicating that graph after every stage.
      canvas.diagnostics.filter { $0.value is String || $0.value is NSNumber }
        .merging(["zoom": canvas.zoom]) { _, new in new }
    }
    @discardableResult func time<T>(_ stage: String, _ work: () throws -> T) rethrows -> T {
      let start = DispatchTime.now().uptimeNanoseconds
      let result = try work()
      if samples[stage] == nil { stages.append(stage) }
      samples[stage, default: []].append(Double(DispatchTime.now().uptimeNanoseconds-start)/1_000_000)
      return result
    }
    // Draw the real native Canvas into a bounded view-sized bitmap. AppKit's
    // cacheDisplay(in: visibleRect) can otherwise allocate a huge document-size
    // image at low magnification instead of the 1280×900 visible viewport.
    let c = try XCTUnwrap(CGContext(data: nil, width: 1280, height: 900, bitsPerComponent: 8,
      bytesPerRow: 1280*4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    func draw() {
      let rect = canvas.convert(scroll.contentView.bounds, from: scroll.contentView)
      let density = 1280/max(1,rect.width)
      c.saveGState(); defer { c.restoreGState() }
      c.translateBy(x: -rect.minX*density, y: 900+rect.minY*density)
      c.scaleBy(x: density, y: -density); c.clip(to: rect)
      NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext: c, flipped: true)
      canvas.draw(rect)
      NSGraphicsContext.restoreGraphicsState()
    }
    func mouse(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent {
      NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseUp ? 0:1)!
    }
    let count = min(12,max(2,Int(environment["FORM_DENSE_BENCHMARK_SAMPLES"] ?? "6") ?? 6))
    time("native.synchronize-cold") { canvas.synchronize() }
    canvas.fit(all: true)
    time("native.overview-draw-cold") { draw() }
    for _ in 0..<count { time("native.overview-draw-warm") { draw() } }
    diagnostics["overview"] = counters()
    let beforeOverviewPan = store.project, historyBeforeOverviewPan = store.engine.undoStack.count
    session.tool = .hand
    let overviewDown = CGPoint(x: 640,y: 450)
    canvas.mouseDown(with: mouse(.leftMouseDown,overviewDown))
    for n in 1...count {
      time("native.overview-pan-handler") {
        canvas.mouseDragged(with: mouse(.leftMouseDragged,
          .init(x: overviewDown.x+Double(n)*9,y: overviewDown.y+Double(n)*4)))
      }
      time("native.overview-pan-draw") { draw() }
    }
    canvas.mouseUp(with: mouse(.leftMouseUp,
      .init(x: overviewDown.x+Double(count)*9,y: overviewDown.y+Double(count)*4)))
    XCTAssertEqual(store.project,beforeOverviewPan)
    XCTAssertEqual(store.engine.undoStack.count,historyBeforeOverviewPan)
    diagnostics["overview-pan"] = counters()
    session.tool = .select
    XCTAssertTrue(canvas.fit(frameIDs: [target.id]))
    time("native.focused-draw-cold") { draw() }
    for _ in 0..<count { time("native.focused-draw-warm") { draw() } }
    diagnostics["focused"] = counters()
    let beforePan = store.project, historyBeforePan = store.engine.undoStack.count
    session.tool = .hand
    let down = CGPoint(x: 640,y: 450)
    canvas.mouseDown(with: mouse(.leftMouseDown,down))
    for n in 1...count {
      time("native.pan-handler") { canvas.mouseDragged(with: mouse(.leftMouseDragged,.init(x: down.x+Double(n)*9,y: down.y+Double(n)*4))) }
      time("native.pan-draw") { draw() }
    }
    canvas.mouseUp(with: mouse(.leftMouseUp,.init(x: down.x+Double(count)*9,y: down.y+Double(count)*4)))
    XCTAssertEqual(store.project,beforePan); XCTAssertEqual(store.engine.undoStack.count,historyBeforePan)
    diagnostics["pan"] = counters()
    let startZoom = canvas.zoom
    for n in 1...count {
      time("native.zoom-handler") { canvas.setZoom(startZoom*(1+Double(n)*0.025)) }
      time("native.zoom-draw") { draw() }
    }
    diagnostics["zoom"] = counters()
    XCTAssertEqual(store.project,beforePan)
    session.tool = .select; session.choose([])
    XCTAssertTrue(canvas.fit(frameIDs:[target.id]))
    let current = try XCTUnwrap(session.frames.first { $0.id == target.id })
    let header = CanvasFrameChrome.headerRect(for: current,scale:TypographyEngine.pointsPerMM*canvas.zoom)
    let anchor = canvas.convert(canvas.documentPoint(.init(x:header.midX,y:header.midY)),to:nil)
    let beforeDrag = store.project, undoBeforeDrag = store.engine.undoStack.count
    canvas.mouseDown(with:mouse(.leftMouseDown,anchor))
    XCTAssertEqual(canvas.diagnostics["pointer_gesture"] as? String,"frame")
    for n in 1...count {
      time("native.frame-drag-handler") { canvas.mouseDragged(with:mouse(.leftMouseDragged,.init(x:anchor.x+Double(n)*9,y:anchor.y))) }
      time("native.frame-drag-synchronize") { canvas.synchronize() }
      time("native.frame-drag-draw") { draw() }
    }
    canvas.mouseUp(with:mouse(.leftMouseUp,.init(x:anchor.x+Double(count)*9,y:anchor.y)))
    XCTAssertEqual(store.engine.undoStack.count,undoBeforeDrag+1)
    diagnostics["frame-drag"] = counters()
    store.engine.undo(); canvas.synchronize()
    XCTAssertEqual(store.project,beforeDrag,"Native frame dragging must remain one reversible document edit.")
    let after = try fingerprint(input)
    XCTAssertEqual(before,after,"The supplied package must remain byte-for-byte unchanged.")
    let report: [String:Any] = ["format_version":1,"input_path":input.path,"input_sha256":before,
      "source_unchanged":before==after,"target_name":target.object.name,"target_elements":target.artwork.elements.count,
      "frames":initialFrames.count,"projected_elements":initialFrames.reduce(0){$0+$1.artwork.elements.count},
      "samples":stages.map { ["stage":$0,"milliseconds":samples[$0]!] as [String:Any] },"diagnostics":diagnostics]
    let data = try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys])
    print("DENSE_NATIVE_CANVAS_BENCHMARK\n"+String(decoding:data,as:UTF8.self))
    if let outputPath=environment["FORM_DENSE_NATIVE_BENCHMARK_OUTPUT"],!outputPath.isEmpty {
      let output=URL(fileURLWithPath:outputPath).standardizedFileURL.resolvingSymlinksInPath()
      guard output.path != input.path,!output.path.hasPrefix(input.path+"/") else { throw FormError.invalid("Benchmark output must be outside the input package.") }
      try FileManager.default.createDirectory(at:output.deletingLastPathComponent(),withIntermediateDirectories:true)
      try data.write(to:output,options:.atomic)
    }
  }
}
