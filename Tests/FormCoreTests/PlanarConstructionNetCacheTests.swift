import Foundation
import FormCADModel
import XCTest
@testable import FormCore

final class PlanarConstructionNetCacheTests:XCTestCase {
  private func source()->PlanarConstructionDefinition {
    .init(name:"Independent source "+UUID().uuidString,
      parameters:[.init("span",20,10...40,unit:"mm")],size:.init(80,40),stockThickness:1.2,
      panels:[.init(id:"plate",name:"Plate",polygon:[.init(0,0),.init("span",0),.init("span",12),.init(0,12)])],rootPanelID:"plate",
      components:[.init(id:"piece",name:"Piece",rootPanelID:"plate",anchor:.init(0,12),groupID:"frame",
        stock:.init(name:"Fiber",thicknessMM:1.2,grain:.parallelWidth,profile:.init(texture:.laid,color:"#AABBCC")),
        front:.init(sourceObjectID:UUID(),sourceOriginMM:.init(2,3)),enabled:1)],
      groups:[.init(id:"frame",name:"Frame",position:.init("opening/2","explosion/4",0))],
      production:.init(assumptions:["Retain the declared physical stock."],processNotes:"Nominal source geometry."))
  }
  private func resolve(_ source:PlanarConstructionDefinition,in cache:PlanarConstructionNetCache)throws->PaperNet {
    try cache.resolve(source){try source.uncachedNet()}
  }
  func testIdenticalCompleteSourceReusesSuccessfulValueAndChangedGeometryResolvesAgain()throws {
    let cache=PlanarConstructionNetCache(),original=source(),first=try resolve(original,in:cache)
    XCTAssertEqual(try resolve(original,in:cache),first)
    XCTAssertEqual(cache.usage.hits,1);XCTAssertEqual(cache.usage.solves,1)
    var changed=original;try changed.setParameters(["span":32])
    XCTAssertEqual(try resolve(changed,in:cache).panels[0].bounds.width,32)
    XCTAssertEqual(try resolve(original,in:cache).panels[0].bounds.width,20)
    XCTAssertEqual(cache.usage.solves,2);XCTAssertEqual(cache.usage.hits,2)
    XCTAssertEqual(cache.usage.maximumEntries,64)
    XCTAssertEqual(cache.usage.maximumCostBytes,16*1024*1024)
  }
  func testWarmCacheDoesNotAcceptChangedInvalidRequirementsStockEnabledOrFaceMetadata()throws {
    let cache=PlanarConstructionNetCache(),original=source();_=try resolve(original,in:cache)
    var bad=original
    bad.requirements=[.init(id:"reject",lhs:"span",relation:.lessThan,rhs:1,message:"The source exceeds its declared limit.")]
    XCTAssertThrowsError(try resolve(bad,in:cache)) {XCTAssertEqual(($0 as? CADRequirementFailure)?.requirementID,"reject")}
    bad=original;bad.components![0].stock!.name=""
    XCTAssertThrowsError(try resolve(bad,in:cache))
    bad=original;bad.components![0].enabled=0
    XCTAssertThrowsError(try resolve(bad,in:cache))
    bad=original;bad.components![0].front!.sourceOriginMM = .init(100001,0)
    XCTAssertThrowsError(try resolve(bad,in:cache))
    bad=original;bad.controls = .init(parameters:[.init(parameter:"missing",label:"Missing")])
    XCTAssertThrowsError(try resolve(bad,in:cache))
    XCTAssertEqual(cache.usage.failedSolves,5)
    XCTAssertEqual(try resolve(original,in:cache).panels.count,1)
    XCTAssertEqual(cache.usage.hits,1)
  }
  func testCompleteProductionMetadataParticipatesInKeyEvenWhenGeometryIsIdentical()throws {
    let cache=PlanarConstructionNetCache(),original=source(),first=try resolve(original,in:cache)
    var changed=original;changed.production!.processNotes="A different declared process."
    XCTAssertEqual(try resolve(changed,in:cache),first)
    XCTAssertEqual(cache.usage.solves,2)
    changed.production!.assumptions=[""]
    XCTAssertThrowsError(try resolve(changed,in:cache))
    XCTAssertEqual(cache.usage.failedSolves,1)
    // A failure is never retained: the same invalid source is solved again.
    XCTAssertThrowsError(try resolve(changed,in:cache))
    XCTAssertEqual(cache.usage.failedSolves,2);XCTAssertEqual(cache.usage.hits,0)
  }
  func testReturnedNetHasIndependentNestedValueStorage()throws {
    let original=source(),baseline=try original.net()
    var edited=try original.net()
    edited.panels[0].polygon[0].x=700
    edited.panels[0].stock?.profile?.color="#FFFFFF"
    edited.panels[0].front?.originMM.x=800
    edited.panels.removeLast()
    XCTAssertEqual(try original.net(),baseline)
    XCTAssertEqual(try original.net().panels[0].stock?.profile?.color,"#AABBCC")
  }
  func testConcurrentMissesAndHitsReturnIdenticalValues()async throws {
    let cache=PlanarConstructionNetCache(),definition=source(),expected=try definition.uncachedNet()
    let results=try await withThrowingTaskGroup(of:PaperNet.self,returning:[PaperNet].self) {group in
      for _ in 0..<24 {group.addTask {try cache.resolve(definition){try definition.uncachedNet()}}}
      var values=[PaperNet]();for try await value in group{values.append(value)};return values
    }
    XCTAssertEqual(results.count,24);XCTAssertTrue(results.allSatisfy{$0==expected})
    XCTAssertEqual(try resolve(definition,in:cache),expected)
    XCTAssertGreaterThan(cache.usage.hits,0);XCTAssertEqual(cache.usage.failedSolves,0)
  }
  func testNestedFeatureValidationRemainsReentrant()throws {
    var definition=source()
    definition.panels[0].features = .init(recesses:[.init(id:"pocket",origin:.init(4,3),size:.init(8,5),depthMM:0.2)])
    let first=try definition.net()
    XCTAssertEqual(first.panels[0].features?.recesses?.first?.id,"pocket")
    XCTAssertEqual(try definition.net(),first)
  }
  func testInvalidEncodingAndOversizedCollectionsKeepOriginalValidationErrors()throws {
    let cache=PlanarConstructionNetCache();var invalid=source();invalid.parameters[0].value = .nan
    var expected="";do{_=try invalid.uncachedNet();XCTFail("Expected invalid nonfinite parameter.")}catch{expected=error.localizedDescription}
    XCTAssertThrowsError(try resolve(invalid,in:cache)){XCTAssertEqual($0.localizedDescription,expected)}
    XCTAssertEqual(cache.usage.bypasses,1);XCTAssertEqual(cache.usage.failedSolves,1)
    invalid=source();invalid.panels += Array(repeating:invalid.panels[0],count:256)
    XCTAssertThrowsError(try resolve(invalid,in:cache))
    XCTAssertEqual(cache.usage.bypasses,2);XCTAssertEqual(cache.usage.failedSolves,2)
    cache.reset();XCTAssertEqual(cache.usage.hits,0);XCTAssertEqual(cache.usage.solves,0)
  }
  func testWarmPureNetDoesNotSkipOwnerStockOrActualJointEngagementValidation()throws {
    let definition=source();_=try definition.net()
    var paper=PaperConstruction(kind:.authored,dimensions:.init(width:20,height:12,depth:1),stock:.init(thicknessMM:2));paper.authored=definition
    XCTAssertThrowsError(try PaperConstructionEngine.validate(paper)) {XCTAssertTrue($0.localizedDescription.contains("stockThickness"))}
    let floor=PlanarPanelDefinition(id:"floor",name:"Entry",polygon:[.init(0,0),.init(40,0),.init(40,40),.init(0,40)])
    let wall=PlanarPanelDefinition(id:"wall",name:"Receiver",polygon:[.init(50,0),.init(70,0),.init(70,10),.init(50,10)])
    let joint=PlanarJoinDefinition(id:"joint",name:"Physical receiving route",firstPanelID:"floor",secondPanelID:"wall",overlapMM:0)
    let short=PlanarStapleDefinition(id:"short",entryPanelID:"floor",receivingPanelID:"wall",anchor:.init(20,20),entrySide:.inside,
      legLengthMM:1,tool:"Declared edge driver",installation:.init(presentComponentIDs:["entry","receiver"]))
    let assembly=PlanarConstructionDefinition(name:"Receiving route "+UUID().uuidString,size:.init(90,50),stockThickness:2,panels:[floor,wall],joins:[joint],rootPanelID:"floor",
      components:[.init(id:"entry",name:"Entry",rootPanelID:"floor",anchor:.init(0,0),position:.init(-20,1,-20),rotationDegrees:.init(-90,0,0)),
        .init(id:"receiver",name:"Receiver",rootPanelID:"wall",anchor:.init(50,10),position:.init(-10,2,0))],
      jointAttachments:[.init(id:"attachment",joinID:"joint",staples:[short])])
    _=try assembly.net();_=try assembly.net()
    XCTAssertThrowsError(try assembly.resolveJointAttachments(stock:.init(thicknessMM:2)))
  }
}
