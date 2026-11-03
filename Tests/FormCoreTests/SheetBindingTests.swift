import Foundation
import XCTest
@testable import FormCore

final class SheetBindingTests:XCTestCase {
  private func fixture(count:Int=52)throws->(Project,PublicationDocument,[SheetAssemblyParentSheet]) {
    var project=Project(name:"Authored mixed-stock run"),ids=[UUID]()
    for index in 0..<count {
      var page=try project.makeObject(recipeID:"artboard",name:"Page \(index+1)",parameters:["width":215.9,"depth":279.4])
      page.artwork=Artwork(background:"#FFFFFF",elements:[],bleed:0);page.artwork!.backgroundOpacity=0
      project.objects.append(page);ids.append(page.id)
    }
    let id=try PublicationCommands.createPublication(in:&project,name:"Source-owned run",pages:ids)
    let document=project.publications!.first{$0.id==id}!,pages=document.pages
    var parents=[SheetAssemblyParentSheet]()
    for index in 0..<(count/4) {
      let thickness=index==0 ? 0.22:([4,8,12].contains(index) ? 0.12:0.10)
      let stock=PaperStock(name:"Parent \(index+1)",thicknessMM:thickness,
        profile:.init(texture:.cotton,color:index==0 ? "#D9BA70":"#F5F2EA"))
      parents.append(.init(frontPageIDs:[pages[count-1-index*2].id,pages[index*2].id],
        backPageIDs:[pages[index*2+1].id,pages[count-2-index*2].id],stock:stock,sizeMM:.init(431.8,279.4),
        printIntent:[0,4,8,12].contains(index) ? .blackOnly:.color))
    }
    return(project,document,parents)
  }
  func testThirteenParentsAuthoritativelySupplyTwentySixLeavesAndStockEditsDoNotCreateCopies()throws {
    var(project,document,parents)=try fixture();let sources=project.objects
    let definition=SheetAssemblyDefinition(publicationID:document.id,stock:.init(thicknessMM:0.9),
      binding:.init(style:.saddleStitch,positionsMM:[50,229.4]),parentSheets:parents)
    let id=try SheetAssemblyCommands.create(in:&project,definition:definition)
    var object=project.objects.first{$0.id==id}!,resolved=try project.resolvedSheetAssembly(object)
    XCTAssertEqual(project.publications?.first?.layout?.facingPages,true)
    XCTAssertEqual(resolved.parentSheets.count,13);XCTAssertEqual(resolved.leaves.count,26)
    XCTAssertEqual(resolved.stackThicknessMM,2.96,accuracy:1e-10)
    XCTAssertEqual(try XCTUnwrap(resolved.binding).penetrationMM,1.48,accuracy:1e-10)
    XCTAssertEqual(resolved.binding?.positionsMM,[50,229.4])
    XCTAssertEqual(resolved.leaves[0].parentSheetID,parents[0].id)
    XCTAssertEqual(resolved.leaves[25].parentSheetID,parents[0].id)
    XCTAssertEqual(try project.parentSheet(forPageObjectID:document.pages[0].objectID,in:object)?.id,parents[0].id)
    XCTAssertEqual(try project.parentSheet(forPageObjectID:document.pages[51].objectID,in:object)?.id,parents[0].id)
    XCTAssertNil(object.sheetAssembly?.leaves,"A folded parent is the only editable stock authority.")
    var changed=parents[0].stock;changed.thicknessMM=0.30
    try SheetAssemblyCommands.setParentStock(in:&project,objectID:id,parentSheetID:parents[0].id,stock:changed)
    object=project.objects.first{$0.id==id}!;resolved=try project.resolvedSheetAssembly(object)
    XCTAssertNil(object.sheetAssembly?.leaves)
    XCTAssertEqual(object.sheetAssembly?.stock.thicknessMM,0.9,"The fallback stock is not an editable copy of every parent.")
    XCTAssertEqual(resolved.leaves[0].stock,changed);XCTAssertEqual(resolved.leaves[25].stock,changed)
    XCTAssertEqual(resolved.stackThicknessMM,3.12,accuracy:1e-10)
    XCTAssertEqual(Array(project.objects.prefix(sources.count)),sources)
    let reopened=try JSONDecoder.form.decode(Project.self,from:JSONEncoder.form.encode(project))
    XCTAssertEqual(reopened.objects,project.objects);XCTAssertEqual(reopened.minimumSchemaVersion,63)
  }
  func testConflictingLeafStockParentOrderAndPhysicalDimensionsRejectAtomically()throws {
    var(project,document,parents)=try fixture(count:8)
    var definition=SheetAssemblyDefinition(publicationID:document.id,binding:.init(style:.saddleStitch),parentSheets:parents)
    let id=try SheetAssemblyCommands.create(in:&project,definition:definition),accepted=project
    definition.leaves=document.leafPairs().map{.init(id:$0.id,frontPageID:$0.front?.id,backPageID:$0.back?.id)}
    definition.leaves![0].stock = .init(thicknessMM:0.8)
    XCTAssertThrowsError(try SheetAssemblyCommands.configure(in:&project,objectID:id,definition:definition));XCTAssertEqual(project,accepted)
    definition.leaves![0].stock=parents[0].stock
    XCTAssertNoThrow(try SheetAssemblyCommands.configure(in:&project,objectID:id,definition:definition))
    project=accepted;definition=accepted.objects.first{$0.id==id}!.sheetAssembly!
    definition.parentSheets![0].frontPageIDs.swapAt(0,1)
    XCTAssertThrowsError(try SheetAssemblyCommands.configure(in:&project,objectID:id,definition:definition));XCTAssertEqual(project,accepted)
    definition=accepted.objects.first{$0.id==id}!.sheetAssembly!
    definition.parentSheets![0].sizeMM.x += 1
    XCTAssertThrowsError(try SheetAssemblyCommands.configure(in:&project,objectID:id,definition:definition));XCTAssertEqual(project,accepted)
  }
  func testNullableSaddleSlotsFollowFirstVersoWithoutInventingSavedPages()throws {
    var(project,document,_)=try fixture(count:4);document.layout = .init(firstPageSide:.verso)
    try PublicationCommands.setPublication(in:&project,document:document)
    let p=document.pages,stock=PaperStock(thicknessMM:0.12)
    let parents:[SheetAssemblyParentSheet]=[
      .init(frontPageIDs:[nil,nil],backPageIDs:[p[0].id,nil],stock:stock,sizeMM:.init(431.8,279.4)),
      .init(frontPageIDs:[nil,p[1].id],backPageIDs:[p[2].id,p[3].id],stock:stock,sizeMM:.init(431.8,279.4))]
    let id=try SheetAssemblyCommands.create(in:&project,definition:.init(publicationID:document.id,binding:.init(style:.saddleStitch),parentSheets:parents))
    let object=project.objects.first{$0.id==id}!,result=try project.resolvedSheetAssembly(object)
    XCTAssertEqual(result.leaves.count,4);XCTAssertNil(result.leaves[0].front)
    XCTAssertNil(result.leaves.last!.front);XCTAssertNil(result.leaves.last!.back)
    XCTAssertEqual(result.stackThicknessMM,0.48,accuracy:1e-12)
    XCTAssertEqual(project.publications!.first!.pages.count,4)
  }
  func testBindingUsesSharedAtomicCommandUndoAndPreservesCanonicalSources()throws {
    var(project,document,_)=try fixture(count:4);project.publications![0].layout = .init(facingPages:false)
    let id=try SheetAssemblyCommands.create(in:&project,definition:.init(publicationID:document.id))
    XCTAssertEqual(project.publications!.first!.layout?.facingPages,false)
    let folder=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer{try? FileManager.default.removeItem(at:folder)}
    let engine=OperationEngine(repository:try ProjectRepository(root:folder));engine.project=project
    var definition=project.objects.first{$0.id==id}!.sheetAssembly!;definition.binding = .init(style:.sideStaple,positionsMM:[50,229.4])
    let raw=try JSONSerialization.jsonObject(with:JSONEncoder.form.encode(definition))
    _=try engine.call("form_publication",arguments:["command":"sheet_assembly_configure","object_id":id.uuidString,"definition":raw])
    XCTAssertEqual(engine.undoStack.count,1)
    XCTAssertEqual(engine.project?.objects.first{$0.id==id}?.sheetAssembly?.binding?.style,.sideStaple)
    XCTAssertEqual(engine.project!.objects.filter{$0.id != id},project.objects.filter{$0.id != id})
    engine.undo();XCTAssertEqual(engine.project,project)
    engine.redo();XCTAssertEqual(engine.project?.objects.first{$0.id==id}?.sheetAssembly?.binding?.style,.sideStaple)
    var invalid=definition;invalid.binding!.positionsMM=[50,50]
    let accepted=engine.project
    XCTAssertThrowsError(try SheetAssemblyCommands.configure(in:&engine.project!,objectID:id,definition:invalid))
    XCTAssertEqual(engine.project,accepted)
  }
  func testDuplexParentFacesReverseOnlyOnDerivedLeftLeaf()throws {
    var(project,document,parents)=try fixture(count:4)
    let reverse=PaperPly(name:"Reverse blue",color:"#2244AA",thicknessMM:0.06,profile:.init(opacity:0.4))
    let front=PaperPly(name:"Front red",color:"#CC3322",thicknessMM:0.08,profile:.init(opacity:0.95))
    parents[0].stock.plies=[reverse,front];parents[0].stock.thicknessMM=0.14
    let id=try SheetAssemblyCommands.create(in:&project,definition:.init(publicationID:document.id,parentSheets:parents))
    let object=project.objects.first{$0.id==id}!,resolved=try project.resolvedSheetAssembly(object)
    XCTAssertEqual(resolved.leaves[0].stock.plies,[reverse,front])
    XCTAssertEqual(resolved.leaves[1].stock.plies,[front,reverse])
    XCTAssertEqual(resolved.leaves[0].stock.sheetFaceOpacity(inside:false),0.95)
    XCTAssertEqual(resolved.leaves[1].stock.sheetFaceOpacity(inside:false),0.4)
    XCTAssertEqual(resolved.leaves[1].stock.sheetFaceOpacity(inside:true),0.95)
    XCTAssertEqual(object.sheetAssembly?.parentSheets,parents,"Physical parent stock is never rewritten by left-leaf projection.")
  }
  func testReimpositionPreservesPhysicalStockIdentityAndAddsExplicitBlankSlots()throws {
    var(project,document,parents)=try fixture(count:8)
    let id=try SheetAssemblyCommands.create(in:&project,definition:.init(publicationID:document.id,
      stock:.init(name:"New body stock",thicknessMM:0.09),activeSpread:4,parentSheets:parents))
    document=project.publications![0];document.pages.reverse();project.publications![0]=document
    try SheetAssemblyCommands.reconcileParentSheets(in:&project,publicationID:document.id)
    var object=project.objects.first{$0.id==id}!,updated=object.sheetAssembly!.parentSheets!
    XCTAssertEqual(updated.map(\.id),parents.map(\.id));XCTAssertEqual(updated.map(\.stock),parents.map(\.stock))
    XCTAssertEqual(updated.map(\.printIntent),parents.map(\.printIntent))
    XCTAssertEqual(updated[0].frontPageIDs,[document.pages[7].id,document.pages[0].id])
    var added=try project.makeObject(recipeID:"artboard",name:"Added canonical page",parameters:["width":215.9,"depth":279.4])
    added.artwork=Artwork(elements:[]);project.objects.append(added)
    document.pages.append(.init(objectID:added.id));project.publications![0]=document
    try SheetAssemblyCommands.reconcileParentSheets(in:&project,publicationID:document.id)
    object=project.objects.first{$0.id==id}!;updated=object.sheetAssembly!.parentSheets!
    XCTAssertEqual(updated.count,3);XCTAssertEqual(Array(updated.prefix(2)).map(\.id),parents.map(\.id))
    XCTAssertEqual(updated[2].stock.name,"New body stock");XCTAssertEqual(updated[2].printIntent,.color)
    XCTAssertEqual(updated.flatMap{$0.frontPageIDs+$0.backPageIDs}.filter{$0==nil}.count,3)
    XCTAssertEqual(try project.resolvedSheetAssembly(object).leaves.count,6)
    document.pages=Array(document.pages.prefix(3));project.publications![0]=document
    try SheetAssemblyCommands.reconcileParentSheets(in:&project,publicationID:document.id)
    object=project.objects.first{$0.id==id}!;updated=object.sheetAssembly!.parentSheets!
    XCTAssertEqual(updated.count,1);XCTAssertEqual(updated[0].id,parents[0].id)
    XCTAssertEqual(object.sheetAssembly?.activeSpread,2)
    XCTAssertEqual(project.publications![0].pages.count,3,"Padding remains physical and creates no source pages.")
  }

  func testSideStapleKeepsPinnedStockStationaryAndFreePageArcLengthPhysical()throws {
    var(project,document,parents)=try fixture(count:8)
    let definition=SheetAssemblyDefinition(publicationID:document.id,openingDegrees:150,activeSpread:2,bendMM:3,
      binding:.init(style:.sideStaple,flexWidthMM:10),parentSheets:parents)
    let id=try SheetAssemblyCommands.create(in:&project,definition:definition),object=project.objects.first{$0.id==id}!
    let resolved=try project.resolvedSheetAssembly(object),binding=try XCTUnwrap(resolved.binding)
    XCTAssertEqual(binding.penetrationMM,resolved.stackThicknessMM)
    XCTAssertTrue(resolved.leaves.allSatisfy{$0.stackOffsetMM>0},"The physically pinned margin never turns below the block.")
    for leaf in resolved.leaves {
      let profile=try SheetSideFlexProfile(binding:binding.definition,leaf:leaf,stackThicknessMM:resolved.stackThicknessMM,
        openingDegrees:resolved.openingDegrees,bendMM:resolved.bendMM)
      let pinned=profile.sample(atMM:binding.definition.edgeInsetMM)
      XCTAssertEqual(pinned.xMM,binding.definition.edgeInsetMM);XCTAssertEqual(pinned.yMM,leaf.stackOffsetMM)
      XCTAssertEqual(pinned.angleRadians,0)
      var length=0.0,prior=profile.sample(atMM:0)
      for step in 1...8000 {
        let next=profile.sample(atMM:leaf.size.x*Double(step)/8000)
        length+=hypot(next.xMM-prior.xMM,next.yMM-prior.yMM);prior=next
      }
      XCTAssertEqual(length,leaf.size.x,accuracy:0.0005,"Each free page retains its authored material length.")
      XCTAssertTrue(prior.xMM.isFinite && prior.yMM.isFinite)
    }
    var closed=definition;closed.openingDegrees=0
    try SheetAssemblyCommands.configure(in:&project,objectID:id,definition:closed)
    let closedResolved=try project.resolvedSheetAssembly(project.objects.first{$0.id==id}!)
    XCTAssertEqual(closedResolved.leaves.map(\.stackOffsetMM),resolved.leaves.map(\.stackOffsetMM))
  }
  func testSideFlexRejectsImpossibleOpenRadiusButKeepsRememberedClosedSettings()throws {
    var(project,document,parents)=try fixture(count:4);parents[0].stock.thicknessMM=20
    var definition=SheetAssemblyDefinition(publicationID:document.id,openingDegrees:0,activeSpread:1,
      binding:.init(style:.sideStaple,flexWidthMM:1),parentSheets:parents)
    let id=try SheetAssemblyCommands.create(in:&project,definition:definition),closed=project
    definition.openingDegrees=180
    XCTAssertThrowsError(try SheetAssemblyCommands.configure(in:&project,objectID:id,definition:definition))
    XCTAssertEqual(project,closed)
  }

  func testExplicitLeavesCannotPairDifferentHalvesOfOneParentOrOmitBlankHalves()throws {
    var(project,document,parents)=try fixture(count:4)
    let id=try SheetAssemblyCommands.create(in:&project,definition:.init(publicationID:document.id,parentSheets:parents))
    let accepted=project,p=document.pages
    var wrong=project.objects.first{$0.id==id}!.sheetAssembly!
    wrong.leaves=[.init(frontPageID:p[0].id,backPageID:p[3].id),.init(frontPageID:p[2].id,backPageID:p[1].id)]
    XCTAssertThrowsError(try SheetAssemblyCommands.configure(in:&project,objectID:id,definition:wrong))
    XCTAssertEqual(project,accepted,"Both invalid pairs share the same parent, but splice different physical halves.")
    document.layout = .init(firstPageSide:.verso);project.publications![0]=document
    let stock=parents[0].stock
    wrong.leaves=nil;wrong.parentSheets=[
      .init(frontPageIDs:[nil,nil],backPageIDs:[p[0].id,nil],stock:stock,sizeMM:.init(431.8,279.4)),
      .init(frontPageIDs:[nil,p[1].id],backPageIDs:[p[2].id,p[3].id],stock:stock,sizeMM:.init(431.8,279.4))]
    try SheetAssemblyCommands.configure(in:&project,objectID:id,definition:wrong)
    let padded=project,physical=try project.resolvedSheetAssembly(project.objects.first{$0.id==id}!)
    wrong.leaves=physical.leaves.dropLast().map{.init(id:$0.id,frontPageID:$0.frontPageID,backPageID:$0.backPageID)}
    XCTAssertThrowsError(try SheetAssemblyCommands.configure(in:&project,objectID:id,definition:wrong))
    XCTAssertEqual(project,padded,"An entirely blank declared parent half is physical stock and cannot be omitted.")
    wrong.leaves=physical.leaves.map{.init(id:$0.id,frontPageID:$0.frontPageID,backPageID:$0.backPageID)}
    let last=wrong.leaves!.count-1;wrong.leaves![last].id=UUID()
    XCTAssertThrowsError(try SheetAssemblyCommands.configure(in:&project,objectID:id,definition:wrong))
    XCTAssertEqual(project,padded,"Blank halves retain their stable physical parent identity.")
  }

}
