import AppKit
import FormCore
import FormGraphics
import XCTest
@testable import FormApp

@MainActor final class NativeTextPaintEditingTests: XCTestCase {
  func testNativeFontEditsPreserveGradientSelectedRecolorOverridesItAndInspectorRecolorsAll() throws {
    _ = NSApplication.shared
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("text-paint-edit-" + UUID().uuidString)
    let store = StudioStore(repository: try ProjectRepository(root: directory), seedLibrary: false)
    var project = Project(name: "Editable paints")
    let owner = try project.ensureCanvasWorkspace()
    var element = ArtworkElement(kind: "text", x: 10, y: 10, width: 100, height: 30, text: "ABCD", color: "#000000", fontSize: 32)
    var type = Typography(); type.fontName = "Helvetica"; element.typography = type
    element.paintStack = [.init(.init(kind: "gradient", gradient: .init(kind: "linear", start: .init(0,0), end: .init(1,0), stops: [.init(0,"#FF0000"),.init(1,"#0000FF")])))]
    project.objects[0].artwork!.elements = [element]; project.schemaVersion = project.minimumSchemaVersion
    store.engine.project = project; store.mode = .artwork; store.showingHome = false
    let window = NSWindow(contentRect: .init(x: -10000, y: -10000, width: 900, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let canvas = VectorCanvasView(frame: .init(x: 0, y: 0, width: 900, height: 600))
    canvas.session = store.artworkSession; store.artworkSession.canvas = canvas; store.artworkSession.objectID = owner.id
    store.artworkSession.selection = [element.id]; window.contentView = canvas; window.orderBack(nil); canvas.synchronize()
    defer { canvas.finishText(); store.engine.project = nil; window.close(); try? FileManager.default.removeItem(at: directory) }
    func current() throws -> ArtworkElement { try XCTUnwrap(store.project?.objects.first { $0.id == owner.id }?.artwork?.elements.first) }
    canvas.beginText(element)
    var editor = try XCTUnwrap(window.firstResponder as? CanvasTextView)
    editor.setSelectedRange(.init(location: 1, length: 2))
    XCTAssertTrue(canvas.applyTextStyle { $0.tracking = 2 })
    XCTAssertTrue(canvas.applyTextSize(24))
    canvas.finishText()
    let changed = try current()
    XCTAssertEqual(changed.paintStack, element.paintStack); XCTAssertEqual(changed.text, "ABCD")
    XCTAssertEqual(changed.textRuns?.first { $0.location == 1 }?.fontSize, 24)
    XCTAssertTrue((changed.textRuns ?? []).allSatisfy { $0.paintStack == nil })
    canvas.beginText(changed)
    editor = try XCTUnwrap(window.firstResponder as? CanvasTextView)
    editor.setSelectedRange(.init(location: 1, length: 2))
    XCTAssertTrue(canvas.applyTextColor("#00AA00"))
    canvas.finishText()
    let recolored = try current()
    XCTAssertEqual(recolored.paintStack, element.paintStack)
    let range = try XCTUnwrap(recolored.textRuns?.first { $0.location == 1 })
    XCTAssertEqual(range.length, 2); XCTAssertEqual(range.paintStack?.first?.paint.kind, "solid")
    XCTAssertEqual(range.paintStack?.first?.paint.color, "#00AA00")
    XCTAssertNil(recolored.textRuns?.first { $0.location == 0 }?.paintStack)
    store.artworkSession.textColor("#AA00AA")
    let all = try current()
    XCTAssertEqual(all.paintStack?.first?.paint.kind, "solid")
    XCTAssertEqual(all.paintStack?.first?.paint.color, "#AA00AA")
    XCTAssertTrue((all.textRuns ?? []).allSatisfy { $0.paintStack == nil || $0.paintStack?.first?.paint.color == "#AA00AA" })
    XCTAssertEqual(all.text, "ABCD"); XCTAssertNil(all.path)
  }
  func testVectorInspectorRecolorChangesEffectiveStackAndPreservesStroke() throws {
    _ = NSApplication.shared
    let directory=FileManager.default.temporaryDirectory.appendingPathComponent("vector-paint-edit-"+UUID().uuidString)
    let store=StudioStore(repository:try ProjectRepository(root:directory),seedLibrary:false)
    var project=Project(name:"Vector paints");let owner=try project.ensureCanvasWorkspace()
    var element=ArtworkElement(kind:"rectangle",x:0,y:0,width:40,height:20)
    let stroke=ArtworkPaintLayer(.init(color:"#000000",opacity:0.7),stroke:.init(width:0.5))
    element.paintStack=[.init(.init(kind:"gradient",gradient:.init(stops:[.init(0,"#FF0000"),.init(1,"#0000FF")]))),stroke]
    project.objects[0].artwork!.elements=[element];project.schemaVersion=project.minimumSchemaVersion
    store.engine.project=project;store.mode = .artwork;store.showingHome=false
    let session=store.artworkSession;session.objectID=owner.id;session.selection=[element.id]
    defer{store.engine.project=nil;try? FileManager.default.removeItem(at:directory)}
    session.textColor("#00FF00")
    let changed=try XCTUnwrap(store.project?.objects[0].artwork?.elements[0])
    XCTAssertEqual(changed.paintStack?[0].paint.kind,"solid");XCTAssertEqual(changed.paintStack?[0].paint.color,"#00FF00")
    XCTAssertEqual(changed.paintStack?[1],stroke)
    var art=Artwork(elements:[changed],bleed:0);art.backgroundOpacity=0
    let rep=try XCTUnwrap(ArtworkRenderer.image(art,width:40,height:20,assets:directory,pixelsPerMM:2).representations.first as? NSBitmapImageRep)
    let color=try XCTUnwrap(rep.colorAt(x:40,y:20))
    XCTAssertGreaterThan(color.greenComponent,0.98);XCTAssertLessThan(color.redComponent,0.02);XCTAssertLessThan(color.blueComponent,0.02)
  }

}
