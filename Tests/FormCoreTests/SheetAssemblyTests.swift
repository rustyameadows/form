import Foundation
import FormCADModel
import XCTest
@testable import FormCore

final class SheetAssemblyTests:XCTestCase {
  private func fixture(count:Int=4)throws->(Project,UUID) {
    var project=Project(name:"Ordered sheet source")
    for index in 0..<count {
      var page=try project.makeObject(recipeID:"artboard",name:"Canonical \(index+1)",parameters:["width":100,"depth":140])
      page.artwork=Artwork(background:"#FFFFFF",elements:[.init(kind:"text",x:10,y:12,width:80,height:20,text:"Page \(index+1)",fontSize:18)])
      project.objects.append(page)
    }
    let publication=try PublicationCommands.createPublication(in:&project,name:"Ordered faces",pages:project.objects.map(\.id))
    return(project,publication)
  }
  func testAutomaticPairingTracksCanonicalOrderCaliperAndDefaultTableConsumptionWithoutHidingSources()throws {
    var (project,publication)=try fixture();let originals=project.objects
    let definition=SheetAssemblyDefinition(publicationID:publication,stock:.init(thicknessMM:0.18),openingDegrees:180,activeSpread:1)
    let id=try SheetAssemblyCommands.create(in:&project,definition:definition)
    let object=try XCTUnwrap(project.objects.first{$0.id==id}),resolved=try project.resolvedSheetAssembly(object)
    XCTAssertEqual(resolved.leaves.count,2);XCTAssertEqual(resolved.stackThicknessMM,0.36,accuracy:1e-12)
    XCTAssertEqual(resolved.leaves[0].front?.sourceObjectID,originals[0].id)
    XCTAssertEqual(resolved.leaves[0].back?.sourceObjectID,originals[1].id)
    XCTAssertEqual(resolved.leaves[1].front?.sourceObjectID,originals[2].id)
    XCTAssertTrue(resolved.leaves[0].backVisible);XCTAssertTrue(resolved.leaves[1].frontVisible)
    XCTAssertEqual(Array(project.objects.prefix(originals.count)),originals)
    XCTAssertEqual(project.tablePresentationObjects.map(\.id),[id])
    XCTAssertTrue(originals.allSatisfy(\.hasTablePresentation),"Explicit source scenes stay available; consumption is a project display rule.")
    XCTAssertEqual(project.minimumSchemaVersion,63)
    let loaded=try JSONDecoder.form.decode(Project.self,from:JSONEncoder.form.encode(project))
    XCTAssertEqual(loaded.objects,project.objects);try loaded.validateSheetAssemblies()
    project.publications![0].pages.swapAt(1,2)
    let reordered=try project.resolvedSheetAssembly(object)
    XCTAssertEqual(reordered.leaves[0].back?.sourceObjectID,originals[2].id)
    XCTAssertEqual(reordered.leaves[1].front?.sourceObjectID,originals[1].id)
  }
  func testClosingFromLastSpreadRestoresOnePositiveStackWhileRememberingSpread()throws {
    var (project,publication)=try fixture(count:6)
    var definition=SheetAssemblyDefinition(publicationID:publication,stock:.init(thicknessMM:0.18),
      openingDegrees:180,activeSpread:3,bendMM:1)
    let id=try SheetAssemblyCommands.create(in:&project,definition:definition)
    let sources=Array(project.objects.prefix(6))
    XCTAssertTrue(try project.resolvedSheetAssembly(project.objects.first{$0.id==id}!).leaves.allSatisfy(\.turned))
    definition.openingDegrees=0
    try SheetAssemblyCommands.configure(in:&project,objectID:id,definition:definition)
    let object=try XCTUnwrap(project.objects.first{$0.id==id}),closed=try project.resolvedSheetAssembly(object)
    XCTAssertEqual(object.sheetAssembly?.activeSpread,3)
    XCTAssertEqual(closed.activeSpread,3)
    XCTAssertTrue(closed.leaves.allSatisfy{!$0.turned})
    XCTAssertEqual(closed.stackThicknessMM,0.54,accuracy:1e-12)
    for (index,leaf) in closed.leaves.enumerated() {
      XCTAssertEqual(leaf.stackOffsetMM,0.54-Double(index)*0.18-0.09,accuracy:1e-12)
      XCTAssertGreaterThanOrEqual(leaf.stackOffsetMM-leaf.stock.resolvedThicknessMM/2,-1e-12)
      XCTAssertLessThanOrEqual(leaf.stackOffsetMM+leaf.stock.resolvedThicknessMM/2,closed.stackThicknessMM+1e-12)
    }
    XCTAssertEqual(closed.leaves.map(\.frontVisible),[true,false,false])
    XCTAssertEqual(closed.leaves.map(\.backVisible),[false,false,true])
    XCTAssertEqual(Array(project.objects.prefix(6)),sources)
    definition.openingDegrees=180
    try SheetAssemblyCommands.configure(in:&project,objectID:id,definition:definition)
    XCTAssertTrue(try project.resolvedSheetAssembly(project.objects.first{$0.id==id}!).leaves.allSatisfy(\.turned))
  }
  func testClosingKeepsRememberedBendWithoutApplyingOpenRadiusToClosedStack()throws {
    var (project,publication)=try fixture(count:8)
    for index in project.objects.indices {project.objects[index].parameters["width"]=10}
    var definition=SheetAssemblyDefinition(publicationID:publication,stock:.init(thicknessMM:3),
      openingDegrees:180,activeSpread:2,bendMM:5)
    let id=try SheetAssemblyCommands.create(in:&project,definition:definition)
    XCTAssertEqual(try project.resolvedSheetAssembly(project.objects.first{$0.id==id}!).stackThicknessMM,12)
    definition.openingDegrees=0
    try SheetAssemblyCommands.configure(in:&project,objectID:id,definition:definition)
    let closed=try project.resolvedSheetAssembly(project.objects.first{$0.id==id}!)
    XCTAssertEqual(closed.bendMM,5)
    XCTAssertEqual(closed.activeSpread,2)
    XCTAssertTrue(closed.leaves.allSatisfy{!$0.turned && $0.stackOffsetMM>0})
    XCTAssertEqual(closed.leaves.first!.stackOffsetMM+1.5,12,accuracy:1e-12)
    XCTAssertEqual(closed.leaves.last!.stackOffsetMM-1.5,0,accuracy:1e-12)
    definition.openingDegrees=180
    try SheetAssemblyCommands.configure(in:&project,objectID:id,definition:definition)
    XCTAssertEqual(try project.resolvedSheetAssembly(project.objects.first{$0.id==id}!).leaves.filter(\.turned).count,2)
  }
  func testFirstVersoAndOddTailKeepDeclaredBlankPhysicalFaces()throws {
    var (project,publication)=try fixture(count:3)
    project.publications![0].layout = .init(firstPageSide:.verso)
    let id=try SheetAssemblyCommands.create(in:&project,definition:.init(publicationID:publication))
    let result=try project.resolvedSheetAssembly(project.objects.first{$0.id==id}!)
    XCTAssertEqual(result.leaves.count,2);XCTAssertNil(result.leaves[0].front)
    XCTAssertEqual(result.leaves[0].back?.sourceObjectID,project.publications![0].pages[0].objectID)
    XCTAssertNotNil(result.leaves[1].front);XCTAssertNotNil(result.leaves[1].back)
  }
  func testExplicitFacePairingMixedTrimAndInvalidEditsAreAtomic()throws {
    var (project,publication)=try fixture();let pages=project.publications![0].pages
    let declaration=SheetAssemblyDefinition(publicationID:publication,
      leaves:[.init(frontPageID:pages[0].id,backPageID:pages[1].id,stock:.init(thicknessMM:0.6)),
        .init(frontPageID:pages[2].id,backPageID:pages[3].id)])
    let id=try SheetAssemblyCommands.create(in:&project,definition:declaration),accepted=project
    var invalid=declaration;invalid.activeSpread=3
    XCTAssertThrowsError(try SheetAssemblyCommands.configure(in:&project,objectID:id,definition:invalid));XCTAssertEqual(project,accepted)
    invalid=declaration;invalid.leaves![1].frontPageID=pages[0].id
    XCTAssertThrowsError(try SheetAssemblyCommands.configure(in:&project,objectID:id,definition:invalid));XCTAssertEqual(project,accepted)
    project.objects[1].parameters["width"]=101
    XCTAssertThrowsError(try project.validateSheetAssemblies(),"A physical sheet cannot fit unlike logical trim sizes.")
    project=accepted;project.objects[2].parameters["width"]=80;project.objects[3].parameters["width"]=80
    try project.validateSheetAssemblies()
    XCTAssertEqual(try project.resolvedSheetAssembly(project.objects.first{$0.id==id}!).leaves[1].size.x,80)
  }
  func testMixedTrimKeepsArtworkOnEveryExposedLargerLeafRatherThanOnlyStackExtremes()throws {
    var (project,publication)=try fixture(count:6)
    let sizes:[Point2]=[.init(100,80),.init(80,100),.init(90,90)]
    for index in 0..<6 {
      project.objects[index].parameters["width"]=sizes[index/2].x
      project.objects[index].parameters["depth"]=sizes[index/2].y
    }
    let id=try SheetAssemblyCommands.create(in:&project,definition:.init(publicationID:publication))
    var object=project.objects.first{$0.id==id}!
    let closed=try project.resolvedSheetAssembly(object)
    XCTAssertTrue(closed.leaves.allSatisfy(\.frontVisible),
      "The third rectangle has an exposed corner despite the preceding leaves' larger separate max dimensions.")
    object.sheetAssembly!.openingDegrees=180;object.sheetAssembly!.activeSpread=3
    let turned=try project.resolvedSheetAssembly(object)
    XCTAssertTrue(turned.leaves.allSatisfy(\.frontVisible))
    XCTAssertTrue(turned.leaves.allSatisfy(\.backVisible))
    XCTAssertEqual(project.objects[0].parameters["width"],100)
  }
  func testBentEqualTrimLeavesKeepPrintedTailsWithBoundedSamplingPriorityAndFlatBehavior()throws {
    var (project,publication)=try fixture(count:64)
    for index in project.objects.indices {project.objects[index].parameters["width"]=40;project.objects[index].parameters["depth"]=60}
    var definition=SheetAssemblyDefinition(publicationID:publication,stock:.init(thicknessMM:0.4),
      openingDegrees:180,activeSpread:0,bendMM:20)
    let id=try SheetAssemblyCommands.create(in:&project,definition:definition),sources=Array(project.objects.prefix(64))
    let curved=try project.resolvedSheetAssembly(project.objects.first{$0.id==id}!)
    XCTAssertEqual(curved.leaves.count,32)
    XCTAssertTrue(curved.leaves.allSatisfy{$0.frontVisible && $0.backVisible})
    XCTAssertTrue(curved.leaves.allSatisfy{$0.frontSamplingWeight>0 && $0.frontSamplingWeight<=1 && $0.backSamplingWeight>0 && $0.backSamplingWeight<=1})
    XCTAssertEqual(curved.leaves.first!.frontSamplingWeight,1)
    XCTAssertEqual(curved.leaves.last!.backSamplingWeight,1)
    XCTAssertLessThan(curved.leaves[30].backSamplingWeight,1)
    // The inner leaf ends at a greater angle than the next outer leaf. Its
    // back cap therefore has a real tail beyond the outer leaf's end plane.
    var low=0.0,high=Double.pi/2
    for _ in 0..<40 {let a=(low+high)/2;if 40*(1-cos(a))/a<20 {low=a}else{high=a}}
    let radius=40/((low+high)/2)
    let inner=curved.leaves[30],outer=curved.leaves[31]
    let innerAngle=40/(radius-inner.stackOffsetMM),outerAngle=40/(radius-outer.stackOffsetMM)
    XCTAssertGreaterThan(innerAngle,outerAngle)
    XCTAssertGreaterThan(inner.size.x-(radius-inner.stackOffsetMM)*outerAngle,0.4)
    definition.bendMM=0
    try SheetAssemblyCommands.configure(in:&project,objectID:id,definition:definition)
    let flat=try project.resolvedSheetAssembly(project.objects.first{$0.id==id}!)
    XCTAssertEqual(flat.leaves.filter(\.frontVisible).count,1)
    XCTAssertEqual(flat.leaves.filter(\.backVisible).count,1)
    XCTAssertEqual(flat.leaves[30].backSamplingWeight,0)
    definition.bendMM=20;definition.stock.profile = .init(opacity:0.4)
    try SheetAssemblyCommands.configure(in:&project,objectID:id,definition:definition)
    let translucent=try project.resolvedSheetAssembly(project.objects.first{$0.id==id}!)
    XCTAssertTrue(translucent.leaves.allSatisfy{$0.frontSamplingWeight==1 && $0.backSamplingWeight==1})
    XCTAssertEqual(Array(project.objects.prefix(64)),sources)
  }
  func testTransparentFrontPlyRetainsUnderlyingPrintingAndResolvesFaceSpecificOpacity()throws {
    var (project,publication)=try fixture(),pages=project.publications![0].pages
    let translucent=PaperStock(thicknessMM:0.2,plies:[
      .init(name:"Opaque back",color:"#FFFFFF",thicknessMM:0.1,profile:.init(opacity:1)),
      .init(name:"Translucent front",color:"#FFFFFF",thicknessMM:0.1,profile:.init(opacity:0.4))])
    let leaves:[SheetAssemblyLeaf]=[.init(frontPageID:pages[0].id,backPageID:pages[1].id,stock:translucent),
      .init(frontPageID:pages[2].id,backPageID:pages[3].id)]
    let id=try SheetAssemblyCommands.create(in:&project,definition:.init(publicationID:publication,leaves:leaves))
    let result=try project.resolvedSheetAssembly(project.objects.first{$0.id==id}!)
    XCTAssertTrue(result.leaves[1].frontVisible,"A transparent covering face cannot erase underlying artwork.")
    XCTAssertEqual(translucent.sheetFaceOpacity(inside:false),0.4)
    XCTAssertEqual(translucent.sheetFaceOpacity(inside:true),1)
  }
  func testPaperInsideCropUsesItsOwnCanonicalBleedRatherThanOutsideBleed()throws {
    var (project,publication)=try fixture()
    var source=try project.makeObject(recipeID:"paperEnvelope")
    source.paperConstruction=try PaperConstruction.definition(for:source)
    source.paperConstruction!.insideArtwork=Artwork(background:"#FFFFFF",elements:[],bleed:8)
    source.artwork=Artwork(background:"#FFFFFF",elements:[],bleed:1)
    project.objects.append(source)
    let plane=SheetAssemblyPlane(id:"selected-face",name:"Selected canonical face",size:.init("width","height"),
      front:.init(sourceObjectID:source.id,sourceSide:.inside,sourceOriginMM:.init(-6,0)))
    let id=try SheetAssemblyCommands.create(in:&project,definition:.init(publicationID:publication,enclosure:[plane]))
    XCTAssertEqual(try project.resolvedSheetAssembly(project.objects.first{$0.id==id}!).enclosure[0].front?.originMM.x,-6)
    let accepted=project
    var definition=project.objects.first{$0.id==id}!.sheetAssembly!
    definition.enclosure![0].front!.sourceSide = .outside
    XCTAssertThrowsError(try SheetAssemblyCommands.configure(in:&project,objectID:id,definition:definition))
    XCTAssertEqual(project,accepted)
  }
  func testCoverWrapCropsSharePhysicalSourceAndSpineWidthFollowsRealStock()throws {
    var (project,publication)=try fixture()
    let body=PaperStock(thicknessMM:0.12),spine=0.24
    var wrap=try project.makeObject(recipeID:"artboard",name:"One continuous cover",parameters:["width":200+spine,"depth":140])
    wrap.artwork=Artwork(elements:[.init(kind:"text",x:110,y:20,width:80,height:20,text:"Front / original",fontSize:18)])
    project.objects.append(wrap)
    let front=SheetAssemblyPlane(id:"front",name:"Front plane",size:.init("width","height"),
      front:.init(sourceObjectID:wrap.id,sourceOriginMM:.init("width+stackThickness",0)))
    let middle=SheetAssemblyPlane(id:"middle",name:"Narrow bound plane",size:.init("stackThickness","height"),
      front:.init(sourceObjectID:wrap.id,sourceOriginMM:.init("width",0)))
    let back=SheetAssemblyPlane(id:"back",name:"Back plane",size:.init("width","height"),front:.init(sourceObjectID:wrap.id))
    let id=try SheetAssemblyCommands.create(in:&project,definition:.init(publicationID:publication,stock:body,enclosure:[front,middle,back]))
    let resolved=try project.resolvedSheetAssembly(project.objects.first{$0.id==id}!)
    XCTAssertEqual(resolved.enclosure.map{ $0.front!.sourceObjectID },[wrap.id,wrap.id,wrap.id])
    XCTAssertEqual(resolved.enclosure[0].front!.originMM.x,100.24,accuracy:1e-10)
    XCTAssertEqual(resolved.enclosure[1].size.x,spine,accuracy:1e-10)
    XCTAssertEqual(project.objects.first{$0.id==wrap.id},wrap)
    var bad=project.objects.first{$0.id==id}!.sheetAssembly!;bad.enclosure![0].front!.sourceOriginMM = .init(150,0)
    let before=project
    XCTAssertThrowsError(try SheetAssemblyCommands.configure(in:&project,objectID:id,definition:bad));XCTAssertEqual(project,before)
    bad=project.objects.first{$0.id==id}!.sheetAssembly!;bad.enclosure![0].front!.sourceObjectID=id
    XCTAssertThrowsError(try SheetAssemblyCommands.configure(in:&project,objectID:id,definition:bad));XCTAssertEqual(project,before)
  }
}
