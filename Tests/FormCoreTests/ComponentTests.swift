import AppKit
import XCTest
@testable import FormCore
@testable import FormGraphics

final class ComponentTests: XCTestCase {
  private func fixture() throws -> (Project, UUID, UUID, UUID) {
    var p = Project(name: "Components")
    var sheet = try p.makeObject(recipeID: "artboard")
    let mark = ArtworkElement(kind: "ellipse", x: 20, y: 30, width: 40, height: 40, color: "#D45A37")
    let label = ArtworkElement(kind: "text", x: 15, y: 75, width: 65, height: 12,
      text: "FORM / 01", color: "#263C64", fontSize: 20)
    sheet.artwork = .init(background: "#F9F7F0", elements: [mark, label], bleed: 0)
    p.objects = [sheet]
    return (p, sheet.id, mark.id, label.id)
  }
  private func element(_ p: Project, _ object: UUID, _ id: UUID) -> ArtworkElement {
    p.objects.first { $0.id == object }!.artwork!.elements.first { $0.id == id }!
  }
  private func source(_ p: Project, _ id: UUID) -> ProductObject { p.objects.first { $0.id == id }! }
  private func equal(_ a: Point2, _ b: Point2, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(a.x, b.x, accuracy: 1e-7, file: file, line: line)
    XCTAssertEqual(a.y, b.y, accuracy: 1e-7, file: file, line: line)
  }
  @MainActor private func imageError(_ a: Artwork, _ b: Artwork) -> Double {
    let first = ArtworkRenderer.image(a, width: 160, height: 150,
      assets: URL(fileURLWithPath: "/tmp"), pixelsPerMM: 2).representations[0] as! NSBitmapImageRep
    let second = ArtworkRenderer.image(b, width: 160, height: 150,
      assets: URL(fileURLWithPath: "/tmp"), pixelsPerMM: 2).representations[0] as! NSBitmapImageRep
    var error = 0.0
    var samples = 0
    for y in stride(from: 0, to: 300, by: 3) {
      for x in stride(from: 0, to: 320, by: 3) {
        let ca = first.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
        let cb = second.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
        error += abs(ca.redComponent - cb.redComponent) + abs(ca.greenComponent - cb.greenComponent)
          + abs(ca.blueComponent - cb.blueComponent)
        samples += 3
      }
    }
    return error / Double(samples)
  }

  func testCreateRetainsGeometryAndStackPositionWithSeparateSource() throws {
    var (p, sheet, mark, label) = try fixture()
    let original = source(p, sheet).artwork!
    let overlay = ArtworkElement(kind: "rectangle", x: 5, y: 5, width: 10, height: 10)
    p.objects[0].artwork!.elements.append(overlay)
    let created = try ComponentCommands.create(in: &p, objectID: sheet, elements: [mark, label], name: "Emblem")
    let ref = element(p, sheet, created.instance)
    XCTAssertEqual(ref.component?.sourceObjectID, created.source)
    XCTAssertEqual(source(p, created.source).componentDefinition, true)
    XCTAssertEqual(source(p, sheet).artwork!.elements.map(\.id), [created.instance, overlay.id])
    XCTAssertEqual(source(p, created.source).artwork!.backgroundOpacity, 0)
    let resolved = try p.resolvingComponents(in: source(p, sheet).artwork!)
    for e in original.elements {
      let expanded = resolved.elements.first { $0.id == ComponentCommands.derivedID(ref.id, e.id) }!
      equal(original.worldTransform(e).apply(.init()), resolved.worldTransform(expanded).apply(.init()))
    }
    XCTAssertEqual(p.minimumSchemaVersion, 6)
  }

  @MainActor func testCreatePreservesAffinePaintParentOpacityAndOuterClip() throws {
    var (p, sheet, mark, label) = try fixture()
    var group = ArtworkElement(kind: "group", x: 25, y: 15, width: 100, height: 100)
    group.contentSize = .init(100, 100)
    group.opacity = 0.7
    group.affine = .init(a: 1, b: 0.1, c: 0.2, d: 1, tx: 0, ty: 0)
    var clip = ArtworkElement(kind: "ellipse", x: 10, y: 10, width: 90, height: 90)
    clip.parentID = group.id
    clip.hidden = true
    for i in p.objects[0].artwork!.elements.indices {
      p.objects[0].artwork!.elements[i].parentID = group.id
      p.objects[0].artwork!.elements[i].clipID = clip.id
    }
    p.objects[0].artwork!.elements[0].gradient = .init()
    p.objects[0].artwork!.elements.insert(group, at: 0)
    p.objects[0].artwork!.elements.append(clip)
    let before = source(p, sheet).artwork!
    let created = try ComponentCommands.create(in: &p, objectID: sheet, elements: [mark, label], name: "Affine emblem")
    XCTAssertEqual(element(p, sheet, created.instance).clipID, clip.id)
    XCTAssertLessThan(imageError(before, p.surfaceArtwork(source(p, sheet))!), 0.0001)
  }

  func testSourceEditsUpdateCrossFrameInstancesWithIndependentSizeAndPaint() throws {
    var (p, sheet, mark, label) = try fixture()
    let made = try ComponentCommands.create(in: &p, objectID: sheet, elements: [mark, label], name: "Emblem")
    let second = try p.makeObject(recipeID: "artboard")
    p.objects.append(second)
    let id = try ComponentCommands.insert(in: &p, objectID: second.id, sourceID: made.source,
      x: 35, y: 20, width: 130, height: 114)
    let raw = source(p, second.id)
    let sourceIndex = p.objects.firstIndex { $0.id == made.source }!
    p.objects[sourceIndex].artwork!.elements[0].color = "#849381"
    let resolved = p.surfaceArtwork(source(p, second.id))!
    let copy = resolved.elements.first { $0.id == ComponentCommands.derivedID(id, mark) }!
    XCTAssertEqual(copy.color, "#849381")
    XCTAssertEqual(source(p, second.id), raw)
    XCTAssertEqual(element(p, second.id, id).width, 130)
    XCTAssertEqual(element(p, second.id, id).height, 114)
    XCTAssertEqual(p.surfaceArtwork(source(p, sheet))!.elements.first {
      $0.id == ComponentCommands.derivedID(made.instance, mark) }!.color, "#849381")
  }

  func testPerPartOverridesTakePrecedenceAndTextResetsRichRuns() throws {
    var (p, sheet, mark, label) = try fixture()
    let made = try ComponentCommands.create(in: &p, objectID: sheet, elements: [mark, label], name: "Emblem")
    let index = p.objects[0].artwork!.elements.firstIndex { $0.id == made.instance }!
    p.objects[0].artwork!.elements[index].component!.color = "#849381"
    p.objects[0].artwork!.elements[index].component!.overrides = [
      .init(elementID: mark, color: "#D45A37", opacity: 0.4),
      .init(elementID: label, text: "EDITION / 02")]
    let expanded = p.surfaceArtwork(source(p, sheet))!
    let shape = expanded.elements.first { $0.id == ComponentCommands.derivedID(made.instance, mark) }!
    let text = expanded.elements.first { $0.id == ComponentCommands.derivedID(made.instance, label) }!
    XCTAssertEqual(shape.color, "#D45A37")
    XCTAssertEqual(shape.opacity, 0.4)
    XCTAssertEqual(text.text, "EDITION / 02")
    XCTAssertEqual(text.color, "#849381")
    XCTAssertNil(text.textRuns)
    XCTAssertEqual(source(p, made.source).artwork!.elements.first { $0.id == label }!.text, "FORM / 01")
  }

  @MainActor func testDetachPreservesPixelsAndBecomesIndependentEditableArtwork() throws {
    var (p, sheet, mark, label) = try fixture()
    let made = try ComponentCommands.create(in: &p, objectID: sheet, elements: [mark, label], name: "Emblem")
    p.objects[0].artwork!.elements[0].component!.overrides = [.init(elementID: label, text: "INDEPENDENT")]
    let before = p.surfaceArtwork(source(p, sheet))!
    try ComponentCommands.detach(in: &p, objectID: sheet, ids: [made.instance])
    let after = p.surfaceArtwork(source(p, sheet))!
    XCTAssertLessThan(imageError(before, after), 0.00001)
    XCTAssertTrue(source(p, sheet).artwork!.elements.allSatisfy { $0.component == nil })
    let index = p.objects.firstIndex { $0.id == made.source }!
    p.objects[index].artwork!.elements[0].width = 80
    XCTAssertEqual(p.surfaceArtwork(source(p, sheet)), after)
    let text = source(p, sheet).artwork!.elements.first { $0.kind == "text" }!
    XCTAssertEqual(text.text, "INDEPENDENT")
    XCTAssertNotEqual(text.id, label)
  }

  func testDerivedElementAndNodeIDsAreStableAndIndependentPerInstance() throws {
    var (p, sheet, mark, label) = try fixture()
    var path = ArtworkElement(kind: "path", x: 0, y: 0, width: 20, height: 20)
    path.path = .init(width: 20, height: 20, contours: [.init([.init(.init()), .init(.init(20, 20))], closed: false)])
    p.objects[0].artwork!.elements.append(path)
    let made = try ComponentCommands.create(in: &p, objectID: sheet, elements: [mark, label, path.id], name: "Paths")
    let other = try ComponentCommands.insert(in: &p, objectID: sheet, sourceID: made.source, x: 100)
    let one = p.surfaceArtwork(source(p, sheet))!
    XCTAssertEqual(one, p.surfaceArtwork(source(p, sheet)))
    let a = one.elements.first { $0.id == ComponentCommands.derivedID(made.instance, path.id) }!
    let b = one.elements.first { $0.id == ComponentCommands.derivedID(other, path.id) }!
    XCTAssertNotEqual(a.path!.contours[0].nodes[0].id, b.path!.contours[0].nodes[0].id)
    XCTAssertEqual(Set(one.elements.map(\.id)).count, one.elements.count)
  }

  func testReferenceCyclesAndExcessiveNestingRejectAtomically() throws {
    var p = Project(name: "Cycles")
    for n in 0..<10 {
      var o = try p.makeObject(recipeID: "artboard", name: "Source \(n)")
      o.componentDefinition = true
      o.artwork = .init(elements: [])
      p.objects.append(o)
    }
    for n in 0..<9 {
      var e = ArtworkElement(kind: "group", x: 0, y: 0)
      e.contentSize = .init(60, 30)
      e.component = .init(sourceObjectID: p.objects[n + 1].id)
      p.objects[n].artwork!.elements = [e]
    }
    // Validate a deep source first, exercising memoized depth checks too.
    p.objects.reverse()
    XCTAssertThrowsError(try p.validateArtworkLinks())
    var (good, sheet, mark, label) = try fixture()
    let made = try ComponentCommands.create(in: &good, objectID: sheet, elements: [mark, label], name: "Cycle")
    let before = good
    XCTAssertThrowsError(try ComponentCommands.insert(in: &good, objectID: made.source, sourceID: made.source))
    XCTAssertEqual(good, before)
  }

  func testInvalidOverridesAndAccidentalUngroupRejectWithoutDataLoss() throws {
    var (p, sheet, mark, label) = try fixture()
    let made = try ComponentCommands.create(in: &p, objectID: sheet, elements: [mark, label], name: "Emblem")
    var art = source(p, sheet).artwork!
    let original = art
    XCTAssertThrowsError(try ArtworkCommands.apply("ungroup", to: &art, ids: [made.instance]))
    XCTAssertEqual(art, original)
    art.elements[0].component!.color = "wrong"
    XCTAssertThrowsError(try validateArtwork(art))
    art = original
    art.elements[0].component!.overrides = [.init(elementID: mark), .init(elementID: mark)]
    XCTAssertThrowsError(try validateArtwork(art))
    art = original
    var child = ArtworkElement(kind: "ellipse", x: 0, y: 0)
    child.parentID = made.instance
    art.elements.append(child)
    XCTAssertThrowsError(try validateArtwork(art))
  }

  func testSchemaSixPersistenceSharedSourceUndoAndDeletionDetachment() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let repo = try ProjectRepository(root: folder)
    let engine = OperationEngine(repository: repo)
    let (p, sheet, mark, label) = try fixture()
    engine.project = p
    let made = try engine.call("form_component", arguments: ["command": "create", "object_id": sheet.uuidString,
      "element_ids": [mark.uuidString, label.uuidString], "name": "Mark"]) as! [String: Any]
    let id = UUID(uuidString: made["source_object_id"] as! String)!
    let after = engine.project!
    engine.undo()
    XCTAssertEqual(engine.project, p)
    engine.redo()
    try engine.flush()
    XCTAssertEqual(try repo.load(p.id).objects, after.objects)
    XCTAssertEqual(try repo.load(p.id).schemaVersion, 6)
    let rendered = after.surfaceArtwork(after.objects[0])
    try engine.call("form_delete_objects", arguments: ["object_ids": [id.uuidString]])
    XCTAssertEqual(engine.project!.surfaceArtwork(engine.project!.objects[0]), rendered)
    XCTAssertFalse(engine.project!.objects[0].artwork!.elements.contains { $0.component != nil })
    engine.undo()
    XCTAssertEqual(engine.project!.objects, after.objects)
  }

  @MainActor func testNestedComponentsRetainLiveBooleansAndOfferOnlyVisiblePaintOverrides() throws {
    var (p, sheet, mark, label) = try fixture()
    var art = source(p, sheet).artwork!
    let cutter = ArtworkElement(kind: "ellipse", x: 28, y: 38, width: 24, height: 24)
    art.elements.append(cutter)
    let boolean = try BooleanCommands.create("subtract", artwork: &art, elements: [mark, cutter.id])
    try p.setArtwork(art, for: sheet)
    XCTAssertEqual(Set(art.componentOverrideParts.map(\.id)), [boolean, label])
    let before = p.surfaceArtwork(source(p, sheet))!
    let first = try ComponentCommands.create(in: &p, objectID: sheet, elements: [boolean, label], name: "Inner")
    let nested = try ComponentCommands.create(in: &p, objectID: sheet, elements: [first.instance], name: "Outer")
    XCTAssertEqual(p.artworkComponents.count, 2)
    XCTAssertLessThan(imageError(before, p.surfaceArtwork(source(p, sheet))!), 0.0001)
    p.objects[0].artwork!.elements[0].component!.color = "#849381"
    let colored = p.surfaceArtwork(source(p, sheet))!
    XCTAssertEqual(colored.elements.first { $0.booleanOperation != nil }!.color, "#849381")
    try ComponentCommands.detach(in: &p, objectID: sheet, ids: [nested.instance])
    XCTAssertTrue(source(p, sheet).artwork!.elements.allSatisfy { $0.component == nil })
    XCTAssertLessThan(imageError(colored, p.surfaceArtwork(source(p, sheet))!), 0.00001)
  }

  func testComponentToolListingAndInvalidOverridesAreAtomic() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let engine = OperationEngine(repository: try .init(root: folder))
    var (p, sheet, mark, label) = try fixture()
    let made = try ComponentCommands.create(in: &p, objectID: sheet, elements: [mark, label], name: "Mark")
    engine.project = p
    let list = try engine.call("form_component", arguments: ["command": "list"]) as! [String: Any]
    XCTAssertEqual((list["components"] as! [[String: Any]]).count, 1)
    XCTAssertTrue(engine.undoStack.isEmpty)
    XCTAssertThrowsError(try engine.call("form_component", arguments: ["command": "override",
      "object_id": sheet.uuidString, "element_ids": [made.instance.uuidString], "color": "invalid"]))
    XCTAssertEqual(engine.project, p)
    XCTAssertTrue(engine.undoStack.isEmpty)
  }

  func testResolutionCacheTracksReachableSourcesAndSkipsUnrelatedChanges() throws {
    var (p, sheet, mark, label) = try fixture()
    let made = try ComponentCommands.create(in: &p, objectID: sheet, elements: [mark, label], name: "Cached")
    let art = source(p, sheet).artwork!
    let start = ComponentCommands.resolutionDiagnostics["builds"] as! Int
    let first = try p.resolvingComponents(in: art)
    XCTAssertEqual(ComponentCommands.resolutionDiagnostics["builds"] as! Int, start + 1)
    XCTAssertEqual(try p.resolvingComponents(in: art), first)
    var unrelated = try p.makeObject(recipeID: "artboard", name: "Unrelated")
    unrelated.componentDefinition = true
    unrelated.artwork = .init(elements: [.init(kind: "ellipse", x: 0, y: 0)])
    p.objects.append(unrelated)
    XCTAssertEqual(try p.resolvingComponents(in: art), first)
    XCTAssertEqual(ComponentCommands.resolutionDiagnostics["builds"] as! Int, start + 1)
    let index = p.objects.firstIndex { $0.id == made.source }!
    p.objects[index].artwork!.elements[0].width += 2
    XCTAssertNotEqual(try p.resolvingComponents(in: art), first)
    XCTAssertEqual(ComponentCommands.resolutionDiagnostics["builds"] as! Int, start + 2)
  }

  func testExpansionBudgetIncludesTextOverrides() throws {
    var (p, sheet, mark, label) = try fixture()
    let made = try ComponentCommands.create(in: &p, objectID: sheet, elements: [mark, label], name: "Text")
    var art = source(p, sheet).artwork!
    let original = art.elements[0]
    art.elements = (0..<31).map { _ in
      var copy = original
      copy.id = UUID()
      copy.component!.overrides = [.init(elementID: label, text: String(repeating: "x", count: 10000))]
      return copy
    }
    try p.setArtwork(art, for: sheet)
    XCTAssertThrowsError(try p.validateArtworkLinks())
  }
}
