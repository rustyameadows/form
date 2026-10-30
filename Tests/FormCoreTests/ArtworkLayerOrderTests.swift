import XCTest
@testable import FormCore

final class ArtworkLayerOrderTests: XCTestCase {
  func testSiblingStepOrderPreservesSelectedBlocksAcrossInterleavedHierarchies() throws {
    func rectangle() -> ArtworkElement { .init(kind: "rectangle", x: 0, y: 0, width: 10, height: 10) }
    var group = ArtworkElement(kind: "group", x: 0, y: 0, width: 20, height: 20)
    group.contentSize = .init(20, 20)
    var child = rectangle(); child.parentID = group.id
    let a = rectangle(), b = rectangle(), c = rectangle()
    var art = Artwork(elements: [a, child, b, c, group])
    let before = art
    try ArtworkCommands.apply("reorder", to: &art, ids: [a.id, b.id], arguments: ["mode": "forward"])
    XCTAssertEqual(art.elements.filter { $0.parentID == nil }.map(\.id), [c.id, a.id, b.id, group.id])
    XCTAssertEqual(art.elements[1], child)
    try ArtworkCommands.apply("reorder", to: &art, ids: [a.id, b.id], arguments: ["mode": "backward"])
    XCTAssertEqual(art, before)
  }
}
