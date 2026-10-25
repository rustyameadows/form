import SceneKit
import XCTest

@testable import FormCore
@testable import FormGraphics

final class CameraNavigationTests: XCTestCase {
  func testCameraDirectionMovesTheCameraWithTheDragAndObjectDirectionReversesBothAxes() {
    var start = CameraState()
    start.azimuth = 0; start.elevation = 0.4
    var preferences = CameraPreferences()
    let camera = CameraNavigation.orbited(start, dx: 90, dy: 60, viewportHeight: 800,
      preferences: preferences)
    XCTAssertGreaterThan(camera.azimuth, start.azimuth)
    XCTAssertGreaterThan(camera.elevation, start.elevation)
    let node = SCNNode()
    SceneCamera.position(node, using: camera)
    XCTAssertGreaterThan(Double(node.position.x), start.target.x)
    XCTAssertGreaterThan(Double(node.position.y), start.target.y + start.distance * sin(start.elevation))
    preferences.orbitDirection = .turnObject
    let object = CameraNavigation.orbited(start, dx: 90, dy: 60, viewportHeight: 800,
      preferences: preferences)
    XCTAssertEqual(camera.azimuth - start.azimuth, start.azimuth - object.azimuth, accuracy: 1e-12)
    XCTAssertEqual(camera.elevation - start.elevation, start.elevation - object.elevation, accuracy: 1e-12)
    XCTAssertEqual(camera.target, start.target)
    XCTAssertEqual(camera.distance, start.distance)
  }

  func testOrbitSpeedIsBoundedAndDoesNotChangePanOrZoom() throws {
    let camera = CameraState()
    var preferences = CameraPreferences()
    preferences.orbitSpeed = 0.5
    let slow = CameraNavigation.orbited(camera, dx: 120, dy: 0, viewportHeight: 800,
      preferences: preferences)
    preferences.orbitSpeed = 1
    let fast = CameraNavigation.orbited(camera, dx: 120, dy: 0, viewportHeight: 800,
      preferences: preferences)
    XCTAssertEqual(fast.azimuth - camera.azimuth, 2 * (slow.azimuth - camera.azimuth), accuracy: 1e-12)
    preferences.orbitSpeed = .nan; XCTAssertEqual(preferences.effectiveOrbitSpeed, 0.75)
    preferences.orbitSpeed = -10; XCTAssertEqual(preferences.effectiveOrbitSpeed, 0.25)
    preferences.orbitSpeed = 1e9; XCTAssertEqual(preferences.effectiveOrbitSpeed, 2)
    XCTAssertEqual(preferences.scrollZoomDelta(10, precise: false), -10)
    XCTAssertEqual(preferences.scrollZoomDelta(10, precise: true), -3.5)
    preferences.reverseScrollZoom = true
    XCTAssertEqual(preferences.scrollZoomDelta(10, precise: false), 10)
    XCTAssertEqual(preferences.scrollZoomDelta(10, precise: true), 3.5)
    XCTAssertEqual(try JSONDecoder().decode(CameraPreferences.self,
      from: JSONEncoder().encode(preferences)), preferences)
  }

  func testRepeatedOrbitAndPanKeepTheActualCameraHorizonUpright() {
    let node = SCNNode()
    var state = CameraState()
    for step in 0..<1200 {
      state = CameraNavigation.orbited(
        state, dx: 9, dy: sin(Double(step) / 30) * 8,
        viewportHeight: 800)
      if step % 3 == 0 {
        state = CameraNavigation.panned(state, dx: -3, dy: 2, viewportHeight: 800)
      }
      SceneCamera.position(node, using: state)
      XCTAssertEqual(node.simdWorldRight.y, 0, accuracy: 0.0002)
      XCTAssertGreaterThan(node.simdWorldUp.y, 0)
      let target = node.convertPosition(
        .init(state.target.x, state.target.y, state.target.z),
        from: nil)
      XCTAssertEqual(target.x, 0, accuracy: 0.0002)
      XCTAssertEqual(target.y, 0, accuracy: 0.0002)
      XCTAssertEqual(-Double(target.z), state.distance, accuracy: 0.0002)
    }
  }
  func testOrbitFollowsTheDraggedSurfaceAndKeepsProjection() {
    var camera = CameraState()
    camera.azimuth = 0
    camera.elevation = 0.7
    camera.projection = "orthographic"
    var preferences = CameraPreferences()
    preferences.orbitDirection = .turnObject; preferences.orbitSpeed = 1
    let right = CameraNavigation.orbited(camera, dx: 80, dy: 0, viewportHeight: 800, preferences: preferences)
    let up = CameraNavigation.orbited(camera, dx: 0, dy: 80, viewportHeight: 800, preferences: preferences)
    // A point on the near face of the subject follows the pointer in both axes.
    let point = Vector3(camera.target.x, camera.target.y, camera.target.z + 0.3)
    let start = project(point, camera, width: 1200, height: 800)
    XCTAssertGreaterThan(project(point, right, width: 1200, height: 800).x, start.x)
    XCTAssertGreaterThan(project(point, up, width: 1200, height: 800).y, start.y)
    XCTAssertEqual(right.projection, "orthographic")
    XCTAssertEqual(right.target, camera.target)
    XCTAssertEqual(right.distance, camera.distance)
    let undo = CameraNavigation.orbited(right, dx: -80, dy: 0, viewportHeight: 800, preferences: preferences)
    XCTAssertEqual(undo.azimuth, camera.azimuth, accuracy: 1e-12)
    XCTAssertEqual(undo.elevation, camera.elevation, accuracy: 1e-12)
    let resized = CameraNavigation.orbited(camera, dx: 160, dy: 0, viewportHeight: 1600, preferences: preferences)
    XCTAssertEqual(right.azimuth, resized.azimuth, accuracy: 1e-12)
  }

  func testPanTracksMousePointsAtEveryViewAngleAndProjection() {
    for projection in ["perspective", "orthographic"] {
      for azimuth in [0.0, 0.55, 2.5] {
        for elevation in [-1.569, -0.7, 0, 0.7, 1.569] {
          for height in [400.0, 900] {
            var camera = CameraState()
            camera.projection = projection
            camera.azimuth = azimuth
            camera.elevation = elevation
            let moved = CameraNavigation.panned(
              camera, dx: 83, dy: -51,
              viewportHeight: height)
            let before = project(camera.target, camera, width: 1400, height: height)
            let after = project(camera.target, moved, width: 1400, height: height)
            XCTAssertEqual(after.x - before.x, 83, accuracy: 0.12)
            XCTAssertEqual(after.y - before.y, -51, accuracy: 0.12)
            let reversed = CameraNavigation.panned(
              moved, dx: -83, dy: 51,
              viewportHeight: height)
            XCTAssertEqual(reversed.target.x, camera.target.x, accuracy: 1e-12)
            XCTAssertEqual(reversed.target.y, camera.target.y, accuracy: 1e-12)
            XCTAssertEqual(reversed.target.z, camera.target.z, accuracy: 1e-12)
          }
        }
      }
    }
  }

  func testOrbitCanInspectBelowTheTableWithoutFlippingTheHorizon() {
    let camera = CameraState()
    let below = CameraNavigation.orbited(camera, dx: 0, dy: -300, viewportHeight: 700)
    XCTAssertLessThan(below.elevation, 0)
    let pole = CameraNavigation.orbited(camera, dx: 1e9, dy: 1e9, viewportHeight: 700)
    XCTAssertLessThan(pole.elevation, .pi / 2)
    XCTAssertLessThanOrEqual(abs(pole.azimuth), .pi)
    let bottom = CameraNavigation.orbited(camera, dx: 0, dy: -1e9, viewportHeight: 700)
    XCTAssertGreaterThan(bottom.elevation, -.pi / 2)
  }

  func testZoomIsReversibleBoundedAndSupportsSmallObjects() {
    let camera = CameraState()
    let closer = CameraNavigation.zoomed(camera, delta: -18)
    XCTAssertLessThan(closer.distance, camera.distance)
    XCTAssertEqual(
      CameraNavigation.zoomed(closer, delta: 18).distance,
      camera.distance, accuracy: 1e-12)
    XCTAssertEqual(
      CameraNavigation.zoomed(camera, delta: -1e9).distance,
      CameraNavigation.minimumDistance)
    XCTAssertEqual(
      CameraNavigation.zoomed(camera, delta: 1e9).distance,
      CameraNavigation.maximumDistance)
    XCTAssertEqual(CameraNavigation.zoomed(camera, delta: .nan), camera)
    XCTAssertEqual(
      CameraNavigation.orbited(
        camera, dx: .infinity, dy: 0,
        viewportHeight: 700), camera)
    XCTAssertEqual(
      CameraNavigation.panned(
        camera, dx: 0, dy: .nan,
        viewportHeight: 700), camera)
  }

  private func project(_ point: Vector3, _ state: CameraState, width: Double, height: Double)
    -> CGPoint
  {
    let node = SCNNode()
    let lens = SCNCamera()
    lens.fieldOfView = 39
    lens.projectionDirection = .vertical
    lens.usesOrthographicProjection = state.projection == "orthographic"
    lens.orthographicScale = state.distance * CameraFraming.orthographicFactor
    node.camera = lens
    SceneCamera.position(node, using: state)
    let p = node.convertPosition(.init(point.x, point.y, point.z), from: nil)
    let m = lens.projectionTransform
    let w = m.m14 * p.x + m.m24 * p.y + m.m34 * p.z + m.m44
    return .init(
      x: (m.m11 * p.x + m.m21 * p.y + m.m31 * p.z + m.m41) / w * height / 2,
      y: (m.m12 * p.x + m.m22 * p.y + m.m32 * p.z + m.m42) / w * height / 2)
  }
}
