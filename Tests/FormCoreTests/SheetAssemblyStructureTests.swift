import Foundation
import FormCADModel
import XCTest
@testable import FormCore

final class SheetAssemblyStructureTests:XCTestCase {
  private func fixture(count:Int=16)throws->(Project,UUID,UUID) {
    var project=Project(name:"Generic physical groups")
    var pages=[UUID]()
    for index in 0..<count {
      var page=try project.makeObject(recipeID:"artboard",name:"Page \(index)",parameters:["width":100,"depth":140])
      page.artwork = .init(background:"#FFFFFF",elements:[],bleed:0)
      project.objects.append(page);pages.append(page.id)
    }
    let publication=try PublicationCommands.createPublication(in:&project,name:"Reading order",pages:pages)
    let logical=project.publications![0].pages
    var parents=[SheetAssemblyParentSheet]()
    for index in 0..<(count/4) {
      let front:[UUID?]=[logical[count-1-index*2].id,logical[index*2].id]
      let back:[UUID?]=[logical[index*2+1].id,logical[count-2-index*2].id]
      let caliper=0.10+Double(index)*0.02
      let stock=PaperStock(name:"Stock \(index)",thicknessMM:caliper)
      parents.append(SheetAssemblyParentSheet(frontPageIDs:front,backPageIDs:back,stock:stock,sizeMM:Point2(200,140)))
    }
    let assembly=try SheetAssemblyCommands.create(in:&project,definition:.init(publicationID:publication,parentSheets:parents))
    return(project,publication,assembly)
  }
  private func object(_ id:UUID,in project:Project)throws->ProductObject {try XCTUnwrap(project.objects.first{$0.id==id})}
  private func artwork(in project:inout Project,name:String="Canonical source",width:Double=200,height:Double=200)throws->UUID {
    var object=try project.makeObject(recipeID:"artboard",name:name,parameters:["width":width,"depth":height])
    object.artwork = .init(background:"#FFFFFF",elements:[.init(kind:"text",x:1,y:1,width:50,height:20,text:"Asymmetric source F →",fontSize:12)],bleed:0)
    project.objects.append(object);return object.id
  }
  func testGatheringReimposesPhysicalParentsWithoutChangingCanonicalReadingOrderOrStocks()throws {
    var (project,_,id)=try fixture()
    let baseline=project,old=try object(id,in:project).sheetAssembly!
    let grouped=try SheetAssemblyCommands.reimposingSignatures(in:project,objectID:id,parentSheetsPerSignature:2)
    XCTAssertEqual(project,baseline,"Candidate creation is read-only.")
    XCTAssertEqual(grouped.signatures?.map{$0.parentSheetIDs.count},[2,2])
    XCTAssertEqual(grouped.parentSheets?.map(\.id),old.parentSheets?.map(\.id))
    XCTAssertEqual(grouped.parentSheets?.map(\.stock),old.parentSheets?.map(\.stock))
    XCTAssertNotEqual(grouped.parentSheets?.map(\.frontPageIDs),old.parentSheets?.map(\.frontPageIDs))
    try SheetAssemblyCommands.configure(in:&project,objectID:id,definition:grouped)
    let resolved=try project.resolvedSheetAssembly(object(id,in:project))
    XCTAssertEqual(resolved.leaves.flatMap{[$0.frontPageID,$0.backPageID].compactMap{$0}},project.publications![0].pages.map(\.id))
    XCTAssertEqual(resolved.leaves.map(\.signatureID),Array(repeating:grouped.signatures![0].id,count:4)+Array(repeating:grouped.signatures![1].id,count:4))
    XCTAssertEqual(resolved.leaves.map(\.parentSheetID),[old.parentSheets![0].id,old.parentSheets![1].id,old.parentSheets![1].id,old.parentSheets![0].id,old.parentSheets![2].id,old.parentSheets![3].id,old.parentSheets![3].id,old.parentSheets![2].id])
    XCTAssertEqual(project.objects.filter{$0.id != id},baseline.objects.filter{$0.id != id})
    let restored=try SheetAssemblyCommands.reimposingSignatures(in:project,objectID:id,parentSheetsPerSignature:0)
    XCTAssertNil(restored.signatures);XCTAssertEqual(restored.parentSheets,old.parentSheets)
  }
  func testGatherLifecycleReordersAndAddsPagesAtomicallyWhileRetainingStockAndGroupIdentity()throws {
    var (project,publication,id)=try fixture(count:8)
    let grouped=try SheetAssemblyCommands.reimposingSignatures(in:project,objectID:id,parentSheetsPerSignature:1)
    try SheetAssemblyCommands.configure(in:&project,objectID:id,definition:grouped)
    let sourceIDs=project.objects.map(\.id)
    var document=project.publications![0];document.pages.swapAt(2,3)
    try PublicationCommands.setPublication(in:&project,document:document)
    let saved=try object(id,in:project).sheetAssembly!
    XCTAssertEqual(saved.signatures,grouped.signatures)
    XCTAssertEqual(saved.parentSheets?.map(\.stock),grouped.parentSheets?.map(\.stock))
    XCTAssertEqual(try project.resolvedSheetAssembly(object(id,in:project)).leaves.flatMap{[$0.frontPageID,$0.backPageID].compactMap{$0}},document.pages.map(\.id))
    let before=project
    var invalid=saved;invalid.signatures![1].parentSheetIDs=invalid.signatures![0].parentSheetIDs
    XCTAssertThrowsError(try SheetAssemblyCommands.configure(in:&project,objectID:id,definition:invalid))
    XCTAssertEqual(project,before);XCTAssertEqual(project.objects.map(\.id),sourceIDs)
    XCTAssertEqual(project.publications?.first?.id,publication)
    let reopened=try JSONDecoder.form.decode(Project.self,from:JSONEncoder.form.encode(project))
    XCTAssertEqual(reopened.objects,project.objects);try reopened.validateSheetAssemblies()
  }
  func testAuxiliaryStockBindingAllowancesAndEdgeSourcesStayDistinctAndActualCalipersAccumulate()throws {
    var (project,publication,id)=try fixture(count:4)
    let source=try artwork(in:&project),canonical=project.objects
    var definition=try object(id,in:project).sheetAssembly!
    definition.parentSheets=nil;definition.stock = .init(thicknessMM:0.12)
    definition.binding = .init(style:.sewn,adhesiveMM:0.1,sewingSwellMM:0.2)
    definition.auxiliaryLeaves=[.init(name:"Front interleaf",placement:.front,stock:.init(thicknessMM:0.18),front:.init(sourceObjectID:source)),
      .init(name:"Back attached liner",placement:.back,stock:.init(thicknessMM:0.2),back:.init(sourceObjectID:source),attachment:.init(widthMM:7))]
    definition.edgeArtwork = .init(head:.init(sourceObjectID:source),tail:.init(sourceObjectID:source),foreEdge:.init(sourceObjectID:source))
    try SheetAssemblyCommands.configure(in:&project,objectID:id,definition:definition)
    let resolved=try project.resolvedSheetAssembly(object(id,in:project))
    XCTAssertEqual(resolved.leaves.count,4);XCTAssertEqual(project.publications![0].pages.count,4)
    XCTAssertNil(resolved.leaves.first!.frontPageID);XCTAssertNotNil(resolved.leaves.first!.auxiliaryID)
    XCTAssertEqual(resolved.textBlockThickness,0.24,accuracy:1e-12)
    XCTAssertEqual(resolved.stackThicknessMM,0.62,accuracy:1e-12)
    XCTAssertEqual(resolved.bindingAllowance,0.3,accuracy:1e-12)
    XCTAssertEqual(resolved.spineThickness,0.92,accuracy:1e-12)
    XCTAssertEqual(resolved.closedThickness,0.92,accuracy:1e-12)
    XCTAssertEqual(resolved.edgeArtwork?.foreEdge?.sourceObjectID,source)
    XCTAssertTrue(resolved.sourceObjectIDs.contains(source))
    XCTAssertTrue(project.consumedSheetSourceIDs.contains(source))
    XCTAssertEqual(project.objects.filter{$0.id != id},canonical.filter{$0.id != id})
    XCTAssertEqual(project.publications!.first?.id,publication)
    var invalid=definition;invalid.binding!.sewingSwellMM = -.infinity
    let accepted=project
    XCTAssertThrowsError(try SheetAssemblyCommands.configure(in:&project,objectID:id,definition:invalid));XCTAssertEqual(project,accepted)
  }
  func testClosedMeasurementsDoNotDependOnViewingPoseOrCropAcceptance()throws {
    var (project,_,id)=try fixture(count:4)
    let source=try artwork(in:&project,width:100,height:140)
    var definition=try object(id,in:project).sheetAssembly!
    definition.enclosure=[.init(id:"overhang",name:"Generic enlarged panel",size:.init("width+10","height+4"),
      positionMM:.init(-5,"stackThickness",-72),rotationDegrees:.init(-90,0,"openingDegrees"),
      stock:.init(thicknessMM:1.5),front:.init(sourceObjectID:source))]
    var candidate=try object(id,in:project);candidate.sheetAssembly=definition
    XCTAssertThrowsError(try project.resolvedSheetAssembly(candidate),"The full resolver must reject a crop that exceeds canonical source trim.")
    let closed=try project.sheetAssemblyMeasurements(candidate)
    XCTAssertGreaterThanOrEqual(closed.closedWidth,110-1e-10)
    definition.openingDegrees=160;definition.activeSpread=1;definition.bendMM=1;candidate.sheetAssembly=definition
    XCTAssertEqual(try project.sheetAssemblyMeasurements(candidate),closed,"Reference dimensions are always the physical rest envelope.")
  }
  func testOldDefinitionsDecodeAndEncodeWithoutAdvancedOptionalKeysAndNewFieldsRoundTrip()throws {
    let (project,_,id)=try fixture(count:4),old=try object(id,in:project).sheetAssembly!
    let data=try JSONEncoder.form.encode(old),raw=try XCTUnwrap(JSONSerialization.jsonObject(with:data) as? [String:Any])
    for key in ["signatures","auxiliaryLeaves","edgeArtwork"] {XCTAssertNil(raw[key])}
    XCTAssertFalse(old.requiresAdvancedStructureSchema)
    let loaded=try JSONDecoder.form.decode(SheetAssemblyDefinition.self,from:data)
    XCTAssertEqual(loaded,old)
    var updated=old;updated.binding = .init(style:.adhesive,adhesiveMM:0.12)
    XCTAssertTrue(updated.requiresAdvancedStructureSchema)
    XCTAssertEqual(try JSONDecoder.form.decode(SheetAssemblyDefinition.self,from:JSONEncoder.form.encode(updated)),updated)
  }
  func testSignatureConfigurationUsesExistingMCPUndoAndReconciliationRetainsGatherIdentityWhenPaddingGrows()throws {
    var (project,_,id)=try fixture(count:8)
    let grouped=try SheetAssemblyCommands.reimposingSignatures(in:project,objectID:id,parentSheetsPerSignature:1)
    let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer{try? FileManager.default.removeItem(at:directory)}
    let engine=OperationEngine(repository:try ProjectRepository(root:directory));engine.project=project
    let raw=try JSONSerialization.jsonObject(with:JSONEncoder.form.encode(grouped))
    _ = try engine.call("form_publication",arguments:["command":"sheet_assembly_configure","object_id":id.uuidString,"definition":raw])
    XCTAssertEqual(engine.undoStack.count,1)
    XCTAssertEqual(engine.project?.objects.first{$0.id==id}?.sheetAssembly?.signatures,grouped.signatures)
    engine.undo();XCTAssertEqual(engine.project,project)
    engine.redo();project=try XCTUnwrap(engine.project)
    var document=project.publications![0];document.layout = .init(firstPageSide:.verso)
    try PublicationCommands.setPublication(in:&project,document:document)
    let changed=try object(id,in:project).sheetAssembly!
    XCTAssertEqual(changed.signatures?.map(\.id),grouped.signatures?.map(\.id))
    XCTAssertEqual(changed.signatures?.map{$0.parentSheetIDs.count},[1,2])
    XCTAssertEqual(changed.parentSheets?.prefix(2).map(\.stock),grouped.parentSheets?.map(\.stock))
    let resolved=try project.resolvedSheetAssembly(object(id,in:project))
    XCTAssertEqual(resolved.leaves.count,6)
    XCTAssertEqual(resolved.leaves.flatMap{[$0.frontPageID,$0.backPageID].compactMap{$0}},document.pages.map(\.id))
    XCTAssertEqual(project.publications!.first!.pages.count,8,"Physical padding must not manufacture logical source pages.")
  }
  func testExpandedLayerBudgetIsBoundedAndLegacyMeasurementsRemainExact()throws {
    var (project,_,id)=try fixture(count:4)
    var definition=try object(id,in:project).sheetAssembly!
    let baseline=try project.resolvedSheetAssembly(object(id,in:project))
    XCTAssertEqual(baseline.trimWidth,100);XCTAssertEqual(baseline.trimHeight,140)
    XCTAssertEqual(baseline.bindingAllowance,0)
    XCTAssertEqual(baseline.textBlockThickness,baseline.stackThicknessMM)
    definition.enclosure=(0..<128).map{.init(id:"layer-\($0)",name:"Generic layer \($0)",size:.init(100,140))}
    try SheetAssemblyCommands.configure(in:&project,objectID:id,definition:definition)
    XCTAssertEqual(try project.resolvedSheetAssembly(object(id,in:project)).enclosure.count,128)
    let accepted=project
    definition.enclosure!.append(.init(id:"excess",name:"Excess",size:.init(100,140)))
    XCTAssertThrowsError(try SheetAssemblyCommands.configure(in:&project,objectID:id,definition:definition))
    XCTAssertEqual(project,accepted)
  }

}
