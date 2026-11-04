import AppKit
import FormCore
import XCTest
@testable import FormApp

@MainActor final class SheetBondedStockEditingTests:XCTestCase {
  func testBackingIsPhysicalAndRetainsOriginalFaceProfile()throws {
    var stock=PaperStock(name:"Woven face",thicknessMM:0.35,profile:.init(texture:.linen,color:"#173D4F",roughness:0.91))
    let before=stock
    try SheetStockControlEditing.addPly(front:false,in:&stock)
    XCTAssertEqual(stock.plies?.count,2);XCTAssertEqual(stock.resolvedThicknessMM,0.45,accuracy:1e-9)
    let face=try XCTUnwrap(stock.plies?.last)
    XCTAssertEqual(face.profile,before.profile);XCTAssertEqual(face.thicknessMM,before.thicknessMM)
    let object=ProductObject(name:"Material probe",recipeID:"artboard",parameters:["width":100,"depth":100]),project=Project(name:"Layer review")
    XCTAssertEqual(PaperGeometry.faceAppearance(for:object,stock:stock,project:project,inside:false).resolvedColor,"#173D4F")
    XCTAssertEqual(PaperGeometry.faceAppearance(for:object,stock:stock,project:project,inside:false).profile.texture,.linen)
    try stock.validate()
    let backing=try XCTUnwrap(stock.plies?.first)
    SheetStockControlEditing.removePly(backing.id,in:&stock)
    XCTAssertEqual(stock.plies?.first?.id,face.id);XCTAssertEqual(stock.resolvedThicknessMM,0.35,accuracy:1e-9)
  }
  func testLayerEditsAndReorderingKeepStableIdentitiesAndEffectiveFaces()throws {
    var stock=PaperStock(thicknessMM:0.6)
    stock.plies=[.init(name:"Back",color:"#102030",thicknessMM:0.2),.init(name:"Face",color:"#BBAA77",thicknessMM:0.4)]
    let ids=try XCTUnwrap(stock.plies?.map(\.id)),untouched=try XCTUnwrap(stock.plies?.last)
    SheetStockControlEditing.editPly(ids[0],in:&stock){$0.thicknessMM=0.3;$0.profile = .init(texture:.cotton,color:"#224466")}
    XCTAssertEqual(stock.plies?.last,untouched);XCTAssertEqual(stock.thicknessMM,0.7,accuracy:1e-9)
    SheetStockControlEditing.movePly(ids[0],towardFront:true,in:&stock)
    XCTAssertEqual(stock.plies?.map(\.id),ids.reversed().map{$0})
    let object=ProductObject(name:"Layer probe",recipeID:"artboard",parameters:[:])
    XCTAssertEqual(PaperGeometry.faceAppearance(for:object,stock:stock,project:Project(name:"Review"),inside:false).resolvedColor,"#224466")
    let accepted=stock
    SheetStockControlEditing.editPly(UUID(),in:&stock){$0.thicknessMM=10}
    SheetStockControlEditing.removePly(UUID(),in:&stock)
    XCTAssertEqual(stock,accepted);try stock.validate()
  }
  func testInvalidAdditionalBackingIsAtomic()throws {
    var stock=PaperStock(thicknessMM:20),before=stock
    XCTAssertThrowsError(try SheetStockControlEditing.addPly(front:false,in:&stock));XCTAssertEqual(stock,before)
    stock=PaperStock(thicknessMM:0.16);stock.plies=(0..<16).map{.init(name:"Layer \($0)",color:"#FFFFFF",thicknessMM:0.01)};before=stock
    XCTAssertThrowsError(try SheetStockControlEditing.addPly(front:true,in:&stock));XCTAssertEqual(stock,before)
  }
  func testDetailEditPreservesPlyColorWhenInheritingDifferentlyColoredStock()throws {
    var stock=PaperStock(thicknessMM:0.3,profile:.init(texture:.linen,color:"#123456",roughness:0.8))
    let ply=PaperPly(name:"Contrasting layer",color:"#DDBB88",thicknessMM:0.3);stock.plies=[ply]
    SheetStockControlEditing.editPlySurface(ply.id,in:&stock){$0.roughness=0.6}
    XCTAssertEqual(stock.plies?.first?.profile?.color,ply.color);XCTAssertEqual(stock.plies?.first?.profile?.texture,.linen)
    XCTAssertEqual(stock.plies?.first?.profile?.roughness,0.6);XCTAssertEqual(stock.resolvedThicknessMM,0.3,accuracy:1e-9)
    try stock.validate()
  }
}
