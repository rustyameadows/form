import XCTest
@testable import FormCore

final class GarmentAssemblyCompatibilityTests: XCTestCase {
  private func fixture() throws -> (Project, UUID, ArtworkElement, ArtworkElement) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let engine = OperationEngine(repository: try ProjectRepository(root: root))
    var project = Project(name: "Declared garment and original assembly")
    let owner = try project.ensureCanvasWorkspace()
    engine.project = project
    _ = try engine.call("form_edit_artwork", arguments: [
      "object_id": owner.id.uuidString, "command": "garment_block", "operation": "create",
      "block": ["style": ["materialID": "flight-nylon"]],
    ])
    project = engine.project!
    let block = project.garmentBlocks![0], art = project.canvasWorkspace!.artwork!
    func piece(_ role: GarmentPieceRole) -> ArtworkElement {
      let binding = block.bindings.first { $0.sizeID == block.baseSizeID && $0.role == role }!
      return art.elements.first { $0.id == binding.elementID }!
    }
    return (project, owner.id, piece(.front), piece(.back))
  }

  func testRawConstructionBoundaryCanSupportOriginalClothWithoutBecomingASeam() throws {
    var (project, owner, front, _) = try fixture()
    let before = project
    var definition = try PatternAssemblyPlanning.arrangedPieces(
      in: &project, sourceID: owner, elements: [front.id])
    definition.maximumEdgeMm = 100
    XCTAssertEqual(project, before)
    XCTAssertTrue(definition.seamIDs.isEmpty)
    let art = project.canvasWorkspace!.artwork!
    let geometry = try SewingPatterns.geometry(front, in: art)
    let top = try XCTUnwrap(geometry.sourceEdges.first { $0.index == 0 })
    XCTAssertTrue(geometry.piece.isUnstitched(edge: 0, edgeID: top.id, endID: top.endID))
    XCTAssertEqual(definition.pins.first?.edgeID, top.id)
    let product = try PatternAssemblyGenerator.generate(definition, in: project)
    XCTAssertEqual(product.panels.count, 1)
    XCTAssertEqual(product.panels[0].sourceAreaMm2, 550 * 718, accuracy: 1e-6)
    XCTAssertEqual(product.study.mesh.massesKg.reduce(0, +), 550 * 718 * 180e-9, accuracy: 1e-10)
    XCTAssertEqual(product.study.mesh.pins.count, 1)
    XCTAssertEqual(project.minimumSchemaVersion, 41)
    XCTAssertEqual(project, before)
  }

  func testUnstitchedTopCannotEnterTheAssemblySeamGraph() throws {
    var (project, owner, front, back) = try fixture()
    var definition = try PatternAssemblyPlanning.arrangedPieces(
      in: &project, sourceID: owner, elements: [front.id, back.id])
    func endpoint(_ piece: ArtworkElement) -> SewingSeamEnd {
      let nodes = piece.path!.contours[0].nodes
      var end = SewingSeamEnd(elementID: piece.id, edge: 0)
      end.edgeID = nodes[0].id; end.endID = nodes[1].id
      return end
    }
    let seam = SewingSeam(name: "Invalid raw-top sewing", first: endpoint(front), second: endpoint(back))
    let index = project.objects.firstIndex { $0.id == owner }!
    project.objects[index].artwork!.sewingSeams!.append(seam)
    definition.seamIDs = [seam.id]
    let before = project
    XCTAssertThrowsError(try PatternAssemblyGenerator.generate(definition, in: project))
    XCTAssertEqual(project, before)
  }
}
