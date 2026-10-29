import AppKit
import FormCore
import FormGeometry
import LabRendering
import simd
import XCTest
@testable import FormApp

@MainActor final class AuthoredPaperRenderingTests: XCTestCase {
  private func engine(_ project: Project) throws -> OperationEngine {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("authored-paper-render-" + UUID().uuidString)
    let engine = OperationEngine(repository: try ProjectRepository(root: directory))
    engine.project = project
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    return engine
  }
  private func panels(_ root: MeshNode) -> [MeshNode] {
    var nodes: [MeshNode] = []
    root.enumerateChildNodes { node, _ in
      if node.name?.hasPrefix(PaperGeometry.panelPrefix) == true { nodes.append(node) }
    }
    return nodes
  }
  private func converted(_ project: Project) throws -> (Project, ProductObject) {
    let engine = try engine(project)
    let original = try XCTUnwrap(project.objects.first { PaperConstruction.isPaper($0) })
    _ = try engine.call("form_construction", arguments: ["command": "convert", "object_id": original.id.uuidString])
    let result = try XCTUnwrap(engine.project)
    let object = try XCTUnwrap(result.objects.first { $0.id == original.id })
    XCTAssertFalse(PaperConstruction.recipeIDs.contains(object.recipeID))
    XCTAssertEqual(object.paperConstruction?.kind, .authored)
    return (result, object)
  }
  func testConvertedExamplesReachTheRealTableGeometryFactoryWithArtwork() throws {
    for sample in [try PaperSamples.sunStudies(), try PaperSamples.cosmetics()] {
      let (project, object) = try converted(sample)
      let source = project
      let root = GeometryFactory.object(object, project: project, assets: FileManager.default.temporaryDirectory, textureLimit: 256)
      let nodes = panels(root), net = try PaperConstruction.definition(for: object).net()
      XCTAssertEqual(nodes.count, net.panels.count, "Converted \(sample.name) disappeared from the Table renderer")
      XCTAssertFalse(nodes.isEmpty)
      for node in nodes {
        XCTAssertEqual(node.geometry?.materials.count, 3)
        XCTAssertTrue(node.geometry?.materials.first?.diffuse.contents is NSImage)
        XCTAssertGreaterThan(node.geometry?.elements.reduce(0) { $0 + $1.primitiveCount } ?? 0, 0)
      }
      XCTAssertEqual(project, source)
    }
  }
  func testUnregisteredConstructionRendersPanelsAndReusesThemAcrossFoldPoses() throws {
    let engine = try engine(Project(name: "Unregistered Table proof"))
    let result = try XCTUnwrap(engine.call("form_construction", arguments: ["command": "create", "definition": try jsonObject(ConstructionCommands.example())]) as? [String: Any])
    let id = try XCTUnwrap(UUID(uuidString: try XCTUnwrap(result["object_id"] as? String)))
    var project = try XCTUnwrap(engine.project), object = try XCTUnwrap(project.objects.first { $0.id == id })
    let assets = FileManager.default.temporaryDirectory
    let first = GeometryFactory.object(object, project: project, assets: assets, textureLimit: 128)
    let firstPanels = panels(first)
    XCTAssertEqual(firstPanels.count, 4)
    XCTAssertNotNil(first.childNode(withName: PaperGeometry.constructionName, recursively: true))
    _ = try engine.call("form_construction", arguments: ["command": "parameter", "object_id": id.uuidString, "values": ["fold": 35]])
    project = try XCTUnwrap(engine.project); object = try XCTUnwrap(project.objects.first { $0.id == id })
    let next = panels(GeometryFactory.object(object, project: project, assets: assets, textureLimit: 128))
    XCTAssertEqual(next.count, firstPanels.count)
    for (a, b) in zip(firstPanels, next) {
      XCTAssertTrue(a.geometry?.sources.first === b.geometry?.sources.first, "Folding must reuse the physical panel buffers")
    }
  }
  func testConvertedCyanotypeArtworkAppearsInAnActualFoldedNativeCapture() async throws {
    let (project, object) = try converted(PaperSamples.sunStudies())
    let root = GeometryFactory.object(object, project: project, assets: FileManager.default.temporaryDirectory, textureLimit: 1024)
    let front = try XCTUnwrap(panels(root).first { $0.name == PaperGeometry.panelPrefix + "front" })
    let panel = try XCTUnwrap(PaperConstruction.definition(for: object).net().panels.first { $0.id == "front" })
    let b = panel.bounds
    func point(_ x: Double, _ y: Double, _ z: Double = 0) -> SIMD3<Double> {
      front.convertPosition(.init(x / 100, -y / 100, z / 100), to: nil).simd * 100
    }
    let center = point(b.x + b.width / 2, b.y + b.height / 2)
    let normal = simd_normalize(point(b.x + b.width / 2, b.y + b.height / 2, 1) - center)
    let up = simd_normalize(point(b.x + b.width / 2, b.y + b.height / 2 - 1) - center)
    let scene = MeshScene(); scene.rootNode.addChildNode(root)
    let renderer = try RealityKitSceneRenderer(), adapter = GeometryPayloadAdapter()
    for payload in adapter.renderables(scene: scene) { try renderer.upsert(payload) }
    try renderer.setCamera(.looking(from: center + normal * 1000, at: center, up: up,
      projection: .orthographic(verticalSpanMM: max(b.width, b.height) * 1.12)))
    let image = try await renderer.capture(width: 640, height: 800, transparent: true)
    let bitmap = NSBitmapImageRep(cgImage: image)
    var bluePixels = 0
    for y in 0..<bitmap.pixelsHigh { for x in 0..<bitmap.pixelsWide {
      if let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), c.alphaComponent > 0.9,
        c.blueComponent > c.redComponent + 0.12, c.blueComponent > c.greenComponent + 0.06 { bluePixels += 1 }
    } }
    XCTAssertGreaterThan(bluePixels, 1500, "The native folded object must visibly show the blue title and leaf, not merely have a valid source")
  }
}
