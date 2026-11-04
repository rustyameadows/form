import Foundation
import FormCADModel
import XCTest
@testable import FormCore

@MainActor final class PhysicalDimensionDependencyRegressionTests:XCTestCase {
  private struct Fixture {var project:Project;var sourceID:UUID;var targetID:UUID;var layerID:UUID}
  private func fixture(affine:Affine2?=nil,bound:Bool=true)throws->Fixture {
    var project=Project(name:"Physical dependency regression")
    var source=try project.makeObject(recipeID:"artboard",name:"Source",parameters:["width":100,"depth":150])
    source.artwork = .init(background:"#FFFFFF",elements:[])
    var target=try project.makeObject(recipeID:"artboard",name:"Dependent",parameters:["width":100,"depth":150])
    var layer=ArtworkElement(kind:"text",x:10,y:20,width:24,height:15,text:"Physical type",fontSize:18)
    layer.affine=affine;layer.rotation=25
    target.artwork = .init(background:"#FFFFFF",elements:[layer])
    target.artworkRegions=[.init(id:"region",name:"Physical region",origin:.init(0,0),size:.init("width","depth"),anchors:[.init(elementIDs:[layer.id],horizontal:1)])]
    if bound {target.dimensionBindings=[.init(parameter:"width",expression:"v",inputs:["v":.init(sourceObjectID:source.id,measurement:.width)])]}
    project.objects.append(contentsOf:[source,target])
    return .init(project:project,sourceID:source.id,targetID:target.id,layerID:layer.id)
  }
  private func object(_ id:UUID,in project:Project)throws->ProductObject {try XCTUnwrap(project.objects.first{$0.id==id})}
  private func engine(_ project:Project)throws->OperationEngine {
    let folder=FileManager.default.temporaryDirectory.appendingPathComponent("physical-regression-"+UUID().uuidString)
    addTeardownBlock{try? FileManager.default.removeItem(at:folder)}
    let engine=OperationEngine(repository:try ProjectRepository(root:folder));engine.project=project;return engine
  }
  func testInputDictionarySchemaAcceptsTypedReferencesAndRejectsUnknownNestedFields()throws {
    let source=UUID()
    let raw:[[String:Any]]=[["parameter":"width","expression":"v+2","inputs":["v":["sourceObjectID":source.uuidString,"measurement":"width"]]]]
    let result=try PhysicalDimensionToolSchema.decodeBindings(raw)
    XCTAssertEqual(result?.first?.inputs["v"]?.sourceObjectID,source)
    var bad=raw
    bad[0]["inputs"]=["v":["sourceObjectID":source.uuidString,"measurement":"width","unknown_reference_field":true]]
    XCTAssertThrowsError(try PhysicalDimensionToolSchema.decodeBindings(bad))
  }
  func testTopLevelAffineAnchorMovesInPhysicalWorldMillimetersAndRepeatedReconciliationIsExact()throws {
    let affine=Affine2.translation(12,-3).followed(by:.rotation(37)).followed(by:.scale(1.7,0.6))
    let f=try fixture(affine:affine),old=try object(f.targetID,in:f.project)
    let oldArtwork=try XCTUnwrap(old.artwork),oldLayer=try XCTUnwrap(oldArtwork.elements.first)
    let oldWorld=ArtworkTransforms.worldOrigin(oldLayer,in:oldArtwork)
    var candidate=f.project
    candidate.objects[candidate.objects.firstIndex{$0.id==f.sourceID}!].parameters["width"]=160
    try candidate.reconcilePhysicalDimensions(previous:f.project)
    let changed=try object(f.targetID,in:candidate),newArtwork=try XCTUnwrap(changed.artwork),newLayer=try XCTUnwrap(newArtwork.elements.first)
    let newWorld=ArtworkTransforms.worldOrigin(newLayer,in:newArtwork)
    XCTAssertEqual(newWorld.x-oldWorld.x,60,accuracy:1e-10)
    XCTAssertEqual(newWorld.y-oldWorld.y,0,accuracy:1e-10)
    XCTAssertEqual(newLayer.affine,oldLayer.affine)
    XCTAssertEqual(newLayer.fontSize,oldLayer.fontSize);XCTAssertEqual(newLayer.width,oldLayer.width);XCTAssertEqual(newLayer.height,oldLayer.height)
    let once=candidate.objects
    try candidate.reconcilePhysicalDimensions(previous:f.project)
    XCTAssertEqual(candidate.objects,once,"The candidate helper and outer engine can reconcile the same transition without double movement.")
  }
  func testNestedAnchorsAndAncestorDescendantPairsRejectInsteadOfDoubleMovingArtwork()throws {
    var f=try fixture(),target=try object(f.targetID,in:f.project)
    var group=ArtworkElement(kind:"group",x:5,y:7,width:80,height:80)
    group.contentSize = .init(40,40);group.rotation=35
    var child=try XCTUnwrap(target.artwork?.elements.first);child.parentID=group.id
    target.artwork!.elements=[group,child]
    target.artworkRegions![0].anchors=[.init(elementIDs:[child.id],horizontal:1)]
    f.project.objects[f.project.objects.firstIndex{$0.id==f.targetID}!]=target
    XCTAssertThrowsError(try f.project.resolvedArtworkRegions(for:target),"Anchor the whole group; a nested layer's position is not a world-space construction authority.")
    target.artworkRegions![0].anchors=[.init(elementIDs:[group.id,child.id],horizontal:1)]
    XCTAssertThrowsError(try f.project.resolvedArtworkRegions(for:target))
    target.artworkRegions![0].anchors=[.init(elementIDs:[group.id],horizontal:1)]
    XCTAssertNoThrow(try f.project.resolvedArtworkRegions(for:target))
  }
  func testConflictingIntentionalPositionAndDimensionEditsRejectAtomicallyAndPreserveUndo()throws {
    let f=try fixture(),e=try engine(f.project),before=e.project,undo=e.undoStack.count
    XCTAssertThrowsError(try e.edit("Conflicting placements") {project in
      project.objects[project.objects.firstIndex{$0.id==f.sourceID}!].parameters["width"]=160
      let index=project.objects.firstIndex{$0.id==f.targetID}!
      project.objects[index].artwork!.elements[0].x+=5
    })
    XCTAssertEqual(e.project,before);XCTAssertEqual(e.undoStack.count,undo)
    // An explicit already-reconciled candidate is accepted by the outer edit.
    try e.edit("Shared construction transition") {project in
      let old=project
      project.objects[project.objects.firstIndex{$0.id==f.sourceID}!].parameters["width"]=160
      try project.reconcilePhysicalDimensions(previous:old)
    }
    XCTAssertEqual(try object(f.targetID,in:XCTUnwrap(e.project)).artwork?.elements.first?.x,70)
    XCTAssertEqual(e.undoStack.count,undo+1)
    e.undo();XCTAssertEqual(e.project?.objects,before?.objects)
  }
  func testDerivedTargetCannotSilentlyDivergeAnExistingLinkedParameterFamily()throws {
    var f=try fixture(bound:false)
    let target=try object(f.targetID,in:f.project)
    var variant=target;variant.id=UUID();variant.relationship="variant";variant.name="Linked member"
    f.project.objects.append(variant)
    let e=try engine(f.project),before=e.project,undo=e.undoStack.count
    let binding=PhysicalDimensionBinding(parameter:"width",expression:"v",inputs:["v":.init(sourceObjectID:f.sourceID,measurement:.width)])
    XCTAssertThrowsError(try e.call("form_update_object",arguments:["object_id":f.targetID.uuidString,"dimension_bindings":try jsonObject([binding])]))
    XCTAssertEqual(e.project,before);XCTAssertEqual(e.undoStack.count,undo)
  }
  func testLockedDependentRejectsSourceRebuildAndRelationshipRemovalWithoutPartialEdits()throws {
    var f=try fixture()
    f.project.objects[f.project.objects.firstIndex{$0.id==f.targetID}!].locked=true
    let e=try engine(f.project),before=e.project,undo=e.undoStack.count
    XCTAssertThrowsError(try e.call("form_update_object",arguments:["object_id":f.sourceID.uuidString,"parameters":["width":160]]))
    XCTAssertEqual(e.project,before);XCTAssertEqual(e.undoStack.count,undo)
    XCTAssertThrowsError(try e.call("form_update_object",arguments:["object_id":f.targetID.uuidString,"dimension_bindings":NSNull()]))
    XCTAssertThrowsError(try e.call("form_update_object",arguments:["object_id":f.targetID.uuidString,"artwork_regions":NSNull()]))
    XCTAssertEqual(e.project,before);XCTAssertEqual(e.undoStack.count,undo)
  }

}
