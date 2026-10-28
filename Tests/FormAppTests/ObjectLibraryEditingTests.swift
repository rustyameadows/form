import AppKit
import FormCore
import Metal
import FormGeometry
import SwiftUI
import XCTest
@testable import FormApp

@MainActor final class ObjectLibraryEditingTests: XCTestCase {
  private func store() throws -> StudioStore {
    _=NSApplication.shared
    let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    addTeardownBlock {try? FileManager.default.removeItem(at:root)}
    let store=StudioStore(repository:try ProjectRepository(root:root),seedLibrary:false)
    store.engine.project=Project(name:"Library editing"); store.showingHome=false
    store.scene=TableSceneController(store:store)
    return store
  }
  func testNativeAddUsesFullFootprintAutosavesAndSharesUndo() async throws {
    let s=try store()
    defer { s.engine.project=nil }
    for id in ["pullover-hoodie","cuffed-beanie","bandana"] {
      XCTAssertTrue(s.useLibraryEntry(ObjectLibrary.entry(id)!))
    }
    XCTAssertEqual(s.project?.objects.count,3); XCTAssertNil(s.error)
    let objects=s.project!.objects
    for (a,b) in zip(objects,objects.dropFirst()) {
      XCTAssertGreaterThan(b.position.x-b.footprintWidth/2,a.position.x+a.footprintWidth/2)
    }
    XCTAssertEqual(s.engine.undoStack.count,3)
    let deadline=Date().addingTimeInterval(5)
    while s.saving && Date()<deadline {try await Task.sleep(for:.milliseconds(20))}
    XCTAssertFalse(s.saving)
    let saved=try s.repository.load(s.project!.id)
    XCTAssertEqual(saved.objects,objects)
    s.undo(); XCTAssertEqual(s.project?.objects.count,2)
    s.redo(); XCTAssertEqual(s.project?.objects,objects)
  }
  func testAllNewGeometryHasExpectedPartsAndCannotBecomeAnFDMObject() throws {
    let p=try Samples.giftShopCollection(), scene=TableSceneController()
    scene.sync(p,selection:[],isolated:[],showGrid:false,studio:true,preset:"Daylight",assets:FileManager.default.temporaryDirectory)
    for (recipe,name) in [("pulloverHoodie","Open laid-out hood"),("cuffedBeanie","Turned cuff"),("hemmedTextile","Folded hem stitch line")] {
      let o=try XCTUnwrap(p.objects.first{$0.recipeID == recipe})
      let n=try XCTUnwrap(scene.objectRoot.childNode(withName:"object:\(o.id.uuidString)",recursively:false))
      XCTAssertNotNil(n.childNode(withName:name,recursively:true),recipe)
      XCTAssertGreaterThan(n.boundingBox.max.x-n.boundingBox.min.x,1)
      XCTAssertThrowsError(try PrintMeshBuilder.mesh(object:o,project:p,assets:FileManager.default.temporaryDirectory,configuration:.init()))
    }
  }
  func testChoosingAProductDoesNotRebuildItsMeshOrMoveCamera() throws {
    let s=try store(); defer{s.engine.project=nil}
    XCTAssertTrue(s.useLibraryEntry(ObjectLibrary.entry("jersey-tee")!))
    let scene=s.scene!, p=s.project!, id=p.objects[0].id, camera=scene.camera, builds=scene.geometryBuilds
    s.perform("form_object_library",["command":"state","object_id":id.uuidString,"state":"chosenBlank"])
    s.synchronizeScene()
    XCTAssertEqual(scene.geometryBuilds,builds); XCTAssertEqual(scene.camera,camera)
    XCTAssertEqual(s.project?.objects[0].librarySelection?.state,.chosenBlank)
    s.undo(); XCTAssertEqual(s.project,p)
  }
  func testBrowserAndGarmentPreviewRenderFromActualNativeViews() async throws {
    let s=try store(); defer{s.engine.project=nil}
    let host=NSHostingView(rootView:ObjectLibraryView().environmentObject(s))
    let window=NSWindow(contentRect:NSRect(x:0,y:0,width:960,height:680),styleMask:[.borderless],backing:.buffered,defer:false)
    window.isReleasedWhenClosed=false
    window.contentView=host; host.layoutSubtreeIfNeeded()
    let rep=try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in:host.bounds))
    host.cacheDisplay(in:host.bounds,to:rep)
    XCTAssertGreaterThan(rep.pixelsWide,900); XCTAssertGreaterThan(rep.pixelsHigh,600)
    if let output=ProcessInfo.processInfo.environment["OBJECT_LIBRARY_PROOF_DIR"] {
      let folder=URL(fileURLWithPath:output); try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
      try XCTUnwrap(rep.representation(using:.png,properties:[:])).write(to:folder.appendingPathComponent("library-browser.png"))
      let p=try Samples.giftShopCollection()
      var shot=StudioShot(name:"Starter assortment",camera:p.camera,referenceAspect:1.5);shot.pixels = .init(width:1500,height:1000)
      let image=try await StudioShotRenderer().render(project:p,shot:shot,assets:s.repository.root,preview:false)
      let tiff=try XCTUnwrap(image.tiffRepresentation), bitmap=try XCTUnwrap(NSBitmapImageRep(data:tiff))
      try XCTUnwrap(bitmap.representation(using:.png,properties:[:])).write(to:folder.appendingPathComponent("starter-assortment.png"))
    }
    window.contentView=nil; window.close()
  }
}
