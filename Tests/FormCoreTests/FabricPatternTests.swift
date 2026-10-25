import XCTest
@testable import FormCore

final class FabricPatternTests: XCTestCase {
  private func fixture() throws -> (Project, UUID, UUID) {
    var project = Samples.flightJacket()
    var tile = try project.makeObject(recipeID: "artboard", name: "Fabric motif", parameters: ["width": 40, "depth": 20])
    var artwork = Artwork(background: "#EEE5CA", bleed: 0)
    artwork.elements = [ArtworkElement(kind: "rectangle", x: 2, y: 3, width: 8, height: 5, color: "#D53A30"),
      ArtworkElement(kind: "ellipse", x: 26, y: 12, width: 6, height: 4, color: "#263C85")]
    tile.artwork = artwork; project.objects.append(tile)
    return (project, tile.id, project.objects[0].id)
  }
  func testModesHaveTruePhysicalPeriodsAndOffsetRowsOrColumns() throws {
    var p = FabricPattern(sourceObjectID: UUID()); p.scale = 1.5; p.spacing = .init(4, 6)
    let source = Point2(40, 20)
    XCTAssertEqual(p.cellSize(sourceSize: source), .init(64, 36))
    XCTAssertEqual(p.supertileSize(sourceSize: source), .init(64, 36))
    XCTAssertEqual(p.motifTransforms(sourceSize: source), [.scale(1.5, 1.5)])
    p.repeatMode = .halfDrop
    XCTAssertEqual(p.supertileSize(sourceSize: source), .init(128, 36))
    let half = p.motifTransforms(sourceSize: source)
    XCTAssertTrue(half.contains { abs($0.tx - 64) < 1e-9 && abs($0.ty - 18) < 1e-9 })
    XCTAssertTrue(half.contains { abs($0.tx - 64) < 1e-9 && abs($0.ty + 18) < 1e-9 })
    p.repeatMode = .brick
    XCTAssertEqual(p.supertileSize(sourceSize: source), .init(64, 72))
    XCTAssertTrue(p.motifTransforms(sourceSize: source).contains { abs($0.tx - 32) < 1e-9 && abs($0.ty - 36) < 1e-9 })
    p.repeatMode = .mirror
    XCTAssertEqual(p.supertileSize(sourceSize: source), .init(128, 72))
    let mirror = p.motifTransforms(sourceSize: source)
    XCTAssertEqual(mirror.count, 4)
    XCTAssertEqual(mirror.filter { $0.a < 0 }.count, 2); XCTAssertEqual(mirror.filter { $0.d < 0 }.count, 2)
    XCTAssertTrue(mirror.contains { $0.apply(.init(40, 20)) == .init(64, 36) })
  }
  func testLatticeAndBomberUVShareScaleRotationAndPhaseAtPhysicalPoints() throws {
    var pattern = FabricPattern(sourceObjectID: UUID()); pattern.scale = 2; pattern.spacing = .init(10, 5)
    pattern.repeatMode = .halfDrop; pattern.rotation = 31; pattern.offset = .init(13, -27)
    let source = Point2(40, 20), size = pattern.supertileSize(sourceSize: source)
    let mapping = pattern.bomberTextureTransform(sourceSize: source)
    for lattice in [Point2(0, 0), .init(size.x, 0), .init(0, size.y), .init(17, 29)] {
      let physical = pattern.latticeTransform.apply(lattice)
      let uv = mapping.apply(.init(physical.x * 0.03, physical.y * 0.03))
      XCTAssertEqual(uv.x, lattice.x / size.x, accuracy: 1e-9); XCTAssertEqual(uv.y, lattice.y / size.y, accuracy: 1e-9)
    }
    let origins = try pattern.tileOrigins(sourceSize: source, width: 400, height: 300)
    let output = Rect2(0, 0, 400, 300), inverse = pattern.latticeTransform.inverse!
    for corner in [Point2(0, 0), .init(output.maxX - 0.01, 0), .init(0, output.maxY - 0.01), .init(output.maxX - 0.01, output.maxY - 0.01)] {
      let p = inverse.apply(corner)
      XCTAssertTrue(origins.contains { p.x >= $0.x && p.x < $0.x + size.x && p.y >= $0.y && p.y < $0.y + size.y })
    }
  }
  func testColorwaysResolveSharedPaintsWithoutMutatingSourceOrOtherGarmentResources() throws {
    var (project, tileID, _) = try fixture()
    let tileIndex = project.objects.firstIndex { $0.id == tileID }!
    var stroke = ArtworkStroke(color: "#D53A30", width: 1); stroke.enabled = true
    project.objects[tileIndex].artwork!.elements[0].stroke = stroke
    project.swatches = [ArtworkSwatch(name: "Red", color: "#D53A30")]
    project.objects[tileIndex].artwork!.elements[0].fillSwatchID = project.swatches![0].id
    let original = project
    var pattern = FabricPattern(sourceObjectID: tileID)
    var colorway = FabricColorway(name: "Night", baseColor: "#13293A"); colorway.replacements = ["#d53a30": "#EFBF66", "#263C85": "#F4F0DB"]
    pattern.colorways = [colorway]; pattern.activeColorwayID = colorway.id
    try project.setFabricPattern(pattern, materialID: "flight-nylon")
    let rendered = try XCTUnwrap(project.resolvedFabricPattern(materialID: "flight-nylon"))
    XCTAssertEqual(rendered.baseColor, "#13293A"); XCTAssertEqual(rendered.artwork.backgroundOpacity, 0)
    XCTAssertEqual(rendered.artwork.elements[0].color, "#EFBF66"); XCTAssertEqual(rendered.artwork.elements[0].stroke?.color, "#EFBF66")
    XCTAssertNil(rendered.artwork.elements[0].fillSwatchID)
    XCTAssertEqual(project.objects, original.objects); XCTAssertEqual(project.swatches, original.swatches)
    pattern.activeColorwayID = nil; try project.setFabricPattern(pattern, materialID: "flight-nylon")
    XCTAssertEqual(try project.resolvedFabricPattern(materialID: "flight-nylon")!.artwork.elements[0].color, "#D53A30")
  }
  func testMCPPatternMutationIsAtomicUndoableAndPersistsSchemaTwentyOne() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at: root) }
    let engine = OperationEngine(repository: try ProjectRepository(root: root)), fixture = try fixture(); engine.project = fixture.0
    let baseline = engine.project!, pattern = FabricPattern(sourceObjectID: fixture.1)
    _ = try engine.call("form_update_object", arguments: ["object_id": fixture.2.uuidString, "fabric_pattern": try jsonObject(pattern)])
    XCTAssertEqual(engine.project!.minimumSchemaVersion, 21)
    try engine.repository.save(engine.project!); let reopened = try engine.repository.load(baseline.id)
    XCTAssertEqual(reopened.material("flight-nylon").fabric?.pattern, pattern)
    XCTAssertEqual(reopened.objects, baseline.objects)
    engine.undo(); XCTAssertEqual(engine.project, baseline)
    XCTAssertThrowsError(try engine.call("form_update_object", arguments: ["object_id": fixture.2.uuidString, "fabric_pattern": ["sourceObjectID": UUID().uuidString], "name": "Must roll back"]))
    XCTAssertEqual(engine.project, baseline)
  }
  func testBrokenLinksAndWorkspaceSourcesAreRejectedWithoutDeletingAnyResources() throws {
    var (project, tileID, garmentID) = try fixture()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at: root) }
    let engine = OperationEngine(repository: try ProjectRepository(root: root))
    try project.setFabricPattern(.init(sourceObjectID: tileID), materialID: "flight-nylon"); engine.project = project
    XCTAssertThrowsError(try engine.call("form_delete_objects", arguments: ["object_ids": [tileID.uuidString]])); XCTAssertEqual(engine.project, project)
    let workspace = try project.ensureCanvasWorkspace()
    XCTAssertThrowsError(try project.setFabricPattern(.init(sourceObjectID: workspace.id), materialID: "flight-nylon"))
    XCTAssertThrowsError(try engine.call("form_update_object", arguments: ["object_id": garmentID.uuidString, "name": "Invalid", "fabric_pattern": ["sourceObjectID": UUID().uuidString]]))
    XCTAssertEqual(engine.project!.objects.first!.name, project.objects.first!.name)
    _ = try engine.call("form_update_object", arguments: ["object_id": garmentID.uuidString, "fabric_pattern": NSNull()])
    XCTAssertNil(engine.project!.material("flight-nylon").fabric?.pattern)
    XCTAssertEqual(engine.project!.objects, project.objects.filter { !$0.isCanvasWorkspace })
  }
  func testLibraryInventoryMergeRetainsProjectPatternAndNeverAddsItToGlobalInput() throws {
    var (project, tileID, _) = try fixture(); let library = StudioLibrary()
    try project.setFabricPattern(.init(sourceObjectID: tileID), materialID: "flight-nylon")
    var incoming = library.materials; let i = incoming.firstIndex { $0.id == "flight-nylon" }!
    incoming[i].fabric?.inventoryMeters = 18.5
    let merged = project.mergingStudioMaterials(incoming)
    XCTAssertEqual(merged.first { $0.id == "flight-nylon" }!.fabric?.inventoryMeters, 18.5)
    XCTAssertEqual(merged.first { $0.id == "flight-nylon" }!.fabric?.pattern?.sourceObjectID, tileID)
    XCTAssertNil(incoming[i].fabric?.pattern); XCTAssertNil(library.materials[i].fabric?.pattern)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }; try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    var leaking = library; leaking.materials = merged
    XCTAssertThrowsError(try leaking.save(to: root)); XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Studio.json").path))
    var legacy = FabricProfile(composition: "Nylon", structure: .woven)
    let encoded = try JSONEncoder.form.encode(legacy); legacy = try JSONDecoder.form.decode(FabricProfile.self, from: encoded)
    XCTAssertNil(legacy.pattern)
  }
  func testInvalidNumbersAmbiguousColorwaysAndExcessiveRepeatWorkFailBeforeRendering() throws {
    var pattern = FabricPattern(sourceObjectID: UUID()); pattern.scale = .nan; XCTAssertThrowsError(try pattern.validate())
    pattern.scale = 1; pattern.spacing.x = -1; XCTAssertThrowsError(try pattern.validate())
    pattern.spacing.x = 0; pattern.offset.y = .infinity; XCTAssertThrowsError(try pattern.validate())
    pattern.offset.y = 0; pattern.activeColorwayID = UUID(); XCTAssertThrowsError(try pattern.validate())
    pattern.activeColorwayID = nil
    var colorway = FabricColorway(name: "Conflict"); colorway.replacements = ["#aaaaaa": "#123456", "#AAAAAA": "#456789"]
    pattern.colorways = [colorway]; XCTAssertThrowsError(try pattern.validate())
    pattern.colorways = []; pattern.scale = 0.01
    XCTAssertThrowsError(try pattern.tileOrigins(sourceSize: .init(10, 10), width: 10000, height: 10000))
    XCTAssertThrowsError(try pattern.tileOrigins(sourceSize: .init(0, 0), width: 100, height: 100))
  }
}
