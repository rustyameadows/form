import XCTest
@testable import FormCore

final class ObjectViewPersistenceTests: XCTestCase {
  func testIndependentViewsRoundTripAndRequireNewSchema() throws {
    let source = UUID()
    var front = ArtworkElement(kind: "path", x: 0, y: 0)
    front.objectView = ObjectViewSettings(sourceID: source, azimuth: 0, elevation: 0,
      style: "silhouette", linked: true)
    var side = ArtworkElement(kind: "path", x: 30, y: 0)
    side.objectView = ObjectViewSettings(sourceID: source, azimuth: 90, elevation: 20,
      style: "lines", linked: false)
    var project = Project(name: "Views")
    project.objects = [ProductObject(name: "Page", recipeID: "artboard", parameters: [:],
      artwork: Artwork(elements: [front, side]))]
    XCTAssertEqual(project.minimumSchemaVersion, 58)
    project.schemaVersion = project.minimumSchemaVersion
    let decoded = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(project))
    let elements = try XCTUnwrap(decoded.objects.first?.artwork?.elements)
    XCTAssertEqual(elements[0].objectView, front.objectView)
    XCTAssertEqual(elements[1].objectView, side.objectView)
    XCTAssertNotEqual(elements[0].objectView, elements[1].objectView)
  }

  func testReferenceAspectSurvivesResizeAndImageTransition() throws {
    var element = ArtworkElement(kind: "path", x: 10, y: 20, width: 60, height: 60)
    element.path = VectorPath(width: 60, height: 60, contours: [])
    var settings = ObjectViewSettings(sourceID: UUID())
    settings.referenceAspect = settings.framingAspect(for: element)
    element.width = 120
    let frame = settings.framingTarget(for: element)
    XCTAssertEqual(frame.width / frame.height, 1)
    XCTAssertEqual(element.width, 120)
    XCTAssertEqual(element.height, 60)
    element.kind = "image"; element.path = nil
    XCTAssertEqual(settings.framingAspect(for: element), 1)
    let decoded = try JSONDecoder().decode(ObjectViewSettings.self, from: JSONEncoder().encode(settings))
    XCTAssertEqual(decoded.referenceAspect, 1)
  }

  func testLegacyReferenceAspectFallsBackToPathThenFrame() {
    var element = ArtworkElement(kind: "path", x: 0, y: 0, width: 120, height: 60)
    element.path = VectorPath(width: 60, height: 60, contours: [])
    let legacy = ObjectViewSettings(sourceID: UUID())
    XCTAssertEqual(legacy.framingAspect(for: element), 1)
    element.path = nil
    XCTAssertEqual(legacy.framingAspect(for: element), 2)
  }

  func testArtworkWithoutObjectViewStillDecodes() throws {
    let element = ArtworkElement(kind: "rectangle", x: 1, y: 2)
    let decoded = try JSONDecoder().decode(ArtworkElement.self, from: JSONEncoder().encode(element))
    XCTAssertNil(decoded.objectView)
  }
}
