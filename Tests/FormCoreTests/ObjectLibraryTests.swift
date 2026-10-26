import XCTest
@testable import FormCore

final class ObjectLibraryTests: XCTestCase {
  private func engine(_ project: Project? = nil) throws -> OperationEngine {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let engine=OperationEngine(repository:try ProjectRepository(root:root)); engine.project=project
    addTeardownBlock { try? FileManager.default.removeItem(at:root) }; return engine
  }
  private func call(_ engine: OperationEngine, _ command: String, _ args: [String:Any] = [:]) throws -> Any {
    try engine.call("form_object_library",arguments:args.merging(["command":command]) { _,new in new })
  }
  func testBundledCatalogPreservesReferencesOptionsExamplesAndSearch() throws {
    let c=ObjectLibrary.catalog
    XCTAssertEqual(c.references.count,211); XCTAssertEqual(c.materialOptions.count,26); XCTAssertEqual(c.workExamples.count,8)
    XCTAssertEqual(Set(c.references.map(\.id)).count,211)
    XCTAssertEqual(c.sourceDate,"2026-10-25")
    for r in c.references { XCTAssertEqual(URL(string:r.referenceURL)?.scheme,"https"); XCTAssertFalse(r.construction.isEmpty) }
    for example in c.workExamples { for id in example.referenceIDs { XCTAssertNotNil(ObjectLibrary.reference(id),id) } }
    XCTAssertEqual(ObjectLibrary.search("5080").map(\.id),["FAB-003"])
    XCTAssertEqual(ObjectLibrary.search("hooded sweatshirt",domain:"Fabric merch",readyOnly:true).map(\.id),["FAB-024","FAB-025"])
    XCTAssertTrue(ObjectLibrary.search("hoodie",domain:"Paper goods").isEmpty)
    XCTAssertTrue(ObjectLibrary.search("PKG-056",readyOnly:true).isEmpty)
  }
  func testEveryStarterCreatesAValidPhysicalObjectWithPortableSource() throws {
    XCTAssertEqual(Set(ObjectLibrary.starters.map(\.id)).count,ObjectLibrary.starters.count)
    for entry in ObjectLibrary.starters {
      var p=Project(name:entry.name)
      let o=try p.addLibraryObject(entry.id)
      XCTAssertEqual(o.librarySelection?.entry,entry)
      XCTAssertEqual(o.librarySelection?.reference.id,entry.referenceID)
      XCTAssertEqual(o.librarySelection?.state,entry.blank == nil ? .concept:.proposedBlank)
      XCTAssertEqual(o.materialID,p.material(o.materialID).id,"Missing material for \(entry.id)")
      XCTAssertEqual(o.librarySelection?.initialParameters,o.parameters)
      if let blank=entry.blank {
        XCTAssertEqual(o.textile?.sku,blank.style); XCTAssertEqual(o.textile?.manufacturer,blank.manufacturer)
        XCTAssertEqual(o.textile?.measurementsVerified,false)
      }
      try p.validateArtworkLinks()
      XCTAssertEqual(p.minimumSchemaVersion,51)
      let encoded=try JSONEncoder.form.encode(p)
      XCTAssertEqual(try JSONEncoder.form.encode(JSONDecoder.form.decode(Project.self,from:encoded)),encoded)
    }
  }
  func testReadOnlyDiscoveryWithoutProjectAndPagingValidation() throws {
    let e=try engine()
    let list=try call(e,"list",["offset":200,"limit":20]) as! [String:Any]
    XCTAssertEqual(list["total"] as? Int,211); XCTAssertEqual((list["items"] as? [Any])?.count,11)
    _=try call(e,"get",["entry_id":"jersey-tee"])
    _=try call(e,"get",["reference_id":"PKG-056"])
    _=try call(e,"examples")
    XCTAssertNil(e.project); XCTAssertTrue(e.undoStack.isEmpty)
    for value in [-1.0,1.5,Double.infinity] { XCTAssertThrowsError(try call(e,"list",["offset":value])) }
    XCTAssertThrowsError(try call(e,"list",["limit":true]))
    XCTAssertThrowsError(try call(e,"add",["entry_id":"jersey-tee"]))
  }
  func testCompatibleSwapKeepsArtworkPhysicalSizeSourcesAndPreviousChoice() throws {
    var p=Project(name:"Swaps")
    let host=try p.addLibraryObject("jersey-tee")
    var sheet=try p.makeObject(recipeID:"artboard",parameters:["width":240,"depth":100])
    sheet.artwork=Artwork(elements:[.init(kind:"text",x:10,y:10,width:200,height:30,text:"DESERT",fontSize:24)],bleed:0)
    var ink=try p.makeObject(recipeID:"textilePrint",parameters:["width":240,"depth":100])
    ink.artwork=nil; ink.artworkSourceID=sheet.id; ink.artworkFit="actual"
    ink.textile?.attachment = .init(garmentID:host.id,zone:.front,clearance:0)
    p.objects += [sheet,ink]
    let e=try engine(p)
    _=try call(e,"replace",["object_id":host.id.uuidString,"entry_id":"heavy-tee"])
    let changed=try XCTUnwrap(e.project?.objects.first)
    XCTAssertEqual(changed.id,host.id); XCTAssertEqual(changed.designID,host.designID)
    XCTAssertEqual(changed.librarySelection?.entry.id,"heavy-tee")
    XCTAssertEqual(changed.librarySelection?.alternatives.map(\.id),["jersey-tee"])
    XCTAssertEqual(e.project?.objects[1],sheet); XCTAssertEqual(e.project?.objects[2],ink)
    XCTAssertEqual(e.undoStack.count,1)
    _=try e.call("form_undo"); XCTAssertEqual(e.project,p)
    _=try e.call("form_redo")
    try e.flush(); let loaded=try e.repository.load(p.id)
    XCTAssertEqual(try JSONEncoder.form.encode(loaded),try JSONEncoder.form.encode(e.project!)); XCTAssertEqual(loaded.schemaVersion,51)
  }
  func testSwapRejectsOutOfBoundsArtAndOtherConstructionWithoutPartialChanges() throws {
    var p=Project(name:"Bounds")
    let host=try p.addLibraryObject("heavy-tee")
    var ink=try p.makeObject(recipeID:"textilePrint",parameters:["width":390,"depth":100])
    ink.textile?.attachment = .init(garmentID:host.id,zone:.front,clearance:0)
    p.objects.append(ink); try p.validateArtworkLinks()
    let e=try engine(p)
    for id in ["jersey-tee","dad-cap","unknown"] {
      XCTAssertThrowsError(try call(e,"replace",["object_id":host.id.uuidString,"entry_id":id]))
      XCTAssertEqual(e.project,p); XCTAssertTrue(e.undoStack.isEmpty)
    }
  }
  func testChoiceIsIndependentFromFidelityAndShapeOrMaterialEditsBecomeCustom() throws {
    let e=try engine(Project(name:"Commitment"))
    let added=try call(e,"add",["entry_id":"jersey-tee"]) as! [String:Any]
    let id=added["id"] as! String
    _=try call(e,"state",["object_id":id,"state":"chosenBlank"])
    let chosen=e.project!
    XCTAssertEqual(chosen.objects[0].librarySelection?.state,.chosenBlank)
    XCTAssertEqual(chosen.objects[0].textile?.measurementsVerified,false)
    XCTAssertThrowsError(try call(e,"state",["object_id":id,"state":"productionChecked"]))
    _=try e.call("form_update_object",arguments:["object_id":id,"parameters":["depth":600]])
    XCTAssertEqual(e.project?.objects[0].librarySelection?.state,.custom)
    XCTAssertEqual(e.project?.objects[0].librarySelection?.entry.blank?.style,"3001")
    XCTAssertThrowsError(try call(e,"state",["object_id":id,"state":"chosenBlank"]))
    _=try e.call("form_undo"); XCTAssertEqual(e.project,chosen)
    _=try e.call("form_update_object",arguments:["object_id":id,"material_id":"jersey-navy"])
    XCTAssertEqual(e.project?.objects[0].librarySelection?.state,.custom)
    _=try e.call("form_undo")
    _=try e.call("form_update_object",arguments:["object_id":id,"color":"#000000"])
    XCTAssertEqual(e.project?.objects[0].librarySelection?.state,.chosenBlank)
  }
  func testLibraryBatchRollsBackAndLegacyObjectsRemainUnchanged() throws {
    let p=Project(name:"Legacy"), e=try engine(p)
    XCTAssertThrowsError(try e.call("form_batch",arguments:["operations":[
      ["name":"form_object_library","arguments":["command":"add","entry_id":"jersey-tee"]],
      ["name":"form_object_library","arguments":["command":"add","entry_id":"missing"]],
    ]]))
    XCTAssertEqual(e.project,p); XCTAssertTrue(e.undoStack.isEmpty)
    let legacy=try p.makeObject(recipeID:"crewTee")
    var data=try JSONSerialization.jsonObject(with:JSONEncoder.form.encode(legacy)) as! [String:Any]
    data.removeValue(forKey:"librarySelection")
    let loaded=try JSONDecoder.form.decode(ProductObject.self,from:JSONSerialization.data(withJSONObject:data))
    XCTAssertEqual(loaded,legacy); XCTAssertNil(loaded.librarySelection)
  }
  func testNewGarmentRegionsExcludePocketAndPreservePhysicalFaceOrientation() throws {
    var p=Project(name:"New silhouettes")
    for id in ["pullover-hoodie","cuffed-beanie","bandana"] {
      let o=try p.addLibraryObject(id), zones=MerchandiseBlanks.zones(o)
      XCTAssertTrue(zones.allSatisfy { $0.width>0 && $0.height>0 })
      XCTAssertEqual(Set(zones.map(\.id)).count,zones.count)
      let front=try XCTUnwrap(zones.first{$0.id == .front}), back=try XCTUnwrap(zones.first{$0.id == .back})
      XCTAssertEqual(front.normal.y,1); XCTAssertEqual(back.normal.y,-1)
      if o.recipeID == "pulloverHoodie" {
        XCTAssertLessThan(front.origin.z+front.height/2,o["depth"]*0.23-o["pocketHeight"]/2)
      }
    }
    try p.validateArtworkLinks()
  }
  func testArtworkRemainsPortableFromASchema51LibraryProject() throws {
    var p=Project(name:"Library artwork")
    let source=try p.addLibraryObject("business-card")
    let shape=ArtworkElement(kind:"rectangle",x:2,y:3,width:20,height:10,color:"#223344")
    p.objects[0].artwork?.elements=[shape]
    let before=p
    let captured=try ArtworkTransferGraph.capture(project:p,objectID:source.id,ids:[shape.id],
      readAsset:{ _,_ in throw FormError.invalid("This source has no external assets.") })
    let bundle=try ArtworkTransferBundle.decode(captured.encoded())
    XCTAssertEqual(bundle.metadata.sourceSchema,51)
    var destination=Project(name:"Destination")
    let workspace=try destination.ensureCanvasWorkspace()
    let plan=try ArtworkTransferGraph.plan(bundle,into:destination,objectID:workspace.id)
    let pasted=try XCTUnwrap(plan.project.canvasWorkspace?.artwork?.elements.first)
    XCTAssertEqual(pasted.width,20); XCTAssertEqual(pasted.height,10); XCTAssertEqual(pasted.color,shape.color)
    XCTAssertEqual(p,before)
  }
}
