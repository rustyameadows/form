import Foundation
import FormCore
import XCTest
@testable import FormApp

final class ObjectViewExportGuardTests: XCTestCase {
  func testOnlySelectedPendingLinkedOutputIsBlocked() throws {
    let source=ProductObject(name:"Source",recipeID:"test",parameters:[:])
    var pending=ArtworkElement(kind:"image",x:0,y:0,asset:"pending.png")
    pending.objectView = .init(sourceID:source.id,style:"rendered",linked:true)
    pending.objectView?.renderPending=true
    var frozen=pending; frozen.id=UUID(); frozen.objectView?.linked=false
    let other=ArtworkElement(kind:"rectangle",x:0,y:0)
    let page=ProductObject(name:"Page",recipeID:"artboard",parameters:[:],artwork:Artwork(elements:[pending,frozen,other]))
    var project=Project(name:"Pending");project.objects=[source,page]
    XCTAssertThrowsError(try ObjectViewExportGuard.validate(project:project,object:page))
    XCTAssertThrowsError(try ObjectViewExportGuard.validate(project:project,object:page,elementIDs:[pending.id.uuidString]))
    XCTAssertNoThrow(try ObjectViewExportGuard.validate(project:project,object:page,elementIDs:[frozen.id.uuidString]))
    XCTAssertNoThrow(try ObjectViewExportGuard.validate(project:project,object:page,elementIDs:[other.id.uuidString]))
  }
}
