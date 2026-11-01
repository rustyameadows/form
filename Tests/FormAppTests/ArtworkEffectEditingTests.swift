import AppKit
import XCTest
import FormCore
@testable import FormApp

@MainActor final class ArtworkEffectEditingTests:XCTestCase {
  func testInspectorEditsOnlyItsLayerAndOneUndoRedoSaveReopenPreservesEditableText()throws {
    _=NSApplication.shared
    let directory=FileManager.default.temporaryDirectory.appendingPathComponent("effect-edit-"+UUID().uuidString)
    let repository=try ProjectRepository(root:directory),store=StudioStore(repository:repository,seedLibrary:false)
    defer{store.engine.project=nil;try? FileManager.default.removeItem(at:directory)}
    var project=Project(name:"Editable ordered effects");let owner=try project.ensureCanvasWorkspace()
    var text=ArtworkElement(kind:"text",x:0,y:0,width:80,height:40,text:"Native text 😀")
    text.effectStack = .init(coverage:"paint-outline",effects:[.init(kind:"drop-shadow",blur:1),.init(kind:"inner-shadow",blur:2)])
    var sibling=ArtworkElement(kind:"rectangle",x:90,y:0,width:20,height:20)
    sibling.effectStack = .init(effects:[.init(kind:"blur",blur:3)])
    try project.setArtwork(.init(elements:[text,sibling]),for:owner.id)
    store.engine.project=project;store.artworkSession.objectID=owner.id;store.artworkSession.selection=[text.id,sibling.id]
    let before=try XCTUnwrap(store.project)
    store.artworkSession.editEffectStack(elementID:text.id){$0.effects[0].spread=2;$0.effects[0].offset = .init(-4,5);$0.effects[0].blendMode="multiply"}
    XCTAssertNil(store.error);XCTAssertEqual(store.engine.undoStack.count,1)
    let changed=try XCTUnwrap(store.project),layers=try XCTUnwrap(changed.canvasWorkspace?.artwork?.elements)
    XCTAssertEqual(layers[1],sibling);XCTAssertEqual(layers[0].text,text.text);XCTAssertNil(layers[0].path)
    XCTAssertEqual(layers[0].effectStack?.coverage,"paint-outline");XCTAssertEqual(layers[0].effectStack?.effects[1],text.effectStack?.effects[1])
    XCTAssertEqual(layers[0].effectStack?.effects[0].spread,2)
    store.engine.undo();XCTAssertEqual(store.project,before)
    store.engine.redo();XCTAssertEqual(store.project,changed)
    try store.engine.flush()
    XCTAssertEqual(try repository.load(changed.id).objects,changed.objects)
  }
  func testInspectorReorderDisableAndRemoveKeepUndoExactAndStaleSelectionDoesNothing()throws {
    _=NSApplication.shared
    let directory=FileManager.default.temporaryDirectory.appendingPathComponent("effect-order-"+UUID().uuidString)
    let store=StudioStore(repository:try ProjectRepository(root:directory),seedLibrary:false)
    defer{store.engine.project=nil;try? FileManager.default.removeItem(at:directory)}
    var project=Project(name:"Order");let owner=try project.ensureCanvasWorkspace()
    var layer=ArtworkElement(kind:"rectangle",x:0,y:0,width:30,height:20)
    layer.effectStack = .init(effects:[.init(kind:"drop-shadow",color:"#FF0000"),.init(kind:"inner-shadow",color:"#0000FF")])
    try project.setArtwork(.init(elements:[layer]),for:owner.id)
    store.engine.project=project;store.artworkSession.objectID=owner.id;store.artworkSession.selection=[layer.id]
    store.artworkSession.editEffectStack(elementID:layer.id,structural:true){$0.effects.swapAt(0,1);$0.effects[0].enabled=false}
    let changed=try XCTUnwrap(store.project)
    XCTAssertEqual(changed.canvasWorkspace?.artwork?.elements[0].effectStack?.effects.map(\.kind),["inner-shadow","drop-shadow"])
    XCTAssertEqual(changed.canvasWorkspace?.artwork?.elements[0].effectStack?.effects[0].enabled,false)
    store.artworkSession.editEffectStack(elementID:layer.id,structural:true){$0.effects.removeLast()}
    store.engine.undo();XCTAssertEqual(store.project,changed)
    store.artworkSession.selection=[]
    store.artworkSession.editEffectStack(elementID:layer.id){$0.effects=[]}
    XCTAssertEqual(store.project,changed)
  }
}
