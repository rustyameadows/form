import AppKit
import XCTest
import FormCore
@testable import FormApp

@MainActor final class SheetParentStockEditingTests:XCTestCase {
  func testDuplexControlsEditEffectiveFaceColorsAndTexturesWithoutDiscardingProfiles()throws {
    var stock=PaperStock(thicknessMM:0.3,profile:.init(texture:.smooth,color:"#AAFFFF"))
    let back=PaperPly(name:"Back",color:"#111111",thicknessMM:0.15,profile:.init(texture:.laid,color:"#224466",roughness:0.63))
    let front=PaperPly(name:"Front",color:"#222222",thicknessMM:0.15,profile:.init(texture:.cotton,color:"#668844",roughness:0.91))
    stock.plies=[back,front];let before=stock
    XCTAssertEqual(SheetParentStockEditing.color(of:front),"#668844");XCTAssertNil(SheetParentStockEditing.texture(in:stock))
    SheetParentStockEditing.setColor("#BB3377",plyID:front.id,in:&stock)
    XCTAssertEqual(stock.plies![1].color,"#BB3377");XCTAssertEqual(stock.plies![1].profile?.color,"#BB3377")
    let object=ProductObject(name:"Substrate probe",recipeID:"artboard",parameters:["width":100,"depth":140])
    let project=Project(name:"Effective stock controls")
    XCTAssertEqual(PaperGeometry.faceAppearance(for:object,stock:stock,project:project,inside:false).resolvedColor,"#BB3377")
    XCTAssertEqual(PaperGeometry.faceAppearance(for:object,stock:stock,project:project,inside:true).resolvedColor,"#224466")
    SheetParentStockEditing.setTexture(.recycled,in:&stock)
    XCTAssertEqual(SheetParentStockEditing.texture(in:stock),.recycled)
    XCTAssertEqual(PaperGeometry.faceAppearance(for:object,stock:stock,project:project,inside:false).profile.texture,.recycled)
    XCTAssertEqual(PaperGeometry.faceAppearance(for:object,stock:stock,project:project,inside:true).profile.texture,.recycled)
    XCTAssertEqual(stock.plies![0].profile?.roughness,0.63);XCTAssertEqual(stock.plies![1].profile?.roughness,0.91)
    XCTAssertEqual(stock.plies![0].profile?.color,before.plies![0].profile?.color)
    XCTAssertEqual(stock.resolvedThicknessMM,before.resolvedThicknessMM);try stock.validate()
  }
  func testPlyWithoutProfileInheritsTextureAndKeepsEditableCutEdgeColor()throws {
    var stock=PaperStock(thicknessMM:0.2)
    let ply=PaperPly(name:"One face",color:"#DDD0B4",thicknessMM:0.2);stock.plies=[ply]
    SheetParentStockEditing.setColor("#773311",plyID:ply.id,in:&stock)
    XCTAssertNil(stock.plies![0].profile);XCTAssertEqual(SheetParentStockEditing.color(of:stock.plies![0]),"#773311")
    SheetParentStockEditing.setTexture(.linen,in:&stock)
    XCTAssertNil(stock.plies![0].profile);XCTAssertEqual(stock.profile?.texture,.linen)
    XCTAssertEqual(SheetParentStockEditing.texture(in:stock),.linen);try stock.validate()
  }
}
