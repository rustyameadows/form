import XCTest

@testable import FormCore

final class MerchandiseTests: XCTestCase {
  private func blank(_ recipe: String, in p: Project) throws -> ProductObject {
    try p.makeObject(recipeID: recipe, materialID: MerchandiseBlanks.defaultMaterial(recipe)!)
  }
  private func printed(
    _ host: ProductObject, zone: TextileAttachment.Zone = .front, width: Double = 80,
    height: Double = 28
  ) -> ProductObject {
    var o = try! Project(name: "Source").makeObject(
      recipeID: "textilePrint", parameters: ["width": width, "depth": height],
      materialID: "label-ecru")
    o.artwork = Artwork(background: "#FFFFFF", elements: [], bleed: 0)
    o.textile?.attachment = .init(garmentID: host.id, zone: zone, clearance: 0)
    return o
  }
  private func engine(_ p: Project) throws -> OperationEngine {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let e = OperationEngine(repository: try ProjectRepository(root: root))
    e.project = p
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    return e
  }
  func testRecipesNativeMaterialsAndReadOnlyPhysicalZoneDiscovery() throws {
    var p = Project(name: "Merchandise")
    XCTAssertEqual(try p.makeObject(recipeID: "crewTee").materialID, "jersey-ecru")
    for id in MerchandiseBlanks.garmentIDs.sorted() {
      let b = try blank(id, in: p)
      p.objects.append(b)
      XCTAssertFalse(b.supportsArtworkFace)
      XCTAssertFalse(b.textile!.measurementsVerified)
      XCTAssertNil(b.textile!.manufacturer)
      XCTAssertNotNil(p.material(b.materialID).fabric)
      let zones = MerchandiseBlanks.zones(b)
      XCTAssertTrue(
        [TextileAttachment.Zone.front, .back, .leftSide, .rightSide].allSatisfy { z in
          zones.contains { $0.id == z }
        })
    }
    try p.validateArtworkLinks()
    let e = try engine(p)
    let before = p
    let report =
      try e.call("form_textile_zones", arguments: ["object_id": p.objects[1].id.uuidString])
      as! [String: Any]
    XCTAssertEqual(report["units"] as? String, "mm")
    XCTAssertEqual(e.project, before)
    let tool = MCP.tools.first { $0["name"] as? String == "form_textile_zones" }!
    XCTAssertEqual((tool["annotations"] as? [String: Any])?["readOnlyHint"] as? Bool, true)
    XCTAssertEqual(p.minimumSchemaVersion, 34)
  }
  func testCapArcMillimetersMatchActualCylindricalCrownAndAvoidDomeOpening() throws {
    let p = Project(name: "Cap")
    let cap = try blank("curvedCap", in: p)
    let r = cap["width"] / 2
    for zone in MerchandiseBlanks.zones(cap) {
      for u in [-zone.width / 2, 0, zone.width / 2] {
        for v in [-zone.height / 2, 0, zone.height / 2] {
          let a = MerchandiseBlanks.sample(cap, zone: zone, u: u, v: v)
          let angle = zone.origin.x - u / r
          let crown = MerchandiseBlanks.crown(cap, angle: angle, t: a.point.y / cap["height"])
          XCTAssertEqual(a.point.x, crown.x, accuracy: 1e-9)
          XCTAssertEqual(a.point.z, crown.z, accuracy: 1e-9)
          XCTAssertEqual(a.point.y, crown.y, accuracy: 1e-9)
          XCTAssertLessThan(a.point.y, cap["height"] * 0.72)
          for seam in MerchandiseBlanks.capSeamAngles {
            let angleDistance = abs(atan2(sin(angle - seam), cos(angle - seam)))
            XCTAssertGreaterThan(
              angleDistance * r, 2, "Every bounded cap region must avoid its raised panel seams.")
          }
          if zone.id == .back { XCTAssertGreaterThan(a.point.y, cap["height"] * 0.72 * 0.6) }
        }
      }
      let a = MerchandiseBlanks.sample(cap, zone: zone, u: -20, v: 0).point
      let b = MerchandiseBlanks.sample(cap, zone: zone, u: 20, v: 0).point
      let dot = (a.x * b.x + a.z * b.z) / (r * r)
      XCTAssertEqual(acos(min(1, max(-1, dot))) * r, 40, accuracy: 1e-8)
    }
  }
  func testRotatedCornersAndBlankShrinkRejectAtomicallyWithUndo() throws {
    var p = Project(name: "Bounded print")
    var b = try blank("crewTee", in: p)
    let art = printed(b, width: 300, height: 280)
    p.objects = [b, art]
    let e = try engine(p)
    let before = p
    XCTAssertThrowsError(
      try e.call(
        "form_update_object",
        arguments: ["object_id": b.id.uuidString, "parameters": ["width": 360]]))
    XCTAssertEqual(e.project, before)
    var spec = art.textile!
    spec.attachment!.offset.x = 110
    spec.attachment!.rotation = 45
    XCTAssertThrowsError(
      try e.call(
        "form_update_object",
        arguments: ["object_id": art.id.uuidString, "textile": try jsonObject(spec)]))
    XCTAssertEqual(e.project, before)
    spec.attachment!.offset = .init()
    spec.attachment!.rotation = 0
    _ = try e.call(
      "form_update_object",
      arguments: [
        "object_id": art.id.uuidString, "parameters": ["width": 200],
        "textile": try jsonObject(spec),
      ])
    XCTAssertNotEqual(e.project, before)
    _ = try e.call("form_undo")
    XCTAssertEqual(e.project, before)
  }
  func testCapRejectsRigidPatchLabelEmbroideryAndFloatingClearance() throws {
    var p = Project(name: "No floating cap plates")
    var cap = try blank("curvedCap", in: p)
    for recipe in ["textilePatch", "textileLabel"] {
      var o = try p.makeObject(recipeID: recipe, parameters: ["width": 40, "depth": 20])
      o.textile?.attachment = .init(garmentID: cap.id, zone: .front)
      p.objects = [cap, o]
      XCTAssertThrowsError(try p.validateArtworkLinks())
    }
    var ink = printed(cap)
    ink.textile!.attachment!.clearance = 1
    p.objects = [cap, ink]
    XCTAssertThrowsError(try p.validateArtworkLinks())
    ink.textile!.attachment!.clearance = 0
    p.objects = [cap, ink]
    XCTAssertNoThrow(try p.validateArtworkLinks())
    p.objects[0].textile!.laidFaceDown = true
    XCTAssertThrowsError(try p.validateArtworkLinks())
  }
  func testFrontBackSideBasesAreOrthonormalAndGarmentYawMovesWholeSurface() throws {
    var p = Project(name: "Deterministic surface basis")
    for recipe in ["crewTee", "canvasTote"] {
      var host = try blank(recipe, in: p)
      host.rotation = 37
      host.position = .init(340, 15, -200)
      for zone in MerchandiseBlanks.zones(host) {
        let o = printed(
          host, zone: zone.id, width: min(20, zone.width), height: min(18, zone.height))
        p.objects = [host, o]
        let placement = p.textilePlacement(o)
        let r = placement.basisRight!
        let d = placement.basisDown!
        let n = placement.normal
        func dot(_ a: Vector3, _ b: Vector3) -> Double { a.x * b.x + a.y * b.y + a.z * b.z }
        XCTAssertEqual(dot(r, r), 1, accuracy: 1e-9)
        XCTAssertEqual(dot(d, d), 1, accuracy: 1e-9)
        XCTAssertEqual(dot(n, n), 1, accuracy: 1e-9)
        XCTAssertEqual(dot(r, n), 0, accuracy: 1e-9)
        XCTAssertEqual(dot(r, d), 0, accuracy: 1e-9)
        let cross = Vector3(r.y * n.z - r.z * n.y, r.z * n.x - r.x * n.z, r.x * n.y - r.y * n.x)
        XCTAssertEqual(cross.x, d.x, accuracy: 1e-9)
        XCTAssertEqual(cross.y, d.y, accuracy: 1e-9)
        XCTAssertEqual(cross.z, d.z, accuracy: 1e-9)
        p.setTextileWorldPosition(o.id, to: placement.position)
        XCTAssertEqual(p.objects[1].textile!.attachment!.offset.x, 0, accuracy: 1e-8)
        XCTAssertEqual(p.objects[1].textile!.attachment!.offset.y, 0, accuracy: 1e-8)
      }
    }
  }
  func testShowBackTransformsEveryRegionAboveTableAndIsOneUndoWithoutSourceChanges() throws {
    var p = Project(name: "Turn over blank")
    var host = try blank("crewTee", in: p)
    var front = printed(host)
    var back = printed(host, zone: .back)
    p.objects = [host, front, back]
    let e = try engine(p)
    let before = p
    let oldFront = p.textilePlacement(front)
    let oldBack = p.textilePlacement(back)
    host.textile!.laidFaceDown = true
    _ = try e.call(
      "form_update_object",
      arguments: ["object_id": host.id.uuidString, "textile": try jsonObject(host.textile!)])
    let q = e.project!
    let newFront = q.textilePlacement(front)
    let newBack = q.textilePlacement(back)
    XCTAssertEqual(newFront.position.y, oldBack.position.y, accuracy: 1e-8)
    XCTAssertEqual(newBack.position.y, oldFront.position.y, accuracy: 1e-8)
    XCTAssertEqual(newBack.basisRight?.x, 1)
    XCTAssertEqual(newBack.basisDown?.z, 1)
    XCTAssertEqual(newBack.position.z, oldBack.position.z)
    XCTAssertEqual(newBack.normal.y, 1)
    XCTAssertEqual(newFront.normal.y, -1)
    XCTAssertGreaterThan(newBack.position.y, 0)
    XCTAssertEqual(q.objects[1...2], before.objects[1...2])
    _ = try e.call("form_undo")
    XCTAssertEqual(e.project, before)
  }
  func testConformingSignatureIgnoresHostWorldTransformButTracksDimensionsAndPlacement() throws {
    var p = Project(name: "Cache")
    var cap = try blank("curvedCap", in: p)
    let art = printed(cap)
    p.objects = [cap, art]
    let a = p.conformedMerchandiseSignature(art)
    p.objects[0].position = .init(500, 20, 300)
    p.objects[0].rotation = 65
    XCTAssertEqual(p.conformedMerchandiseSignature(art), a)
    p.objects[0].parameters["width"] = 220
    XCTAssertNotEqual(p.conformedMerchandiseSignature(art), a)
    p.objects[0] = cap
    p.objects[1].textile!.attachment!.rotation = 12
    XCTAssertNotEqual(p.conformedMerchandiseSignature(p.objects[1]), a)
  }
  func testCollectionRetainsOriginalEditableSharedArtAndIndependentFrontBackZones() throws {
    let p = try Samples.merchandiseCollection()
    try p.validateArtworkLinks()
    XCTAssertFalse(
      p.objects.flatMap { $0.artwork?.elements ?? [] }.contains { $0.text.contains(" ·  M") },
      "The new concept collection must not inherit a standard-size claim from the bomber sample.")
    XCTAssertEqual(p.minimumSchemaVersion, 34)
    XCTAssertEqual(p.objects.filter { MerchandiseBlanks.garmentIDs.contains($0.recipeID) }.count, 3)
    XCTAssertEqual(p.objects.filter { $0.recipeID == "textilePrint" }.count, 6)
    let printRegions = p.objects.filter { $0.recipeID == "textilePrint" }
    XCTAssertTrue(
      printRegions.allSatisfy {
        $0.artworkSourceID != nil
          && p.editableArtwork($0)?.elements.contains { $0.kind == "text" } == true
      })
    XCTAssertTrue(
      p.objects.allSatisfy {
        $0.textile?.measurementsVerified != true && $0.textile?.manufacturer == nil
      })
    let data = try JSONEncoder.form.encode(p)
    let loaded = try JSONDecoder.form.decode(Project.self, from: data)
    XCTAssertEqual(loaded.objects, p.objects)
    let old = Samples.flightJacket()
    XCTAssertNoThrow(try old.validateArtworkLinks())
    XCTAssertEqual(old.objects.first!.recipeID, "bomberJacket")
  }
  func testMovingTurnedOverBlankKeepsBaseHeightAndDetachingCapPrintReturnsFlatTableArt() throws {
    var p = Project(name: "Display pose is not model base")
    var tee = try p.makeObject(recipeID: "crewTee")
    tee.textile!.laidFaceDown = true
    p.objects = [tee]
    let displayed = p.textilePlacement(tee).position
    p.setTextileWorldPosition(tee.id, to: .init(displayed.x + 50, displayed.y, displayed.z - 30))
    XCTAssertEqual(p.objects[0].position, .init(50, 0, -30))
    XCTAssertEqual(p.textilePlacement(p.objects[0]).position.y, displayed.y)
    let cap = try p.makeObject(recipeID: "curvedCap")
    let ink = printed(cap)
    p.objects = [cap, ink]
    let before = p
    let flat = p.detachedTextilePlacement(ink)
    XCTAssertEqual(flat.position.y, 0)
    XCTAssertFalse(flat.underside)
    p.detachTextileConsumers(of: [cap.id])
    XCTAssertNil(p.objects[1].textile!.attachment)
    XCTAssertEqual(p.objects[1].position, flat.position)
    XCTAssertEqual(p.objects[1].artwork, before.objects[1].artwork)
  }

  func testMerchandiseVariantsShareParametersWhileTheirPhysicalPlacementsStayIndependent() throws {
    let p = try Samples.merchandiseCollection()
    let e = try engine(p)
    let tee = p.objects.first { $0.recipeID == "crewTee" }!
    let variant =
      try e.call(
        "form_duplicate_object",
        arguments: [
          "object_id": tee.id.uuidString, "mode": "variant", "material_id": "jersey-navy",
        ]) as! [String: Any]
    let id = UUID(uuidString: variant["id"] as! String)!
    let before = e.project!
    _ = try e.call(
      "form_update_object",
      arguments: ["object_id": tee.id.uuidString, "parameters": ["width": 560]])
    let changed = e.project!
    let copy = changed.objects.first { $0.id == id }!
    XCTAssertEqual(copy.parameters["width"], 560)
    XCTAssertEqual(copy.materialID, "jersey-navy")
    XCTAssertEqual(copy.position, before.objects.first { $0.id == id }!.position)
    XCTAssertEqual(changed.objects.first { $0.id == tee.id }!.position, tee.position)
    _ = try e.call("form_undo")
    XCTAssertEqual(e.project, before)
    let source = p.objects.first { $0.name == "Artwork / ORBITAL field division" }!
    let consumers = p.objects.filter { $0.artworkSourceID == source.id }
    var art = source.artwork!
    art.elements[0].color = "#BC5739"
    _ = try e.call(
      "form_set_artwork",
      arguments: ["object_id": source.id.uuidString, "artwork": try jsonObject(art)])
    for consumer in consumers { XCTAssertEqual(e.project!.editableArtwork(consumer), art) }
    XCTAssertEqual(
      e.project!.objects.filter { $0.artworkSourceID == source.id }.map(\.textile),
      p.objects.filter { $0.artworkSourceID == source.id }.map(\.textile))
  }

}
