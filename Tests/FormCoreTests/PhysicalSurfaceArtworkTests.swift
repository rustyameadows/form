import Foundation
import XCTest
import FormCADModel
@testable import FormCore

final class PhysicalSurfaceArtworkTests:XCTestCase {
  private func fixture()throws->(OperationEngine,UUID,UUID) {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("physical-surfaces-"+UUID().uuidString)
    addTeardownBlock{try? FileManager.default.removeItem(at:root)}
    let engine=OperationEngine(repository:try ProjectRepository(root:root))
    var p=Project(name:"Mapped surfaces"),sheet=try p.makeObject(recipeID:"artboard",parameters:["width":100,"depth":50])
    sheet.artwork = .init(background:"#FFFFFF",elements:[.init(kind:"text",x:4,y:6,text:"Upright source",fontSize:12)])
    let feature=CADFeatureNode(name:"Body",operation:.init(.box,values:["width":100,"height":20,"depth":50]))
    let surface=CADPlanarSurface(id:"top",name:"Top",outputFeatureID:feature.id,selection:.faceAtMaximum(axis:"y"),origin:.init(0,20,50),uAxis:.xAxis,vAxis:.init(0,0,-1),width:100,height:50)
    let definition=CADModelDefinition(name:"Body",features:[feature],outputs:[feature.id],surfaces:[surface])
    let hash=String(repeating:"a",count:64)
    var component=CADComponentRepresentation(id:feature.id,name:"Body",brepAsset:"body.brep",brepSHA256:hash,meshAsset:"body.mesh",meshSHA256:hash,minimum:.init(),maximum:.init(100,20,50),volumeMM3:100000,valid:true,closed:true,solidCount:1,faceCount:6,edgeCount:12,vertexCount:8,triangleCount:12)
    component.featureFingerprint=hash
    var representation=CADRepresentation(modelID:definition.id,definitionSHA256:try CADRepresentation.definitionHash(definition),kernelVersion:"test",components:[component])
    var resolved=try surface.resolved(using:[:]);resolved.faceIndex=1;resolved.fingerprint=hash
    representation.resolvedSurfaces=[resolved]
    var model=ProductObject(name:"Body",recipeID:"cadModel",parameters:[:]);model.cadModel=definition;model.cadRepresentation=representation
    p.objects=[sheet,model];engine.project=p;return(engine,model.id,sheet.id)
  }
  func testNamedExactSurfaceUsesPolygonSafetyRatherThanItsBoundingRectangle()throws {
    let (engine,id,sourceID)=try fixture()
    try engine.edit("Declared triangular print region"){p in
      let i=p.objects.firstIndex{$0.id==id}!
      p.objects[i].cadModel!.surfaces![0].boundary=[.init(0,0),.init(100,0),.init(0,50)]
      p.objects[i].cadRepresentation!.definitionSHA256=try CADRepresentation.definitionHash(p.objects[i].cadModel!)
      p.objects[i].cadRepresentation!.resolvedSurfaces![0].boundary=[.init(0,0),.init(100,0),.init(0,50)]
    }
    let before=try XCTUnwrap(engine.project),undo=engine.undoStack.count
    let intent=PhysicalArtworkIntent(surface:.init(kind:.cadSurface,surfaceID:"top"),bleedMM:2,safeInsetMM:3)
    _ = try engine.call("form_surface",arguments:["command":"set_intent","object_id":id.uuidString,"intent":try jsonObject(intent)])
    let current=try XCTUnwrap(engine.project),object=try XCTUnwrap(current.objects.first{$0.id==id})
    let report=try current.physicalArtworkIntentReport(for:object),guide=try XCTUnwrap(report.guides.first)
    XCTAssertTrue(report.issues.isEmpty);XCTAssertFalse(guide.safe.isEmpty)
    for p in guide.safe.flatMap({$0}) {
      XCTAssertGreaterThanOrEqual(p.x,2.999);XCTAssertGreaterThanOrEqual(p.y,2.999)
      XCTAssertLessThanOrEqual(p.x/100+p.y/50,1-3*hypot(0.01,0.02)+0.0001)
    }
    XCTAssertEqual(object.cadRepresentation,before.objects.first{$0.id==id}?.cadRepresentation)
    XCTAssertEqual(current.objects.first{$0.id==sourceID},before.objects.first{$0.id==sourceID})
    XCTAssertEqual(engine.undoStack.count,undo+1)
    engine.undo();XCTAssertEqual(engine.project,before)
  }
  func testNamedBindingIsOneUndoAndPreservesOriginalSource()throws {
    let (e,modelID,sourceID)=try fixture(),before=e.project!
    _ = try e.call("form_surface",arguments:["command":"bind","object_id":modelID.uuidString,"surface_id":"top","source_object_id":sourceID.uuidString])
    XCTAssertEqual(e.undoStack.count,1)
    let binding=try XCTUnwrap(e.project!.objects.first{$0.id==modelID}?.surfaceArtworkBindings?.first)
    XCTAssertEqual(e.project!.physicalSurfaceArtwork(binding),before.objects[0].artwork)
    XCTAssertEqual(e.project!.objects[0],before.objects[0])
    try e.flush();XCTAssertEqual(try e.repository.load(e.project!.id).objects,e.project!.objects)
    e.undo();XCTAssertEqual(e.project,before)
  }
  func testDeletingSourcePreservesDetachedSurfaceAndUndoRestoresLink()throws {
    let (e,modelID,sourceID)=try fixture()
    _ = try e.call("form_surface",arguments:["command":"bind","object_id":modelID.uuidString,"surface_id":"top","source_object_id":sourceID.uuidString])
    let before=e.project!
    _ = try e.call("form_delete_objects",arguments:["object_ids":[sourceID.uuidString]])
    let binding=try XCTUnwrap(e.project!.objects.first?.surfaceArtworkBindings?.first)
    XCTAssertNil(binding.sourceObjectID);XCTAssertEqual(binding.artwork,before.objects[0].artwork)
    XCTAssertNoThrow(try e.project!.validateArtworkLinks())
    e.undo();XCTAssertEqual(e.project,before)
  }
  func testUnknownSurfaceAndInvalidPhysicalSourceRejectAtomically()throws {
    let (e,modelID,sourceID)=try fixture(),before=e.project!
    XCTAssertThrowsError(try e.call("form_surface",arguments:["command":"bind","object_id":modelID.uuidString,"surface_id":"missing","source_object_id":sourceID.uuidString]))
    XCTAssertThrowsError(try e.call("form_surface",arguments:["command":"bind","object_id":modelID.uuidString,"surface_id":"top","source_object_id":modelID.uuidString]))
    XCTAssertEqual(e.project,before);XCTAssertTrue(e.undoStack.isEmpty)
  }
  func testShrinkingSurfaceReportsPlacementWithoutChangingSourceBindingOrMeshes()throws {
    let (e,modelID,sourceID)=try fixture()
    _ = try e.call("form_surface",arguments:["command":"bind","object_id":modelID.uuidString,"surface_id":"top","source_object_id":sourceID.uuidString])
    let before=e.project!,model=try XCTUnwrap(before.objects.first{$0.id==modelID})
    var surfaces=try XCTUnwrap(model.cadRepresentation?.resolvedSurfaces)
    surfaces[0].width=80
    let issues=before.physicalSurfaceArtworkPlacementIssues(for:model,surfaces:surfaces)
    XCTAssertEqual(issues.map(\.code),["source_exceeds_surface"])
    XCTAssertEqual(issues.first?.surfaceID,"top");XCTAssertEqual(issues.first?.sourceObjectID,sourceID)
    XCTAssertEqual(issues.first?.boundSourceSizeMM,Point2(100,50))
    XCTAssertEqual(issues.first?.currentSourceSizeMM,Point2(100,50))
    XCTAssertEqual(issues.first?.surfaceSizeMM,Point2(80,50))
    XCTAssertEqual(e.project,before);XCTAssertEqual(e.undoStack.count,1)
    var resized=before
    resized.objects[1].cadRepresentation!.resolvedSurfaces=surfaces
    e.project=resized
    let inspected=try XCTUnwrap(try e.call("form_surface",arguments:["object_id":modelID.uuidString]) as? [String:Any])
    let reported=try XCTUnwrap(inspected["surface_artwork_issues"] as? [[String:Any]])
    XCTAssertEqual(reported.first?["code"] as? String,"source_exceeds_surface")
    XCTAssertEqual(e.project!.objects[0],before.objects[0])
    XCTAssertEqual(e.project!.objects[1].surfaceArtworkBindings,model.surfaceArtworkBindings)
    XCTAssertEqual(e.project!.objects[1].cadRepresentation?.components,model.cadRepresentation?.components)
  }
  func testSourceArtboardResizeRequiresReviewAndRetainsBoundPhysicalSize()throws {
    let (e,modelID,sourceID)=try fixture()
    _ = try e.call("form_surface",arguments:["command":"bind","object_id":modelID.uuidString,"surface_id":"top","source_object_id":sourceID.uuidString])
    let before=try XCTUnwrap(e.project!.objects.first{$0.id==modelID})
    try e.edit("Resized source"){p in p.objects[0].parameters["width"]=120}
    let model=try XCTUnwrap(e.project!.objects.first{$0.id==modelID})
    let issues=e.project!.physicalSurfaceArtworkPlacementIssues(for:model)
    XCTAssertEqual(issues.map(\.code),["source_frame_changed","source_exceeds_surface"])
    XCTAssertEqual(issues.first?.boundSourceSizeMM,Point2(100,50))
    XCTAssertEqual(issues.first?.currentSourceSizeMM,Point2(120,50))
    XCTAssertEqual(model.surfaceArtworkBindings,before.surfaceArtworkBindings)
    XCTAssertEqual(model.cadRepresentation,before.cadRepresentation)
    e.undo();XCTAssertTrue(e.project!.physicalSurfaceArtworkPlacementIssues(for:before).isEmpty)
  }
  private func detach(_ e:OperationEngine,modelID:UUID,sourceID:UUID)throws {
    _ = try e.call("form_surface",arguments:["command":"bind","object_id":modelID.uuidString,"surface_id":"top","source_object_id":sourceID.uuidString])
    _ = try e.call("form_delete_objects",arguments:["object_ids":[sourceID.uuidString]])
  }
  func testDetachedSnapshotRetainsPaletteStyleAndFontResourceSemantics()throws {
    let (e,modelID,sourceID)=try fixture();var p=e.project!
    let textID=p.objects[0].artwork!.elements[0].id
    let swatch=try SwatchCommands.save(in:&p,name:"Source ink",color:"#AA3322")
    var type=Typography();type.fontName="Georgia"
    let style=try TextStyleCommands.save(in:&p,name:"Body",typography:type,fontSize:12)
    try TextStyleCommands.apply(in:&p,objectID:sourceID,ids:[textID],styleID:style)
    try SwatchCommands.assign(in:&p,objectID:sourceID,ids:[textID],swatchID:swatch)
    e.project=p;try detach(e,modelID:modelID,sourceID:sourceID);p=e.project!
    _ = try SwatchCommands.save(in:&p,id:swatch,name:"Source ink",color:"#2266AA")
    let bound=try XCTUnwrap(p.objects[0].surfaceArtworkBindings?.first)
    XCTAssertEqual(p.physicalSurfaceArtwork(bound)?.elements[0].color,"#2266AA")
    try SwatchCommands.delete(in:&p,id:swatch)
    XCTAssertEqual(p.objects[0].surfaceArtworkBindings?.first?.artwork?.elements[0].color,"#2266AA")
    XCTAssertNil(p.objects[0].surfaceArtworkBindings?.first?.artwork?.elements[0].fillSwatchID)
    type.fontName="Baskerville"
    _ = try TextStyleCommands.save(in:&p,id:style,name:"Body",typography:type,fontSize:18)
    XCTAssertEqual(p.objects[0].surfaceArtworkBindings?.first?.artwork?.elements[0].fontSize,18)
    XCTAssertEqual(p.objects[0].surfaceArtworkBindings?.first?.artwork?.elements[0].typography?.fontName,"Baskerville")
    try TextStyleCommands.delete(in:&p,id:style)
    XCTAssertNil(p.objects[0].surfaceArtworkBindings?.first?.artwork?.elements[0].textStyle)
    XCTAssertTrue(FontUsage.uses(in:p).contains{$0.objectID==modelID && $0.fontName=="Baskerville"})
    p=try FontUsage.replacing(in:p,from:"Baskerville",to:"Georgia")
    XCTAssertEqual(p.objects[0].surfaceArtworkBindings?.first?.artwork?.elements[0].typography?.fontName,"Georgia")
    var invalid=p
    invalid.objects[0].surfaceArtworkBindings![0].artwork!.elements[0].fillSwatchID=UUID()
    XCTAssertThrowsError(try invalid.validateSwatches())
    invalid=p;invalid.objects[0].surfaceArtworkBindings![0].artwork!.elements[0].textStyle = .init(styleID:UUID())
    XCTAssertThrowsError(try invalid.validateTextStyles())
    try e.repository.save(p);XCTAssertEqual(try e.repository.load(p.id).objects,p.objects)
  }
  func testDetachedProductionInkStillBlocksImplicitDeletion()throws {
    let (e,modelID,sourceID)=try fixture();var p=e.project!
    let profile=ArtworkOutputProfile(name:"Source print",asset:"icc-"+String(repeating:"a",count:64)+".icc",sha256:String(repeating:"a",count:64),model:"CMYK")
    let ink=ProductionInk(kind:.spot,components:.init(0,0.5,1,0),profile:profile,spotName:"Source Orange")
    let swatch=try SwatchCommands.save(in:&p,name:"Orange",color:"#DD7722",printInk:ink)
    try SwatchCommands.assign(in:&p,objectID:sourceID,ids:[p.objects[0].artwork!.elements[0].id],swatchID:swatch)
    e.project=p;try detach(e,modelID:modelID,sourceID:sourceID);p=e.project!;let before=p
    XCTAssertTrue(p.productionInkIsReferenced(swatch))
    XCTAssertThrowsError(try SwatchCommands.delete(in:&p,id:swatch));XCTAssertEqual(p,before)
    _ = try SwatchCommands.save(in:&p,id:swatch,name:"Orange preview",color:"#DD7722",printInk:nil,replacingInk:true)
    try SwatchCommands.delete(in:&p,id:swatch)
    XCTAssertFalse(p.physicalSurfaceArtwork(p.objects[0].surfaceArtworkBindings![0])!.requiresInkOutput)
  }
  func testDetachedStoryPersistsCompleteLocalCompositionAfterAllLiveFramesAndStoryAreRemoved()throws {
    let (e,modelID,sourceID)=try fixture();var p=e.project!
    p.objects[0].artwork!.elements[0].typography = .init();p.objects[0].artwork!.elements[0].typography!.fontName="Georgia"
    let firstFrame=StoryFrameID(objectID:sourceID,elementID:p.objects[0].artwork!.elements[0].id)
    var continuation=try p.makeObject(recipeID:"artboard",parameters:["width":100,"depth":50])
    var text=ArtworkElement(kind:"text",x:4,y:6,width:80,height:30,text:"Continue the original words",fontSize:12)
    text.typography=p.objects[0].artwork!.elements[0].typography;continuation.artwork = .init(elements:[text]);p.objects.append(continuation)
    let story=try PublicationCommands.createStory(in:&p,frames:[firstFrame,.init(objectID:continuation.id,elementID:text.id)])
    let style=try TextStyleCommands.save(in:&p,name:"Frozen body",typography:text.typography!,fontSize:12)
    try TextStyleCommands.apply(in:&p,objectID:sourceID,ids:[firstFrame.elementID],styleID:style)
    let expected=try XCTUnwrap(p.resolvedTextStory(story)),original=p.surfaceArtwork(p.objects[0])!
    e.project=p;try detach(e,modelID:modelID,sourceID:sourceID)
    _ = try e.call("form_delete_objects",arguments:["object_ids":[continuation.id.uuidString]])
    try e.edit("Removed unused live story"){value in value.textStories?.removeAll{$0.id==story}}
    try e.flush();p=try e.repository.load(e.project!.id)
    XCTAssertTrue(p.textStories?.isEmpty ?? true)
    let binding=try XCTUnwrap(p.objects[0].surfaceArtworkBindings?.first)
    XCTAssertEqual(binding.detachedSourceObjectID,sourceID)
    XCTAssertEqual(binding.storySnapshots?.first,expected)
    let rendered=try XCTUnwrap(p.physicalSurfaceArtwork(binding)),frame=try XCTUnwrap(rendered.elements[0].storyFrame)
    XCTAssertEqual(frame.frame,firstFrame);XCTAssertEqual(frame.resolved,expected)
    XCTAssertEqual(try rendered.renderCacheData(),try original.renderCacheData())
    var type=text.typography!;type.fontName="Baskerville"
    _ = try TextStyleCommands.save(in:&p,id:style,name:"Frozen body",typography:type,fontSize:18)
    XCTAssertEqual(p.objects[0].surfaceArtworkBindings![0].storySnapshots![0].story.fontSize,18)
    XCTAssertEqual(p.objects[0].surfaceArtworkBindings![0].storySnapshots![0].story.text,expected.story.text)
    XCTAssertEqual(p.objects[0].surfaceArtworkBindings![0].storySnapshots![0].frames,expected.frames)
    p=try FontUsage.replacing(in:p,from:"Baskerville",to:"Georgia")
    XCTAssertEqual(p.objects[0].surfaceArtworkBindings![0].storySnapshots![0].story.typography?.fontName,"Georgia")
    var invalid=p;invalid.objects[0].surfaceArtworkBindings![0].storySnapshots![0].frames.removeLast()
    XCTAssertThrowsError(try invalid.validatePhysicalSurfaceBindings())
    try p.validateArtworkLinks()
  }
}
