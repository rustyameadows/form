import Foundation
import XCTest
import FormCADModel
@testable import FormCore

final class PaperAppearanceTests: XCTestCase {
  private func fixture() throws -> OperationEngine {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("paper-appearance-" + UUID().uuidString)
    let engine = OperationEngine(repository: try ProjectRepository(root: root))
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    var project = Project(name: "Paper appearance")
    var paper = try project.makeObject(recipeID: "paperEnvelope")
    paper.artwork = .init(background: "#FFFFFF", elements: [
      .init(kind: "text", x: 20, y: 80, width: 130, height: 30, text: "Editable letterpress", color: "#223344", fontSize: 20),
      .init(kind: "ellipse", x: 60, y: 130, width: 20, height: 20, color: "#B59048")])
    project.objects = [paper]; engine.project = project
    return engine
  }
  @discardableResult private func call(_ engine: OperationEngine, _ command: String, _ arguments: [String: Any] = [:]) throws -> Any {
    var input = arguments
    input["command"] = command
    if input["object_id"] == nil, let id = engine.project?.objects.first?.id { input["object_id"] = id.uuidString }
    return try engine.call("form_paper", arguments: input)
  }
  func testLegacyStockAndProjectRemainUnchangedWithoutAppearanceDeclarations() throws {
    let engine = try fixture(), original = engine.project!
    let bytes = try JSONEncoder.form.encode(original.objects[0].paperConstruction!.stock)
    let decoded = try JSONDecoder.form.decode(PaperStock.self, from: bytes)
    XCTAssertNil(decoded.profile); XCTAssertNil(decoded.plies)
    XCTAssertEqual(decoded.resolvedThicknessMM, 0.35)
    _ = try call(engine, "appearance")
    _ = try call(engine, "inspect")
    let presets = try XCTUnwrap(try call(engine, "stock_presets") as? [String: Any])
    XCTAssertEqual((presets["stocks"] as? [[String: Any]])?.count, 7)
    XCTAssertEqual(presets["manufacturing_verified"] as? Bool, false)
    XCTAssertEqual(engine.project, original); XCTAssertTrue(engine.undoStack.isEmpty)
    XCTAssertEqual(original.minimumSchemaVersion, 53)
  }
  func testFinishTracksCanonicalTextAndMaskEditsRetainsMissingTargetsAndIsOneUndo() throws {
    let engine = try fixture(), original = engine.project!, paperID = original.objects[0].id
    let textID = original.objects[0].artwork!.elements[0].id
    _ = try call(engine, "set_finish", ["finish": ["name": "Letterpress text", "kind": "letterpress", "elementIDs": [textID.uuidString], "depthMM": 0.06]])
    XCTAssertEqual(engine.undoStack.count, 1)
    let assigned = engine.project!, finish = try XCTUnwrap(assigned.objects[0].paperConstruction!.finishes?.first)
    XCTAssertEqual(finish.elementIDs, [textID]); XCTAssertEqual(finish.side, .outside)
    let first = try PaperAppearance.inspect(project: assigned, object: assigned.objects[0])
    XCTAssertEqual(first.finishes[0].resolvedElementIDs, [textID])
    XCTAssertFalse(first.manufacturingVerified)
    XCTAssertTrue(first.issues.contains { $0.code == "reliefIsAppearance" })
    engine.undo(); XCTAssertEqual(engine.project, original)
    engine.redo(); XCTAssertEqual(engine.project, assigned)
    try engine.edit("Changed wording") { project in
      var art = project.objects[0].artwork!; art.elements[0].text = "Changed wording, same mask"
      try project.setArtwork(art, for: paperID)
    }
    let changed = try PaperAppearance.inspect(project: engine.project!, object: engine.project!.objects[0])
    XCTAssertEqual(changed.finishes[0].assignment, finish)
    XCTAssertNotEqual(first.finishes[0].sourceRevision, changed.finishes[0].sourceRevision)
    try engine.edit("Removed target") { project in
      var art = project.objects[0].artwork!; art.elements.removeAll { $0.id == textID }
      try project.setArtwork(art, for: paperID)
    }
    let missing = try PaperAppearance.inspect(project: engine.project!, object: engine.project!.objects[0])
    XCTAssertEqual(missing.finishes[0].missingElementIDs, [textID])
    XCTAssertTrue(missing.finishes[0].resolvedElementIDs.isEmpty)
    XCTAssertTrue(missing.issues.contains { $0.code == "missingFinishTargets" })
    XCTAssertEqual(missing.finishes[0].assignment.id, finish.id)
  }
  func testInsideFinishResolvesIndependentBackSourceAndPartialEditsKeepIdentity() throws {
    let engine = try fixture(), textID = engine.project!.objects[0].artwork!.elements[0].id
    XCTAssertThrowsError(try call(engine, "set_finish", ["finish": ["kind": "foil", "side": "inside", "elementIDs": [textID.uuidString]]]))
    _ = try call(engine, "ensure_inside")
    let sourceID = engine.project!.objects[0].paperConstruction!.insideArtworkSourceID!
    XCTAssertEqual(engine.project!.objects.first { $0.id == sourceID }?.artwork?.backgroundOpacity, 0)
    let mark = ArtworkElement(kind: "rectangle", x: 25, y: 100, width: 12, height: 12, color: "#FFFFFF")
    try engine.edit("Back artwork") { project in
      try project.setArtwork(.init(background: "#FFFFFF", elements: [mark]), for: sourceID)
    }
    _ = try call(engine, "set_finish", ["finish": ["name": "Back foil", "kind": "foil", "side": "inside", "elementIDs": [mark.id.uuidString], "metallic": 1.0, "roughness": 0.15]])
    let finish = engine.project!.objects[0].paperConstruction!.finishes![0]
    _ = try call(engine, "set_finish", ["finish": ["id": finish.id.uuidString, "depthMM": 0.03]])
    let report = try PaperAppearance.inspect(project: engine.project!, object: engine.project!.objects[0])
    XCTAssertEqual(report.finishes[0].sourceObjectID, sourceID)
    XCTAssertEqual(report.finishes[0].resolvedElementIDs, [mark.id])
    XCTAssertEqual(report.finishes[0].assignment.id, finish.id)
    XCTAssertEqual(report.finishes[0].assignment.side, .inside)
    XCTAssertEqual(report.finishes[0].assignment.depthMM, 0.03)
    XCTAssertEqual(report.finishes[0].assignment.metallic, 1)
  }
  func testBondedPliesUseSummedCaliperAndPersistExactAppearanceAfterReopen() throws {
    let engine = try fixture()
    _ = try call(engine, "configure", ["stock": ["name": "Bonded contrast", "profile": ["texture": "cotton", "color": "#F3EBD7"], "plies": [
      ["name": "Dark back", "color": "#243C47", "thicknessMM": 0.45],
      ["name": "Warm front", "color": "#F3EBD7", "thicknessMM": 0.35]]]])
    let paper = engine.project!.objects[0], stock = paper.paperConstruction!.stock
    XCTAssertEqual(stock.thicknessMM, 0.8, accuracy: 1e-12)
    XCTAssertEqual(stock.resolvedThicknessMM, 0.8, accuracy: 1e-12)
    XCTAssertEqual(paper["stock"], 0.8, accuracy: 1e-12)
    XCTAssertEqual(stock.plies?.map(\.color), ["#243C47", "#F3EBD7"])
    XCTAssertEqual(stock.profile?.texture, .cotton)
    XCTAssertEqual(engine.undoStack.count, 1)
    XCTAssertEqual(engine.project!.minimumSchemaVersion, 57)
    try engine.flush()
    let reopened = try engine.repository.load(engine.project!.id)
    XCTAssertEqual(reopened.objects, engine.project!.objects)
    XCTAssertEqual(reopened.schemaVersion, 57)
  }
  func testAuthoredCaliperMustAgreeAtomicallyWithoutRewritingItsExpression() throws {
    let engine = try fixture()
    let parameters: [CADModelParameter] = [.init("caliper", 0.35, 0.1...2)]
    let polygon: [CADExpressionPoint2] = [.init(0, 0), .init(90, 0), .init(90, 55), .init(0, 55)]
    let definition = PlanarConstructionDefinition(name: "Card", parameters: parameters,
      size: .init(90, 55), stockThickness: "caliper", panels: [
        .init(id: "card", name: "Card", polygon: polygon)], rootPanelID: "card")
    _ = try engine.call("form_construction", arguments: ["command": "create", "definition": try jsonObject(definition)])
    let objectID = try XCTUnwrap(engine.selection.first)
    let plies: [[String: Any]] = [["name": "Back", "color": "#223344", "thicknessMM": 0.4], ["name": "Front", "color": "#F5EEDD", "thicknessMM": 0.4]]
    let before = engine.project!, undo = engine.undoStack.count
    XCTAssertThrowsError(try call(engine, "configure", ["object_id": objectID.uuidString, "stock": ["plies": plies]]))
    XCTAssertEqual(engine.project, before); XCTAssertEqual(engine.undoStack.count, undo)
    _ = try call(engine, "configure", ["object_id": objectID.uuidString, "stock": ["plies": plies], "parameters": ["caliper": 0.8]])
    let paper = engine.project!.objects.first { $0.id == objectID }!.paperConstruction!
    XCTAssertEqual(paper.authored!.stockThickness.expression, "caliper")
    XCTAssertEqual(try paper.authored!.number(paper.authored!.stockThickness), 0.8)
    XCTAssertEqual(paper.stock.resolvedThicknessMM, 0.8)
    XCTAssertEqual(engine.undoStack.count, undo + 1)
  }
  func testStrictNestedAppearanceAndFinishFailuresAreAtomic() throws {
    let engine = try fixture(), textID = engine.project!.objects[0].artwork!.elements[0].id
    let original = engine.project!
    let invalid: [[String: Any]] = [
      ["command": "configure", "stock": ["profile": ["roughnes": 0.2]]],
      ["command": "configure", "stock": ["profile": ["opacity": true]]],
      ["command": "configure", "stock": ["plies": [["name": "Ply", "color": "#FFFFFF", "thicknessMM": 0.3, "unknown": 1]]]],
      ["command": "configure", "stock": ["plies": [["name": "Ply", "color": "#FFFFFF", "thicknessMM": 0.3]], "thicknessMM": 0.7]],
      ["command": "set_finish", "finish": ["kind": "foil", "elementIDs": [UUID().uuidString]]],
      ["command": "set_finish", "finish": ["kind": "foil", "elementIDs": [textID.uuidString], "depthMM": Double.nan]],
      ["command": "set_finish", "finish": ["kind": "flatInk", "elementIDs": [textID.uuidString], "depthMM": 0.1]],
      ["command": "set_finish", "finish": ["kind": "foil", "elementIDs": [textID.uuidString], "physicalVerified": true]]]
    for var arguments in invalid {
      arguments["object_id"] = original.objects[0].id.uuidString
      XCTAssertThrowsError(try engine.call("form_paper", arguments: arguments))
      XCTAssertEqual(engine.project, original); XCTAssertTrue(engine.undoStack.isEmpty)
    }
  }
  func testFinishAssignmentsStayLocalWhenSharedConstructionChanges() throws {
    let engine = try fixture()
    var project = engine.project!, sibling = project.objects[0]
    sibling.id = UUID(); sibling.relationship = "variant"; sibling.name = "Local finish variant"
    project.objects.append(sibling); engine.project = project
    let elementID = project.objects[0].artwork!.elements[0].id
    _ = try call(engine, "set_finish", ["finish": ["kind": "foil", "elementIDs": [elementID.uuidString]]])
    XCTAssertNil(engine.project!.objects[1].paperConstruction!.finishes)
    _ = try call(engine, "configure", ["parameters": ["width": 230]])
    XCTAssertEqual(engine.project!.objects.map { $0["width"] }, [230, 230])
    XCTAssertNotNil(engine.project!.objects[0].paperConstruction!.finishes)
    XCTAssertNil(engine.project!.objects[1].paperConstruction!.finishes)
  }

  func testModeledContentsPreflightUsesReadOnlyNativePathAndRejectsAmbiguousUnits() throws {
    let engine = try fixture(), before = engine.project!
    let contents = UUID().uuidString
    var requests = [[String: Any]]()
    engine.onGraphics = { name, args in
      XCTAssertEqual(name, "form_paper")
      requests.append(args)
      return ["scope": "modeled_bounds"]
    }
    _ = try call(engine, "preflight", ["contents_object_id": contents, "interior_id": "tray-interior", "clearance_mm": 0.5])
    XCTAssertEqual(requests.count, 1)
    XCTAssertEqual(requests[0]["contents_object_id"] as? String, contents)
    XCTAssertTrue(PaperCommands.isReadOnly(["command": "preflight"]))
    for args: [String: Any] in [
      ["contents_object_id": contents, "contents": ["width": 10, "height": 10, "depth": 10]],
      ["contents_object_id": contents, "clearance_mm": true],
      ["contents_object_id": contents, "interior_id": 1],
      ["clearance_mm": 0.5],
      ["contents": ["width": 10, "height": 10, "depth": 10, "meters": true]]
    ] { XCTAssertThrowsError(try call(engine, "preflight", args)) }
    XCTAssertEqual(requests.count, 1)
    XCTAssertEqual(engine.project, before); XCTAssertTrue(engine.undoStack.isEmpty)
  }

  func testReusablePaperStockUsesExistingMaterialsAndNormalPickerWithOneUndo() throws {
    let engine = try fixture()
    _ = try call(engine, "configure", ["stock": ["profile": ["texture": "cotton", "color": "#E8D9BB"], "thicknessMM": 0.8]])
    let beforeSave = engine.project!, undoBeforeSave = engine.undoStack.count
    let saved = try XCTUnwrap(try call(engine, "save_stock", ["name": "Reusable cotton"]) as? [String: Any])
    let id = try XCTUnwrap((saved["material"] as? [String: Any])?["id"] as? String)
    XCTAssertEqual(engine.project, beforeSave); XCTAssertEqual(engine.undoStack.count, undoBeforeSave)
    XCTAssertFalse(PaperCommands.isReadOnly(["command": "save_stock"]))
    XCTAssertTrue(PaperCommands.preservesDocumentDrafts(["command": "save_stock"]))
    XCTAssertNotNil(StudioLibrary.load(from: engine.repository.root).materials.first { $0.id == id }?.paperStock)
    var p = engine.project!, recipient = try p.makeObject(recipeID: "tuckCarton")
    recipient.name = "New material recipient"; p.objects.append(recipient); engine.project = p
    let before = engine.project!, undo = engine.undoStack.count
    _ = try engine.call("form_update_object", arguments: ["object_id": recipient.id.uuidString, "material_id": id])
    XCTAssertEqual(engine.undoStack.count, undo + 1)
    let assigned = engine.project!.objects.first { $0.id == recipient.id }!
    XCTAssertEqual(assigned["stock"], 0.8)
    XCTAssertEqual(assigned.paperConstruction!.stock.profile?.texture, .cotton)
    XCTAssertEqual(engine.project!.materials.first { $0.id == assigned.materialID }?.paperStock, assigned.paperConstruction!.stock)
    engine.undo(); XCTAssertEqual(engine.project, before)
    _ = try call(engine, "apply_stock", ["object_id": recipient.id.uuidString, "material_id": id])
    let accepted = engine.project!
    _ = try call(engine, "save_stock", ["material_id": id, "stock": ["profile": ["color": "#254F91"]]])
    XCTAssertEqual(engine.project, accepted, "Editing a Lab stock must not rewrite assigned project snapshots")
    _ = try call(engine, "apply_stock", ["object_id": recipient.id.uuidString, "material_id": id])
    let reapplied = engine.project!.objects.first { $0.id == recipient.id }!
    XCTAssertNotEqual(reapplied.materialID, id)
    XCTAssertEqual(reapplied.paperConstruction!.stock.profile?.color, "#254F91")
    XCTAssertEqual(engine.project!.materials.first { $0.id == id }?.paperStock?.profile?.color, "#E8D9BB")
    try engine.flush()
    XCTAssertEqual(try engine.repository.load(engine.project!.id).materials, engine.project!.materials)
  }

  func testTemplateAndBleedDispatchRejectBadMetadataBeforeTouchingNativeHost() throws {
    let engine = try fixture(), before = engine.project!
    var requests = [[String: Any]]()
    engine.onGraphics = { _, args in requests.append(args); return ["ok": true] }
    let template: [String: Any] = ["path": "/tmp/vendor.svg", "instructions": "Keep original cut and crease layers.",
      "vendor": "Declared supplier", "revision": "A", "technical_mapping": [["elementID": "cut", "kind": "cut"]],
      "canonical_to_template": ["a": 1, "d": 1, "tx": 10]]
    _ = try call(engine, "template_attach", template)
    _ = try call(engine, "template_inspect")
    _ = try call(engine, "export", ["path": "/tmp/proof.svg", "format": "svg", "bleed_mm": 3.0, "handoff": "separate"])
    XCTAssertEqual(requests.count, 3)
    for invalid: [String: Any] in [["vendor": true], ["revision": 42], ["technical_mapping": [["elementID": "cut", "kind": "unknown"]]], ["canonical_to_template": ["a": true]]] {
      XCTAssertThrowsError(try call(engine, "template_attach", template.merging(invalid) { _, new in new }))
    }
    for invalid: [String: Any] in [["bleed_mm": true], ["bleed_mm": 25.1], ["handoff": "press_approved"]] {
      XCTAssertThrowsError(try call(engine, "export", invalid.merging(["path": "/tmp/proof.svg", "format": "svg"]) { _, new in new }))
    }
    XCTAssertEqual(requests.count, 3)
    XCTAssertEqual(engine.project, before); XCTAssertTrue(engine.undoStack.isEmpty)
    XCTAssertTrue(PaperCommands.isReadOnly(["command": "template_inspect"]))
  }

  func testStockChangesPreserveExplicitTintUntilOneUndoableClear() throws {
    let engine = try fixture()
    engine.project!.objects[0].color = "#102030"
    _ = try call(engine, "configure", ["stock": ["profile": ["color": "#D4C4A3"]]])
    XCTAssertEqual(engine.project!.objects[0].color, "#102030")
    let before = engine.project!, undo = engine.undoStack.count
    _ = try engine.call("form_update_object", arguments: ["object_id": before.objects[0].id.uuidString, "color": NSNull()])
    XCTAssertNil(engine.project!.objects[0].color)
    XCTAssertEqual(engine.project!.objects[0].paperConstruction, before.objects[0].paperConstruction)
    XCTAssertEqual(engine.undoStack.count, undo + 1)
    engine.undo(); XCTAssertEqual(engine.project, before)
  }

  func testSavingLegacyStockRetainsItsExistingMaterialColorWithoutAProfile() throws {
    let engine = try fixture()
    engine.project!.objects[0].materialID = "cobalt"
    let before = engine.project!
    XCTAssertNil(before.objects[0].color)
    XCTAssertNil(before.objects[0].paperConstruction!.stock.profile)
    let saved = try XCTUnwrap(try call(engine, "save_stock") as? [String: Any])
    let material = try XCTUnwrap(saved["material"] as? [String: Any])
    XCTAssertEqual(material["color"] as? String, before.material("cobalt").color)
    XCTAssertEqual(engine.project, before); XCTAssertTrue(engine.undoStack.isEmpty)
    _ = try call(engine, "apply_stock", ["material_id": try XCTUnwrap(material["id"] as? String)])
    XCTAssertEqual(engine.project!.material(engine.project!.objects[0].materialID).color, before.material("cobalt").color)
  }

  func testBitmapInkOverridesRejectAtomicallyWhileImageAlphaFoilAndOriginalInkRemainSupported() throws {
    let engine = try fixture()
    let group = ArtworkElement(kind: "group", x: 0, y: 0, width: 50, height: 30)
    var image = ArtworkElement(kind: "image", x: 5, y: 5, width: 30, height: 20, asset: "source.png")
    image.parentID = group.id
    try engine.edit("Bitmap source") { p in try p.setArtwork(.init(elements: [group, image]), for: p.objects[0].id) }
    let before = engine.project!, undo = engine.undoStack.count
    for target in [group.id, image.id] {
      for kind in ["flatInk", "letterpress", "screenPrint"] {
        XCTAssertThrowsError(try call(engine, "set_finish", ["finish": ["kind": kind, "elementIDs": [target.uuidString], "color": "#A12345"]]))
        XCTAssertEqual(engine.project, before); XCTAssertEqual(engine.undoStack.count, undo)
      }
    }
    _ = try call(engine, "set_finish", ["finish": ["kind": "flatInk", "elementIDs": [image.id.uuidString]]])
    _ = try call(engine, "set_finish", ["finish": ["kind": "foil", "elementIDs": [group.id.uuidString], "color": "#B68C45", "depthMM": 0.03]])
    XCTAssertEqual(engine.project!.objects[0].paperConstruction!.finishes?.count, 2)
  }
}
