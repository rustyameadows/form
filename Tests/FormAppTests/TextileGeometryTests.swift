import AppKit
import FormGeometry
import Metal
import XCTest
@testable import FormApp
@testable import FormCore

@MainActor final class TextileGeometryTests:XCTestCase {
  func testFlightStudyProducesANativeRenderedPreview() async throws {
    _=NSApplication.shared
    guard MTLCreateSystemDefaultDevice() != nil else {throw XCTSkip("Native textile preview needs Metal.")}
    let p=Samples.flightJacket(),garment=p.objects[0]
    let ids=Set([garment.id]+p.objects.filter{$0.textile?.attachment?.garmentID==garment.id}.map(\.id))
    let controller=TableSceneController()
    controller.sync(p,selection:[],isolated:ids,showGrid:false,studio:true,preset:"Daylight",assets:FileManager.default.temporaryDirectory)
    controller.camera = .init();controller.camera.target = .init(garment.position.x/100,0.3,0)
    controller.camera.azimuth=0.04;controller.camera.elevation=1.18;controller.camera.distance=25
    controller.updateCamera()
    let image=try await controller.snapshot(size:.init(width:1600,height:1200))
    let png=try XCTUnwrap(image.pngData());XCTAssertGreaterThan(png.count,20000)
    if let path=ProcessInfo.processInfo.environment["FORM_TEXTILE_PREVIEW_PATH"] {
      try png.write(to:URL(fileURLWithPath:path))
    }
  }
  func testBomberUsesShapedMeshesAndPhysicalParametersChangeItsBounds() throws {
    _=NSApplication.shared
    let p=Samples.flightJacket(),o=p.objects[0],root=TextileGeometry.bomber(o,project:p)
    let body=try XCTUnwrap(root.childNode(withName:"Shaped nylon body",recursively:true))
    XCTAssertGreaterThan(body.geometry?.sources(for:.vertex).first?.vectorCount ?? 0,2000)
    XCTAssertNotNil(root.childNode(withName:"Left shaped sleeve",recursively:true))
    XCTAssertNotNil(root.childNode(withName:"Right shaped sleeve",recursively:true))
    XCTAssertNotNil(root.childNode(withName:"Rescue-orange neck lining",recursively:true))
    XCTAssertNotNil(root.childNode(withName:"Rib-knit waistband",recursively:true))
    XCTAssertNotNil(root.childNode(withName:"Zipper pull",recursively:true))
    var wider=o;wider.parameters["sleeveLength"]=760
    let large=TextileGeometry.bomber(wider,project:p)
    XCTAssertGreaterThan(large.boundingBox.max.x-large.boundingBox.min.x,root.boundingBox.max.x-root.boundingBox.min.x)
    XCTAssertGreaterThan(root.boundingBox.max.x-root.boundingBox.min.x,10)
  }
  func testAttachedDecorationFollowsScenePlacementWithoutRebuildingGeometry() throws {
    _=NSApplication.shared
    let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:root)}
    let repository=try ProjectRepository(root:root),store=StudioStore(repository:repository,seedLibrary:false)
    var p=Samples.flightJacket();store.engine.project=p
    let scene=TableSceneController(store:store)
    func sync(){scene.sync(p,selection:[],isolated:[],showGrid:false,studio:false,preset:"Daylight",assets:root)}
    sync();let count=scene.geometryBuilds
    let part=p.objects.first{$0.textile?.attachment != nil}!,before=p.textilePlacement(part)
    let node=try XCTUnwrap(scene.objectRoot.childNode(withName:"object:\(part.id.uuidString)",recursively:false))
    XCTAssertEqual(Double(node.position.x)*100,before.position.x,accuracy:1e-4)
    XCTAssertEqual(Double(node.simdWorldUp.x),before.normal.x,accuracy:1e-5)
    XCTAssertEqual(Double(node.simdWorldUp.y),before.normal.y,accuracy:1e-5)
    XCTAssertEqual(Double(node.simdWorldUp.z),before.normal.z,accuracy:1e-5)
    p.objects[0].position.x+=200;store.engine.project=p;sync()
    XCTAssertEqual(Double(node.position.x)*100,before.position.x+200,accuracy:1e-4)
    XCTAssertEqual(scene.geometryBuilds,count)
    let index=p.objects.firstIndex{$0.id==part.id}!
    p.objects[index].textile?.attachment?.offset.x+=15;store.engine.project=p;sync()
    XCTAssertEqual(scene.geometryBuilds,count)
  }
}
