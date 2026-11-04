import AppKit
import FormCADModel
import FormCore
import SwiftUI
import XCTest
@testable import FormApp

@MainActor final class PartAssemblyNativeEditingTests:XCTestCase {
  private func fixture()throws->(StudioStore,UUID) {
    _=NSApplication.shared
    let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store=StudioStore(repository:try ProjectRepository(root:directory),seedLibrary:false)
    var definition=PlanarConstructionDefinition(name:"Separate display material",parameters:[.init("span",60,20...200)],size:.init("span",50),stockThickness:0.7,panels:[
      .init(id:"plate",name:"Display piece",polygon:[.init(0,0),.init("span",0),.init("span",50),.init(0,50)])],rootPanelID:"plate",components:[
      .init(id:"plate",name:"Display piece",rootPanelID:"plate",anchor:.init(0,50),position:.init(),rotationDegrees:.init(-90,0,0))])
    definition.version=4;definition.controls = .init(parameters:[.init(parameter:"span",label:"Finished span")])
    let art=Artwork(background:"#FFFFFF",elements:[.init(kind:"text",x:8,y:9,width:40,height:12,text:"Retain this source",color:"#18382F",fontSize:11)],bleed:0)
    let starter=ConstructionStarter(id:"display-material",name:"Display material",definition:definition,stock:.init(thicknessMM:0.7),artwork:art)
    var project=Project(name:"Native staged assemblies");let result=try project.importConstructionStarter(starter)
    store.engine.project=project;store.showingHome=false
    addTeardownBlock{@MainActor in store.engine.project=nil;try? FileManager.default.removeItem(at:directory)}
    return(store,result.objectID)
  }
  func testPreviewDoesNotPublishAndNativeApplyIsOneUndoableSourcePreservingEdit()throws {
    let (store,id)=try fixture(),before=try XCTUnwrap(store.project),object=try XCTUnwrap(before.objects.first{$0.id==id})
    let original=try XCTUnwrap(object.paperConstruction?.authored);var draft=original;try draft.setParameters(["span":90])
    let preview=try PartAssemblyNativeEditing.preview(project:before,objectID:id,definition:draft)
    XCTAssertEqual(store.project,before);XCTAssertTrue(store.engine.undoStack.isEmpty)
    XCTAssertEqual(preview.object.parameters["span"],90);XCTAssertEqual(preview.activePieces,1)
    XCTAssertTrue(PartAssemblyNativeEditing.apply(store:store,projectID:before.id,objectID:id,expectedRevision:try ConstructionSourceEditing.revision(original),definition:draft),store.error ?? "Native apply failed")
    let after=try XCTUnwrap(store.project),changed=try XCTUnwrap(after.objects.first{$0.id==id})
    XCTAssertEqual(changed.artwork,object.artwork);XCTAssertEqual(changed.parameters["span"],90)
    XCTAssertEqual(after.camera,before.camera);XCTAssertEqual(store.engine.undoStack.count,1)
    store.engine.undo();XCTAssertEqual(store.project,before);store.engine.redo();XCTAssertEqual(store.project,after)
  }
  func testInvalidAndStaleNativeCandidatesCannotChangeAcceptedSourcesOrHistory()throws {
    let (store,id)=try fixture(),before=try XCTUnwrap(store.project),object=try XCTUnwrap(before.objects.first{$0.id==id}),original=try XCTUnwrap(object.paperConstruction?.authored)
    var invalid=original;invalid.parameters[0].value = -10
    XCTAssertThrowsError(try PartAssemblyNativeEditing.preview(project:before,objectID:id,definition:invalid))
    XCTAssertFalse(PartAssemblyNativeEditing.apply(store:store,projectID:before.id,objectID:id,expectedRevision:try ConstructionSourceEditing.revision(original),definition:invalid))
    XCTAssertEqual(store.project,before);XCTAssertTrue(store.engine.undoStack.isEmpty)
    for target in [(UUID(),id),(before.id,UUID())] {
      XCTAssertFalse(PartAssemblyNativeEditing.apply(store:store,projectID:target.0,objectID:target.1,expectedRevision:try ConstructionSourceEditing.revision(original),definition:original))
      XCTAssertEqual(store.project,before);XCTAssertTrue(store.engine.undoStack.isEmpty)
    }
    var imported=before;imported.id=UUID();store.engine.project=imported
    XCTAssertFalse(PartAssemblyNativeEditing.apply(store:store,projectID:before.id,objectID:id,expectedRevision:try ConstructionSourceEditing.revision(original),definition:original))
    XCTAssertEqual(store.project,imported);XCTAssertTrue(store.engine.undoStack.isEmpty)
  }
  func testNativePieceSourceCreationRejectsStaleProjectAndPreservesPartIdentity()throws {
    let (store,id)=try fixture(),before=try XCTUnwrap(store.project),original=try XCTUnwrap(before.objects.first{$0.id==id}?.paperConstruction?.authored),revision=try ConstructionSourceEditing.revision(original)
    XCTAssertNil(PartAssemblyNativeEditing.createArtwork(store:store,projectID:UUID(),objectID:id,componentID:"plate",side:.outside,expectedRevision:revision))
    XCTAssertEqual(store.project,before);XCTAssertTrue(store.engine.undoStack.isEmpty)
    let sourceID=try XCTUnwrap(PartAssemblyNativeEditing.createArtwork(store:store,projectID:before.id,objectID:id,componentID:"plate",side:.outside,expectedRevision:revision))
    let after=try XCTUnwrap(store.project),source=try XCTUnwrap(after.objects.first{$0.id==sourceID})
    XCTAssertEqual(after.objects.first{$0.id==id}?.paperConstruction?.authored?.components?.first?.id,"plate")
    XCTAssertEqual(after.objects.first{$0.id==id}?.paperConstruction?.authored?.components?.first?.front?.sourceObjectID,sourceID)
    XCTAssertEqual(source.artworkSize,.init(60,50));XCTAssertEqual(source.canvasSourceOnly,true)
    XCTAssertEqual(source.artwork?.backgroundOpacity,0);XCTAssertEqual(store.engine.undoStack.count,1)
    XCTAssertEqual(after.camera,before.camera)
    store.engine.undo();XCTAssertEqual(store.project,before)
  }
  func testExplicitTablePieceSelectionDoesNotChangeOwnerCameraInspectorOrUndo()throws {
    let (store,id)=try fixture(),before=try XCTUnwrap(store.project)
    store.engine.selection=[id]
    store.constructionTableTarget = .init(ownerID:id,kind:.joint,jointID:"old-seam",panelIDs:["another-part"])
    store.paperSelectedFoldID="old-fold"
    let selection=store.engine.selection,visible=store.tableInspectorVisible
    XCTAssertFalse(PartAssemblyNativeEditing.selectTablePart(store:store,projectID:UUID(),objectID:id,componentID:"plate"))
    XCTAssertTrue(PartAssemblyNativeEditing.selectTablePart(store:store,projectID:before.id,objectID:id,componentID:"plate"))
    XCTAssertEqual(store.paperSelectedPanelID,"plate");XCTAssertEqual(store.engine.selection,selection)
    XCTAssertNil(store.constructionTableTarget);XCTAssertNil(store.paperSelectedFoldID)
    XCTAssertEqual(store.tableInspectorVisible,visible);XCTAssertEqual(store.project,before);XCTAssertTrue(store.engine.undoStack.isEmpty)
  }
  func testCaliperPreviewAndApplyKeepBondedLayersInAgreement()throws {
    let (store,id)=try fixture()
    let index=try XCTUnwrap(store.engine.project?.objects.firstIndex{$0.id==id})
    store.engine.project!.objects[index].paperConstruction!.stock.plies=[.init(name:"Back",color:"#112233",thicknessMM:0.2),.init(name:"Face",color:"#DDBB88",thicknessMM:0.5)]
    let before=try XCTUnwrap(store.project),object=try XCTUnwrap(before.objects.first{$0.id==id}),original=try XCTUnwrap(object.paperConstruction?.authored)
    var draft=original;draft.stockThickness=0.9
    let preview=try PartAssemblyNativeEditing.preview(project:before,objectID:id,definition:draft)
    XCTAssertEqual(preview.object.paperConstruction?.stock.resolvedThicknessMM ?? 0,0.9,accuracy:1e-9)
    XCTAssertEqual(store.project,before);XCTAssertTrue(store.engine.undoStack.isEmpty)
    XCTAssertTrue(PartAssemblyNativeEditing.apply(store:store,projectID:before.id,objectID:id,expectedRevision:try ConstructionSourceEditing.revision(original),definition:draft),store.error ?? "Caliper apply failed")
    let stock=try XCTUnwrap(store.project?.objects.first{$0.id==id}?.paperConstruction?.stock)
    XCTAssertEqual(stock.plies?.map(\.id),object.paperConstruction?.stock.plies?.map(\.id))
    XCTAssertEqual((stock.plies?[0].thicknessMM ?? 0)/(stock.plies?[1].thicknessMM ?? 1),0.4,accuracy:1e-9)
    XCTAssertEqual(stock.resolvedThicknessMM,0.9,accuracy:1e-9);XCTAssertEqual(store.engine.undoStack.count,1)
    store.engine.undo();XCTAssertEqual(store.project,before)
  }
  func testNativePartObserverIgnoresAnotherConstructionWithTheSamePanelIDs()throws {
    let (store,id)=try fixture(),index=try XCTUnwrap(store.engine.project?.objects.firstIndex{$0.id==id})
    var first=store.engine.project!.objects[index],definition=try XCTUnwrap(first.paperConstruction?.authored)
    definition.size.x="span+100"
    definition.panels.append(.init(id:"second",name:"Second piece",polygon:[.init(80,0),.init(110,0),.init(110,50),.init(80,50)]))
    definition.components!.append(.init(id:"second",name:"Second piece",rootPanelID:"second",anchor:.init(80,50),position:.init(),rotationDegrees:.init(-90,0,0)))
    first.paperConstruction!.authored=definition
    var second=first;second.id=UUID();second.designID=UUID();second.name="Independent second assembly"
    store.engine.project!.objects=[first,second];store.engine.selection=[second.id]
    var selected:String?="plate",draft=definition
    let projectID=try XCTUnwrap(store.project?.id)
    let host=NSHostingView(rootView:PartAssemblyPartsControls(definition:Binding(get:{draft},set:{draft=$0}),componentID:Binding(get:{selected},set:{selected=$0}),object:second,projectID:projectID,canCreateArtwork:false,createArtwork:{_,_ in}).environmentObject(store))
    let window=NSWindow(contentRect:.init(x:-10000,y:-10000,width:340,height:600),styleMask:[.titled],backing:.buffered,defer:false)
    window.isReleasedWhenClosed=false;window.contentView=host;window.orderBack(nil);defer{window.close()}
    func settle(){host.layoutSubtreeIfNeeded();RunLoop.main.run(until:Date().addingTimeInterval(0.04));host.layoutSubtreeIfNeeded()}
    settle();let before=store.project!,camera=store.project!.camera,inspector=store.tableInspectorVisible
    store.paperSelectionObjectID=first.id;store.paperSelectedPanelID="second";store.artworkSession.paperFocusPanelID="second"
    settle();XCTAssertEqual(selected,"plate","A shared panel name cannot transfer another owner's selection into this inspector.")
    store.paperSelectionObjectID=second.id;store.changed(save:false);settle()
    XCTAssertEqual(selected,"second","An explicit matching-owner selection must synchronize even when the panel ID is unchanged.")
    XCTAssertEqual(store.engine.selection,[second.id]);XCTAssertEqual(store.project!.camera,camera);XCTAssertEqual(store.tableInspectorVisible,inspector)
    XCTAssertEqual(store.project,before);XCTAssertTrue(store.engine.undoStack.isEmpty)
  }
}
