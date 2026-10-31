import AppKit
import FormCore
import XCTest
@testable import FormApp

@MainActor final class LinkedObjectViewRendererTests: XCTestCase {
  private final class Gate {
    var first: CheckedContinuation<Void, Never>?
    var calls = 0
  }
  func testSourceChangesCancelStaleRenderAndPreserveUndo() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = try ProjectRepository(root:root)
    let store = StudioStore(repository:repository,seedLibrary:false)
    var source = ProductObject(name:"Source",recipeID:"test",parameters:["width":1])
    var view = ArtworkElement(kind:"image",x:0,y:0,width:50,height:50,asset:"old.png")
    view.objectView = .init(sourceID:source.id,style:"rendered",linked:true)
    let page = ProductObject(name:"Page",recipeID:"artboard",parameters:[:],artwork:Artwork(elements:[view]))
    var project = Project(name:"Refresh"); project.objects=[source,page]
    store.engine.project=project
    let started = expectation(description:"first capture starts")
    let second = expectation(description:"replacement capture starts")
    let gate = Gate()
    let coordinator = LinkedObjectViewRenderer(store:store) { object, _, _, _, _, _, _ in
      gate.calls += 1
      if object["width"] == 2 {
        started.fulfill()
        await withCheckedContinuation { gate.first = $0 }
        return Data("stale".utf8)
      }
      second.fulfill(); return Data("current".utf8)
    }
    coordinator.synchronize(project)
    try store.engine.edit("First edit") { $0.objects[0].parameters["width"] = 2 }
    coordinator.synchronize(store.project)
    await fulfillment(of:[started],timeout:5)
    try store.engine.edit("Second edit") { $0.objects[0].parameters["width"] = 3 }
    coordinator.synchronize(store.project)
    await fulfillment(of:[second],timeout:5)
    gate.first?.resume(); gate.first=nil
    for _ in 0..<100 where store.project?.objects[1].artwork?.elements[0].asset == "old.png" { await Task.yield() }
    let name = try XCTUnwrap(store.project?.objects[1].artwork?.elements[0].asset)
    XCTAssertNotEqual(name,"old.png")
    let bytes = try Data(contentsOf:repository.url(for:project.id).appendingPathComponent("Assets").appendingPathComponent(name))
    XCTAssertEqual(bytes,Data("current".utf8))
    XCTAssertEqual(store.engine.undoStack.count,2)
    store.engine.undo()
    XCTAssertEqual(store.project?.objects[0]["width"],2)
    XCTAssertEqual(store.project?.objects[1].artwork?.elements[0].asset,"old.png")
    store.engine.redo()
    XCTAssertEqual(store.project?.objects[0]["width"],3)
    XCTAssertEqual(store.project?.objects[1].artwork?.elements[0].asset,name)
    coordinator.reset()
  }
  func testPendingCapturePersistsAndResumesOnOpenWithoutUndo() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at:root) }
    let repository = try ProjectRepository(root:root)
    let store = StudioStore(repository:repository,seedLibrary:false)
    let source = ProductObject(name:"Source",recipeID:"test",parameters:["width":1])
    var view = ArtworkElement(kind:"image",x:0,y:0,width:50,height:50,asset:"old.png")
    view.objectView = .init(sourceID:source.id,style:"rendered",linked:true)
    let page = ProductObject(name:"Page",recipeID:"artboard",parameters:[:],artwork:Artwork(elements:[view]))
    var before=Project(name:"Pending"); before.objects=[source,page]
    var changed=before; changed.objects[0].parameters["width"]=2
    LinkedObjectViewRenderer.markPending(before:before,project:&changed)
    XCTAssertEqual(changed.objects[1].artwork?.elements[0].objectView?.renderPending,true)
    let reopened = try JSONDecoder.form.decode(Project.self,from:JSONEncoder.form.encode(changed))
    store.engine.project=reopened
    let rendered=expectation(description:"saved pending render resumed")
    let coordinator=LinkedObjectViewRenderer(store:store) { _,_,_,_,_,_,_ in
      rendered.fulfill(); return Data("resumed".utf8)
    }
    coordinator.synchronize(reopened)
    await fulfillment(of:[rendered],timeout:5)
    for _ in 0..<100 where store.project?.objects[1].artwork?.elements[0].objectView?.renderPending == true { await Task.yield() }
    XCTAssertEqual(store.project?.objects[1].artwork?.elements[0].objectView?.renderPending,false)
    XCTAssertNotEqual(store.project?.objects[1].artwork?.elements[0].asset,"old.png")
    XCTAssertTrue(store.engine.undoStack.isEmpty)
    coordinator.reset()
  }

  func testPendingMarkIncludesMaterialChangesButNotFrozenViews() throws {
    let source=ProductObject(name:"Source",recipeID:"test",parameters:[:])
    var live=ArtworkElement(kind:"image",x:0,y:0,asset:"live.png")
    live.objectView = .init(sourceID:source.id,style:"rendered",linked:true)
    var frozen=ArtworkElement(kind:"image",x:0,y:0,asset:"frozen.png")
    frozen.objectView = .init(sourceID:source.id,style:"rendered",linked:false)
    let page=ProductObject(name:"Page",recipeID:"artboard",parameters:[:],artwork:Artwork(elements:[live,frozen]))
    var before=Project(name:"Materials"); before.objects=[source,page]
    var after=before; after.materials=[Material.presets[0]]
    LinkedObjectViewRenderer.markPending(before:before,project:&after)
    XCTAssertEqual(after.objects[1].artwork?.elements[0].objectView?.renderPending,true)
    XCTAssertNil(after.objects[1].artwork?.elements[1].objectView?.renderPending)
  }

}
