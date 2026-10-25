import AppKit
import Metal
import SwiftUI
import XCTest

@testable import FormApp
@testable import FormCore
@testable import FormGraphics

@MainActor final class AffinitiesStudyEditingTests: XCTestCase {
  @MainActor private final class Fixture {
    let root: URL
    let store: StudioStore
    init(create: Bool = true) throws {
      _ = NSApplication.shared
      root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      store = StudioStore(repository: try ProjectRepository(root: root), seedLibrary: false)
      if create { store.createProject(template: "affinities") }
    }
    func close() {
      store.engine.project = nil
      try? FileManager.default.removeItem(at: root)
    }
  }
  private func source(_ p: Project) throws -> ProductObject {
    try XCTUnwrap(p.objects.first { $0.name == AffinitiesStudy.sourceName })
  }
  private func saved(_ store: StudioStore) async throws {
    let deadline = Date().addingTimeInterval(5)
    while store.saving && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
    XCTAssertFalse(store.saving)
  }
  private func proofDirectory() throws -> URL? {
    guard let path = ProcessInfo.processInfo.environment["FORM_AFFINITIES_PROOF_DIR"] else {
      return nil
    }
    let directory = URL(fileURLWithPath: path)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }
  func testNativeCreationOpensSplitWithEditableWordmarkAndLinkedEditionWithoutAnExtraUndo() throws {
    let f = try Fixture()
    defer { f.close() }
    XCTAssertNil(f.store.error)
    let p = try XCTUnwrap(f.store.project)
    let original = try source(p)
    XCTAssertEqual(f.store.surfaceLayout, .split)
    XCTAssertEqual(f.store.mode, .artwork)
    XCTAssertEqual(f.store.artworkSession.objectID, original.id)
    XCTAssertEqual(f.store.artworkSession.primary?.name, "Editable display wordmark")
    XCTAssertEqual(f.store.artworkSession.primary?.fontSize, 67)
    XCTAssertEqual(f.store.primary?.name, "AFFINITIES / Oak edition")
    XCTAssertEqual(f.store.artworkSession.previewObject?.id, f.store.primary?.id)
    XCTAssertTrue(f.store.engine.undoStack.isEmpty)
    XCTAssertEqual(try f.store.repository.load(p.id).objects, p.objects)
  }
  func testUnavailableFontsOpenExplicitDiagnosticsWithoutChangingAssignmentsOrStoredOutlines()
    throws
  {
    let f = try Fixture()
    defer { f.close() }
    let before = f.store.project!
    let library = f.store.library
    let missing = f.store.presentAffinitiesStudy(fontAvailable: { $0 != "Baskerville" })
    XCTAssertEqual(missing, ["Baskerville"])
    XCTAssertTrue(f.store.showingDocumentFonts)
    XCTAssertEqual(f.store.project, before)
    XCTAssertEqual(f.store.library, library)
    XCTAssertTrue(f.store.engine.undoStack.isEmpty)
    XCTAssertEqual(
      try source(f.store.project!).artwork!.elements.first {
        $0.name == "Editable display wordmark"
      }?.typography?.fontName, "Baskerville")
    XCTAssertTrue(
      before.objects.first { $0.name == AffinitiesStudy.alternateName }!.artwork!.elements.contains
      { $0.kind == "path" && $0.name?.contains("wordmark · outlines") == true })
    XCTAssertEqual(
      AffinitiesStudyPresentation.missingFonts(in: before, available: { _ in true }), [])
  }
  func testRecordedOutlineAlternateMatchesActualCurrentCoreTextShaping() throws {
    let p = try Samples.affinities()
    guard FontLibraryCatalog.installed("Baskerville") else {
      XCTAssertTrue(AffinitiesStudyPresentation.missingFonts(in: p).contains("Baskerville"))
      return
    }
    let alternate = p.objects.first { $0.name == AffinitiesStudy.alternateName }!
    let original = alternate.artwork!
    var editable = original
    editable.elements.removeAll { $0.name == "Editable display wordmark · outlines" }
    let index = editable.elements.firstIndex {
      $0.name == "Editable display wordmark · editable source"
    }!
    editable.elements[index].hidden = false
    let conversion = try ArtworkOutlines.convert(
      editable, ids: [editable.elements[index].id], mode: "text")
    XCTAssertFalse(conversion.created.isEmpty)
    let assets = FileManager.default.temporaryDirectory
    let a = ArtworkRenderer.image(
      original, width: 203.2, height: 254, assets: assets, pixelsPerMM: 2)
    let b = ArtworkRenderer.image(
      conversion.artwork, width: 203.2, height: 254, assets: assets, pixelsPerMM: 2)
    let ar = try XCTUnwrap(NSBitmapImageRep(data: a.tiffRepresentation!))
    let br = try XCTUnwrap(NSBitmapImageRep(data: b.tiffRepresentation!))
    var error = 0.0
    var samples = 0.0
    for y in stride(from: 0, to: ar.pixelsHigh, by: 2) {
      for x in stride(from: 0, to: ar.pixelsWide, by: 2) {
        let ac = ar.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
        let bc = br.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
        error +=
          abs(ac.redComponent - bc.redComponent) + abs(ac.greenComponent - bc.greenComponent)
          + abs(ac.blueComponent - bc.blueComponent)
        samples += 3
      }
    }
    XCTAssertLessThan(
      error / samples, 0.001,
      "Recorded real glyph geometry must agree with the assigned font, not an invented wordmark shape."
    )
  }
  func testNativeWordmarkEditUpdatesOnlySourceResourceAndBothPhysicalMeshesWithOneUndo()
    async throws
  {
    let f = try Fixture()
    defer { f.close() }
    let before = f.store.project!
    let original = try source(before)
    let scene = TableSceneController(store: f.store)
    f.store.scene = scene
    f.store.synchronizeScene()
    let builds = scene.geometryBuilds
    let package = f.store.repository.url(for: before.id)
    func refs() throws -> [String: String] {
      let manifest =
        try JSONSerialization.jsonObject(
          with: Data(contentsOf: package.appendingPathComponent("Manifest.json"))) as! [String: Any]
      return Dictionary(
        uniqueKeysWithValues: (manifest["objects"] as! [[String: Any]]).map {
          ($0["id"] as! String, $0["file"] as! String)
        })
    }
    let oldRefs = try refs()
    f.store.artworkSession.update { $0.fontSize = 69 }
    // The real Table representable performs this sync when the published revision changes.
    f.store.synchronizeScene()
    XCTAssertEqual(f.store.engine.undoStack.count, 1)
    XCTAssertEqual(f.store.artworkSession.primary?.fontSize, 69)
    XCTAssertEqual(scene.geometryBuilds, builds + 3)
    XCTAssertEqual(
      f.store.project!.objects.filter { $0.id != original.id },
      before.objects.filter { $0.id != original.id })
    try await saved(f.store)
    let changedRefs = try refs()
    XCTAssertEqual(
      Set(oldRefs.keys.filter { oldRefs[$0] != changedRefs[$0] }), [original.id.uuidString])
    f.store.undo()
    XCTAssertEqual(f.store.project!.objects, before.objects)
    XCTAssertEqual(f.store.artworkSession.primary?.fontSize, 67)
  }
  func testStudyExportsAndReopenPreserveRealPhysicalSizeAndOriginalSource() async throws {
    let f = try Fixture()
    defer { f.close() }
    let p = f.store.project!
    let before = p
    let original = try source(p)
    let alternate = p.objects.first { $0.name == AffinitiesStudy.alternateName }!
    let edition = p.objects.first { $0.recipeID == "box" }!
    let proof = try proofDirectory()
    for (name, object) in [
      ("composition", original), ("outlined-alternate", alternate), ("physical-face", edition),
    ] {
      for format in ["pdf", "svg", "png"] {
        let path = f.root.appendingPathComponent(name + "." + format)
        let result =
          try f.store.exportArtwork(
            object: object, arguments: ["format": format, "path": path.path, "dpi": 150.0])
          as! [String: Any]
        XCTAssertEqual(result["width_mm"] as? Double, 203.2)
        XCTAssertEqual(result["height_mm"] as? Double, 254)
        let data = try Data(contentsOf: path)
        if format == "pdf" {
          let doc = try XCTUnwrap(CGPDFDocument(CGDataProvider(data: data as CFData)!))
          let box = doc.page(at: 1)!.getBoxRect(.mediaBox)
          XCTAssertEqual(box.width, 576, accuracy: 0.01)
          XCTAssertEqual(box.height, 720, accuracy: 0.01)
        }
        if format == "png" {
          let image = try XCTUnwrap(NSBitmapImageRep(data: data))
          XCTAssertEqual(image.pixelsWide, 1200)
          XCTAssertEqual(image.pixelsHigh, 1500)
        }
        if let proof { try data.write(to: proof.appendingPathComponent(name + "." + format)) }
      }
    }
    XCTAssertEqual(f.store.project, before)
    f.store.openProject(p.id)
    XCTAssertEqual(f.store.project!.objects, p.objects)
    if let proof {
      if MTLCreateSystemDefaultDevice() != nil {
        let image = TableSceneController.preview(
          project: p, size: .init(width: 1500, height: 900), assets: f.root, fitContents: true)
        let rep = try XCTUnwrap(NSBitmapImageRep(data: image.tiffRepresentation!))
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(
          to: proof.appendingPathComponent("linked-material-editions.png"))
      }
      let card = NSHostingView(
        rootView: StudyCard(template: Samples.templates.first { $0.id == "affinities" }!)
          .environmentObject(f.store).frame(width: 430, height: 116).background(Palette.paper))
      let window = NSWindow(
        contentRect: .init(x: 0, y: 0, width: 430, height: 116), styleMask: [.borderless],
        backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      card.sizingOptions = []
      window.contentView = card
      defer { window.close() }
      card.layoutSubtreeIfNeeded()
      try await Task.sleep(for: .milliseconds(100))
      card.layoutSubtreeIfNeeded()
      XCTAssertEqual(card.bounds.width, 430, accuracy: 0.1)
      XCTAssertEqual(card.bounds.height, 116, accuracy: 0.1)
      let image = try XCTUnwrap(card.bitmapImageRepForCachingDisplay(in: card.bounds))
      card.cacheDisplay(in: card.bounds, to: image)
      try XCTUnwrap(image.representation(using: .png, properties: [:])).write(
        to: proof.appendingPathComponent("native-study-card.png"))
    }
  }
}
