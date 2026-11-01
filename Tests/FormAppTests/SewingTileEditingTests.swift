import AppKit
import PDFKit
import SwiftUI
import Vision
import XCTest
@testable import FormApp
@testable import FormCore
@testable import FormGraphics

@MainActor final class SewingTileEditingTests: XCTestCase {
  private func fixture() throws -> (StudioStore, ProductObject) {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = StudioStore(repository: try ProjectRepository(root: root), seedLibrary: false)
    store.fontLibraryPreferences = .init(file: root.appendingPathComponent("FontPreferences.json"))
    var project = Project(name: "Tiled sewing proof")
    let template = try SewingPatternTemplates.roundedPouch()
    var frame = try project.makeObject(recipeID: "artboard", name: "Rounded pouch",
      parameters: ["width": template.frameSize.x, "depth": template.frameSize.y])
    frame.artwork = template.artwork
    project.objects = [frame]
    store.engine.project = project
    store.showingHome = false
    store.artworkSession.activate(frame.id)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    return (store, frame)
  }
  private func pdf(_ data: Data) throws -> CGPDFDocument {
    try XCTUnwrap(CGPDFDocument(CGDataProvider(data: data as CFData)!))
  }
  func testNativeReviewDraftAndExportAreImmutableAndLargeFormatRemainsAvailable() throws {
    let (store, object) = try fixture(), before = store.project!
    let model = SewingPatternReviewModel(session: store.artworkSession)
    model.refresh()
    XCTAssertNotNil(model.proof)
    XCTAssertEqual(try pdf(model.proof!).numberOfPages, 1)
    let largeIdentity = model.identity
    model.tiled = true
    model.draft.preset("Letter landscape")
    model.draft.values[SewingTileDraft.Field.overlap.rawValue] = "12.5"
    model.refresh()
    XCTAssertEqual(model.sourceBuilds, 1)
    XCTAssertNotEqual(model.identity, largeIdentity)
    XCTAssertGreaterThan(try pdf(model.proof!).numberOfPages, 1)
    let proof = model.proof
    model.dpi = "600"
    model.refresh()
    XCTAssertEqual(model.proof, proof, "Export raster density must not replace or fit the vector review.")
    let path = store.repository.root.appendingPathComponent("tiled.pdf")
    XCTAssertTrue(model.export("pdf", path: path), model.error)
    let page = try XCTUnwrap(pdf(Data(contentsOf: path)).page(at: 2))
    XCTAssertEqual(page.getBoxRect(.mediaBox).width / TypographyEngine.pointsPerMM, 279.4, accuracy: 0.001)
    XCTAssertEqual(store.project, before)
    XCTAssertTrue(store.engine.undoStack.isEmpty)
    model.tiled = false
    model.refresh()
    XCTAssertEqual(model.identity, largeIdentity)
    XCTAssertEqual(try pdf(model.proof!).numberOfPages, 1)
    let result = try store.exportSewingPattern(object: object,
      arguments: ["format": "svg", "path": store.repository.root.appendingPathComponent("source.svg").path]) as! [String: Any]
    XCTAssertEqual(result["format"] as? String, "svg")
    XCTAssertEqual(store.project, before)
  }
  func testSavedOptionsAreOneUndoAutosaveAndReopenWithoutSourceOrRenderChanges() async throws {
    let (store, object) = try fixture(), before = store.project!
    defer { store.engine.project = nil }
    let model = SewingPatternReviewModel(session: store.artworkSession)
    model.refresh()
    model.tiled = true
    model.draft.preset("Letter portrait")
    model.draft.values[SewingTileDraft.Field.left.rawValue] = "13.25"
    model.refresh()
    let wanted = try model.draft.options()
    XCTAssertTrue(model.saveOptions(), model.error)
    XCTAssertTrue(store.saving)
    XCTAssertEqual(store.engine.undoStack.count, 1)
    XCTAssertEqual(model.sourceBuilds, 1, "Saving nonvisual sheet options must reuse the source proof.")
    XCTAssertEqual(store.project!.minimumSchemaVersion, 40)
    XCTAssertEqual(store.project!.objects[0].artwork!.elements, object.artwork!.elements)
    XCTAssertEqual(try store.project!.objects[0].artwork!.renderCacheData(), try object.artwork!.renderCacheData())
    let deadline = Date().addingTimeInterval(4)
    while store.saving && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
    XCTAssertFalse(store.saving)
    let loaded = try store.repository.load(before.id)
    XCTAssertEqual(loaded.objects[0].artwork!.sewingTiles, wanted)
    XCTAssertEqual(loaded.objects[0].artwork!.elements, object.artwork!.elements)
    store.engine.undo()
    model.refresh()
    XCTAssertEqual(store.project, before)
    store.engine.redo()
    model.refresh()
    XCTAssertEqual(try model.draft.options(), wanted)
    let reopened = SewingPatternReviewModel(session: store.artworkSession)
    reopened.refresh()
    XCTAssertTrue(reopened.tiled)
    XCTAssertEqual(try reopened.draft.options(), wanted)
    let saved = store.project!
    XCTAssertTrue(model.saveOptions(clear: true))
    XCTAssertNil(store.project!.objects[0].artwork!.sewingTiles)
    store.engine.undo()
    XCTAssertEqual(store.project, saved)
  }
  func testInvalidActiveDraftAndLockedSourceNeverSaveOrOverwriteAnExport() throws {
    let (store, _) = try fixture(), before = store.project!
    let model = SewingPatternReviewModel(session: store.artworkSession)
    model.refresh()
    model.tiled = true
    let path = store.repository.root.appendingPathComponent("approved.pdf"), sentinel = Data("Approved existing output".utf8)
    try sentinel.write(to: path)
    for bad in ["", "nan", "-1", "100000"] {
      model.draft.values[SewingTileDraft.Field.width.rawValue] = bad
      model.refresh()
      XCTAssertNil(model.proof, "Invalid values must not leave an apparently current stale proof.")
      XCTAssertFalse(model.saveOptions())
      XCTAssertFalse(model.export("pdf", path: path))
      XCTAssertEqual(try Data(contentsOf: path), sentinel)
      XCTAssertEqual(store.project, before)
      XCTAssertTrue(store.engine.undoStack.isEmpty)
    }
    model.draft.load(.init())
    model.refresh()
    XCTAssertNotNil(model.proof)
    var locked = before
    locked.objects[0].locked = true
    store.engine.project = locked
    XCTAssertFalse(model.saveOptions())
    XCTAssertEqual(store.project, locked)
    XCTAssertTrue(store.engine.undoStack.isEmpty)
  }
  func testMCPUsesSavedOrExplicitOptionsAndRejectsMixedSelectorsWithoutMutation() throws {
    let (store, object) = try fixture(), before = store.project!
    var options = SewingTileOptions(sheetSize: SewingTileOptions.letter)
    options.margins.top = 14
    _ = try store.engine.call("form_edit_artwork", arguments: ["object_id": object.id.uuidString,
      "command": "pattern_tiles", "tile_options": try jsonObject(options)])
    let saved = store.project!, history = store.engine.undoStack.count
    let report = try store.graphicsCall("form_export_artwork", ["object_id": object.id.uuidString,
      "pattern_pieces": true, "pattern_tiles": true, "format": "preflight"]) as! [String: Any]
    let tiled = try XCTUnwrap(report["tiled"] as? [String: Any])
    XCTAssertEqual(tiled["sheet_width_mm"] as? Double, 215.9)
    XCTAssertEqual(tiled["scale"] as? Int, 1)
    let override = SewingTileOptions(sheetSize: .init(350, 250))
    let path = store.repository.root.appendingPathComponent("custom.pdf")
    let result = try store.graphicsCall("form_export_artwork", ["object_id": object.id.uuidString,
      "pattern_pieces": true, "pattern_tiles": try jsonObject(override), "format": "pdf", "path": path.path]) as! [String: Any]
    XCTAssertTrue(FileManager.default.fileExists(atPath: result["path"] as! String))
    let doc = try pdf(Data(contentsOf: path))
    XCTAssertGreaterThan(doc.numberOfPages, 1)
    XCTAssertEqual(doc.page(at: 1)!.getBoxRect(.mediaBox).width / TypographyEngine.pointsPerMM, 350, accuracy: 0.001)
    XCTAssertEqual(store.project, saved)
    XCTAssertEqual(store.engine.undoStack.count, history)
    for additional: [String: Any] in [["roles": ["cut"]], ["cut_layout": true], ["ink_output": "preview"], ["format": "svg"]] {
      var args: [String: Any] = ["object_id": object.id.uuidString, "pattern_pieces": true,
        "pattern_tiles": true, "format": "pdf", "path": path.path]
      args.merge(additional) { _, new in new }
      let data = try Data(contentsOf: path)
      XCTAssertThrowsError(try store.graphicsCall("form_export_artwork", args))
      XCTAssertEqual(try Data(contentsOf: path), data)
    }
    XCTAssertThrowsError(try store.graphicsCall("form_export_artwork", ["object_id": object.id.uuidString,
      "pattern_tiles": true, "format": "pdf", "path": path.path]))
    XCTAssertEqual(store.project, saved)
    store.engine.undo()
    XCTAssertEqual(store.project, before)
  }
  func testMultipageReviewAndModeChangesKeepTheirOwnViewportWhileDPIIsIndependent() throws {
    let (store, _) = try fixture(), before = store.project!
    let model = SewingPatternReviewModel(session: store.artworkSession)
    model.refresh()
    model.tiled = true
    model.refresh()
    let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 800, height: 600),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let pdfView = PhysicalPDFView(frame: window.contentView!.bounds)
    window.contentView = pdfView
    let review = PhysicalDocumentController()
    review.attach(pdfView)
    defer { review.detach(); window.close() }
    review.load(try XCTUnwrap(model.proof), identifier: model.identity)
    XCTAssertEqual(review.pages, model.pageCount)
    review.restore(.init(fitted: false, scale: 3, page: 3, center: .init(x: 0.6, y: 0.4)))
    let position = try XCTUnwrap(review.capture()), loads = review.documentLoads
    XCTAssertEqual(position.page, 3)
    model.dpi = "600"
    model.refresh()
    review.load(try XCTUnwrap(model.proof), identifier: model.identity)
    XCTAssertEqual(review.documentLoads, loads)
    model.tiled = false
    model.refresh()
    review.load(try XCTUnwrap(model.proof), identifier: model.identity)
    XCTAssertEqual(review.pages, 1)
    model.tiled = true
    model.refresh()
    review.load(try XCTUnwrap(model.proof), identifier: model.identity)
    let restored = try XCTUnwrap(review.capture())
    XCTAssertEqual(restored.page, position.page)
    XCTAssertEqual(restored.scale, position.scale, accuracy: 0.0001)
    XCTAssertEqual(restored.center.x, position.center.x, accuracy: 0.004)
    XCTAssertEqual(restored.center.y, position.center.y, accuracy: 0.004)
    XCTAssertEqual(store.project, before)
    XCTAssertTrue(store.engine.undoStack.isEmpty)
    if let directory = ProcessInfo.processInfo.environment["FORM_SEWING_TILE_PROOF_DIR"] {
      let root = URL(fileURLWithPath: directory)
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      review.goPage(-(review.page - 1))
      review.fit()
      review.remember()
      let hosted = NSHostingView(rootView: SewingPatternPreview(session: store.artworkSession, model: model).environmentObject(store))
      hosted.sizingOptions = []
      hosted.frame = .init(x: 0, y: 0, width: 1120, height: 830)
      window.contentView = hosted
      window.setContentSize(.init(width: 1120, height: 830))
      hosted.frame = .init(x: 0, y: 0, width: 1120, height: 830)
      hosted.layoutSubtreeIfNeeded()
      RunLoop.main.run(until: Date().addingTimeInterval(0.1))
      let bitmap = try XCTUnwrap(hosted.bitmapImageRepForCachingDisplay(in: hosted.bounds))
      hosted.cacheDisplay(in: hosted.bounds, to: bitmap)
      try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: root.appendingPathComponent("native-tiled-pattern-review.png"))
    }
  }
  /// Locate the real mounted button. SwiftUI may expose virtual NSObject AX
  /// children without declaring NSAccessibilityProtocol, so read both APIs.
  private func saveButton(_ view:NSView)throws -> (frame:CGRect,enabled:Bool?) {
    func descendants(_ root:NSView)->[NSView] {[root]+root.subviews.flatMap(descendants)}
    if let button=descendants(view).compactMap({$0 as? NSButton}).first(where:{$0.title=="Save sheet options"}) {
      let window=try XCTUnwrap(button.window)
      return (window.convertToScreen(button.convert(button.bounds,to:nil)),button.isEnabled)
    }
    var seen=Set<ObjectIdentifier>()
    func search(_ value:Any,depth:Int=0)->(CGRect,Bool)? {
      guard depth<40,seen.count<3000,let object=value as? NSObject,seen.insert(ObjectIdentifier(object)).inserted else{return nil}
      let modern=object as? any NSAccessibilityProtocol
      func raw(_ name:String)->Any? {
        let selector=NSSelectorFromString(name)
        return object.responds(to:selector) ? object.perform(selector)?.takeUnretainedValue():nil
      }
      func legacy(_ name:String)->Any? {
        object.responds(to:NSSelectorFromString("accessibilityAttributeValue:")) ? object.accessibilityAttributeValue(.init(rawValue:name)):nil
      }
      let role=modern?.accessibilityRole()?.rawValue ?? (raw("accessibilityRole") ?? legacy("AXRole")) as? String
      let label=modern?.accessibilityLabel() ?? (raw("accessibilityLabel") ?? legacy("AXDescription")) as? String
      let title=modern?.accessibilityTitle() ?? (raw("accessibilityTitle") ?? legacy("AXTitle")) as? String
      if role==NSAccessibility.Role.button.rawValue,[label,title].compactMap({$0}).contains(where:{["Save pattern sheet options","Save sheet options"].contains($0)}) {
        let frame=modern?.accessibilityFrame() ?? CGRect(origin:(legacy("AXPosition") as? NSValue)?.pointValue ?? .zero,size:(legacy("AXSize") as? NSValue)?.sizeValue ?? .zero)
        let enabled=modern?.isAccessibilityEnabled() ?? (legacy("AXEnabled") as? NSNumber)?.boolValue
        if let enabled,frame.width>0,frame.height>0 {return(frame,enabled)}
      }
      var children=modern?.accessibilityChildren() ?? []
      if let navigation=raw("accessibilityChildrenInNavigationOrder") as? NSArray {children += navigation.map{$0}}
      if modern==nil {children += raw("accessibilityChildren") as? [Any] ?? []}
      if children.isEmpty {children += legacy("AXChildren") as? [Any] ?? [];children += legacy("AXChildrenInNavigationOrder") as? [Any] ?? []}
      for child in children {if let found=search(child,depth:depth+1) {return found}}
      return nil
    }
    for root in descendants(view) {if let found=search(root) {return(found.0,found.1)}}
    // Inactive offscreen SwiftUI can expose neither NSButton nor AX children.
    // Read the actual rendered label instead of assuming a position or invoking
    // the closure. The following native click/action-count assertion proves the
    // control is enabled even when AppKit exposes no enabled-state getter.
    let bitmap=try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in:view.bounds))
    view.cacheDisplay(in:view.bounds,to:bitmap)
    if let directory=ProcessInfo.processInfo.environment["FORM_SEWING_TILE_PROOF_DIR"] {
      let root=URL(fileURLWithPath:directory);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
      try XCTUnwrap(bitmap.representation(using:.png,properties:[:])).write(to:root.appendingPathComponent("native-sheet-options-save-target.png"))
    }
    let image=try XCTUnwrap(bitmap.cgImage),request=VNRecognizeTextRequest()
    request.recognitionLevel = .accurate;request.recognitionLanguages=["en-US"];request.usesLanguageCorrection=false
    try VNImageRequestHandler(cgImage:image).perform([request])
    let window=try XCTUnwrap(view.window)
    for observation in request.results ?? [] {
      guard let text=observation.topCandidates(1).first,
        let range=text.string.range(of:"Save sheet options",options:.caseInsensitive),
        let label=try text.boundingBox(for:range) else{continue}
      let box=label.boundingBox
      let rect=CGRect(x:box.minX*view.bounds.width,y:(view.isFlipped ? 1-box.maxY:box.minY)*view.bounds.height,width:box.width*view.bounds.width,height:box.height*view.bounds.height)
      guard !rect.isEmpty,view.bounds.contains(rect) else{continue}
      return(window.convertToScreen(view.convert(rect,to:nil)),nil)
    }
    return try XCTUnwrap(Optional<(frame:CGRect,enabled:Bool?)>.none,"The actual mounted Save sheet options label must be discovered before a native click")
  }
  func testNativeFocusedSheetFieldUsesTheRealSaveButtonWithoutTabAndUndoIsExact() throws {
    let (store, _) = try fixture(), before = store.project!
    let model = SewingPatternReviewModel(session: store.artworkSession)
    model.refresh()
    let window = NSWindow(contentRect: .init(x: -10000, y: -10000, width: 260, height: 600),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    var saves=0
    let view = NSHostingView(rootView: SewingTileSettings(draft: model.draft, saved: false,
      save: { saves+=1;model.saveOptions() }, clear: { model.saveOptions(clear: true) }).padding(20).background(Palette.paper))
    view.sizingOptions=[]
    window.contentView = view
    view.frame=window.contentView!.bounds
    window.orderBack(nil)
    view.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    func fields(_ root: NSView) -> [NSTextField] {
      ([root as? NSTextField].compactMap { $0 }) + root.subviews.flatMap { fields($0) }
    }
    let field = try XCTUnwrap(fields(view).first { $0.isEditable && $0.placeholderString == "Left margin" })
    window.makeFirstResponder(field)
    let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
    editor.selectAll(nil)
    editor.insertText("13.75", replacementRange: .init(location: NSNotFound, length: 0))
    RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    view.layoutSubtreeIfNeeded()
    XCTAssertEqual(model.draft.values[SewingTileDraft.Field.left.rawValue],"13.75","The active native field must remain authoritative before Save")
    // Find the actual mounted control after layout; shared field styling is free
    // to change row heights without silently moving this event onto another row.
    let button=try saveButton(view)
    if let enabled=button.enabled {XCTAssertTrue(enabled)}
    let buttonInWindow=window.convertFromScreen(button.frame)
    let location=NSPoint(x:buttonInWindow.midX,y:buttonInWindow.midY)
    let point=view.convert(location,from:nil)
    XCTAssertTrue(view.bounds.contains(point),"Save must be inside the mounted form")
    let hit=try XCTUnwrap(view.hitTest(view.superview?.convert(point,from:view) ?? point))
    XCTAssertFalse(hit.isHiddenOrHasHiddenAncestor)
    if let control=hit as? NSControl {XCTAssertTrue(control.isEnabled)}
    let stamp = ProcessInfo.processInfo.systemUptime
    let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: location,
      modifierFlags: [], timestamp: stamp, windowNumber: window.windowNumber, context: nil,
      eventNumber: 1, clickCount: 1, pressure: 1))
    let up = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: location,
      modifierFlags: [], timestamp: stamp + 0.02, windowNumber: window.windowNumber, context: nil,
      eventNumber: 2, clickCount: 1, pressure: 0))
    NSApp.postEvent(up, atStart: false)
    NSApp.sendEvent(down)
    NSApp.sendEvent(up)
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    XCTAssertEqual(saves,1,"The actual mounted Save button must receive the native click")
    XCTAssertEqual(store.project!.objects[0].artwork!.sewingTiles?.margins.left, 13.75,model.error)
    XCTAssertEqual(store.engine.undoStack.count, 1)
    store.engine.undo()
    XCTAssertEqual(store.project, before)
  }
}
