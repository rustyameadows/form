import SceneKit
import XCTest

@testable import FormCore
@testable import FormGraphics

final class CameraNavigationTests: XCTestCase {
  func testCameraDirectionMovesTheCameraWithTheDragAndObjectDirectionReversesBothAxes() {
    var start = CameraState()
    start.azimuth = 0; start.elevation = 0.4
    var preferences = CameraPreferences()
    preferences.orbitDirection = .moveCamera
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
    let restored = CameraNavigation.orbited(camera, dx: 90, dy: 60, viewportHeight: 800, preferences: preferences)
    assertSameBasis(start, restored)
    XCTAssertLessThan(object.azimuth, start.azimuth)
    XCTAssertLessThan(object.elevation, start.elevation)
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
    preferences.orbitSpeed = 0.5
    let secondSlow = CameraNavigation.orbited(slow, dx: 120, dy: 0, viewportHeight: 800, preferences: preferences)
    assertSameBasis(fast, secondSlow)
    XCTAssertNotEqual(fast.orientation, slow.orientation)
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

  func testRepeatedOrbitAndPanKeepTheActualCameraOrthonormalAndPivotCentered() {
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
      let axes = CameraNavigation.basis(state)
      XCTAssertEqual(Double(node.simdWorldRight.x), axes.right.x, accuracy: 0.0002)
      XCTAssertEqual(Double(node.simdWorldRight.y), axes.right.y, accuracy: 0.0002)
      XCTAssertEqual(Double(node.simdWorldRight.z), axes.right.z, accuracy: 0.0002)
      XCTAssertEqual(Double(node.simdWorldUp.x), axes.up.x, accuracy: 0.0002)
      XCTAssertEqual(Double(node.simdWorldUp.y), axes.up.y, accuracy: 0.0002)
      XCTAssertEqual(Double(node.simdWorldUp.z), axes.up.z, accuracy: 0.0002)
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
        for elevation in [-Double.pi, -Double.pi / 2, -1.569, -0.7, 0, 0.7, 1.569, Double.pi / 2, Double.pi] {
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

  func testDefaultOrbitFollowsEveryDragDirectionAtUprightInvertedAndPoleOrientations() {
    XCTAssertEqual(CameraPreferences().orbitDirection, .turnObject)
    for projection in ["perspective", "orthographic"] {
      for elevation in [-Double.pi, -.pi / 2, -0.7, 0.0, 0.7, .pi / 2, .pi] {
        var start = CameraState()
        start.projection = projection; start.elevation = elevation
        let axes = CameraNavigation.basis(start)
        let point = Vector3(start.target.x + axes.outward.x * 0.3,
          start.target.y + axes.outward.y * 0.3, start.target.z + axes.outward.z * 0.3)
        let initial = project(point, start, width: 1200, height: 800)
        for (dx, dy) in [(40.0, 0.0), (-40.0, 0.0), (0.0, 40.0), (0.0, -40.0), (40.0, -40.0)] {
          let moved = CameraNavigation.orbited(start, dx: dx, dy: dy, viewportHeight: 800)
          let position = project(point, moved, width: 1200, height: 800)
          if dx != 0 { XCTAssertGreaterThan((position.x - initial.x) * dx, 0) }
          else { XCTAssertEqual(position.x, initial.x, accuracy: 0.001) }
          if dy != 0 { XCTAssertGreaterThan((position.y - initial.y) * dy, 0) }
          else { XCTAssertEqual(position.y, initial.y, accuracy: 0.001) }
          let reversed = CameraNavigation.orbited(moved, dx: -dx, dy: -dy, viewportHeight: 800)
          assertSameBasis(start, reversed)
          XCTAssertEqual(moved.target, start.target)
          XCTAssertEqual(moved.distance, start.distance)
        }
      }
    }
  }

  func testFullHorizontalAndVerticalRotationsHaveNoStopsOrPoleFlips() {
    for (dx, dy) in [(1.0, 0.0), (0.0, 1.0), (0.0, -1.0), (-1.0, 0.0)] {
      let start = CameraState()
      var state = start
      // Four full revolutions, crossing each pole eight times for vertical drags.
      let step = 800.0 * 8 / (0.75 * 1440)
      var previous = CameraNavigation.basis(start)
      let node = SCNNode()
      for _ in 0..<1440 {
        state = CameraNavigation.orbited(state, dx: dx * step, dy: dy * step, viewportHeight: 800)
        let axes = CameraNavigation.basis(state)
        func dot(_ a: Vector3, _ b: Vector3) -> Double { a.x * b.x + a.y * b.y + a.z * b.z }
        XCTAssertGreaterThan(dot(previous.right, axes.right), 0.999)
        XCTAssertGreaterThan(dot(previous.up, axes.up), 0.999)
        XCTAssertGreaterThan(dot(previous.outward, axes.outward), 0.999)
        SceneCamera.position(node, using: state)
        let target = node.convertPosition(.init(state.target.x, state.target.y, state.target.z), from: nil)
        XCTAssertEqual(target.x, 0, accuracy: 0.0002)
        XCTAssertEqual(target.y, 0, accuracy: 0.0002)
        XCTAssertEqual(-Double(target.z), state.distance, accuracy: 0.0002)
        previous = axes
      }
      assertSameBasis(start, state)
      XCTAssertEqual(state.target, start.target)
      XCTAssertEqual(state.distance, start.distance)
    }
  }

  func testRolledCameraOrbitAndPanStillFollowTheActualScreenAxes() {
    var start = CameraNavigation.orbited(CameraState(), dx: 300, dy: -450, viewportHeight: 800)
    start = CameraNavigation.orbited(start, dx: -610, dy: -230, viewportHeight: 800)
    let axes = CameraNavigation.basis(start)
    let near = Vector3(start.target.x + axes.outward.x * 0.3,
      start.target.y + axes.outward.y * 0.3, start.target.z + axes.outward.z * 0.3)
    for (dx, dy) in [(40.0, 0.0), (-40.0, 0.0), (0.0, 40.0), (0.0, -40.0)] {
      let before = project(near, start, width: 1200, height: 800)
      let orbit = CameraNavigation.orbited(start, dx: dx, dy: dy, viewportHeight: 800)
      let after = project(near, orbit, width: 1200, height: 800)
      if dx != 0 { XCTAssertGreaterThan((after.x - before.x) * dx, 0) }
      if dy != 0 { XCTAssertGreaterThan((after.y - before.y) * dy, 0) }
      let pan = CameraNavigation.panned(start, dx: dx, dy: dy, viewportHeight: 800)
      let originalTarget = project(start.target, start, width: 1200, height: 800)
      let movedTarget = project(start.target, pan, width: 1200, height: 800)
      XCTAssertEqual(movedTarget.x - originalTarget.x, dx, accuracy: 0.001)
      XCTAssertEqual(movedTarget.y - originalTarget.y, dy, accuracy: 0.001)
    }
  }

  func testQuaternionPersistenceAndInvalidRotationFallbackPreserveLegacyCameras() throws {
    let legacy = CameraState()
    let encodedLegacy = try JSONEncoder.form.encode(legacy)
    XCTAssertFalse(String(decoding: encodedLegacy, as: UTF8.self).contains("orientation"))
    XCTAssertNil(try JSONDecoder.form.decode(CameraState.self, from: encodedLegacy).orientation)
    let rotated = CameraNavigation.orbited(legacy, dx: 530, dy: -840, viewportHeight: 800)
    let decoded = try JSONDecoder.form.decode(CameraState.self, from: JSONEncoder.form.encode(rotated))
    XCTAssertEqual(decoded, rotated); assertSameBasis(decoded, rotated)
    for bad in [CameraOrientation(x: 0, y: 0, z: 0, w: 0),
      CameraOrientation(x: .nan, y: 0, z: 0, w: 1), CameraOrientation(x: 0, y: .infinity, z: 0, w: 1)] {
      var invalid = legacy; invalid.orientation = bad
      assertSameBasis(invalid, legacy)
    }
    var enormous = legacy
    enormous.orientation = CameraOrientation(x: 0, y: 0, z: 0, w: Double.greatestFiniteMagnitude)
    var identity = legacy; identity.azimuth = 0; identity.elevation = 0
    assertSameBasis(enormous, identity)
    var project = Project(name: "Free camera")
    XCTAssertEqual(project.minimumSchemaVersion, 1)
    project.camera = rotated
    XCTAssertEqual(project.minimumSchemaVersion, 16)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = try ProjectRepository(root: root)
    try repository.save(project)
    let reopened = try repository.load(project.id)
    XCTAssertEqual(reopened.schemaVersion, 16)
    assertSameBasis(reopened.camera, rotated)
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

  private func assertSameBasis(_ a: CameraState, _ b: CameraState, file: StaticString = #filePath, line: UInt = #line) {
    let first = CameraNavigation.basis(a), second = CameraNavigation.basis(b)
    for (x, y) in [(first.right, second.right), (first.up, second.up), (first.outward, second.outward)] {
      XCTAssertEqual(x.x, y.x, accuracy: 1e-10, file: file, line: line)
      XCTAssertEqual(x.y, y.y, accuracy: 1e-10, file: file, line: line)
      XCTAssertEqual(x.z, y.z, accuracy: 1e-10, file: file, line: line)
    }
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
