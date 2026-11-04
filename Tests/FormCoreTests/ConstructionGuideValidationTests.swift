import Foundation
import FormCADModel
import XCTest
@testable import FormCore

final class ConstructionGuideValidationTests:XCTestCase {
  private func source()->PlanarConstructionDefinition {
    .init(name:"Independent retained guide source",parameters:[.init("showAlternative",0,0...1,unit:""),.init("guideInset",2,0...10,unit:"mm")],size:.init(100,60),stockThickness:1,panels:[
      .init(id:"main",name:"Main sheet",polygon:[.init(0,0),.init(30,0),.init(30,20),.init(0,20)]),
      .init(id:"alternative",name:"Retained alternative",polygon:[.init(50,5),.init(90,5),.init(90,35),.init(50,35)])],rootPanelID:"main",derived:["guideEnd":"40-guideInset"],components:[
        .init(id:"main-piece",name:"Main",rootPanelID:"main",anchor:.init(0,0)),
        .init(id:"saved-piece",name:"Saved alternate",rootPanelID:"alternative",anchor:.init(50,5),enabled:"showAlternative")],production:.init(guides:[
          .init(id:"local-guide",componentID:"saved-piece",role:.seam,points:[.init("guideInset",10),.init("guideEnd",10)])]))
  }
  func testCandidateValidationRejectsUnknownNonfiniteAndOutOfPieceGuideCoordinates()throws {
    let accepted=source(),saved=accepted
    XCTAssertNoThrow(try accepted.net())
    for (coordinate,message) in [(CADScalar("missingAlias"),"invalid coordinate"),(.init("1/0"),"invalid coordinate"),(.init("sqrt(-1)"),"invalid coordinate"),(.init(-0.01),"outside"),(.init(40.01),"outside")] {
      var candidate=accepted;candidate.production!.guides[0].points[0].x=coordinate
      XCTAssertThrowsError(try candidate.net()) {error in
        XCTAssertTrue(error.localizedDescription.contains("local-guide"));XCTAssertTrue(error.localizedDescription.contains(message),error.localizedDescription)
      }
    }
    var vertical=accepted;vertical.production!.guides[0].points[1].y=30.01
    XCTAssertThrowsError(try vertical.net()) {XCTAssertTrue($0.localizedDescription.contains("outside"))}
    XCTAssertEqual(accepted,saved,"Rejected candidates cannot rewrite the accepted source or retained alternative.")
  }
  func testDisabledAlternativeKeepsValidLocalGuidesAndUsesSamePredicateWhenEnabled()throws {
    var definition=source();let guide=definition.production!.guides[0]
    let context=try PlanarAssemblySourceContext(definition)
    XCTAssertFalse(context.enabledIDs.contains("saved-piece"));XCTAssertEqual(context.bounds["saved-piece"],.init(x:50,y:5,width:40,height:30))
    XCTAssertNoThrow(try definition.production!.validate(in:definition,context:context))
    XCTAssertEqual(try guide.resolvedPoints(values:context.values,bounds:XCTUnwrap(context.bounds["saved-piece"])),[.init(2,10),.init(38,10)])
    definition.parameters[0].value=1
    XCTAssertNoThrow(try definition.net());XCTAssertEqual(definition.production!.guides[0],guide)
    var paper=PaperConstruction(kind:.authored,dimensions:.init(width:100,height:60,depth:1),stock:.init(thicknessMM:1));paper.authored=definition
    let resolved=try XCTUnwrap(ConstructionPieces.resolve(paper).first{$0.id=="saved-piece"})
    XCTAssertEqual(resolved.guides.first{$0.id==guide.id}?.points,[.init(2,10),.init(38,10)])
  }
}
