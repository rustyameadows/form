import CoreGraphics
import XCTest
@testable import FormCore

final class PaperPrintGeometryTests: XCTestCase {
  private func net() -> PaperNet {
    var panel=PaperPanel(id:"sheet",name:"Sheet",role:.body,polygon:[.init(0,0),.init(10,0),.init(10,10),.init(0,10)])
    panel.cutouts=[.init(id:"window",polygon:[.init(3,3),.init(7,3),.init(7,7),.init(3,7)],kind:.window)]
    return .init(size:.init(10,10),panels:[panel],folds:[],joins:[],cutEdges:[],rootPanelID:"sheet")
  }
  private func contains(_ contours:[[Point2]],_ point:CGPoint)->Bool {
    let path=CGMutablePath()
    for contour in contours {guard let first=contour.first else{continue};path.move(to:.init(x:first.x,y:first.y));for p in contour.dropFirst(){path.addLine(to:.init(x:p.x,y:p.y))};path.closeSubpath()}
    return path.contains(point,using:.evenOdd)
  }
  func testBleedExpandsActualOuterCutAndContractsWindowWithCommonPhysicalCoordinates()throws {
    let source=net(),original=try PaperPrintGeometry.bleedContours(source,millimeters:0)
    XCTAssertTrue(contains(original,.init(x:1,y:5)));XCTAssertFalse(contains(original,.init(x:5,y:5)))
    let expanded=try PaperPrintGeometry.bleedContours(source,millimeters:0.5)
    XCTAssertTrue(contains(expanded,.init(x:-0.25,y:5)))
    XCTAssertTrue(contains(expanded,.init(x:3.25,y:5)),"Print bleeds into the future cutout")
    XCTAssertFalse(contains(expanded,.init(x:5,y:5)),"The remaining cutout cannot become printed stock")
    XCTAssertEqual(expanded.flatMap{$0}.map(\.x).min()!,-0.5,accuracy:0.002)
    XCTAssertEqual(source,net(),"Offset generation cannot edit the canonical construction")
    XCTAssertThrowsError(try PaperPrintGeometry.bleedContours(source,millimeters:26))
  }
  func testTemplateReviewTracksPhysicalRegistrationRatherThanInkOrOpenPose()throws {
    var d=PaperConstruction(kind:.envelope,dimensions:.init(width:100,height:150,depth:4))
    let before=try PaperTemplateReference.geometryRevision(d)
    d.openingPercent=100;d.foldPercent=20;d.stock.profile = .init(texture:.cotton,color:"#EEEEEE")
    d.annotations=[.init(text:"Prototype fit feedback")]
    XCTAssertEqual(try PaperTemplateReference.geometryRevision(d),before)
    d.dimensions.width+=5
    XCTAssertNotEqual(try PaperTemplateReference.geometryRevision(d),before)
  }
  func testRegisteredViewportContainsTheWholeTransformedBleedOrRefusesIt() {
    var reference=PaperTemplateReference(originalAsset:"paper-template-"+String(repeating:"a",count:64)+".svg",originalSHA256:String(repeating:"a",count:64),sourceName:"trim.svg",instructions:"Actual size",sizeMM:.init(10,10),viewBox:.init(x:0,y:0,width:10,height:10),channels:[.init(elementID:"cut",kind:.cut)],interpretedGeometrySHA256:"")
    XCTAssertTrue(reference.containsPrintBounds(netSize:.init(10,10),bleedMM:0))
    XCTAssertFalse(reference.containsPrintBounds(netSize:.init(10,10),bleedMM:3))
    reference.viewBox = .init(x:-3,y:-3,width:16,height:16)
    XCTAssertTrue(reference.containsPrintBounds(netSize:.init(10,10),bleedMM:3))
    reference.canonicalToTemplate = .init(a:2,b:0,c:0,d:2,tx:0,ty:0)
    XCTAssertFalse(reference.containsPrintBounds(netSize:.init(10,10),bleedMM:0))
  }

}
