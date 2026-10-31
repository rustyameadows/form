import Foundation
import FormCore
import XCTest
@testable import FormApp

@MainActor final class ObjectViewUpdateTests: XCTestCase {
  func testFailedRefreshReportsFailureAndKeepsPriorPath() throws {
    let triangles: [(SIMD3<Double>, SIMD3<Double>, SIMD3<Double>)] = [
      (.init(0, 0, 0), .init(2, 0, 0), .init(2, 1, 0)),
      (.init(0, 0, 0), .init(2, 1, 0), .init(0, 1, 0)),
    ]
    var source = ProductObject(name: "Source", recipeID: "unavailable", parameters: [:])
    var view = try ObjectViewProjection.project(triangles, azimuth: 0, elevation: 0,
      style: "silhouette", name: "Source")
    view.objectView = ObjectViewSettings(sourceID: source.id, style: "invalid", linked: true)
    let page = ProductObject(name: "Page", recipeID: "artboard", parameters: [:],
      artwork: Artwork(elements: [view]))
    var before = Project(name: "Views")
    before.objects = [source, page]
    source.parameters["width"] = 200
    var after = before
    after.objects[0] = source
    let failures = ObjectViewUpdates.refreshChangedSources(before: before, project: &after,
      assets: URL(fileURLWithPath: "/tmp"))
    XCTAssertEqual(failures.count, 1)
    XCTAssertTrue(failures[0].contains("Source"))
    XCTAssertEqual(after.objects[1].artwork?.elements.first?.path, view.path)
  }
  func testRecipeGeometryChangeRefreshesLinkedView() throws {
    let recipe = Recipe("view-test", "Test object", "cube", "Test", [], parts: [
      .init("box", ["width":"100", "height":"40", "depth":"20", "corner":"0"])
    ])
    let source = ProductObject(name: "Source", recipeID: recipe.id, parameters: [:])
    var before = Project(name: "Views")
    before.recipes = [recipe]
    before.objects = [source]
    var view = try ObjectViewProjection.make(object: source, project: before,
      assets: URL(fileURLWithPath: "/tmp"), azimuth: 0, elevation: 0, style: "silhouette")
    view.objectView = .init(sourceID: source.id, linked: true)
    let page = ProductObject(name: "Page", recipeID: "artboard", parameters: [:],
      artwork: Artwork(elements: [view]))
    before.objects.append(page)
    var after = before
    after.recipes[0].parts[0].values["height"] = "80"
    XCTAssertEqual(ObjectViewUpdates.refreshChangedSources(before: before, project: &after,
      assets: URL(fileURLWithPath: "/tmp")), [])
    XCTAssertNotEqual(after.objects[1].artwork?.elements.first?.path, view.path)
  }

}
