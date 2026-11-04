import Foundation
import XCTest
@testable import FormCore

final class PhysicalAppearanceTests:XCTestCase {
  private func fixture()throws->OperationEngine {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("physical-appearance-"+UUID().uuidString)
    let engine=OperationEngine(repository:try ProjectRepository(root:root));engine.project=Project(name:"Material source")
    addTeardownBlock {try? FileManager.default.removeItem(at:root)};return engine
  }
  func testLegacyRoundTripKeepsOmittedAppearanceAndSchema()throws {
    let engine=try fixture(),before=engine.project!
    let decoded=try JSONDecoder.form.decode(Project.self,from:JSONEncoder.form.encode(before))
    XCTAssertEqual(try JSONEncoder.form.encode(decoded),try JSONEncoder.form.encode(before));XCTAssertNil(decoded.renderSettings)
    XCTAssertTrue(decoded.materials.allSatisfy{$0.appearance==nil && $0.references==nil})
    XCTAssertLessThan(decoded.minimumSchemaVersion,67)
    let partial=try JSONDecoder.form.decode(PhysicalAppearance.self,from:Data("{\"sheen\":0.7}".utf8))
    try partial.validate();XCTAssertEqual(partial.sheen,0.7);XCTAssertEqual(partial.ior,1.5);XCTAssertEqual(partial.normalStrength,1)
  }
  func testMaterialEditIsPortableUndoableAndRejectsInvalidAtomically()throws {
    let engine=try fixture(),before=engine.project!
    _ = try engine.call("form_material",arguments:["command":"create","material":["id":"woven-test","name":"Woven surface","color":"#AA9988","appearance":["sheen":0.5,"anisotropy":0.4,"normalStrength":0.35],"references":[["title":"Declared material","url":"https://example.com/material","evidence":"manufacturerSpecification"]]]])
    XCTAssertEqual(engine.undoStack.count,1);XCTAssertEqual(engine.project?.minimumSchemaVersion,67)
    let created=engine.project!
    XCTAssertEqual(created.materials.first{$0.id=="woven-test"}?.appearance?.normalStrength,0.35)
    XCTAssertThrowsError(try engine.call("form_material",arguments:["command":"update","material_id":"woven-test","patch":["appearance":["normalStrength":10.1]]]))
    XCTAssertThrowsError(try engine.call("form_material",arguments:["command":"update","material_id":"woven-test","patch":["appearance":["sheen":2]]]))
    XCTAssertThrowsError(try engine.call("form_material",arguments:["command":"update","material_id":"woven-test","patch":["appearance":["sheeen":0.2]]]))
    XCTAssertEqual(engine.project,created);XCTAssertEqual(engine.undoStack.count,1)
    engine.undo();XCTAssertEqual(engine.project,before);engine.redo();XCTAssertEqual(engine.project,created)
    try engine.flush();XCTAssertEqual(try JSONEncoder.form.encode(engine.repository.load(created.id)),try JSONEncoder.form.encode(created))
    _ = try engine.call("form_material",arguments:["command":"update","material_id":"woven-test","patch":["appearance":NSNull()]])
    XCTAssertNil(engine.project?.materials.first{$0.id=="woven-test"}?.appearance)
    XCTAssertEqual(engine.project?.camera,before.camera)
  }
  func testDataMapsRejectColorEncodingAndAssetsVerifyHash()throws {
    let engine=try fixture(),before=engine.project!
    let bytes=Data(base64Encoded:"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=")!
    let path=engine.repository.root.appendingPathComponent("source.png");try bytes.write(to:path)
    let result=try XCTUnwrap(try engine.call("form_material",arguments:["command":"import_texture","path":path.path,"color_space":"data"]) as? [String:Any])
    let raw=try XCTUnwrap(result["texture"] as? [String:Any])
    var texture=try JSONDecoder.form.decode(PhysicalTextureReference.self,from:JSONSerialization.data(withJSONObject:raw))
    let assets=engine.repository.url(for:before.id).appendingPathComponent("Assets")
    XCTAssertEqual(try Data(contentsOf:texture.verifiedURL(in:assets)),bytes);XCTAssertEqual(engine.project,before);XCTAssertTrue(engine.undoStack.isEmpty)
    var appearance=PhysicalAppearance();appearance.textures["roughness"]=texture;try appearance.validate()
    texture.colorSpace = .srgb;appearance.textures["roughness"]=texture;XCTAssertThrowsError(try appearance.validate())
    texture.asset="../source.png";XCTAssertThrowsError(try texture.validate())
    texture=try JSONDecoder.form.decode(PhysicalTextureReference.self,from:JSONSerialization.data(withJSONObject:raw))
    try Data("changed".utf8).write(to:assets.appendingPathComponent(texture.asset));XCTAssertThrowsError(try texture.verifiedURL(in:assets))
  }
  func testThreadRoughnessRoundTripUndoPreservesNeedleAndManufacturingInputs()throws {
    let engine=try fixture();var project=engine.project!
    var object=try project.makeObject(recipeID:"textilePatch")
    let source=ArtworkElement(kind:"line",x:10,y:10,width:20,height:0.1)
    object.artwork = .init(elements:[source])
    let design=EmbroideryDesign(threads:[.init(name:"Original thread",color:"#884422")],regions:[.init(elementIDs:[source.id],method:.running)])
    object.textile!.embroidery=design;project.objects=[object];engine.project=project
    var changed=design;changed.threads[0].roughness=0.18
    _ = try engine.call("form_update_object",arguments:["object_id":object.id.uuidString,"embroidery":try jsonObject(changed)])
    let saved=try XCTUnwrap(engine.project),updated=try XCTUnwrap(saved.objects.first)
    XCTAssertEqual(saved.minimumSchemaVersion,67);XCTAssertEqual(engine.undoStack.count,1)
    XCTAssertEqual(updated.parameters,object.parameters);XCTAssertEqual(updated.artwork,object.artwork)
    XCTAssertEqual(updated.textile?.embroidery?.regions,design.regions);XCTAssertEqual(updated.textile?.embroidery?.process,design.process)
    try engine.flush();XCTAssertEqual(try engine.repository.load(saved.id).objects.first?.textile?.embroidery?.threads[0].roughness,0.18)
    engine.undo();XCTAssertEqual(engine.project,project);engine.redo();XCTAssertEqual(engine.project,saved)
    changed.threads[0].roughness=1.01
    XCTAssertThrowsError(try engine.call("form_update_object",arguments:["object_id":object.id.uuidString,"embroidery":try jsonObject(changed)]))
    XCTAssertEqual(engine.project,saved)
    let legacy=try JSONDecoder.form.decode(EmbroideryThread.self,from:Data("{\"name\":\"Legacy\",\"color\":\"#FFFFFF\"}".utf8))
    XCTAssertNil(legacy.roughness)
  }
  func testIndependentReverseSurfaceIsPersistedValidatedAndUndoable()throws {
    let engine=try fixture()
    _ = try engine.call("form_material",arguments:["command":"create","material":["id":"two-sides","name":"Independently finished cloth","color":"#EEEEEE","thickness":0.2,"backSurface":["color":"#DDDCDC","roughness":0.8,"metallic":0,"appearance":["sheen":0.15]]]])
    let before=engine.project!,material=try XCTUnwrap(before.materials.first{$0.id=="two-sides"})
    XCTAssertNil(material.appearance);XCTAssertEqual(material.backSurface?.roughness,0.8);XCTAssertEqual(before.minimumSchemaVersion,67)
    try engine.flush();XCTAssertEqual(try engine.repository.load(before.id).materials,before.materials)
    let invalid:[[String:Any]]=[["color":"#FFFFFF","roughness":-1,"metallic":0],["color":"#FFFFFF","roughness":0.5],["color":"#FFFFFF","roughness":0.5,"metallic":0,"typo":1],["color":"#FFFFFF","roughness":0.5,"metallic":0,"appearance":["sheeen":0.2]]]
    for bad in invalid {
      XCTAssertThrowsError(try engine.call("form_material",arguments:["command":"update","material_id":material.id,"patch":["backSurface":bad]]))
      XCTAssertEqual(engine.project,before)
    }
    _ = try engine.call("form_material",arguments:["command":"update","material_id":material.id,"patch":["backSurface":NSNull()]])
    XCTAssertNil(engine.project?.materials.first{$0.id==material.id}?.backSurface)
    engine.undo();XCTAssertEqual(engine.project,before)
    let schema=Material.toolSchema(create:false),properties=try XCTUnwrap(schema["properties"] as? [String:Any])
    XCTAssertNotNil(properties["backSurface"]);XCTAssertNotNil(PaperAppearanceCommands.profileSchema["properties"] as? [String:Any])
  }
  func testPaperOverridesDoNotChangeStockCaliper()throws {
    let engine=try fixture();var project=engine.project!
    let object=try project.makeObject(recipeID:"paperEnvelope");project.objects=[object];engine.project=project
    let thickness=object.paperConstruction!.stock.resolvedThicknessMM
    _ = try engine.call("form_paper",arguments:["command":"configure","object_id":object.id.uuidString,"stock":["profile":["appearance":["diffuseTransmission":0.4]]]])
    let stock=try XCTUnwrap(engine.project?.objects.first?.paperConstruction?.stock)
    XCTAssertEqual(stock.resolvedThicknessMM,thickness);XCTAssertEqual(stock.profile?.appearance?.diffuseTransmission,0.4)
    XCTAssertEqual(engine.project?.minimumSchemaVersion,67);engine.undo();XCTAssertEqual(engine.project,project)
  }
  func testRenderSettingsRoundTripAndPhysicalLightingValidation()throws {
    let engine=try fixture();let before=engine.project!
    var settings=CyclesRenderSettings();settings.areaLights=[PhysicalAreaLight()]
    XCTAssertEqual(settings.samples,512);XCTAssertEqual(settings.previewSamples,64);try settings.validate()
    XCTAssertEqual(settings.displacementDicingRate,2);XCTAssertEqual(settings.displacementMaxTriangles,2_000_000);XCTAssertEqual(settings.displacementMaxSubdivisions,10)
    try engine.edit("Render settings"){$0.renderSettings=settings}
    XCTAssertEqual(engine.project?.minimumSchemaVersion,67)
    try engine.flush();XCTAssertEqual(try engine.repository.load(before.id).renderSettings,settings)
    XCTAssertEqual(try engine.project!.studioDesignDigest(),try before.studioDesignDigest())
    settings.areaLights![0].targetMM=settings.areaLights![0].positionMM;XCTAssertThrowsError(try settings.validate())
    settings=CyclesRenderSettings();settings.environmentStrength = .infinity;XCTAssertThrowsError(try settings.validate())
    settings=CyclesRenderSettings();settings.displacementDicingRate=0.1;XCTAssertThrowsError(try settings.validate())
    settings=CyclesRenderSettings();settings.displacementMaxTriangles=2_000_001;XCTAssertThrowsError(try settings.validate())
    engine.undo();XCTAssertEqual(engine.project,before)
  }
  func testDetachedAssemblyAndSheetMaterialSnapshotsRequireNewSchemaAndValidate()throws {
    var project=Project(name:"Portable material snapshots")
    var object=try project.makeObject(recipeID:"patternAssembly")
    var material=Material("cloth","Cloth","Fabric","#FFFFFF",roughness:0.6,metallic:0,thickness:0.4)
    material.appearance=PhysicalAppearance()
    var definition=PatternAssemblyDefinition(sourceObjectID:UUID(),panels:[.init(panel:.init(elementID:UUID(),copy:1),pose:.init(),material:material,densityGSM:200)],seamIDs:[])
    try definition.validateDeclarations();object.patternAssembly=definition;project.objects=[object]
    XCTAssertEqual(project.minimumSchemaVersion,67)
    definition.panels[0].material.appearance!.ior = .nan
    XCTAssertThrowsError(try definition.validateDeclarations())
    object.patternAssembly=nil
    var stock=PaperStock();stock.profile=PaperSurfaceProfile();stock.profile!.appearance=PhysicalAppearance()
    object.sheetAssembly = .init(publicationID:UUID(),stock:stock);project.objects=[object]
    XCTAssertEqual(project.minimumSchemaVersion,67)
    object.sheetAssembly!.stock.profile=nil
    object.sheetAssembly!.parentSheets=[.init(frontPageIDs:[nil,nil],backPageIDs:[nil,nil],stock:stock,sizeMM:.init(100,100),printIntent:.color)]
    project.objects=[object];XCTAssertEqual(project.minimumSchemaVersion,67)
  }
}
