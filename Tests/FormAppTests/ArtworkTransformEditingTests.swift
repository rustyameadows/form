import AppKit
import XCTest
@testable import FormApp
@testable import FormCore

@MainActor final class ArtworkTransformEditingTests: XCTestCase {
  private func fixture(_ text:Bool = false) throws -> (StudioStore,ArtworkSession,ArtworkElement,URL) {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = StudioStore(repository:try ProjectRepository(root:root),seedLibrary:false)
    var p = Project(name:"Native origin"),o = try p.makeObject(recipeID:"artboard")
    var e = ArtworkElement(kind:text ? "text":"rectangle",x:20,y:30,width:80,height:40,text:text ? "Editable source":"",fontSize:18)
    if text { var type = Typography(); type.frameMode = "area"; e.typography = type }
    o.artwork = Artwork(elements:[e]); p.objects = [o]; store.engine.project = p
    let s = store.artworkSession; s.objectID = o.id; s.selection = [e.id]
    return(store,s,e,root)
  }
  private func assertPoint(_ a:Point2,_ b:Point2,file:StaticString = #filePath,line:UInt = #line) {
    XCTAssertEqual(a.x,b.x,accuracy:1e-8,file:file,line:line)
    XCTAssertEqual(a.y,b.y,accuracy:1e-8,file:file,line:line)
  }
  func testNativeOriginRotationAndUndoUseTheSharedCommand() throws {
    let (store,s,e,root) = try fixture(); defer { try? FileManager.default.removeItem(at:root) }
    let original = store.project!
    s.setTransformOrigin(.init(0,1)); let chosen = store.project!
    XCTAssertEqual(s.primary!.transformOrigin,.init(0,1)); XCTAssertEqual(s.primary!.localTransform,e.localTransform)
    let pivot = s.transformOrigin!
    s.rotate(90); assertPoint(s.transformOrigin!,pivot)
    XCTAssertNil(store.error); XCTAssertEqual(s.art.bounds(of:s.primary!).width,40,accuracy:1e-8)
    store.engine.undo(); XCTAssertEqual(store.project,chosen)
    store.engine.undo(); XCTAssertEqual(store.project,original)
  }
  func testNumericSizingAnchorsTheSelectedOriginWhilePositionStillUsesBounds() throws {
    let (store,s,_,root) = try fixture(); defer { try? FileManager.default.removeItem(at:root) }
    s.setTransformOrigin(.init(1,1)); let chosen = store.project!,pivot = s.transformOrigin!
    s.transformBounds(width:160,height:120)
    assertPoint(s.transformOrigin!,pivot)
    XCTAssertEqual(s.selectionBounds!.width,160,accuracy:1e-8)
    XCTAssertEqual(s.selectionBounds!.height,120,accuracy:1e-8)
    store.engine.endInteraction()
    s.transformBounds(x:12.3,y:45.6)
    XCTAssertEqual(s.selectionBounds!.x,12.3,accuracy:1e-8)
    XCTAssertEqual(s.selectionBounds!.y,45.6,accuracy:1e-8)
    store.engine.undo(); store.engine.undo(); XCTAssertEqual(store.project,chosen)
  }
  func testAreaTextReflowsAroundItsOriginWithoutScalingTypography() throws {
    let (store,s,e,root) = try fixture(true); defer { try? FileManager.default.removeItem(at:root) }
    s.setTransformOrigin(.init(1,0)); let chosen = store.project!,pivot = s.transformOrigin!
    s.transformBounds(width:120,height:65)
    assertPoint(s.transformOrigin!,pivot)
    XCTAssertEqual(s.primary!.width,120,accuracy:1e-8); XCTAssertEqual(s.primary!.height,65,accuracy:1e-8)
    XCTAssertEqual(s.primary!.fontSize,e.fontSize); XCTAssertEqual(s.primary!.typography,e.typography)
    XCTAssertEqual(s.primary!.text,e.text)
    store.engine.undo(); XCTAssertEqual(store.project,chosen)
  }
}
