import AppKit
import XCTest

@testable import FormApp
@testable import FormCore

@MainActor final class PrintMeshBuilderTests: XCTestCase {
  private func mesh(
    _ object: ProductObject, project: Project, component: String = "Complete object"
  ) throws -> PrintMesh {
    _ = NSApplication.shared
    var config = PrintConfiguration()
    config.component = component
    return try PrintMeshBuilder.mesh(
      object: object, project: project,
      assets: FileManager.default.temporaryDirectory, configuration: config)
  }
  private func size(
    _ mesh: PrintMesh, _ x: Double, _ y: Double, _ z: Double, file: StaticString = #filePath,
    line: UInt = #line
  ) {
    XCTAssertEqual(mesh.size.x, x, accuracy: 0.02, file: file, line: line)
    XCTAssertEqual(mesh.size.y, y, accuracy: 0.02, file: file, line: line)
    XCTAssertEqual(mesh.size.z, z, accuracy: 0.02, file: file, line: line)
  }
  func testUnseenPrimitivesHavePhysicalDimensionsAndRealChamferGeometry() throws {
    let p = Project(name: "Primitive export")
    var box = try p.makeObject(
      recipeID: "box", parameters: ["width": 20, "height": 30, "depth": 40, "corner": 0])
    let plain = try mesh(box, project: p)
    size(plain, 20, 40, 30)
    box.parameters["corner"] = 3
    let rounded = try mesh(box, project: p)
    size(rounded, 20, 40, 30)
    XCTAssertGreaterThan(rounded.triangles.count, plain.triangles.count)
    XCTAssertEqual(try rounded.binarySTL().count, 84 + 50 * rounded.triangles.count)
    let cylinder = try p.makeObject(
      recipeID: "cylinder", parameters: ["diameter": 35, "height": 12])
    size(try mesh(cylinder, project: p), 35, 35, 12)
  }
  func testCustomConeSphereAndTorusBakeTheirParametersWithoutAViewport() throws {
    for (kind, values, expected): (String, [String: String], [Double]) in [
      (
        "cone",
        ["bottomRadius": "size", "topRadius": "size/2", "height": "size*3", "y": "size*1.5"],
        [16, 16, 24]
      ),
      ("sphere", ["radius": "size", "y": "size"], [16, 16, 16]),
      ("torus", ["ringRadius": "size", "pipeRadius": "size/4", "y": "size/4"], [20, 20, 4]),
    ] {
      var p = Project(name: kind)
      p.recipes = [
        .init(
          "primitiveTest", "Primitive", "cube", "Test", [.init("size", "Size", 8, 1...100)],
          parts: [.init(kind, values)])
      ]
      let object = try p.makeObject(recipeID: "primitiveTest")
      let result = try mesh(object, project: p)
      size(result, expected[0], expected[1], expected[2])
      XCTAssertGreaterThan(result.triangles.count, 10)
    }
  }
  func testRecipePartTransformsAndPrintRotationScaleApplyExactlyOnce() throws {
    var p = Project(name: "Transforms")
    p.recipes = [
      .init(
        "turnedPart", "Turned", "cube", "Test", [],
        parts: [
          .init(
            "box",
            [
              "width": "20", "height": "10", "depth": "30", "rotationZ": "90", "y": "10",
              "corner": "0",
            ])
        ])
    ]
    let object = try p.makeObject(recipeID: "turnedPart")
    size(try mesh(object, project: p), 10, 30, 20)
    var config = PrintConfiguration()
    config.scalePercent = 200
    config.rotation.x = 90
    let result = try PrintMeshBuilder.mesh(
      object: object, project: p,
      assets: FileManager.default.temporaryDirectory, configuration: config)
    size(result, 20, 40, 60)
  }
  func testHollowShadeRemainsPhysicalAndPlaneArtworkIsExcluded() throws {
    var p = Project(name: "Hollow shade")
    var lamp = try p.makeObject(
      recipeID: "lamp",
      parameters: ["height": 200, "shadeHeight": 60, "shadeDiameter": 100, "topDiameter": 40])
    lamp.artwork = .init(elements: [.init(kind: "rectangle", x: 0, y: 0, width: 100, height: 100)])
    p.objects = [lamp]
    let shade = try mesh(lamp, project: p, component: "Shade")
    size(shade, 100, 100, 60)
    XCTAssertGreaterThan(shade.triangles.count, 500)
  }
}
