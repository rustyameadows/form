import AppKit
import SwiftUI
import XCTest
import FormCore
import FormCADModel
@testable import FormApp

@MainActor final class CanvasFrameCachingTests:XCTestCase {
  private func makeStore(_ project:Project)throws->StudioStore {
    _ = NSApplication.shared
    let directory=FileManager.default.temporaryDirectory.appendingPathComponent("canvas-frame-memo-"+UUID().uuidString)
    let store=StudioStore(repository:try ProjectRepository(root:directory),seedLibrary:false)
    store.engine.project=project;store.showingHome=false
    addTeardownBlock { @MainActor in store.engine.project=nil;try? FileManager.default.removeItem(at:directory) }
    return store
  }
  private func project()throws->(Project,UUID,UUID,UUID) {
    var p=Project(name:"Exact Canvas frame inputs")
    let d=PlanarConstructionDefinition(name:"Shared folded source",parameters:[.init("width",100,60...160)],
      size:.init("2*width",50),panels:[
        .init(id:"front",name:"Front",polygon:[.init(0,0),.init("width",0),.init("width",50),.init(0,50)]),
        .init(id:"back",name:"Back",polygon:[.init("width",0),.init("2*width",0),.init("2*width",50),.init("width",50)])],
      hinges:[.init(id:"crease",parentPanelID:"front",childPanelID:"back",start:.init("width",0),end:.init("width",50),angleDegrees:-90)],rootPanelID:"front")
    p.recipes=[.init("memo-source","Shared folded source","square","Authored memo fixture",[
      .init("width","Width",100,60...160),.init("fold","Fold",100,0...100),.init("opening","Opening",0,0...100)])]
    var paper=try p.makeObject(recipeID:"memo-source"),loose=try p.makeObject(recipeID:"artboard",name:"Loose source"),inside=try p.makeObject(recipeID:"artboard",name:"Inside source")
    var settings=PaperConstruction(kind:.authored,dimensions:.init(width:100,height:50,depth:20));settings.authored=d
    settings.insideArtworkSourceID=inside.id;paper.paperConstruction=settings
    paper.artwork = .init(elements:[.init(kind:"text",x:10,y:10,width:60,height:10,text:"Outside source")])
    var text=ArtworkElement(kind:"text",x:10,y:10,width:100,height:30,text:"Global source words",fontSize:14)
    text.typography = .init();text.typography!.frameMode="area"
    loose.artwork = .init(elements:[text]);inside.artwork = .init(elements:[.init(kind:"text",x:10,y:10,text:"Inside source")]);inside.canvasSourceOnly=true
    p.objects=[paper,loose,inside]
    return(p,paper.id,loose.id,inside.id)
  }
  private func proof(_ session:ArtworkSession,_ id:UUID)throws->CanvasFrame {
    try XCTUnwrap(session.frames.first{$0.projection?.constructionID==id && $0.projection?.isProof == true})
  }
  func testTwelveCaseLayerTraversalAndRepeatedInspectorReadsBuildFramesOnlyOnce()throws {
    var p=Project(name:"Twelve paper frame graphs")
    let directory=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("examples/paper-packaging")
    let files=try FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:nil)
      .filter{$0.pathExtension=="json" && !$0.lastPathComponent.contains("liner-component")}.sorted{$0.path<$1.path}
    XCTAssertEqual(files.count,12)
    for (index,file) in files.enumerated() {
      let d=try JSONDecoder.form.decode(PlanarConstructionDefinition.self,from:Data(contentsOf:file)),net=try d.net()
      let controls:[FormCore.Parameter]=d.parameters.map{.init($0.name,$0.name,$0.value,$0.minimum...$0.maximum,unit:$0.unit)}
      p.recipes.append(.init("memo-\(index)",d.name,"square","Authored case fixture",controls+[.init("fold","Fold",100,0...100),.init("opening","Opening",0,0...100)]))
      var object=ProductObject(name:d.name,recipeID:"memo-\(index)",parameters:d.values.merging(["fold":100,"opening":0]){_,new in new})
      var paper=PaperConstruction(kind:.authored,dimensions:.init(width:d.values["width"] ?? net.size.x,height:d.values["height"] ?? net.size.y,depth:d.values["depth"] ?? 1),stock:.init(thicknessMM:try d.number(d.stockThickness)))
      paper.authored=d;object.paperConstruction=paper
      object.artwork = .init(elements:[.init(kind:"text",x:2,y:2,text:"Case \(index)")]);p.objects.append(object)
    }
    let store=try makeStore(p),session=store.artworkSession;session.objectID=p.objects[0].id;session.linkedTargetID=p.objects[0].id
    let frames=session.frames,builds=session.frameBuildCount,before=store.project!,history=store.engine.undoStack.count
    let proofs=frames.compactMap{frame->UUID? in frame.projection?.isProof == true ? frame.projection?.constructionID:nil}
    XCTAssertEqual(Set(proofs),Set(p.objects.map(\.id)));XCTAssertEqual(proofs.count,24)
    var expectedCount=0
    for object in p.objects {
      let net=try PaperConstruction.definition(for:object).net()
      expectedCount+=2*(net.panels.count+1)
      let panelIDs=frames.filter{$0.projection?.constructionID==object.id}.compactMap{$0.projection?.panelID}
      XCTAssertEqual(Set(panelIDs),Set(net.panels.map(\.id)),object.name)
    }
    XCTAssertEqual(frames.count,expectedCount)
    for _ in 0..<100 {
      XCTAssertEqual(session.frames.map(\.id),frames.map(\.id))
      _ = session.activeCanvasFrame;_ = session.art;_ = session.primary
    }
    let host=NSHostingView(rootView:ArtworkLayers(session:session).environmentObject(store))
    host.frame = .init(x:0,y:0,width:234,height:600);host.layoutSubtreeIfNeeded()
    XCTAssertGreaterThan(host.fittingSize.height,0)
    XCTAssertEqual(session.frameBuildCount,builds)
    XCTAssertEqual(store.project!.objects,before.objects);XCTAssertEqual(store.engine.undoStack.count,history)
  }
  func testDirectSourceAndGeometryAssignmentsAndUndoNeverReturnStaleFrames()throws {
    let (p,id,_,_)=try project(),store=try makeStore(p),s=store.artworkSession
    s.objectID=id;s.linkedTargetID=id
    let initial=try proof(s,id),builds=s.frameBuildCount,revision=store.revision
    var changed=p;changed.objects[0].artwork!.elements[0].text="Changed without a store revision"
    changed.objects[0].parameters["width"]=110;store.engine.project=changed
    let refreshed=try proof(s,id)
    XCTAssertEqual(store.revision,revision)
    XCTAssertEqual(refreshed.artwork.elements[0].text,"Changed without a store revision")
    XCTAssertEqual(refreshed.rect.width,220);XCTAssertNotEqual(refreshed.rect.width,initial.rect.width)
    XCTAssertGreaterThan(s.frameBuildCount,builds)
    let baseline=s.frameBuildCount
    _ = s.frames;XCTAssertEqual(s.frameBuildCount,baseline)
    let key=try XCTUnwrap(refreshed.projection?.key)
    try store.engine.edit("Moved physical view"){project in project.objects[0].canvasProjectionPositions=[key:.init(700,800)]}
    XCTAssertEqual(try proof(s,id).rect.origin,.init(x:700,y:800))
    let movedBuilds=s.frameBuildCount
    store.engine.undo();XCTAssertEqual(try proof(s,id).rect,refreshed.rect)
    XCTAssertGreaterThan(s.frameBuildCount,movedBuilds,"A single-entry memo rebuilds the returned older snapshot")
    store.engine.redo();XCTAssertEqual(try proof(s,id).rect.origin,.init(x:700,y:800))
  }
  func testTableCameraOnlyUpdatesReuseCanonicalFrames()throws {
    let (p,id,_,_)=try project(),store=try makeStore(p),s=store.artworkSession
    s.objectID=id;s.linkedTargetID=id
    let frames=s.frames,count=s.frameBuildCount,history=store.engine.undoStack.count
    for step in 1...30 {
      var orbit=p;orbit.camera.azimuth=Double(step)/10;orbit.camera.distance=12+Double(step)
      orbit.camera.target = .init(Double(step),2,3);store.engine.project=orbit
      let current=s.frames
      XCTAssertEqual(current.map(\.id),frames.map(\.id));XCTAssertEqual(current.map(\.rect),frames.map(\.rect))
      XCTAssertEqual(current.map(\.artwork),frames.map(\.artwork))
    }
    XCTAssertEqual(s.frameBuildCount,count);XCTAssertEqual(store.engine.undoStack.count,history)
  }
  func testGlobalStorySwatchAndStyleChangesInvalidateEvenWhenFrameObjectsDoNotChange()throws {
    var (p,_,id,_)=try project()
    let index=try XCTUnwrap(p.objects.firstIndex{$0.id==id}),elementID=try XCTUnwrap(p.objects[index].artwork?.elements.first?.id)
    let swatch=ArtworkSwatch(name:"Story ink",color:"#224466");p.swatches=[swatch]
    p.objects[index].artwork!.elements[0].fillSwatchID=swatch.id
    let style=try TextStyleCommands.save(in:&p,name:"Story style",typography:.init(),fontSize:14)
    try TextStyleCommands.apply(in:&p,objectID:id,ids:[elementID],styleID:style)
    _ = try PublicationCommands.createStory(in:&p,frames:[.init(objectID:id,elementID:elementID)])
    let store=try makeStore(p),s=store.artworkSession;s.objectID=id
    func story()throws->TextStory {try XCTUnwrap(s.frames.first{$0.object.id==id && $0.projection==nil}?.artwork.elements.first?.storyFrame?.resolved?.story)}
    XCTAssertEqual(try story().text,"Global source words");let first=s.frameBuildCount,objects=p.objects
    p.textStories![0].text="Updated shared story";p.swatches![0].color="#AA7733";store.engine.project=p
    XCTAssertEqual(p.objects,objects);XCTAssertEqual(try story().text,"Updated shared story")
    XCTAssertEqual(try story().color,"#AA7733");XCTAssertGreaterThan(s.frameBuildCount,first)
    let second=s.frameBuildCount
    let typography=p.textStyles![0].typography
    try TextStyleCommands.save(in:&p,id:style,name:"Story style",typography:typography,fontSize:24)
    store.engine.project=p
    XCTAssertEqual(try story().fontSize,24);XCTAssertGreaterThan(s.frameBuildCount,second)
  }
  func testInsideNavigationActivePanelAndComponentContextUseCurrentInputs()throws {
    let (p,id,loose,inside)=try project(),store=try makeStore(p),s=store.artworkSession
    s.activate(id)
    let outside=try XCTUnwrap(s.activeCanvasFrame);XCTAssertEqual(outside.projection?.inside,false)
    let outsideIDs=s.frames.map(\.id),count=s.frameBuildCount,history=store.engine.undoStack.count,before=store.project!
    let panels=s.frames.filter{$0.projection?.constructionID==id && $0.projection?.panelID != nil && $0.projection?.inside==false}
    XCTAssertEqual(panels.count,2)
    for panel in panels {s.projectionFrameID=panel.id;XCTAssertEqual(s.activeCanvasFrame?.id,panel.id)}
    XCTAssertEqual(s.frameBuildCount,count,"Choosing another existing frame only changes the active resolver")
    s.activate(inside);XCTAssertEqual(s.activeProjection?.inside,true);XCTAssertEqual(s.objectID,inside)
    XCTAssertEqual(s.frames.map(\.id),outsideIDs,"Side navigation retains the complete graph.")
    XCTAssertEqual(s.frameBuildCount,count,"Side navigation reuses both canonical face graphs.")
    s.activate(id);XCTAssertEqual(s.frames.map(\.id),outsideIDs);XCTAssertEqual(s.activeProjection?.inside,false)
    let afterNavigation=s.frameBuildCount
    s.componentReturn = .init(objectID:loose,linkedTargetID:id,instanceID:UUID());_ = s.frames
    XCTAssertGreaterThan(s.frameBuildCount,afterNavigation)
    s.componentReturn=nil;_ = s.frames
    XCTAssertEqual(store.project!.objects,before.objects);XCTAssertEqual(store.engine.undoStack.count,history)
    store.engine.project=nil;XCTAssertTrue(s.frames.isEmpty)
    store.engine.project=before;XCTAssertFalse(s.frames.isEmpty)
  }
  func testLegacyDielineAndLinkedTargetContextCannotReuseWrongDimensions()throws {
    var p=Project(name:"Legacy unfolding context"),sheet=try p.makeObject(recipeID:"artboard",parameters:["width":120,"depth":100])
    sheet.artwork = .init(elements:[.init(kind:"rectangle",x:2,y:2,width:20,height:10)])
    let sleeve=try p.makeObject(recipeID:"sleeve");p.objects=[sheet,sleeve]
    let store=try makeStore(p),s=store.artworkSession;s.objectID=sheet.id;s.linkedTargetID=sleeve.id
    let ordinary=try XCTUnwrap(s.activeCanvasFrame),count=s.frameBuildCount
    s.dieline=true;let unfolded=try XCTUnwrap(s.activeCanvasFrame)
    XCTAssertNotEqual(unfolded.rect.size,ordinary.rect.size);XCTAssertEqual(unfolded.surfaceObject.id,sleeve.id)
    XCTAssertGreaterThan(s.frameBuildCount,count)
    s.linkedTargetID=sheet.id;let unlinked=try XCTUnwrap(s.activeCanvasFrame)
    XCTAssertEqual(unlinked.surfaceObject.id,sheet.id);XCTAssertEqual(unlinked.rect.size,ordinary.rect.size)
  }
}
