import Foundation
import XCTest
import FormCADModel
@testable import FormCore

@MainActor final class PhysicalDimensionBindingTests:XCTestCase {
  private func engine()throws->OperationEngine {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("physical-dimensions-"+UUID().uuidString)
    addTeardownBlock{try? FileManager.default.removeItem(at:root)}
    let engine=OperationEngine(repository:try .init(root:root));engine.project=Project(name:"Independent physical sources")
    return engine
  }
  private func add(_ e:OperationEngine,name:String="Source",width:Double=100)throws->UUID {
    let result=try XCTUnwrap(e.call("form_add_object",arguments:["recipe_id":"artboard","name":name,"parameters":["width":width,"depth":150]]) as? [String:Any])
    return try XCTUnwrap(UUID(uuidString:try XCTUnwrap(result["id"] as? String)))
  }
  private func object(_ e:OperationEngine,_ id:UUID)throws->ProductObject {try XCTUnwrap(e.project?.objects.first{$0.id==id})}
  private func bind(_ e:OperationEngine,_ id:UUID,_ bindings:[PhysicalDimensionBinding])throws {
    _ = try e.call("form_update_object",arguments:["object_id":id.uuidString,"dimension_bindings":try jsonObject(bindings)])
  }
  func testTransitiveDimensionsUndoAndReopenKeepAuthorityAndExactArtworkScale()throws {
    let e=try engine(),a=try add(e),b=try add(e,name:"Sleeve"),c=try add(e,name:"Outer panel")
    var layer=ArtworkElement(kind:"text",x:70,y:12,width:24,height:15,text:"Fixed size",fontSize:18)
    layer.color="#243B36"
    _ = try e.call("form_set_artwork",arguments:["object_id":b.uuidString,"artwork":try jsonObject(Artwork(background:"#FFFFFF",elements:[layer]))])
    let region=PhysicalArtworkRegion(id:"front",name:"Front",origin:.init("width/2",0),size:.init("width/2","depth"),anchors:[.init(elementIDs:[layer.id],horizontal:1)])
    _ = try e.call("form_update_object",arguments:["object_id":b.uuidString,"artwork_regions":try jsonObject([region])])
    try bind(e,b,[.init(parameter:"width",expression:"base+20",inputs:["base":.init(sourceObjectID:a,measurement:.width)])])
    try bind(e,c,[.init(parameter:"width",expression:"inside+8",inputs:["inside":.init(sourceObjectID:b,measurement:.width)])])
    let before=try XCTUnwrap(e.project),beforeLayer=try XCTUnwrap(object(e,b).artwork?.elements.first)
    _ = try e.call("form_update_object",arguments:["object_id":a.uuidString,"parameters":["width":160]])
    XCTAssertEqual(try object(e,b)["width"],180);XCTAssertEqual(try object(e,c)["width"],188)
    let moved=try XCTUnwrap(object(e,b).artwork?.elements.first)
    XCTAssertEqual(moved.x,beforeLayer.x+60);XCTAssertEqual(moved.y,beforeLayer.y)
    XCTAssertEqual(moved.fontSize,18);XCTAssertEqual(moved.width,24);XCTAssertEqual(moved.id,layer.id)
    var repeated=try XCTUnwrap(e.project);try repeated.reconcilePhysicalDimensions(previous:before)
    XCTAssertEqual(repeated.objects,e.project?.objects,"Candidate validation and outer transaction must not translate twice")
    try e.flush();let reopened=try e.repository.load(try XCTUnwrap(e.project?.id))
    XCTAssertEqual(reopened.objects,e.project?.objects);XCTAssertEqual(reopened.schemaVersion,65)
    e.undo();XCTAssertEqual(e.project?.objects,before.objects)
    e.redo();XCTAssertEqual(try object(e,b)["width"],180)
  }
  func testCycleMissingSourceUnknownInputAndBoundsRejectWithoutPartialEdits()throws {
    let e=try engine(),a=try add(e),b=try add(e)
    try bind(e,b,[.init(parameter:"width",expression:"base",inputs:["base":.init(sourceObjectID:a,measurement:.width)])])
    let before=e.project,undo=e.undoStack.count
    XCTAssertThrowsError(try bind(e,a,[.init(parameter:"width",expression:"other",inputs:["other":.init(sourceObjectID:b,measurement:.width)])]))
    XCTAssertEqual(e.project,before);XCTAssertEqual(e.undoStack.count,undo)
    XCTAssertThrowsError(try bind(e,b,[.init(parameter:"width",expression:"missing",inputs:[:])]))
    XCTAssertThrowsError(try bind(e,b,[.init(parameter:"width",expression:"v",inputs:["v":.init(sourceObjectID:UUID(),measurement:.width)])]))
    XCTAssertThrowsError(try e.call("form_update_object",arguments:["object_id":a.uuidString,"parameters":["width":10001]]))
    XCTAssertEqual(e.project,before)
    XCTAssertThrowsError(try e.call("form_delete_objects",arguments:["object_ids":[a.uuidString]]))
    XCTAssertEqual(e.project,before)
  }
  func testBindingsAreExplicitAndSourceObjectsRemainVisible()throws {
    let e=try engine(),a=try add(e),b=try add(e)
    try bind(e,b,[.init(parameter:"width",expression:"v+2",inputs:["v":.init(sourceObjectID:a,measurement:.width)])])
    XCTAssertTrue(try XCTUnwrap(e.project).tablePresentationObjects.contains{$0.id==a})
    XCTAssertThrowsError(try e.call("form_update_object",arguments:["object_id":b.uuidString,"parameters":["width":123]]))
    _ = try e.call("form_update_object",arguments:["object_id":b.uuidString,"dimension_bindings":NSNull(),"parameters":["width":123]])
    XCTAssertEqual(try object(e,b)["width"],123)
  }
  func testCropIndependentBookMeasurementsCanDriveTheirOwnCoverArtwork()throws {
    let e=try engine(),page=try add(e,width:100),cover=try add(e,width:100)
    _ = try e.call("form_set_artwork",arguments:["object_id":page.uuidString,"artwork":try jsonObject(Artwork(background:"#FFFFFF"))])
    _ = try e.call("form_set_artwork",arguments:["object_id":cover.uuidString,"artwork":try jsonObject(Artwork(background:"#FFFFFF"))])
    var assembly=UUID()
    try e.edit("Physical edition") {p in
      let publication=try PublicationCommands.createPublication(in:&p,name:"Pages",pages:[page],margins:.init(),language:nil)
      let stock=PaperStock(thicknessMM:0.2)
      let plane=SheetAssemblyPlane(id:"cover",name:"Outer panel",size:.init("width","height"),stock:stock,front:.init(sourceObjectID:cover))
      assembly=try SheetAssemblyCommands.create(in:&p,definition:.init(publicationID:publication,stock:stock,enclosure:[plane]))
    }
    try bind(e,cover,[.init(parameter:"width",expression:"trim",inputs:["trim":.init(sourceObjectID:assembly,measurement:.trimWidth)])])
    _ = try e.call("form_update_object",arguments:["object_id":page.uuidString,"parameters":["width":130]])
    XCTAssertEqual(try object(e,cover)["width"],130)
    XCTAssertEqual(try XCTUnwrap(e.project).resolvedSheetAssembly(object(e,assembly)).size.x,130)
  }
  func testRegionsRejectConflictingAuthoritiesAndNeverEnterArtwork()throws {
    let e=try engine(),a=try add(e)
    let layer=ArtworkElement(kind:"text",x:3,y:4,width:20,height:10,text:"Original",fontSize:12)
    _ = try e.call("form_set_artwork",arguments:["object_id":a.uuidString,"artwork":try jsonObject(Artwork(elements:[layer]))])
    let region=PhysicalArtworkRegion(id:"zone",name:"Unprinted guide",origin:.init(0,0),size:.init("width","depth"),anchors:[.init(elementIDs:[layer.id])])
    _ = try e.call("form_update_object",arguments:["object_id":a.uuidString,"artwork_regions":try jsonObject([region])])
    XCTAssertEqual(try object(e,a).artwork?.elements,[layer])
    XCTAssertEqual(try XCTUnwrap(e.project).resolvedArtworkRegions(for:object(e,a)).first?.size.x,100)
    XCTAssertThrowsError(try e.call("form_update_object",arguments:["object_id":a.uuidString,"artwork_regions":try jsonObject([region,region])]))
    let binding=ArtworkParameterBinding(id:"position",elementID:layer.id,property:.x,value:"width/2")
    XCTAssertThrowsError(try e.call("form_update_object",arguments:["object_id":a.uuidString,"artwork_parameter_bindings":try jsonObject([binding])]))
  }
}
