import Foundation
import XCTest
@testable import FormCore

@MainActor final class RecipeParameterEvolutionTests:XCTestCase {
  private func fixture()throws->(OperationEngine,Recipe,UUID) {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("recipe-parameter-evolution-"+UUID().uuidString)
    addTeardownBlock{try? FileManager.default.removeItem(at:root)}
    var project=Project(name:"Project-owned control evolution")
    let recipe=Recipe("ordinarySourceControls","Authored source controls","square.and.pencil","Generic editable model controls",[
      .init("width","Source width",120,20...1000),.init("depth","Source height",80,20...1000),
      .init("strokeMM","Rule width",0.2,0.1...3),.init("unused","Unused construction allowance",7,0...20)])
    project.recipes.append(recipe)
    var object=try project.makeObject(recipeID:recipe.id,name:"Original canonical artwork",parameters:["width":168,"depth":94,"strokeMM":0.7,"unused":9],position:.init(17,2,31))
    var text=ArtworkElement(kind:"text",x:9,y:12,width:90,height:18,text:"Unscaled type, café 🌿",fontSize:16)
    var typography=Typography();typography.fontName="HelveticaNeue";text.typography=typography
    object.artwork = .init(background:"#FFFFFF",elements:[text,.init(kind:"line",x:9,y:35,width:90,height:0.7,color:"#234C39")],bleed:0)
    project.objects=[object,try project.makeObject(recipeID:"box",name:"Unrelated physical object")]
    project.camera.azimuth=0.83;project.camera.distance=18.5
    let engine=OperationEngine(repository:try ProjectRepository(root:root));engine.project=project
    return(engine,recipe,object.id)
  }
  private func replacement(_ recipe:Recipe)->Recipe {
    var changed=recipe;changed.parameters.removeAll{$0.id=="unused"}
    changed.parameters[changed.parameters.firstIndex{$0.id=="width"}!].value=180
    changed.parameters.append(.init("cornerMM","New edge allowance",2.5,0...10))
    return changed
  }
  private func replace(_ engine:OperationEngine,_ recipe:Recipe)throws {
    _=try engine.call("form_create_recipe",arguments:["recipe":try jsonObject(recipe),"replace":true])
  }
  func testRemovingUnusedControlAddsNewDefaultsPreservesRetainedValuesSourceIdentityCameraAndUndoReopen()throws {
    let(e,recipe,id)=try fixture(),before=try XCTUnwrap(e.project),changed=replacement(recipe),undo=e.undoStack.count
    let selected:Set<UUID>=[id];e.selection=selected
    try replace(e,changed)
    let after=try XCTUnwrap(e.project),object=try XCTUnwrap(after.objects.first{$0.id==id})
    var expected=try XCTUnwrap(before.objects.first{$0.id==id})
    expected.parameters.removeValue(forKey:"unused");expected.parameters["cornerMM"]=2.5
    XCTAssertEqual(object,expected,"Only the deliberately evolved numeric schema changes; artwork scale, layer IDs, type and placement remain exact.")
    XCTAssertEqual(object.parameters["width"],168,"A replacement default must not overwrite the user's retained value.")
    XCTAssertEqual(object.parameters["strokeMM"],0.7)
    XCTAssertEqual(after.objects.filter{$0.id != id},before.objects.filter{$0.id != id})
    XCTAssertEqual(after.recipes,[changed]);XCTAssertEqual(after.camera,before.camera);XCTAssertEqual(e.selection,selected)
    XCTAssertEqual(e.undoStack.count,undo+1)
    e.undo();XCTAssertEqual(e.project,before)
    e.redo();XCTAssertEqual(e.project,after)
    try e.flush();let reopened=try e.repository.load(before.id)
    XCTAssertEqual(reopened.objects,after.objects);XCTAssertEqual(reopened.recipes,[changed]);XCTAssertEqual(reopened.camera,before.camera)
    try reopened.validateArtworkLinks()
  }
  func testRemovingControlStillReferencedByArtworkDimensionsOrPhysicalPlanesRejectsAtomically()throws {
    for authority in ["artwork","dimension","plane"] {
      let(e,recipe,id)=try fixture();var project=try XCTUnwrap(e.project)
      let index=try XCTUnwrap(project.objects.firstIndex{$0.id==id})
      switch authority {
      case "artwork":
        let layer=try XCTUnwrap(project.objects[index].artwork?.elements.first)
        project.objects[index].artworkParameterBindings=[.init(id:"required-placement",elementID:layer.id,property:.x,value:"unused")]
      case "dimension":
        project.objects[index].parameters["width"]=129
        project.objects[index].dimensionBindings=[.init(parameter:"width",expression:"120+unused",inputs:[:])]
      default:
        var page=try project.makeObject(recipeID:"artboard",parameters:["width":100,"depth":140]);page.artwork = .init(elements:[])
        project.objects.append(page)
        let publication=try PublicationCommands.createPublication(in:&project,name:"Generic physical faces",pages:[page.id])
        let plane=SheetAssemblyPlane(id:"outer",name:"Authored panel",size:.init("width+unused","height"),stock:.init(thicknessMM:0.2))
        _=try SheetAssemblyCommands.create(in:&project,definition:.init(publicationID:publication,enclosure:[plane]),recipeID:recipe.id)
      }
      try project.validateArtworkLinks();e.project=project
      let before=e.project,undo=e.undoStack.count,redo=e.redoStack.count
      XCTAssertThrowsError(try replace(e,replacement(recipe)),"Removing the still-referenced \(authority) control must fail.")
      XCTAssertEqual(e.project,before);XCTAssertEqual(e.undoStack.count,undo);XCTAssertEqual(e.redoStack.count,redo)
    }
  }
  func testVariantFamilyRetainsSharedValuesAndIndependentIterationKeepsItsOwnValuesAfterEvolution()throws {
    let(e,recipe,id)=try fixture()
    let variant=try XCTUnwrap(e.call("form_duplicate_object",arguments:["object_id":id.uuidString,"mode":"variant"]) as? [String:Any])
    let variantID=try XCTUnwrap(UUID(uuidString:try XCTUnwrap(variant["id"] as? String)))
    let iteration=try XCTUnwrap(e.call("form_duplicate_object",arguments:["object_id":id.uuidString,"mode":"iteration"]) as? [String:Any])
    let iterationID=try XCTUnwrap(UUID(uuidString:try XCTUnwrap(iteration["id"] as? String)))
    _=try e.call("form_update_object",arguments:["object_id":iterationID.uuidString,"parameters":["width":222]])
    let before=try XCTUnwrap(e.project),undo=e.undoStack.count
    try replace(e,replacement(recipe))
    let after=try XCTUnwrap(e.project)
    for old in before.objects where old.recipeID==recipe.id {
      var expected=old;expected.parameters.removeValue(forKey:"unused");expected.parameters["cornerMM"]=2.5
      XCTAssertEqual(after.objects.first{$0.id==old.id},expected)
    }
    XCTAssertEqual(after.objects.first{$0.id==id}?.designID,after.objects.first{$0.id==variantID}?.designID)
    XCTAssertNotEqual(after.objects.first{$0.id==id}?.designID,after.objects.first{$0.id==iterationID}?.designID)
    XCTAssertEqual(e.undoStack.count,undo+1);e.undo();XCTAssertEqual(e.project,before);e.redo();XCTAssertEqual(e.project,after)
    _=try e.call("form_update_object",arguments:["object_id":variantID.uuidString,"parameters":["width":199]])
    let final=try XCTUnwrap(e.project)
    XCTAssertEqual(final.objects.first{$0.id==id}?.parameters["width"],199)
    XCTAssertEqual(final.objects.first{$0.id==variantID}?.parameters["width"],199)
    XCTAssertEqual(final.objects.first{$0.id==iterationID}?.parameters["width"],222)
    XCTAssertEqual(final.objects.map(\.artwork),before.objects.map(\.artwork));XCTAssertEqual(final.camera,before.camera)
  }
}
