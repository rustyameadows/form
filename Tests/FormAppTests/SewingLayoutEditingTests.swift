import AppKit
import XCTest
@testable import FormApp
@testable import FormCore
@testable import FormGraphics

@MainActor final class SewingLayoutEditingTests: XCTestCase {
  @MainActor private final class Fixture {
    let store: StudioStore, root: URL, frameID: UUID, model: SewingLayoutController
    init(source: Artwork? = nil, pattern: Bool = false, knownWidth: Bool = true) throws {
      _ = NSApplication.shared
      root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      store = StudioStore(repository: try ProjectRepository(root: root), seedLibrary: false)
      var p = Project(name: "Cutting layout regression"); _ = try p.ensureCanvasWorkspace()
      var material = p.material("flight-nylon"); material.color = "#18365A"; material.fabric!.inventoryMeters = 8.5
      if !knownWidth { material.fabric!.usableWidth = nil }
      p.materials = [material]
      var frame = try p.makeObject(recipeID: "artboard", name: "Cutting sources", parameters: ["width":800,"depth":750])
      frame.artwork = try source ?? SewingPatternTemplates.tote().artwork
      frameID = frame.id; p.objects.append(frame)
      if pattern {
        var tile = try p.makeObject(recipeID: "artboard", name: "Physical fabric tile", parameters: ["width":40,"depth":40])
        var art = Artwork(background:"#FFFFFF",elements:[ArtworkElement(kind:"rectangle",x:0,y:0,width:10,height:10,color:"#E23C2F")],bleed:0)
        art.backgroundOpacity = 0; tile.artwork = art; p.objects.append(tile)
        try p.setFabricPattern(.init(sourceObjectID:tile.id), materialID:"flight-nylon")
      }
      p.schemaVersion = p.minimumSchemaVersion
      store.engine.project = p; store.mode = .artwork; store.showingHome = false
      store.artworkSession.objectID = frame.id
      model = SewingLayoutController(session:store.artworkSession)
    }
    func close() { model.finish(); store.engine.project = nil; try? FileManager.default.removeItem(at:root) }
  }
  private func settle(_ model:SewingLayoutController) async throws {
    let deadline = Date().addingTimeInterval(5)
    while (model.planning || model.checking) && Date() < deadline { try await Task.sleep(for:.milliseconds(15)) }
    XCTAssertFalse(model.planning); XCTAssertFalse(model.checking)
  }
  private func autosaved(_ store:StudioStore) async throws {
    let deadline = Date().addingTimeInterval(5)
    while store.saving && Date() < deadline { try await Task.sleep(for:.milliseconds(20)) }
    XCTAssertFalse(store.saving)
  }
  private func simpleSource() -> Artwork {
    var e = ArtworkElement(kind:"rectangle",x:0,y:0,width:20,height:20)
    e.sewingPiece = .init(name:"Panel"); e.sewingPiece!.seamAllowance = 0
    e.sewingPiece!.materialID = "flight-nylon"; e.sewingPiece!.cutQuantity = 2
    return Artwork(background:"#FFFFFF",elements:[e],bleed:0)
  }
  private func simpleLayout(_ source:Artwork, folded:Bool = false) -> SewingCutLayout {
    var l = SewingCutLayout(materialID:"flight-nylon",stockWidth:100)
    l.margin = 0; l.spacing = 3; l.surface = .sheet; l.sheetLength = 50; l.grain = .unrestricted
    if folded {
      l.stock = .foldedPair; l.placements = [.init(elementID:source.elements[0].id,copies:[1,2],x:5,y:5)]
    } else {
      l.placements = [.init(elementID:source.elements[0].id,copies:[1],x:5,y:5),.init(elementID:source.elements[0].id,copies:[2],x:45,y:5)]
    }
    return l
  }
  func testNativePlanningAndNumericEditsAutosaveWithoutChangingSourceOrInventory() async throws {
    let f = try Fixture(); defer { f.close() }
    let original = f.store.project!, elements = f.model.source.elements, library = f.store.library
    f.model.plan(); try await settle(f.model)
    XCTAssertEqual(f.model.layout.placements.count,4); XCTAssertTrue(f.model.canExport)
    f.model.edit { $0.costPerSquareMeter = 12.5; $0.costCurrency = "USD" }
    XCTAssertTrue(f.store.saving)
    try await autosaved(f.store)
    let loaded = try f.store.repository.load(original.id), art = loaded.objects.first { $0.id == f.frameID }!.artwork!
    XCTAssertEqual(art.sewingLayout, f.model.layout); XCTAssertEqual(art.elements,elements)
    XCTAssertEqual(loaded.materials,original.materials); XCTAssertEqual(f.store.library,library)
    XCTAssertEqual(loaded.minimumSchemaVersion,27)
    XCTAssertEqual(loaded.material("flight-nylon").fabric?.inventoryMeters,8.5)
  }
  func testUnknownWidthStaysUnknownAndPlanningDoesNotGuessIt() async throws {
    let f = try Fixture(knownWidth:false); defer { f.close() }
    XCTAssertNil(f.model.layout.stockWidth)
    let before = f.store.project!
    f.model.plan(); try await settle(f.model)
    XCTAssertFalse(f.model.error.isEmpty); XCTAssertEqual(f.store.project,before)
    f.model.edit { $0.stockWidth = 1200 }; f.model.plan(); try await settle(f.model)
    XCTAssertTrue(f.model.canExport)
    var unassigned = simpleSource(); unassigned.elements[0].sewingPiece!.materialID = nil
    let explicit = try Fixture(source:unassigned); defer { explicit.close() }
    XCTAssertEqual(explicit.model.layout.materialID, ""); XCTAssertNil(explicit.model.layout.stockWidth)
    XCTAssertFalse(explicit.model.canPlan, "Unassigned pieces must not silently acquire the first library fabric.")
    explicit.model.chooseMaterial(explicit.store.materials.first { $0.id == "flight-nylon" }!)
    explicit.model.plan(); try await settle(explicit.model); XCTAssertTrue(explicit.model.canExport)
    XCTAssertNil(explicit.model.source.elements[0].sewingPiece!.materialID)
  }
  func testNativeMouseDragFollowsPointerOneUndoEscapeAndLateProjectDragAreSafe() async throws {
    let f = try Fixture(); defer { f.close() }; f.model.plan(); try await settle(f.model)
    let window = NSWindow(contentRect:.init(x:0,y:0,width:900,height:650),styleMask:[.titled],backing:.buffered,defer:false)
    window.isReleasedWhenClosed = false; defer { window.close() }
    let scroll = NSScrollView(frame:window.contentView!.bounds); scroll.allowsMagnification = true; scroll.minMagnification = 0.02; scroll.maxMagnification = 12
    let canvas = SewingLayoutCanvasView(frame:.init(x:0,y:0,width:900,height:650)); canvas.controller = f.model
    scroll.documentView = canvas; window.contentView = scroll; window.makeFirstResponder(canvas); canvas.synchronize(); canvas.fit()
    let stock = CGRect(origin:canvas.documentPoint(.init()),size:.init(width:f.model.report!.workingWidth*TypographyEngine.pointsPerMM,height:f.model.report!.requiredLength*TypographyEngine.pointsPerMM))
    XCTAssertTrue(scroll.documentVisibleRect.contains(stock),"Fit stock must actually center and contain the full layout, independent of selection.")
    let original = f.model.previewPlacements[0], before = f.store.project!
    func event(_ type:NSEvent.EventType,_ point:Point2) -> NSEvent {
      NSEvent.mouseEvent(with:type,location:canvas.convert(canvas.documentPoint(point),to:nil),modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,
        windowNumber:window.windowNumber,context:nil,eventNumber:1,clickCount:1,pressure:type == .leftMouseUp ? 0 : 1)!
    }
    let start = original.bounds.center, down = event(.leftMouseDown,start)
    XCTAssertTrue(canvas.acceptsFirstMouse(for:down))
    canvas.mouseDown(with:down); canvas.mouseDragged(with:event(.leftMouseDragged,.init(start.x,start.y+50))); canvas.mouseUp(with:event(.leftMouseUp,.init(start.x,start.y+50)))
    let moved = f.model.layout.placements.first { $0.id == original.placement.id }!
    XCTAssertEqual(moved.x,original.placement.x,accuracy:0.001); XCTAssertEqual(moved.y,original.placement.y+50,accuracy:0.001)
    XCTAssertEqual(f.model.source.elements,before.objects.first { $0.id == f.frameID }!.artwork!.elements)
    f.store.undo(); _ = f.model.refreshContext(); XCTAssertEqual(f.store.project,before)
    canvas.synchronize(); canvas.mouseDown(with:event(.leftMouseDown,start)); canvas.mouseDragged(with:event(.leftMouseDragged,.init(start.x+40,start.y+20)))
    let escape = NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:window.windowNumber,context:nil,characters:"\u{1b}",charactersIgnoringModifiers:"\u{1b}",isARepeat:false,keyCode:53)!
    canvas.keyDown(with:escape); XCTAssertEqual(f.store.project,before)
    canvas.mouseDragged(with:event(.leftMouseDragged,.init(start.x+100,start.y+100))); canvas.mouseUp(with:event(.leftMouseUp,start)); XCTAssertEqual(f.store.project,before)
    canvas.mouseDown(with:event(.leftMouseDown,start)); canvas.mouseDragged(with:event(.leftMouseDragged,.init(start.x,start.y+10)))
    _ = try f.store.engine.call("form_create_project",arguments:["name":"Replacement project"]); f.store.changed()
    let replacement = f.store.project!
    canvas.mouseDragged(with:event(.leftMouseDragged,.init(start.x+200,start.y+200))); canvas.mouseUp(with:event(.leftMouseUp,start))
    XCTAssertEqual(f.store.project,replacement)
  }
  func testPhysicalFabricPhaseUsesOneRollOriginAndTheOpenStockUpperPly() throws {
    let source = simpleSource(), f = try Fixture(source:source,pattern:true); defer { f.close() }
    let design = try f.store.project!.resolvedFabricPattern(materialID:"flight-nylon"), color = f.store.project!.material("flight-nylon").color
    func render(_ l:SewingCutLayout) throws -> NSBitmapImageRep {
      let output = try SewingLayoutOutput(layout:l,source:source,fabric:design,fabricColor:color,includeFabricPreview:true)
      return try XCTUnwrap(output.image(assets:f.model.assets,dpi:254).representations.first as? NSBitmapImageRep)
    }
    func pixel(_ image:NSBitmapImageRep,_ x:Int,_ y:Int) -> [UInt] { var p = [UInt](repeating:0,count:4); image.getPixel(&p,atX:x*10, y:y*10); return p }
    var l = simpleLayout(source); let first = try render(l)
    XCTAssertGreaterThan(pixel(first,6,6)[0],200); XCTAssertGreaterThan(pixel(first,46,6)[0],200)
    l.placements[1].x = 30; let moved = try render(l)
    XCTAssertLessThan(pixel(moved,31,6)[0],50,"Moving the piece must sample the roll, not fit the motif anew to its bounds.")
    l.fabricOrigin.x = 10; let phase = try render(l)
    XCTAssertLessThan(pixel(phase,6,6)[0],50)
    l = simpleLayout(source,folded:true); let upper = try render(l)
    XCTAssertLessThan(pixel(upper,6,6)[0],50,"Folded x6 is open-stock x56, on the upper/right ply.")
    l.fabricOrigin.x = 10; let shifted = try render(l)
    XCTAssertGreaterThan(pixel(shifted,6,6)[0],200)
  }
  func testRealLayoutSVGAndPDFKeepStockOriginPhysicalDimensionsAndPreflightDoesNotWrite() throws {
    let f = try Fixture(pattern:true); defer { f.close() }
    let plan = try SewingLayouts.planned(f.model.layout,source:f.model.source)
    _ = try f.store.engine.call("form_edit_artwork",arguments:["object_id":f.frameID.uuidString,"command":"cut_layout","cutting_layout":try jsonObject(plan.layout)])
    let object = f.store.project!.objects.first { $0.id == f.frameID }!, before = f.store.project!
    let folder = f.root.appendingPathComponent("Outputs"); try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
    for format in ["svg","pdf","png"] {
      let url = folder.appendingPathComponent("tote-layout."+format)
      let result = try f.store.graphicsCall("form_export_artwork",["object_id":f.frameID.uuidString,"cut_layout":true,"format":format,"path":url.path,"dpi":72,"include_fabric_preview":true]) as! [String:Any]
      XCTAssertEqual(result["width_mm"] as? Double,plan.preflight.workingWidth); XCTAssertEqual(result["height_mm"] as? Double,plan.preflight.consumedLength)
      XCTAssertEqual(result["inventory_deducted"] as? Bool,false)
      let data = try Data(contentsOf:url)
      if format == "svg" {
        let xml = String(decoding:data,as:UTF8.self); XCTAssertTrue(xml.contains("form-cutting-layout")); XCTAssertTrue(xml.contains("form-role-fabric-reference")); XCTAssertTrue(XMLParser(data:data).parse())
      }
      if format == "pdf" {
        let doc = try XCTUnwrap(CGPDFDocument(CGDataProvider(data:data as CFData)!)), page = try XCTUnwrap(doc.page(at:1))
        XCTAssertEqual(page.getBoxRect(.mediaBox).width/TypographyEngine.pointsPerMM,plan.preflight.workingWidth,accuracy:0.001)
        XCTAssertEqual(page.getBoxRect(.mediaBox).height/TypographyEngine.pointsPerMM,plan.preflight.consumedLength,accuracy:0.001)
      }
      if let directory = ProcessInfo.processInfo.environment["FORM_CUT_LAYOUT_PROOF_DIR"] {
        let proof = URL(fileURLWithPath:directory); try FileManager.default.createDirectory(at:proof,withIntermediateDirectories:true)
        try data.write(to:proof.appendingPathComponent("tote-material-layout."+format),options:.atomic)
      }
    }
    XCTAssertEqual(f.store.project,before)
    let absent = folder.appendingPathComponent("preflight-must-not-exist.pdf")
    let checked = try f.store.exportSewingLayout(object:object,arguments:["layout_preflight":true,"format":"pdf","path":absent.path]) as! [String:Any]
    XCTAssertEqual(checked["valid"] as? Bool,true); XCTAssertFalse(FileManager.default.fileExists(atPath:absent.path))
    XCTAssertThrowsError(try f.store.exportSewingLayout(object:object,arguments:["format":"pdf","roles":["cut"]]))
  }
}
