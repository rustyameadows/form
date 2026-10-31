import XCTest
@testable import FormCore

final class ObjectViewPathGuardTests: XCTestCase {
  private func path() -> ArtworkElement {
    var element = ArtworkElement(kind: "path", x: 0, y: 0, width: 10, height: 10)
    element.path = VectorPath(width: 10, height: 10, contours: [
      .init([.init(.init(0, 0)), .init(.init(10, 0)), .init(.init(10, 10))], closed: true)
    ])
    return element
  }

  func testViewPathMustBeConvertedBeforeEditing() throws {
    var view = path()
    view.objectView = ObjectViewSettings(sourceID: UUID(), linked: true)
    var art = Artwork(elements: [view])
    let original = art
    XCTAssertThrowsError(try PathCommands.edit("reverse", artwork: &art, elements: [view.id])) { error in
      XCTAssertTrue(error.localizedDescription.contains("Convert object views"))
    }
    XCTAssertEqual(art, original)

    art.elements[0].objectView = nil
    let before = art.elements[0].path
    try PathCommands.edit("reverse", artwork: &art, elements: [view.id])
    XCTAssertNotEqual(art.elements[0].path, before)
  }

  func testMixedPathOperationFailsWithoutMutatingEitherElement() throws {
    var view = path()
    view.objectView = ObjectViewSettings(sourceID: UUID(), linked: false)
    let ordinary = path()
    var art = Artwork(elements: [view, ordinary])
    let original = art
    XCTAssertThrowsError(try PathCommands.edit("combine", artwork: &art,
      elements: [view.id, ordinary.id]))
    XCTAssertEqual(art, original)
  }
}
