import XCTest
import FormCore
import FormGeometry
@testable import FormApp

final class SolidWorkerTests:XCTestCase {
  private func definition()->ParametricSolid {
    .init(normalizeHeight:"40",nodes:[.init(kind:"sweep",sweep:.init(samples:"24",variable:"u",values:["x":"sin(pi*u)","y":"40*u","z":"0","radiusX":"3","radiusY":"1"],sides:24))],previewNodes:[.init(kind:"sweep",sweep:.init(samples:"4",variable:"u",values:["x":"sin(pi*u)","y":"40*u","z":"0","radiusX":"3","radiusY":"1"],sides:6))])
  }
  func testDetachedWorkerBuildsSeparatePreviewWithoutReplacingFullSource()async throws {
    let source=definition()
    let result=try await Task.detached{(try SolidSurfaceBuilder.build(source,parameters:[:]),try SolidSurfaceBuilder.build(source,parameters:[:],useEditingPreview:true))}.value
    XCTAssertFalse(result.0.isEditingPreview);XCTAssertTrue(result.1.isEditingPreview)
    XCTAssertLessThan(result.1.indices.count,result.0.indices.count/10)
    XCTAssertEqual(source.nodes[0].sweep?.samples,"24")
    for mesh in [result.0,result.1] {
      XCTAssertEqual(mesh.displayChunks.reduce(0){$0+$1.indices.count},mesh.indices.count)
      XCTAssertTrue(mesh.displayChunks.allSatisfy{$0.positions.count==$0.normals.count})
      XCTAssertEqual(mesh.positions.map(\.y).max()!,40,accuracy:1e-8)
    }
  }
  @MainActor func testFullAndPreviewCachesCannotCollide()throws {
    let source=definition(),preview=try SolidSurfaceBuilder.build(source,parameters:[:],useEditingPreview:true)
    try SolidRecipeGeometry.remember(preview,definition:source,parameters:[:])
    XCTAssertTrue(try XCTUnwrap(SolidRecipeGeometry.cachedSurface(source,parameters:[:],useEditingPreview:true)).isEditingPreview)
    let full=try SolidRecipeGeometry.surface(source,parameters:[:])
    XCTAssertGreaterThan(full.indices.count,preview.indices.count*10)
    XCTAssertFalse(try XCTUnwrap(SolidRecipeGeometry.cachedSurface(source,parameters:[:])).isEditingPreview)
  }
  func testCancelledWorkerDoesNotReturnAPartialSurface()async throws {
    let source=definition()
    let work=Task.detached{withUnsafeCurrentTask{$0?.cancel()};return try SolidSurfaceBuilder.build(source,parameters:[:])}
    do{_ = try await work.value;XCTFail("Cancelled work must not publish geometry.")}catch{XCTAssertTrue(error is CancellationError)}
  }
}
