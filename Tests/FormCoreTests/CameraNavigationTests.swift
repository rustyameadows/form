import FormGeometry
import simd
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
    let node = MeshNode()
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
    let node = MeshNode()
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
      XCTAssertEqual(axes.right.y, 0, accuracy: 1e-12)
      XCTAssertGreaterThanOrEqual(axes.up.y, -1e-12)
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

  func testDefaultOrbitFollowsEveryDragDirectionAwayFromVerticalEndpoints() {
    XCTAssertEqual(CameraPreferences().orbitDirection, .turnObject)
    for projection in ["perspective", "orthographic"] {
      for elevation in [-1.2, -0.7, 0.0, 0.7, 1.2] {
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
          // Yaw follows a latitude around world-up; at nonzero pitch its finite
          // perspective motion need not lie on an exact image-space horizontal.
          let reversed = CameraNavigation.orbited(moved, dx: -dx, dy: -dy, viewportHeight: 800)
          assertSameBasis(start, reversed)
          XCTAssertEqual(moved.target, start.target)
          XCTAssertEqual(moved.distance, start.distance)
          XCTAssertEqual(CameraNavigation.basis(moved).right.y, 0, accuracy: 1e-12)
        }
      }
    }
  }

  func testHorizontalOrbitCompletesRepeatedTurnsWithoutRollOrStops() {
    for dx in [-1.0, 1.0] {
      for initialPitch in [-Double.pi / 2, -0.7, 0.7, Double.pi / 2] {
        var start = CameraState(); start.elevation = initialPitch
        var state = start
        let step = 800.0 * 8 / (0.75 * 1440)
        for _ in 0..<1440 {
          let previous = CameraNavigation.basis(state)
          state = CameraNavigation.orbited(state, dx: dx * step, dy: 0, viewportHeight: 800)
          let axes = CameraNavigation.basis(state)
          XCTAssertEqual(axes.right.y, 0, accuracy: 1e-12)
          XCTAssertGreaterThanOrEqual(axes.up.y, -1e-12)
          XCTAssertEqual(state.elevation, initialPitch, accuracy: 1e-10)
          XCTAssertGreaterThan(previous.right.x * axes.right.x + previous.right.z * axes.right.z, 0.999)
        }
        assertSameBasis(start, state)
        XCTAssertEqual(state.target, start.target)
        XCTAssertEqual(state.distance, start.distance)
      }
    }
  }

  func testVerticalEndpointsPreventInversionAndReverseImmediatelyWhileYawStaysAvailable() {
    for dy in [-1.0, 1.0] {
      let initial = CameraState()
      let endpoint = CameraNavigation.orbited(initial, dx: 0, dy: dy * 10000, viewportHeight: 800)
      let expected = dy > 0 ? CameraNavigation.minimumElevation : CameraNavigation.maximumElevation
      XCTAssertEqual(endpoint.elevation, expected, accuracy: 1e-12)
      let held = CameraNavigation.orbited(endpoint, dx: 0, dy: dy * 10000, viewportHeight: 800)
      assertSameBasis(endpoint, held)
      let yawed = CameraNavigation.orbited(endpoint, dx: 80, dy: 0, viewportHeight: 800)
      XCTAssertNotEqual(CameraNavigation.basis(yawed).right, CameraNavigation.basis(endpoint).right)
      XCTAssertEqual(yawed.elevation, expected, accuracy: 1e-12)
      let reversed = CameraNavigation.orbited(endpoint, dx: 0, dy: -dy, viewportHeight: 800)
      XCTAssertLessThan(abs(reversed.elevation), abs(endpoint.elevation))
      XCTAssertEqual(CameraNavigation.basis(reversed).right.y, 0, accuracy: 1e-12)
      XCTAssertGreaterThan(CameraNavigation.basis(reversed).up.y, 0)
      XCTAssertEqual(reversed.target, initial.target)
      XCTAssertEqual(reversed.distance, initial.distance)
    }
  }

  func testMostlyHorizontalMouseNoiseAndDiagonalPathsNeverAccumulateBank() {
    var state = CameraState()
    let start = state
    for step in 0..<2000 {
      state = CameraNavigation.orbited(state, dx: 6, dy: step % 2 == 0 ? 0.25 : -0.25, viewportHeight: 800)
      let axes = CameraNavigation.basis(state)
      XCTAssertEqual(axes.right.y, 0, accuracy: 1e-12)
      XCTAssertGreaterThan(axes.up.y, 0)
      // Project a pair of distant points on the ground-plane horizon using the
      // actual renderer camera matrix. Bank would give them different screen Y.
      let a = Vector3(state.target.x - axes.outward.x * 100 - axes.right.x * 10, 0,
        state.target.z - axes.outward.z * 100 - axes.right.z * 10)
      let b = Vector3(state.target.x - axes.outward.x * 100 + axes.right.x * 10, 0,
        state.target.z - axes.outward.z * 100 + axes.right.z * 10)
      XCTAssertEqual(project(a, state, width: 1200, height: 800).y,
        project(b, state, width: 1200, height: 800).y, accuracy: 0.005) // Double camera projection, in screen pixels.
    }
    XCTAssertEqual(state.elevation, start.elevation, accuracy: 1e-10)
    let actualVertical = CameraNavigation.orbited(start, dx: 0, dy: 0.25, viewportHeight: 800)
    XCTAssertLessThan(actualVertical.elevation, start.elevation) // No invented deadband.
    var diagonal = start
    for (dx, dy) in [(80.0, 30.0), (-40.0, 20.0), (-80.0, -30.0), (40.0, -20.0)] {
      diagonal = CameraNavigation.orbited(diagonal, dx: dx, dy: dy, viewportHeight: 800)
      XCTAssertEqual(CameraNavigation.basis(diagonal).right.y, 0, accuracy: 1e-12)
    }
    assertSameBasis(start, diagonal)
  }

  func testSavedFreeOrbitRollIsRemovedWithoutChangingLookDirectionPivotOrZoom() {
    var saved = CameraState()
    let rotation = simd_quatd(angle: saved.azimuth, axis: SIMD3(0, 1, 0))
      * simd_quatd(angle: -saved.elevation, axis: SIMD3(1, 0, 0))
      * simd_quatd(angle: 1.1, axis: SIMD3(0, 0, 1))
    saved.orientation = CameraOrientation(rotation)
    let before = saved
    let axes = CameraNavigation.basis(saved)
    let outward = rotation.act(SIMD3<Double>(0, 0, 1))
    XCTAssertEqual(axes.outward.x, outward.x, accuracy: 1e-12)
    XCTAssertEqual(axes.outward.y, outward.y, accuracy: 1e-12)
    XCTAssertEqual(axes.outward.z, outward.z, accuracy: 1e-12)
    XCTAssertEqual(axes.right.y, 0, accuracy: 1e-12)
    XCTAssertGreaterThan(axes.up.y, 0)
    XCTAssertEqual(saved, before) // Rendering old files does not rewrite them.
    for (dx, dy) in [(40.0, 0.0), (-40.0, 0.0), (0.0, 40.0), (0.0, -40.0)] {
      let moved = CameraNavigation.orbited(saved, dx: dx, dy: dy, viewportHeight: 800)
      XCTAssertEqual(moved.target, saved.target)
      XCTAssertEqual(moved.distance, saved.distance)
      XCTAssertEqual(CameraNavigation.basis(moved).right.y, 0, accuracy: 1e-12)
      let pan = CameraNavigation.panned(saved, dx: dx, dy: dy, viewportHeight: 800)
      let oldTarget = project(saved.target, saved, width: 1200, height: 800)
      let newTarget = project(saved.target, pan, width: 1200, height: 800)
      XCTAssertEqual(newTarget.x - oldTarget.x, dx, accuracy: 0.001)
      XCTAssertEqual(newTarget.y - oldTarget.y, dy, accuracy: 0.001)
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
    let node = MeshNode()
    let lens = MeshCamera()
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
