import AppKit
import XCTest
@testable import FormApp
import FormCore
import FormGraphics

@MainActor final class ColorProfileEditingTests: XCTestCase {
  private let path = "/System/Library/ColorSync/Profiles/Generic CMYK Profile.icc"
  private func fixture() throws -> (StudioStore, ProductObject) {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = StudioStore(repository: try ProjectRepository(root: root), seedLibrary: false)
    var project = Project(name: "Color output")
    var object = try project.makeObject(recipeID: "artboard")
    object.parameters["width"] = 100; object.parameters["depth"] = 80
    object.artwork = .init(background: "#FFFFFF", elements: [
      .init(kind: "rectangle", x: 10, y: 10, width: 20, height: 20, color: "#CC2610"),
      .init(kind: "text", x: 10, y: 40, width: 70, height: 20, text: "Portable color", color: "#173E87", fontSize: 14),
    ])
    project.objects = [object]; store.engine.project = project
    addTeardownBlock { store.engine.project = nil; try? FileManager.default.removeItem(at: root) }
    return (store, object)
  }
  func testProfileAssignmentHasSharedUndoSourcePreservationAndSchema30Reopen() throws {
    let (store, object) = try fixture(), before = store.project!
    _ = try store.colorProfileCall(["command": "set", "object_id": object.id.uuidString, "profile_path": path])
    let after = store.project!, profile = try XCTUnwrap(after.objects[0].artwork?.outputColorProfile)
    XCTAssertEqual(after.objects[0].artwork?.elements, before.objects[0].artwork?.elements)
    XCTAssertEqual(after.minimumSchemaVersion, 30); XCTAssertEqual(profile.model, "CMYK")
    XCTAssertEqual(store.engine.undoStack.count, 1)
    store.engine.undo(); XCTAssertEqual(store.project, before)
    store.engine.redo(); XCTAssertEqual(store.project, after)
    try store.repository.save(after)
    let loaded = try store.repository.load(after.id)
    XCTAssertEqual(loaded.objects, after.objects); XCTAssertEqual(loaded.schemaVersion, 30)
    _ = try ICCOutputProfile(reference: profile, assets: store.repository.url(for: after.id).appendingPathComponent("Assets"))
    let undos = store.engine.undoStack.count
    _ = try store.colorProfileCall(["command": "set", "object_id": object.id.uuidString, "profile_path": path])
    XCTAssertEqual(store.engine.undoStack.count, undos, "Reassigning identical bytes is a no-op.")
  }
  func testProfiledArtworkAndRolePDFsConvertWithoutChangingProjectOrHistory() throws {
    let (store, object) = try fixture()
    _ = try store.colorProfileCall(["command": "set", "object_id": object.id.uuidString, "profile_path": path])
    let before = store.project!
    for roles in [false, true] {
      let target = store.repository.root.appendingPathComponent(roles ? "roles.pdf" : "artwork.pdf")
      var args: [String: Any] = ["format": "pdf", "path": target.path]
      if roles { args["roles"] = ["print"] }
      let exported = try store.exportArtwork(object: store.project!.objects[0], arguments: args) as! [String: Any]
      XCTAssertEqual(exported["color_space"] as? String, "CMYK")
      XCTAssertEqual((exported["pdf_output_profile"] as? [String: Any])?["sha256"] as? String,
        before.objects[0].artwork?.outputColorProfile?.sha256)
      let data = try Data(contentsOf: target), raw = String(data: data, encoding: .isoLatin1)!
      let pdf = CGPDFDocument(CGDataProvider(data: data as CFData)!)!
      XCTAssertEqual(pdf.page(at: 1)!.getBoxRect(.trimBox).width, 100 * 72 / 25.4, accuracy: 0.001)
      XCTAssertTrue(raw.contains("/N 4")); XCTAssertTrue(raw.contains("FORM-ICC-"))
      XCTAssertEqual(store.project, before)
    }
  }
  func testMissingProfilePreflightKeepsExistingOutputAndLockRejectsChanges() throws {
    let (store, object) = try fixture()
    _ = try store.colorProfileCall(["command": "set", "object_id": object.id.uuidString, "profile_path": path])
    let before = store.project!, reference = before.objects[0].artwork!.outputColorProfile!
    let target = store.repository.root.appendingPathComponent("approved.pdf"), sentinel = Data("Approved output".utf8)
    try sentinel.write(to: target)
    try FileManager.default.removeItem(at: store.repository.url(for: before.id).appendingPathComponent("Assets").appendingPathComponent(reference.asset))
    XCTAssertThrowsError(try store.exportArtwork(object: before.objects[0], arguments: ["format": "pdf", "path": target.path]))
    XCTAssertEqual(try Data(contentsOf: target), sentinel); XCTAssertEqual(store.project, before)
    store.engine.project!.objects[0].locked = true; let locked = store.project!
    XCTAssertThrowsError(try store.colorProfileCall(["command": "clear", "object_id": object.id.uuidString]))
    XCTAssertEqual(store.project, locked)
  }
  func testLinkedSourceAssignmentAndPublicationSizedBatchesAreAtomic() throws {
    let (store, source) = try fixture()
    var linked = try store.project!.makeObject(recipeID: "box")
    linked.artworkSourceID = source.id; linked.artworkFit = "fit"; linked.artwork = nil
    store.engine.project!.objects.append(linked)
    let before = store.project!
    let command: [String: Any] = ["command": "set", "object_id": linked.id.uuidString, "profile_path": path]
    _ = try store.engine.call("form_color_profile", arguments: command)
    let assigned = store.project!
    XCTAssertNotNil(assigned.objects[0].artwork?.outputColorProfile); XCTAssertNil(assigned.objects[1].artwork)
    XCTAssertEqual(assigned.surfaceArtwork(linked)?.renderDefinition, before.surfaceArtwork(linked)?.renderDefinition)
    store.engine.undo(); XCTAssertEqual(store.project, before)
    let undoCount = store.engine.undoStack.count
    XCTAssertThrowsError(try store.engine.call("form_batch", arguments: ["operations": [
      ["name": "form_color_profile", "arguments": command],
      ["name": "form_color_profile", "arguments": ["command": "set", "object_id": source.id.uuidString, "profile_path": "/missing.icc"]],
    ]]))
    XCTAssertEqual(store.project, before); XCTAssertEqual(store.engine.undoStack.count, undoCount)
    XCTAssertThrowsError(try store.engine.call("form_batch", arguments: ["operations": [
      ["name": "form_color_profile", "arguments": ["command": "list"]],
    ]]))
    XCTAssertEqual(store.project, before)
  }
}
