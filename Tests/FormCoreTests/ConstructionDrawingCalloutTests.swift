import Foundation
import XCTest
@testable import FormCore

final class ConstructionDrawingCalloutTests:XCTestCase {
  private func drawing(_ count:Int)->ConstructionResolvedDrawing {
    let shapes=(0..<count).map {index in
      ConstructionDrawingShape(pieceID:String(format:"piece-%03d",index),panelID:"face-\(index)",color:"#C8C8BB",
        points:[.init(0,0),.init(120,0),.init(120,80),.init(0,80)],closed:true,lineWidthMM:0.1,depth:Double(index))
    }
    return .init(view:.init(id:"exploded",title:"Overlapping source pieces",explosionPercent:100),shapes:shapes,
      bounds:.init(x:0,y:0,width:120,height:80),assembledDimensionsMM:.init(120,80,20),representation:"Nominal reference")
  }
  func testCoincidentPartsGetDisjointNumberGuttersAndCompleteUnclippedSourceLegend()throws {
    let source=drawing(40),layout=ConstructionAssemblyDrawings.calloutLayout(source)
    XCTAssertEqual(layout.callouts.count,40);XCTAssertEqual(layout.legend.count,40)
    XCTAssertEqual(Set(layout.callouts.map(\.pieceID)),Set(source.shapes.map(\.pieceID)))
    XCTAssertEqual(Set(layout.callouts.map(\.number)).count,40)
    for i in layout.callouts.indices {for j in layout.callouts.indices where j>i {
      let a=layout.callouts[i].position,b=layout.callouts[j].position
      XCTAssertGreaterThan(hypot(a.x-b.x,a.y-b.y),layout.radius*2,"Coincident source geometry must not produce overlapping part labels.")
    }}
    for item in layout.legend {
      XCTAssertGreaterThanOrEqual(item.position.x,layout.bounds.x);XCTAssertLessThan(item.position.y+Double(item.lines.count)*layout.fontSize*1.45,layout.bounds.y+layout.bounds.height)
      XCTAssertEqual(item.lines.joined(),item.pieceID)
    }
    let svg=ConstructionAssemblyDrawings.svg(source)
    XCTAssertTrue(svg.contains("data-role=\"part-callouts\""));XCTAssertTrue(svg.contains("data-role=\"part-legend\""));XCTAssertTrue(svg.contains("piece-039"))
    let hidden=ConstructionAssemblyDrawings.svg(source,labels:false)
    XCTAssertFalse(hidden.contains("part-callouts"));XCTAssertFalse(hidden.contains("part-legend"))
    XCTAssertEqual(source.shapes,drawing(40).shapes,"Label placement cannot change accepted physical shapes.")
  }
  func testPaginatedPartKeysKeepGlobalNumberIdentityAndWrapLongIDs()throws {
    var source=drawing(70)
    let id=String(repeating:"long-source-id-",count:8);source.shapes[10].pieceID=id
    let all=ConstructionAssemblyDrawings.calloutLayout(source),subset=Set(source.shapes.prefix(32).map(\.pieceID))
    let page=ConstructionAssemblyDrawings.calloutLayout(source,pieceIDs:subset)
    XCTAssertEqual(page.callouts.count,32)
    let numbers=Dictionary(uniqueKeysWithValues:all.callouts.map{($0.pieceID,$0.number)})
    for value in page.callouts {XCTAssertEqual(value.number,numbers[value.pieceID])}
    let entry=try XCTUnwrap(page.legend.first{$0.pieceID==id});XCTAssertGreaterThan(entry.lines.count,1);XCTAssertEqual(entry.lines.joined(),id)
  }
}
