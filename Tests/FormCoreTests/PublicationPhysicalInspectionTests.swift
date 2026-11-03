import XCTest
@testable import FormCore

final class PublicationPhysicalInspectionTests: XCTestCase {
  private func fixture(binding: SheetBindingDefinition? = .init(style: .saddleStitch), parents: Bool = true) throws -> (OperationEngine, UUID, UUID) {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("physical-inspection-" + UUID().uuidString)
    addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
    var project = Project(name: "Physical publication inspection"), ids = [UUID]()
    for i in 1...12 {
      var page = try project.makeObject(recipeID: "artboard", name: "Page \(i)", parameters: ["width": 100, "depth": 140])
      page.artwork = .init(elements: [.init(kind: "text", x: 0, y: 0, text: "Page \(i)")], bleed: 0)
      project.objects.append(page); ids.append(page.id)
    }
    let publication = try PublicationCommands.createPublication(in: &project, name: "Document", pages: ids)
    let entries = project.publications![0].pages
    let sheets = (0..<3).map { i in SheetAssemblyParentSheet(
      frontPageIDs: [entries[11 - i * 2].id, entries[i * 2].id],
      backPageIDs: [entries[i * 2 + 1].id, entries[10 - i * 2].id],
      stock: .init(name: "Stock \(i)", thicknessMM: 0.1 + Double(i) * 0.02),
      sizeMM: .init(200, 140), printIntent: i == 1 ? .blackOnly : .color) }
    let object = try SheetAssemblyCommands.create(in: &project, definition: .init(publicationID: publication,
      openingDegrees: 180, activeSpread: 2, binding: binding, parentSheets: parents ? sheets : nil))
    let engine = OperationEngine(repository: try .init(root: folder)); engine.project = project
    return (engine, publication, object)
  }
  private func inspect(_ engine: OperationEngine, _ object: UUID, offset: Int = 0, limit: Int = 25) throws -> [String: Any] {
    guard let result = try engine.call("form_publication", arguments: ["command": "sheet_assembly_inspect", "object_id": object.uuidString,
      "offset": offset, "limit": limit]) as? [String: Any] else { throw FormError.invalid("Expected physical inspection response.") }
    return result
  }
  func testNullablePoseEnumAndBindingDefaultsMatchRuntimeContract() throws {
    let properties = try XCTUnwrap(PublicationPhysicalToolSchema.posePatch["properties"] as? [String: Any])
    let binding = try XCTUnwrap(properties["bindingStyle"] as? [String: Any])
    XCTAssertEqual(Set(try XCTUnwrap(binding["type"] as? [String])), Set(["string", "null"]))
    let values = try XCTUnwrap(binding["enum"] as? [Any])
    XCTAssertEqual(values.filter { $0 is NSNull }.count, 1)
    XCTAssertEqual(values.compactMap { $0 as? String }, SheetBindingStyle.allCases.map(\.rawValue))
    XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: PublicationPhysicalToolSchema.posePatch))
    XCTAssertNoThrow(try PublicationPhysicalToolSchema.validateFields(["bindingStyle": NSNull()],
      schema: PublicationPhysicalToolSchema.posePatch, path: "pose"))
    let defaults = try JSONDecoder.form.decode(SheetBindingDefinition.self, from: Data("{}".utf8))
    let decoded = try XCTUnwrap(jsonObject(defaults) as? [String: Any])
    let bindingProperties = try XCTUnwrap(PublicationPhysicalToolSchema.binding["properties"] as? [String: Any])
    for key in ["style", "count", "endMarginMM", "edgeInsetMM", "crownLengthMM", "wireDiameterMM", "clinchLengthMM", "flexWidthMM"] {
      let field = try XCTUnwrap(bindingProperties[key] as? [String: Any])
      let actual = try XCTUnwrap(field["default"])
      XCTAssertEqual(try JSONSerialization.data(withJSONObject: actual, options: .fragmentsAllowed),
        try JSONSerialization.data(withJSONObject: XCTUnwrap(decoded[key]), options: .fragmentsAllowed), key)
    }
  }
  func testInspectionReportsDistinctPhysicalCountsAndPagesWithoutMutation() throws {
    let (engine, publication, object) = try fixture(), before = engine.project, generation = engine.projectGeneration
    let value = try inspect(engine, object, limit: 2)
    XCTAssertEqual(value["publication_id"] as? String, publication.uuidString)
    let resolved = try XCTUnwrap(value["resolved"] as? [String: Any])
    XCTAssertEqual(resolved["logical_page_count"] as? Int, 12)
    XCTAssertEqual(resolved["leaf_count"] as? Int, 6)
    XCTAssertEqual(resolved["parent_sheet_count"] as? Int, 3)
    XCTAssertEqual(resolved["binding_state"] as? String, "bound")
    XCTAssertEqual(resolved["stack_thickness_mm"] as? Double ?? 0, 0.72, accuracy: 1e-9)
    let pages = try XCTUnwrap(value["pages"] as? [String: Any])
    XCTAssertEqual(pages["total"] as? Int, 12); XCTAssertEqual(pages["next_offset"] as? Int, 2)
    XCTAssertEqual(pages["truncated"] as? Bool, true)
    var collected = [String]()
    for offset in stride(from: 0, to: 12, by: 2) {
      let section = try XCTUnwrap(inspect(engine, object, offset: offset, limit: 2)["pages"] as? [String: Any])
      collected += try XCTUnwrap(section["items"] as? [[String: Any]]).compactMap { $0["page_object_id"] as? String }
    }
    XCTAssertEqual(collected, before!.publications![0].pages.map { $0.objectID.uuidString })
    let parents = try XCTUnwrap(value["parent_sheets"] as? [String: Any])
    let parent = try XCTUnwrap((parents["items"] as? [[String: Any]])?.first)
    let front = try XCTUnwrap(parent["front"] as? [[String: Any]])
    XCTAssertEqual(front.map { $0["label"] as? String }, ["12", "1"])
    XCTAssertNotEqual(front[0]["publication_page_id"] as? String, front[0]["page_object_id"] as? String)
    XCTAssertEqual(engine.project, before); XCTAssertEqual(engine.projectGeneration, generation)
    XCTAssertTrue(engine.undoStack.isEmpty)
    XCTAssertLessThan(try JSONSerialization.data(withJSONObject: value).count, 1_048_576)
  }
  func testUnspecifiedBindingIsNotReportedAsAnExplicitUnboundConstruction() throws {
    let declarations: [(SheetBindingDefinition?, String)] = [(nil, "unspecified"), (.init(style: .none), "unbound")]
    for (binding, state) in declarations {
      let (engine, _, object) = try fixture(binding: binding)
      let value = try inspect(engine, object)
      let authored = try XCTUnwrap(value["authored"] as? [String: Any])
      XCTAssertEqual(authored["binding_state"] as? String, state)
      XCTAssertEqual(authored["binding"] is NSNull, binding == nil)
    }
  }
  func testNestedDefinitionTyposAndInvalidPaginationAreRejectedAtomically() throws {
    let (engine, _, object) = try fixture(), before = engine.project
    var raw = try XCTUnwrap(jsonObject(before!.objects.first { $0.id == object }!.sheetAssembly!) as? [String: Any])
    var binding = try XCTUnwrap(raw["binding"] as? [String: Any]); binding["inventedBinding"] = true; raw["binding"] = binding
    XCTAssertThrowsError(try engine.call("form_publication", arguments: ["command": "sheet_assembly_configure", "object_id": object.uuidString, "definition": raw]))
    raw = try XCTUnwrap(jsonObject(before!.objects.first { $0.id == object }!.sheetAssembly!) as? [String: Any])
    var parents = try XCTUnwrap(raw["parentSheets"] as? [[String: Any]])
    var stock = try XCTUnwrap(parents[0]["stock"] as? [String: Any]); stock["assumedGrain"] = "long"; parents[0]["stock"] = stock; raw["parentSheets"] = parents
    XCTAssertThrowsError(try engine.call("form_publication", arguments: ["command": "sheet_assembly_configure", "object_id": object.uuidString, "definition": raw]))
    for limit in [0, 51] { XCTAssertThrowsError(try inspect(engine, object, limit: limit)) }
    XCTAssertThrowsError(try inspect(engine, object, offset: -1))
    XCTAssertEqual(engine.project, before); XCTAssertTrue(engine.undoStack.isEmpty)
  }
  func testCompleteStockSchemaMatchesNestedCodableRequirementsWithoutChangingPartialPaperUpdates() throws {
    let profile = PaperSurfaceProfile(texture: .cotton, color: "#FFFDF8")
    let stock = PaperStock(name: "Bonded stock", thicknessMM: 0.2, profile: profile,
      plies: [.init(name: "Face", color: "#FFFDF8", thicknessMM: 0.2, profile: profile)])
    let raw = try XCTUnwrap(jsonObject(stock) as? [String: Any])
    let schema = PublicationPhysicalToolSchema.stock
    func decode(_ value: [String: Any]) throws -> PaperStock {
      try JSONDecoder.form.decode(PaperStock.self, from: JSONSerialization.data(withJSONObject: value))
    }
    XCTAssertEqual(try decode(raw), stock)
    XCTAssertNoThrow(try PublicationPhysicalToolSchema.validateFields(raw, schema: schema, path: "stock"))
    let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
    let profileSchema = try XCTUnwrap(properties["profile"] as? [String: Any])
    let requiredProfile = try XCTUnwrap(profileSchema["required"] as? [String])
    XCTAssertEqual(Set(requiredProfile), Set(["texture", "roughness", "textureScaleMM", "textureDepthMM", "opacity"]))
    let pliesSchema = try XCTUnwrap(properties["plies"] as? [String: Any])
    let plySchema = try XCTUnwrap(pliesSchema["items"] as? [String: Any])
    XCTAssertEqual(Set(try XCTUnwrap(plySchema["required"] as? [String])), Set(["id", "name", "color", "thicknessMM"]))
    for key in requiredProfile {
      for nestedInPly in [false, true] {
        var missing = raw
        var incomplete = try XCTUnwrap(raw["profile"] as? [String: Any]); incomplete[key] = nil
        if nestedInPly {
          var plies = try XCTUnwrap(raw["plies"] as? [[String: Any]])
          plies[0]["profile"] = incomplete; missing["plies"] = plies
        } else { missing["profile"] = incomplete }
        XCTAssertThrowsError(try decode(missing), "Missing \(key), nested in ply: \(nestedInPly)")
        XCTAssertThrowsError(try PublicationPhysicalToolSchema.validateFields(missing, schema: schema, path: "stock"))
      }
    }
    var missingID = raw, plies = try XCTUnwrap(raw["plies"] as? [[String: Any]])
    plies[0]["id"] = nil; missingID["plies"] = plies
    XCTAssertThrowsError(try decode(missingID))
    XCTAssertThrowsError(try PublicationPhysicalToolSchema.validateFields(missingID, schema: schema, path: "stock"))
    var inherited = raw; inherited["profile"] = nil; inherited["plies"] = nil
    XCTAssertNoThrow(try decode(inherited))
    XCTAssertNoThrow(try PublicationPhysicalToolSchema.validateFields(inherited, schema: schema, path: "stock"))
    XCTAssertNil(PaperAppearanceCommands.profileSchema["required"], "Existing paper configure still accepts sparse profile updates.")
    let partialProperties = try XCTUnwrap(PaperAppearanceCommands.stockSchema["properties"] as? [String: Any])
    let partialPlies = try XCTUnwrap(partialProperties["plies"] as? [String: Any])
    let partialPly = try XCTUnwrap(partialPlies["items"] as? [String: Any])
    XCTAssertFalse((partialPly["required"] as? [String] ?? []).contains("id"))
  }
  func testTargetedPoseUpdateInheritsResetsAndPreservesOtherCopiesWithOneUndo() throws {
    let (engine, _, object) = try fixture()
    var scene = StudioComposition(name: "Independent copies", camera: engine.project!.camera)
    let first = StudioInstance(name: "Open copy", sourceObjectID: object), second = StudioInstance(name: "Other copy", sourceObjectID: object)
    scene.instances = [first, second]
    var presentation = StudioPresentation(); presentation.scenes = [scene]; engine.project?.studioPresentation = presentation
    let before = engine.project, canonical = engine.project!.objects
    let page = engine.project!.publications![0].pages[4]
    var arguments: [String: Any] = ["command": "pose_update", "scene_id": scene.id.uuidString,
      "instance_id": first.id.uuidString, "revision": 1, "pose": ["openingDegrees": 110, "bendMM": 1.0, "bindingStyle": "sideStaple"],
      "page_object_id": page.objectID.uuidString]
    let changed = try XCTUnwrap(engine.call("form_studio_scene", arguments: arguments) as? [String: Any])
    XCTAssertEqual(changed["revision"] as? Int, 2)
    let effective = try XCTUnwrap(changed["effective"] as? [String: Any])
    XCTAssertEqual(effective["activeSpread"] as? Int, 2); XCTAssertEqual(effective["openingDegrees"] as? Double, 110)
    let displayed = try XCTUnwrap(changed["displayed_faces"] as? [String: Any])
    XCTAssertEqual((displayed["right"] as? [String: Any])?["publication_page_id"] as? String, page.id.uuidString)
    XCTAssertEqual(engine.project?.objects, canonical)
    XCTAssertEqual(engine.project?.studioPresentation?.scenes?.first?.instances[1], second)
    XCTAssertEqual(engine.project?.studioPresentation?.scenes?.first?.camera, scene.camera)
    XCTAssertEqual(engine.undoStack.count, 1)
    let after = engine.project; engine.undo(); XCTAssertEqual(engine.project, before); engine.redo(); XCTAssertEqual(engine.project, after)
    arguments["revision"] = 2; arguments["page_object_id"] = nil; arguments["pose"] = ["openingDegrees": NSNull()]
    let cleared = try XCTUnwrap(engine.call("form_studio_scene", arguments: arguments) as? [String: Any])
    XCTAssertEqual((cleared["field_origins"] as? [String: String])?["openingDegrees"], "source")
    XCTAssertEqual((cleared["effective"] as? [String: Any])?["openingDegrees"] as? Double, 180)
    XCTAssertEqual(engine.project?.studioPresentation?.scenes?.first?.instances[0].sheetPose?.bendMM, 1)
    let reset = try XCTUnwrap(engine.call("form_studio_scene", arguments: ["command": "pose_reset", "scene_id": scene.id.uuidString,
      "instance_id": first.id.uuidString, "revision": 3]) as? [String: Any])
    XCTAssertTrue(reset["authored"] is NSNull); XCTAssertEqual(reset["revision"] as? Int, 4)
    XCTAssertEqual(engine.project?.objects, canonical)
    let count = engine.undoStack.count
    _ = try engine.call("form_studio_scene", arguments: ["command": "pose_reset", "scene_id": scene.id.uuidString,
      "instance_id": first.id.uuidString, "revision": 4])
    XCTAssertEqual(engine.undoStack.count, count, "Resetting inherited pose is a no-op.")
  }
  func testPoseQueriesAndRejectedStaleOrAmbiguousUpdatesLeaveSourceAndHistoryExact() throws {
    let (engine, _, object) = try fixture(parents: false)
    var scene = StudioComposition(name: "Pose query", camera: engine.project!.camera)
    let instance = StudioInstance(name: "Copy", sourceObjectID: object); scene.instances = [instance]
    var presentation = StudioPresentation(); presentation.scenes = [scene]; engine.project?.studioPresentation = presentation
    engine.project?.publications?[0].pages[0].label = "Duplicate"
    engine.project?.publications?[0].pages[1].label = "Duplicate"
    let before = engine.project, generation = engine.projectGeneration
    let base: [String: Any] = ["scene_id": scene.id.uuidString, "instance_id": instance.id.uuidString]
    let query = try XCTUnwrap(engine.call("form_studio_scene", arguments: base.merging(["command": "pose_get", "limit": 2]) { _, new in new }) as? [String: Any])
    XCTAssertEqual((query["available_spreads"] as? [String: Any])?["total"] as? Int, 7)
    XCTAssertTrue(query["authored"] is NSNull)
    for patch: [String: Any] in [
      ["revision": 0, "pose": ["openingDegrees": 90]],
      ["revision": 1, "pose": ["activeSpread": 7]],
      ["revision": 1, "pose": ["openingDegrees": true]],
      ["revision": 1, "pose": ["unknown": 1]],
      ["revision": 1, "page_label": "Duplicate"],
      ["revision": 1, "page_label": "3", "pose": ["activeSpread": 1]],
      ["revision": 1, "publication_page_id": UUID().uuidString]
    ] {
      let args = base.merging(["command": "pose_update"]) { _, new in new }.merging(patch) { _, new in new }
      XCTAssertThrowsError(try engine.call("form_studio_scene", arguments: args))
    }
    XCTAssertEqual(engine.project, before); XCTAssertEqual(engine.projectGeneration, generation); XCTAssertTrue(engine.undoStack.isEmpty)
  }

  func testPoseInspectionReportsClampingWithoutRewritingAcceptedSceneAndLogicalSelectorIsExplicit() throws {
    let (engine, publication, object) = try fixture(parents: false)
    var scene = StudioComposition(name: "Remembered spread", camera: engine.project!.camera)
    var instance = StudioInstance(name: "Copy", sourceObjectID: object)
    instance.sheetPose = .init(openingDegrees: 120, activeSpread: 5); scene.instances = [instance]
    _ = try engine.call("form_studio_scene", arguments: ["command": "save", "scene": try jsonObject(scene)])
    let remove = engine.project!.publications![0].pages.dropFirst(4).map { $0.objectID.uuidString }
    _ = try engine.call("form_publication", arguments: ["command": "remove", "publication_id": publication.uuidString,
      "page_ids": remove, "delete_objects": true])
    let before = engine.project, history = engine.undoStack, generation = engine.projectGeneration
    let base: [String: Any] = ["scene_id": scene.id.uuidString, "instance_id": instance.id.uuidString]
    let result = try XCTUnwrap(engine.call("form_studio_scene", arguments: base.merging(["command": "pose_get"]) { _, new in new }) as? [String: Any])
    XCTAssertEqual(result["spread_clamped"] as? Bool, true)
    XCTAssertEqual((result["authored"] as? [String: Any])?["activeSpread"] as? Int, 5)
    XCTAssertEqual((result["effective"] as? [String: Any])?["activeSpread"] as? Int, 2)
    XCTAssertEqual(engine.project, before); XCTAssertEqual(engine.undoStack, history); XCTAssertEqual(engine.projectGeneration, generation)
    let page = engine.project!.publications![0].pages[2]
    _ = try engine.call("form_studio_scene", arguments: base.merging(["command": "pose_update", "revision": 1,
      "publication_page_id": page.id.uuidString]) { _, new in new })
    XCTAssertEqual(engine.project?.studioPresentation?.scenes?.first?.instances.first?.sheetPose?.activeSpread, 1)
    XCTAssertEqual(engine.project?.objects, before?.objects)
    XCTAssertEqual(engine.undoStack.count, history.count + 1)
  }
}
