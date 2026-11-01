import Foundation
import XCTest
import CFormMesher
import FormGeometry

final class OrganicCancellationTests:XCTestCase {
  private final class Probe {
    let lock=NSLock()
    var visits=0
    func check()->Int32 {lock.lock();defer{lock.unlock()};visits+=1;return visits>=32 ? 1:0}
  }
  func testNativeMesherStopsInsideParallelFieldSamplingWithoutPartialBuffers()throws {
    var shape=FMOrganicShape(cx:0,cy:0,cz:0,ux:1,uy:0,uz:0,vx:0,vy:1,vz:0,wx:0,wy:0,wz:1,rx:8,ry:8,rz:8,length:0,blend:0,end_aspect:1,kind:0)
    let probe=Probe();var output=FMOrganicMesh()
    let result=fm_organic_mesh_cancellable(&shape,1,0.15,0,0,0,{raw in
      guard let raw else{return 0}
      return Unmanaged<Probe>.fromOpaque(raw).takeUnretainedValue().check()
    },Unmanaged.passUnretained(probe).toOpaque(),&output)
    defer{fm_free_organic_mesh(&output)}
    XCTAssertEqual(result,-4);XCTAssertGreaterThanOrEqual(probe.visits,32)
    XCTAssertNil(output.xyz);XCTAssertNil(output.indices);XCTAssertEqual(output.vertex_count,0);XCTAssertEqual(output.index_count,0)
  }
  func testOldAndUncancelledEntryPointsProduceIdenticalBuffers()throws {
    var shape=FMOrganicShape(cx:0,cy:0,cz:0,ux:1,uy:0,uz:0,vx:0,vy:1,vz:0,wx:0,wy:0,wz:1,rx:3,ry:4,rz:2,length:0,blend:0,end_aspect:1,kind:0)
    var original=FMOrganicMesh(),cancellable=FMOrganicMesh()
    defer{fm_free_organic_mesh(&original);fm_free_organic_mesh(&cancellable)}
    XCTAssertEqual(fm_organic_mesh(&shape,1,0.4,0,0,0,&original),0)
    XCTAssertEqual(fm_organic_mesh_cancellable(&shape,1,0.4,0,0,0,{_ in 0},nil,&cancellable),0)
    XCTAssertEqual(original.vertex_count,cancellable.vertex_count);XCTAssertEqual(original.index_count,cancellable.index_count)
    XCTAssertEqual(Array(UnsafeBufferPointer(start:original.xyz,count:original.vertex_count*3)),Array(UnsafeBufferPointer(start:cancellable.xyz,count:cancellable.vertex_count*3)))
    XCTAssertEqual(Array(UnsafeBufferPointer(start:original.indices,count:original.index_count)),Array(UnsafeBufferPointer(start:cancellable.indices,count:cancellable.index_count)))
  }
  func testSwiftTokenCancelsBeforeNativeConstruction()throws {
    var source=OrganicSolid();source.ellipsoid(.zero,radii:.init(repeating:4))
    let token=OrganicMeshCancellation();token.cancel()
    XCTAssertThrowsError(try source.mesh(spacing:0.4,cancellation:token)){XCTAssertTrue($0 is CancellationError)}
  }
}
