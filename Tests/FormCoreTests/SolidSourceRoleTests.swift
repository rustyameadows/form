import XCTest
@testable import FormCore

final class SolidSourceRoleTests: XCTestCase {
  func testSolidWithArtworkCannotBecomeAnIndependentFlatSource() throws {
    let recipe = Recipe("authoredSolid", "Authored solid", "cube", "Generic source",
      [.init("radius", "Radius", 5, 1...20)], solid: .init(nodes: [
        .init(kind: "ellipsoid", values: ["x":"0", "y":"0", "z":"0",
          "radiusX":"radius", "radiusY":"radius", "radiusZ":"radius"])
      ]))
    var project = Project(name: "Source roles")
    project.recipes = [recipe]
    let object = ProductObject(name: "Authored geometry", recipeID: recipe.id,
      parameters: recipe.defaults, artwork: Artwork(elements: [
        .init(kind:"rectangle",x:0,y:0,width:10,height:10)
      ]))
    XCTAssertTrue(recipe.parts.isEmpty)
    XCTAssertFalse(project.isIndependentFlatArtworkSource(object))
    let restored = try JSONDecoder.form.decode(Project.self, from: JSONEncoder.form.encode(project))
    XCTAssertFalse(restored.isIndependentFlatArtworkSource(object))
    var source = recipe; source.solid = nil; project.recipes = [source]
    XCTAssertTrue(project.isIndependentFlatArtworkSource(object),
      "An explicitly geometry-free custom recipe must retain the existing canonical artwork path.")
  }

  func testOrdinaryArtboardsRetainTheirSourceRole() throws {
    var project = Project(name:"Artboards")
    var board = try project.makeObject(recipeID:"artboard")
    board.artwork = Artwork(elements:[.init(kind:"rectangle",x:1,y:1,width:4,height:4)])
    XCTAssertTrue(project.isIndependentFlatArtworkSource(board))
    var noArtwork = board; noArtwork.artwork = nil
    XCTAssertFalse(project.isIndependentFlatArtworkSource(noArtwork))
  }
}
