import Foundation
import FormCADModel
import XCTest
@testable import FormCore

final class PhysicalSchemaIntegrationTests:XCTestCase {
  private func physicalStock()->PaperStock {
    var stock=PaperStock(thicknessMM:0.1,profile:PaperSurfaceProfile())
    stock.profile!.appearance=PhysicalAppearance();return stock
  }
  private func object(_ name:String="Ordinary source")->ProductObject {
    .init(name:name,recipeID:"box",parameters:["width":100,"height":100,"depth":100])
  }
  func testPhysicalResourcesAndObjectsOutrankPublicationSchemasWithoutChangingLegacyFloors()throws {
    var project=Project(name:"Mixed persisted features")
    var story=TextStory(source:.init(kind:"text",x:0,y:0,text:"Source words"))
    story.annotations=[.init(location:0,length:6,kind:.note,body:"Editorial source")]
    project.textStories=[story];XCTAssertEqual(project.minimumSchemaVersion,64)
    var structural=object();structural.dimensionBindings=[]
    project.objects=[structural];XCTAssertEqual(project.minimumSchemaVersion,65)
    var physical=object("Physical source")
    physical.paperConstruction = .init(kind:.envelope,dimensions:.init(width:100,height:140,depth:10),stock:physicalStock())
    project.objects.append(physical);XCTAssertEqual(project.minimumSchemaVersion,66)
    project.objects.reverse();XCTAssertEqual(project.minimumSchemaVersion,66)
    project.objects.removeAll{$0.id==physical.id};XCTAssertEqual(project.minimumSchemaVersion,65)

    let resourceEdits:[(String,(inout Project)->Void)]=[
      ("Table renderer",{$0.renderSettings=CyclesRenderSettings()}),
      ("Material optics",{var value=Material("surface","Surface","Paper","#FFFFFF");value.appearance=PhysicalAppearance();$0.materials=[value]}),
      ("Saved shot",{var shot=StudioShot(name:"Saved camera",camera:.init(),referenceAspect:1.5);shot.renderSettings=CyclesRenderSettings();$0.studioPresentation = .init(shots:[shot])}),
      ("Saved scene",{var scene=StudioComposition(name:"Saved arrangement",camera:.init());scene.renderSettings=CyclesRenderSettings();$0.studioPresentation = .init();$0.studioPresentation!.scenes=[scene]})]
    for (label,edit) in resourceEdits {
      var candidate=project;edit(&candidate)
      XCTAssertEqual(candidate.minimumSchemaVersion,66,label)
      let decoded=try JSONDecoder.form.decode(Project.self,from:JSONEncoder.form.encode(candidate))
      XCTAssertEqual(decoded.minimumSchemaVersion,66,label)
      XCTAssertEqual(decoded.objects,project.objects,label)
    }
    project.objects=[];XCTAssertEqual(project.minimumSchemaVersion,64)
    project.textStories=nil;XCTAssertEqual(project.minimumSchemaVersion,1)
  }
  func testNestedPanelWrapInsertAndAuxiliaryStockAppearancesRequirePhysicalSchema()throws {
    let stock=physicalStock()
    let wrapping=SheetPanelFeatures(wrap:.init(stock:stock,turnInMM:4))
    let insert=SheetPanelFeatures(recesses:[.init(id:"seat",origin:.init(10,10),size:.init(30,40),depthMM:0.2,insert:.init(stock:stock))])
    func panelObject(_ features:SheetPanelFeatures)->ProductObject {
      var value=object()
      var paper=PaperConstruction(kind:.authored,dimensions:.init(width:100,height:140,depth:1),stock:.init(thicknessMM:1))
      let panel=PlanarPanelDefinition(id:"panel",name:"Physical panel",polygon:[.init(0,0),.init(100,0),.init(100,140),.init(0,140)],features:features)
      paper.authored = .init(name:"Layered panel",size:.init(100,140),stockThickness:1,panels:[panel],rootPanelID:"panel")
      value.paperConstruction=paper;return value
    }
    func enclosureObject(_ features:SheetPanelFeatures)->ProductObject {
      var value=object()
      value.sheetAssembly = .init(publicationID:UUID(),enclosure:[.init(id:"panel",name:"Physical plane",size:.init(100,140),stock:.init(thicknessMM:1),features:features)])
      return value
    }
    var auxiliary=object()
    auxiliary.sheetAssembly = .init(publicationID:UUID(),auxiliaryLeaves:[.init(stock:stock)])
    let cases=[("panel wrapping",panelObject(wrapping)),("panel insert",panelObject(insert)),
      ("enclosure wrapping",enclosureObject(wrapping)),("enclosure insert",enclosureObject(insert)),("auxiliary stock",auxiliary)]
    for (label,source) in cases {
      var project=Project(name:"Nested physical stock");project.objects=[source]
      XCTAssertEqual(project.minimumSchemaVersion,66,label)
      let decoded=try JSONDecoder.form.decode(Project.self,from:JSONEncoder.form.encode(project))
      XCTAssertEqual(decoded.minimumSchemaVersion,66,label);XCTAssertEqual(decoded.objects,[source],label)
    }
    var plain=Project(name:"Legacy advanced construction");plain.objects=[panelObject(.init(wrap:.init(stock:.init(thicknessMM:0.1))))]
    XCTAssertEqual(plain.minimumSchemaVersion,65,"A wrapping declaration without physical optics remains upstream schema65.")
    plain.objects=[enclosureObject(.init(recesses:[.init(id:"seat",origin:.init(10,10),size:.init(30,40),depthMM:0.2,insert:.init(stock:.init(thicknessMM:0.1)))]))]
    XCTAssertEqual(plain.minimumSchemaVersion,65)
    auxiliary.sheetAssembly!.auxiliaryLeaves![0].stock.profile=nil;plain.objects=[auxiliary]
    XCTAssertEqual(plain.minimumSchemaVersion,65)
  }
  func testPreMergeCyclesSchema64StillDecodesAndSavesAt66WithoutChangingSourceFields()throws {
    var prior=Project(name:"Earlier Cycles source")
    prior.schemaVersion=64;prior.renderSettings=CyclesRenderSettings()
    var material=Material("surface","Surface","Paper","#EFEDE9");material.appearance=PhysicalAppearance();prior.materials=[material]
    prior.camera.azimuth=0.71;prior.camera.distance=3.4;prior.objects=[object()]
    prior.createdAt=Date(timeIntervalSince1970:1_700_000_000);prior.updatedAt=prior.createdAt
    let decoded=try JSONDecoder.form.decode(Project.self,from:JSONEncoder.form.encode(prior))
    XCTAssertEqual(decoded,prior);XCTAssertEqual(decoded.schemaVersion,64);XCTAssertEqual(decoded.minimumSchemaVersion,66)
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("physical-schema-"+UUID().uuidString)
    addTeardownBlock {try? FileManager.default.removeItem(at:root)}
    let repository=try ProjectRepository(root:root);try repository.save(decoded)
    var expected=decoded;expected.schemaVersion=66
    XCTAssertEqual(try repository.load(decoded.id),expected)
    XCTAssertEqual(decoded,prior,"Saving raises persisted metadata without mutating the caller's source value.")
  }
  func testUpstreamNestedStockValidationRejectsInvalidPhysicalOptics()throws {
    let stock=physicalStock()
    func resolve(_ features:SheetPanelFeatures)throws {
      _ = try features.resolved(size:.init(100,140),stock:.init(thicknessMM:1),variables:[:]){_,_ in nil}
    }
    var wrap=SheetPanelFeatures(wrap:.init(stock:stock,turnInMM:4))
    var insert=SheetPanelFeatures(recesses:[.init(id:"seat",origin:.init(10,10),size:.init(30,40),depthMM:0.2,insert:.init(stock:stock))])
    XCTAssertNoThrow(try resolve(wrap));XCTAssertNoThrow(try resolve(insert))
    wrap.wrap!.stock.profile!.appearance!.ior = .nan
    insert.recesses![0].insert!.stock.profile!.appearance!.sheen=2
    XCTAssertThrowsError(try resolve(wrap));XCTAssertThrowsError(try resolve(insert))

    var project=Project(name:"Validated auxiliary optics")
    for _ in 0..<2 {
      var page=try project.makeObject(recipeID:"artboard",parameters:["width":100,"depth":140])
      page.artwork = .init(elements:[]);project.objects.append(page)
    }
    let pageIDs=project.objects.map(\.id)
    let publication=try PublicationCommands.createPublication(in:&project,name:"Physical pages",pages:pageIDs)
    let assemblyID=try SheetAssemblyCommands.create(in:&project,definition:.init(publicationID:publication,auxiliaryLeaves:[.init(stock:stock)]))
    let index=try XCTUnwrap(project.objects.firstIndex{$0.id==assemblyID})
    XCTAssertNoThrow(try project.resolvedSheetAssembly(project.objects[index]))
    project.objects[index].sheetAssembly!.auxiliaryLeaves![0].stock.profile!.appearance!.normalStrength = -.infinity
    XCTAssertThrowsError(try project.resolvedSheetAssembly(project.objects[index]))
  }
}
