import Foundation
import XCTest
import FormCore
import FormCADModel
@testable import FormApp

@MainActor final class PlanarIndependentStockSolidTests:XCTestCase {
  func testExactNominalQueriesUseAndReportEachActualPieceCaliperAcrossCases() async throws {
    let a=PlanarPanelDefinition(id:"first",name:"First",polygon:[.init(0,0),.init(20,0),.init(20,20),.init(0,20)])
    let b=PlanarPanelDefinition(id:"second",name:"Second",polygon:[.init(30,0),.init(50,0),.init(50,20),.init(30,20)])
    let definition=PlanarConstructionDefinition(name:"Independent nominal core specimens",parameters:[.init("secondCaliper",4,2...6),.init("gap",1,0...2)],size:.init(60,30),stockThickness:0.5,
      panels:[a,b],rootPanelID:"first",solidChecks:[.init(id:"actual-core-gap",firstPanelID:"first",secondPanelID:"second",metric:.clearance,relation:.equal,value:"gap",message:"Keep the specified nominal core gap",tolerance:1e-6)],components:[
        .init(id:"a",name:"A",rootPanelID:"first",anchor:.init(0,0),position:.init(0,1,0),rotationDegrees:.init(-90,0,0),stock:.init(thicknessMM:2)),
        .init(id:"b",name:"B",rootPanelID:"second",anchor:.init(30,0),position:.init(0,5,0),rotationDegrees:.init(-90,0,0),stock:.init(thicknessMM:4),stockThickness:"secondCaliper")])
    let request=PlanarConstructionValidationRequest(projectID:UUID(),objectID:UUID(),sourceRevision:"independent-stock-source",definition:definition,fold:100,opening:0,cases:[.init(name:"gapped",values:[:]),.init(name:"contact",values:["secondCaliper":6,"gap":0])])
    let result=try await PlanarSolidValidation.run(request)
    XCTAssertTrue(result.passed);XCTAssertEqual(result.cases.count,2)
    let first=try XCTUnwrap(result.cases[0].solidChecks?.first),second=try XCTUnwrap(result.cases[1].solidChecks?.first)
    XCTAssertEqual(first.measured,1,accuracy:1e-6);XCTAssertEqual(second.measured,0,accuracy:1e-6)
    XCTAssertEqual(first.firstStockThicknessMM,2);XCTAssertEqual(first.secondStockThicknessMM,4)
    XCTAssertEqual(second.firstStockThicknessMM,2);XCTAssertEqual(second.secondStockThicknessMM,6)
    XCTAssertEqual(first.stockThicknessMM,0.5,"Legacy nominal source field is retained; pair-specific actual calipers are explicit.")
  }
}
