import SceneKit
import XCTest

@testable import FormCore
@testable import FormGraphics

final class CameraFramingTests: XCTestCase {
  private let corners = [-5.0, 8].flatMap { x in
    [0.0, 7].flatMap { y in [-4.0, 3].map { Vector3(x, y, $0) } }
  }
  func testPerspectiveFitsDepthAndBothViewportAxes() {
    verify(projection: "perspective")
  }
  func testOrthographicFitsBothAxesUsingActualSceneKitProjection() {
    verify(projection: "orthographic")
  }
  func testNoFiniteBoundsKeepsExistingCamera() {
    let camera = CameraState()
    XCTAssertEqual(CameraFraming.fitted(camera, points: [], aspect: 1), camera)
    XCTAssertEqual(
      CameraFraming.fitted(camera, points: [.init(.infinity, 0, 0)], aspect: 1), camera)
    XCTAssertTrue(CameraFraming.fitted(camera, points: corners, aspect: .nan).distance.isFinite)
  }
  func testFocusKeepsBoundsClearOfFloatingControlsWithoutMovingTheOrbitPivot() {
    let insets = CameraFraming.Insets(top: 0.12, right: 0.29, bottom: 0.15, left: 0.03)
    for projection in ["perspective", "orthographic"] {
      for aspect in [1.2, 1.7, 2.5] {
        for azimuth in [0.0, 0.55, 2.5] {
          for elevation in [-1.569, -0.7, 0.1, 0.7, 1.569] {
            var input = CameraState()
            input.azimuth = azimuth
            input.elevation = elevation
            input.projection = projection
            let plain = CameraFraming.fitted(input, points: corners, aspect: aspect)
            let fitted = CameraFraming.fitted(input, points: corners, aspect: aspect, insets: insets)
            XCTAssertEqual(fitted.target, plain.target)
            XCTAssertEqual(fitted.viewportAspect, aspect)
            XCTAssertGreaterThanOrEqual(fitted.distance, plain.distance)
            let node = SCNNode()
            let lens = SCNCamera()
            lens.fieldOfView = 39
            lens.projectionDirection = .vertical
            lens.usesOrthographicProjection = projection == "orthographic"
            lens.orthographicScale = fitted.distance * CameraFraming.orthographicFactor
            node.camera = lens
            SceneCamera.position(node, using: fitted)
            let matrix = lens.projectionTransform
            for point in corners {
              let p = node.convertPosition(.init(point.x, point.y, point.z), from: nil)
              let w = matrix.m14 * p.x + matrix.m24 * p.y + matrix.m34 * p.z + matrix.m44
              let x = (matrix.m11 * p.x + matrix.m21 * p.y + matrix.m31 * p.z + matrix.m41) / w / aspect
              let y = (matrix.m12 * p.x + matrix.m22 * p.y + matrix.m32 * p.z + matrix.m42) / w
              XCTAssertLessThanOrEqual(x, 1 - 2 * insets.right)
              XCTAssertGreaterThanOrEqual(x, -1 + 2 * insets.left)
              XCTAssertLessThanOrEqual(y, 1 - 2 * insets.top)
              XCTAssertGreaterThanOrEqual(y, -1 + 2 * insets.bottom)
              XCTAssertGreaterThan(-p.z, 0.01)
            }
          }
        }
      }
    }
  }

  func testInvalidFramingInsetsAreBounded() {
    let input = CameraState()
    let plain = CameraFraming.fitted(input, points: corners, aspect: 1.7)
    XCTAssertEqual(
      CameraFraming.fitted(
        input, points: corners, aspect: 1.7,
        insets: .init(top: -.infinity, right: .nan, bottom: -1, left: -.infinity)), plain)
    let tight = CameraFraming.fitted(
      input, points: corners, aspect: 1.7,
      insets: .init(top: 1, right: 10, bottom: 1, left: 10))
    XCTAssertTrue(tight.distance.isFinite)
    XCTAssertGreaterThan(tight.distance, plain.distance)
    XCTAssertEqual(tight.target, plain.target)
  }
  func testOutputViewportPreservesTheFullSourceViewWithoutCropping() throws {
    XCTAssertEqual(CameraFraming.viewportExpansion(from: 3, to: 1.5), 2)
    XCTAssertEqual(CameraFraming.viewportExpansion(from: 1.5, to: 3), 1)
    XCTAssertEqual(CameraFraming.viewportExpansion(from: nil, to: 1.5), 1)
    XCTAssertEqual(CameraFraming.viewportExpansion(from: .nan, to: 1.5), 1)
    var camera = CameraState()
    camera.viewportAspect = 3
    XCTAssertEqual(
      try JSONDecoder.form.decode(CameraState.self, from: JSONEncoder.form.encode(camera)), camera)
    for source in [0.55, 1.5, 3.0] {
      for output in [0.55, 1.5, 3.0] {
        let expansion = CameraFraming.viewportExpansion(from: source, to: output)
        XCTAssertGreaterThanOrEqual(expansion, 1)
        XCTAssertGreaterThanOrEqual(expansion * output, source)
      }
    }
  }
  private func verify(projection: String) {
    for aspect in [0.55, 1, 1.5, 3] {
      for azimuth in [0.0, 0.55, 2.5] {
        for elevation in [-1.569, -0.7, 0.1, 0.7, 1.569] {
          var input = CameraState()
          input.azimuth = azimuth
          input.elevation = elevation
          input.projection = projection
          let fitted = CameraFraming.fitted(input, points: corners, aspect: aspect)
          let node = SCNNode()
          let camera = SCNCamera()
          camera.fieldOfView = 39
          camera.projectionDirection = .vertical
          camera.usesOrthographicProjection = projection == "orthographic"
          camera.orthographicScale = fitted.distance * CameraFraming.orthographicFactor
          node.camera = camera
          node.position = .init(
            fitted.target.x + fitted.distance * cos(elevation) * sin(azimuth),
            fitted.target.y + fitted.distance * sin(elevation),
            fitted.target.z + fitted.distance * cos(elevation) * cos(azimuth))
          node.look(at: .init(fitted.target.x, fitted.target.y, fitted.target.z))
          let matrix = camera.projectionTransform
          for point in corners {
            let p = node.convertPosition(.init(point.x, point.y, point.z), from: nil)
            let w = matrix.m14 * p.x + matrix.m24 * p.y + matrix.m34 * p.z + matrix.m44
            let x =
              (matrix.m11 * p.x + matrix.m21 * p.y + matrix.m31 * p.z + matrix.m41) / w
              / CGFloat(aspect)
            let y = (matrix.m12 * p.x + matrix.m22 * p.y + matrix.m32 * p.z + matrix.m42) / w
            XCTAssertLessThanOrEqual(abs(x), 1 / 1.2 + 0.00001)
            XCTAssertLessThanOrEqual(abs(y), 1 / 1.2 + 0.00001)
            XCTAssertGreaterThan(-p.z, 0.01)
          }
        }
      }
    }
  }
}
