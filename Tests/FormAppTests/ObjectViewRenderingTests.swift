import AppKit
import FormCore
import FormGraphics
import LabRendering
import XCTest
@testable import FormApp

@MainActor final class ObjectViewRenderingTests: XCTestCase {
  func testCameraFitsProjectedObjectToFrameWithoutCropping() throws {
    let points: [SIMD3<Double>] = [.init(-10,-5,0), .init(10,-5,0), .init(10,5,20), .init(-10,5,20)]
    let mesh = SceneMeshPayload(id: "test", revision: "1", positionsMM: points,
      parts: [.init(triangleIndices: [0,1,2,0,2,3])])
    let value = SceneRenderablePayload(componentID: "test", objectID: UUID(), mesh: mesh,
      materials: [.init(id:"test")], transform: .init(translationMM: .init(35,12,7)))
    let camera = try ObjectViewRendering.camera(for:[value], azimuth: 35, elevation: 20, aspect: 2)
    let viewport = CGSize(width: 1000, height: 500)
    let projected = try points.map { p in
      try XCTUnwrap(SceneProjection.project(p + .init(35,12,7), camera: camera, viewport: viewport))
    }
    XCTAssertTrue(projected.allSatisfy { $0.x >= 0 && $0.x <= 1000 && $0.y >= 0 && $0.y <= 500 })
    let center = try XCTUnwrap(SceneProjection.project(.init(35,12,17), camera:camera, viewport:viewport))
    XCTAssertEqual(center.x, 500, accuracy: 0.001)
    XCTAssertEqual(center.y, 250, accuracy: 0.001)
    let side = try ObjectViewRendering.camera(for:[value], azimuth:90, elevation:0, aspect:2)
    guard case .orthographic(let span) = camera.projection,
      case .orthographic(let sideSpan) = side.projection else { return XCTFail("Expected orthographic cameras") }
    XCTAssertEqual(span, sideSpan, accuracy:0.000001)
  }
  func testVectorAndRenderedViewsUseSameFrameAtDifferentAngles() throws {
    let vertices: [SIMD3<Double>] = [
      .init(0,0,0), .init(2,0,0), .init(2,1,0),
      .init(0,0,0), .init(2,1,0), .init(0,1,0),
      .init(0,0,0), .init(0,1,0), .init(0,1,3),
      .init(0,0,0), .init(0,1,3), .init(0,0,3),
    ]
    var triangles: [(SIMD3<Double>, SIMD3<Double>, SIMD3<Double>)] = []
    for index in stride(from: 0, to: vertices.count, by: 3) {
      let first = vertices[index]
      let second = vertices[index + 1]
      let third = vertices[index + 2]
      triangles.append((first, second, third))
    }
    let mesh = SceneMeshPayload(id:"frame-test",revision:"1",positionsMM:vertices,
      parts:[.init(triangleIndices:Array(0..<UInt32(vertices.count)))])
    let value = SceneRenderablePayload(componentID:"frame-test",objectID:UUID(),mesh:mesh,
      materials:[.init(id:"frame-test")],transform:.init())
    for angle in [0.0, 45.0, 90.0] {
      let generated = try ObjectViewProjection.project(triangles,azimuth:angle,elevation:0,style:"silhouette",name:"Model")
      var placement = ArtworkElement(kind:"path",x:7,y:9,width:100,height:60)
      placement.path = ObjectViewProjection.fit(generated,into:placement)
      let bounds = VectorGeometry.path(placement).boundingBoxOfPath
      let camera = try ObjectViewRendering.camera(for:[value],azimuth:angle,elevation:0,aspect:100.0/60.0)
      let points = try vertices.map { try XCTUnwrap(SceneProjection.project($0,camera:camera,viewport:.init(width:100,height:60))) }
      XCTAssertEqual(bounds.minX,points.map(\.x).min()!,accuracy:0.001)
      XCTAssertEqual(bounds.maxX,points.map(\.x).max()!,accuracy:0.001)
      XCTAssertEqual(bounds.minY,points.map(\.y).min()!,accuracy:0.001)
      XCTAssertEqual(bounds.maxY,points.map(\.y).max()!,accuracy:0.001)
      XCTAssertEqual(placement.x,7); XCTAssertEqual(placement.y,9)
      XCTAssertEqual(placement.width,100); XCTAssertEqual(placement.height,60)
    }
  }

  func testVectorRefreshRetainsNonuniformResize() throws {
    let triangles: [(SIMD3<Double>,SIMD3<Double>,SIMD3<Double>)] = [
      (.init(0,0,0),.init(2,0,0),.init(2,1,0)),
      (.init(0,0,0),.init(2,1,0),.init(0,1,0)),
      (.init(0,0,0),.init(0,1,0),.init(0,1,3)),
      (.init(0,0,0),.init(0,1,3),.init(0,0,3)),
    ]
    var view = try ObjectViewProjection.project(triangles,azimuth:0,elevation:0,style:"silhouette",name:"Model")
    view.width = 120; view.height = 60
    let initial = VectorGeometry.path(view).boundingBoxOfPath
    let rotated = try ObjectViewProjection.project(triangles,azimuth:90,elevation:0,style:"silhouette",name:"Model")
    view.path = ObjectViewProjection.fit(rotated,into:view)
    let after = VectorGeometry.path(view).boundingBoxOfPath
    XCTAssertEqual(initial.height,after.height,accuracy:0.001)
    XCTAssertEqual(after.width / initial.width,1.5,accuracy:0.001)
    XCTAssertEqual(view.path?.width,60); XCTAssertEqual(view.path?.height,60)
  }

  func testEmptySceneAndInvalidAspectFail() {
    XCTAssertThrowsError(try ObjectViewRendering.camera(for: [], azimuth: 0, elevation: 0, aspect: 1))
    XCTAssertThrowsError(try ObjectViewRendering.camera(for: [], azimuth: 0, elevation: 0, aspect: 0))
  }
}
