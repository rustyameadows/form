import AppKit
import Foundation
import FormCore
import XCTest
@testable import FormApp

@MainActor final class ObjectViewSourceStateTests: XCTestCase {
  private func artwork() -> Artwork {
    .init(background: "#FFFFFF", elements: [
      .init(kind: "rectangle", x: 2, y: 3, width: 12, height: 10, color: "#D45632")
    ])
  }
  private func project() throws -> (Project, UUID, UUID) {
    var project = Project(name: "Independent linked source placement")
    var source = try project.makeObject(recipeID: "box", parameters: ["width": 60, "height": 40, "depth": 30])
    source.artwork = artwork()
    let triangles: [(SIMD3<Double>, SIMD3<Double>, SIMD3<Double>)] = [
      (.init(0, 0, 0), .init(2, 0, 0), .init(2, 1, 0)),
      (.init(0, 0, 0), .init(2, 1, 0), .init(0, 1, 0))
    ]
    var vector = try ObjectViewProjection.project(triangles, azimuth: 0, elevation: 0,
      style: "silhouette", name: "Linked vector")
    vector.objectView = .init(sourceID: source.id, style: "silhouette", linked: true)
    var raster = ArtworkElement(kind: "image", x: 20, y: 20, width: 50, height: 40, asset: "unchanged.png")
    raster.objectView = .init(sourceID: source.id, style: "rendered", linked: true)
    var page = try project.makeObject(recipeID: "artboard")
    page.artwork = .init(elements: [vector, raster])
    project.objects = [source, page]
    return (project, source.id, page.id)
  }

  func testCanvasAndTablePlacementDoNotRefreshVectorPathsOrMarkRasterPending() throws {
    let (before, _, _) = try project()
    var after = before
    after.objects[0].canvasProjectionPositions = ["front": .init(350, -120)]
    after.objects[0].artwork?.canvasPosition = .init(-300, 450)
    after.objects[0].position = .init(10, 20, 30); after.objects[0].rotation = 45
    let originalAfter = after
    XCTAssertEqual(LinkedObjectViewRenderer.state(before.objects[0], in: before),
      LinkedObjectViewRenderer.state(after.objects[0], in: after))
    XCTAssertEqual(ObjectViewUpdates.refreshChangedSources(before: before, project: &after,
      assets: FileManager.default.temporaryDirectory), [])
    LinkedObjectViewRenderer.markPending(before: before, project: &after)
    XCTAssertEqual(after, originalAfter, "Canvas layout must not regenerate stored linked paths, pending flags or assets.")
    XCTAssertEqual(before.objects[1], after.objects[1])
  }

  func testPlacementFastPathStripsOnlyCanvasPositionsAndOrdinaryEditBookkeeping() throws {
    var (before, _, _) = try project()
    var paper = try before.makeObject(recipeID: "tuckCarton")
    var construction = try PaperConstruction.definition(for: paper)
    construction.insideArtwork = artwork(); paper.paperConstruction = construction
    var binding = PhysicalSurfaceArtworkBinding(surfaceID: "detached", sourceObjectID: UUID(), widthMM: 20, heightMM: 20)
    binding.sourceObjectID = nil; binding.artwork = artwork()
    paper.surfaceArtworkBindings = [binding]
    before.objects.append(paper)
    let original = before
    var after = before
    for index in after.objects.indices {
      after.objects[index].canvasProjectionPositions = ["front": .init(300, -80)]
      after.objects[index].artwork?.canvasPosition = .init(100, 200)
      after.objects[index].paperConstruction?.insideArtwork?.canvasPosition = .init(500, 600)
      for surface in after.objects[index].surfaceArtworkBindings?.indices ?? 0..<0 {
        after.objects[index].surfaceArtworkBindings?[surface].artwork?.canvasPosition = .init(700, 800)
      }
    }
    after.updatedAt = before.updatedAt.addingTimeInterval(10)
    after.history.append(.init("Moved Canvas representation"))
    let moved = after
    XCTAssertTrue(ObjectViewSourceChanges.sameExceptCanvasPlacement(before, after))
    XCTAssertEqual(ObjectViewUpdates.refreshChangedSources(before: before, project: &after,
      assets: FileManager.default.temporaryDirectory), [])
    LinkedObjectViewRenderer.markPending(before: before, project: &after)
    XCTAssertEqual(after, moved); XCTAssertEqual(before, original)

    let physicalAndGlobalEdits: [(inout Project) -> Void] = [
      { $0.objects[0].position.x += 1 },
      { $0.objects[0].rotation += 1 },
      { $0.objects[0].artwork!.guides = [.init(axis: "x", position: 8)] },
      { $0.objects[2].paperConstruction!.insideArtwork!.elements[0].width += 1 },
      { $0.objects[2].surfaceArtworkBindings![0].artwork!.elements[0].color = "#225599" },
      { $0.objects[2].surfaceArtworkBindings![0].widthMM += 1 },
      { $0.objects.swapAt(0, 1) },
      { $0.objects[0].id = UUID() },
      { $0.id = UUID() },
      { $0.createdAt = $0.createdAt.addingTimeInterval(1) },
      { $0.camera.azimuth += 0.2 },
      { $0.schemaVersion += 1 },
      { $0.swatches = [.init(name: "Ink", color: "#335599")] },
      { $0.textStyles = [.init(name: "Body", fontSize: 16)] },
      { $0.textStories = [.init(source: .init(kind: "text", x: 0, y: 0, text: "Changed story"))] },
      { $0.recipes.append(.init("new-source", "New source", "cube", "Source dependency", [])) }
    ]
    for (index, edit) in physicalAndGlobalEdits.enumerated() {
      var changed = moved; edit(&changed)
      XCTAssertFalse(ObjectViewSourceChanges.sameExceptCanvasPlacement(before, changed), "Dependency edit \(index)")
    }
  }

  func testPlacementFastPathCannotHideGlyphPaintMaterialOrSharedSourceChanges() throws {
    var (before, _, _) = try project()
    before.objects[0].artwork!.elements.append(.init(kind: "text", x: 10, y: 10, text: "A"))
    let edits: [(inout Project) -> Void] = [
      { $0.objects[0].artwork!.elements[1].glyphOverrides = [
        .init(location: 0, sourceText: "A", glyph: .init(fontName: "Helvetica", glyphID: 36, fontSignature: "source-font-revision"))
      ] },
      { $0.objects[0].artwork!.elements[0].color = "#7822B3" },
      { $0.materials = [Material.presets[0]] }
    ]
    for edit in edits {
      var after = before
      after.objects[0].artwork!.canvasPosition = .init(450, 600)
      edit(&after)
      XCTAssertFalse(ObjectViewSourceChanges.sameExceptCanvasPlacement(before, after))
      LinkedObjectViewRenderer.markPending(before: before, project: &after)
      XCTAssertEqual(after.objects[1].artwork!.elements[1].objectView?.renderPending, true)
    }

    var shared = try before.makeObject(recipeID: "artboard")
    shared.artwork = artwork()
    before.objects[0].artwork = nil
    before.objects[0].artworkSourceID = shared.id; before.objects[0].artworkFit = "actual"
    before.objects.append(shared)
    var after = before
    after.objects[2].artwork!.canvasPosition = .init(10, 20)
    XCTAssertTrue(ObjectViewSourceChanges.sameExceptCanvasPlacement(before, after))
    after.objects[2].artwork!.elements[0].color = "#22AA77"
    XCTAssertFalse(ObjectViewSourceChanges.sameExceptCanvasPlacement(before, after))
    LinkedObjectViewRenderer.markPending(before: before, project: &after)
    XCTAssertEqual(after.objects[1].artwork!.elements[1].objectView?.renderPending, true)
  }

  func testLinkedOutsideInsideAndPhysicalArtworkPlacementIsExcludedFromSourceIdentity() throws {
    var project = Project(name: "Independent physical artwork placements")
    var paper = try project.makeObject(recipeID: "tuckCarton")
    var outside = try project.makeObject(recipeID: "artboard")
    var inside = try project.makeObject(recipeID: "artboard")
    outside.artwork = artwork(); inside.artwork = artwork()
    paper.artworkSourceID = outside.id; paper.artworkFit = "actual"
    var definition = try PaperConstruction.definition(for: paper)
    definition.insideArtworkSourceID = inside.id; paper.paperConstruction = definition
    paper.surfaceArtworkBindings = [.init(surfaceID: "physical", sourceObjectID: outside.id, widthMM: 60, heightMM: 40)]
    project.objects = [paper, outside, inside]
    let before = project, signature = LinkedObjectViewRenderer.state(paper, in: project)
    for index in project.objects.indices {
      project.objects[index].artwork?.canvasPosition = .init(Double(index) * 200, -75)
    }
    project.objects[0].canvasProjectionPositions = ["outside:front": .init(-800, 100)]
    XCTAssertEqual(signature, LinkedObjectViewRenderer.state(project.objects[0], in: project))
    XCTAssertNotEqual(project, before, "The edit remains authored Canvas layout, only the render identity excludes it.")
    project.objects[2].artwork!.elements[0].color = "#254DC7"
    XCTAssertNotEqual(signature, LinkedObjectViewRenderer.state(project.objects[0], in: project),
      "Actual linked inside print must still invalidate the rendered source.")

    var detached = before
    detached.objects[0].paperConstruction?.insideArtworkSourceID = nil
    detached.objects[0].paperConstruction?.insideArtwork = artwork()
    detached.objects[0].surfaceArtworkBindings?[0].sourceObjectID = nil
    detached.objects[0].surfaceArtworkBindings?[0].artwork = artwork()
    let detachedSignature = LinkedObjectViewRenderer.state(detached.objects[0], in: detached)
    detached.objects[0].updateStoredArtworks { $0.canvasPosition = .init(900, 600) }
    XCTAssertEqual(detachedSignature, LinkedObjectViewRenderer.state(detached.objects[0], in: detached))
    detached.objects[0].surfaceArtworkBindings?[0].artwork?.elements[0].width = 25
    XCTAssertNotEqual(detachedSignature, LinkedObjectViewRenderer.state(detached.objects[0], in: detached))
  }

  func testGeometryPaintAndMaterialEditsStillMarkLinkedRasterPending() throws {
    let (before, _, _) = try project()
    let edits: [(inout Project) -> Void] = [
      { $0.objects[0].parameters["height"] = 55 },
      { $0.objects[0].artwork!.elements[0].color = "#2046A5" },
      { $0.objects[0].color = "#85A520" },
      { $0.materials = [Material.presets[0]] }
    ]
    let baseline = LinkedObjectViewRenderer.state(before.objects[0], in: before)
    for edit in edits {
      var after = before; edit(&after)
      XCTAssertNotEqual(baseline, LinkedObjectViewRenderer.state(after.objects[0], in: after))
      LinkedObjectViewRenderer.markPending(before: before, project: &after)
      XCTAssertEqual(after.objects[1].artwork?.elements[1].objectView?.renderPending, true)
    }
  }

  func testPaperValueStateIncludesDetachedNestedComponentAndSharedSwatchDependencies() throws {
    var project = Project(name: "Detached paper component dependencies")
    var paper = try project.makeObject(recipeID: "tuckCarton")
    paper.artwork = artwork()
    let swatch = ArtworkSwatch(name: "Inside ink", color: "#2468AB")
    project.swatches = [swatch]
    var leaf = try project.makeObject(recipeID: "artboard", parameters: ["width": 20, "depth": 20])
    leaf.componentDefinition = true; leaf.canvasSourceOnly = true
    var ink = ArtworkElement(kind: "rectangle", x: 1, y: 1, width: 10, height: 10)
    ink.fillSwatchID = swatch.id; leaf.artwork = .init(elements: [ink])
    var parent = try project.makeObject(recipeID: "artboard", parameters: ["width": 30, "depth": 30])
    parent.componentDefinition = true; parent.canvasSourceOnly = true
    var nested = ArtworkElement(kind: "group", x: 1, y: 1, width: 20, height: 20)
    nested.component = .init(sourceObjectID: leaf.id); nested.contentSize = .init(20, 20)
    parent.artwork = .init(elements: [nested])
    var instance = ArtworkElement(kind: "group", x: 5, y: 6, width: 30, height: 30)
    instance.component = .init(sourceObjectID: parent.id); instance.contentSize = .init(30, 30)
    var construction = try PaperConstruction.definition(for: paper)
    construction.insideArtwork = .init(elements: [instance]); paper.paperConstruction = construction
    project.objects = [paper, parent, leaf]
    let baseline = LinkedObjectViewRenderer.state(paper, in: project)
    XCTAssertTrue(try XCTUnwrap(baseline.inside).elements.contains { $0.color == "#2468AB" })
    XCTAssertTrue(try XCTUnwrap(baseline.inside).elements.allSatisfy { $0.component == nil })

    var changed = project
    changed.objects[2].artwork!.elements[0].width += 2
    XCTAssertEqual(changed.objects[0], paper)
    XCTAssertNotEqual(baseline, LinkedObjectViewRenderer.state(paper, in: changed))
    changed = project; changed.swatches![0].color = "#AB6824"
    XCTAssertEqual(changed.objects, project.objects)
    let recolored = LinkedObjectViewRenderer.state(paper, in: changed)
    XCTAssertNotEqual(baseline, recolored)
    XCTAssertTrue(try XCTUnwrap(recolored.inside).elements.contains { $0.color == "#AB6824" })
    changed = project
    changed.objects[0].canvasProjectionPositions = ["inside": .init(600, -200)]
    changed.objects[0].paperConstruction!.insideArtwork!.canvasPosition = .init(-500, 100)
    XCTAssertEqual(baseline, LinkedObjectViewRenderer.state(changed.objects[0], in: changed))
  }

  func testPaperValueStateRetainsLinkedRuntimeStorySnapshotWhenObjectsAreUnchanged() throws {
    var project = Project(name: "Linked inside story dependency")
    var paper = try project.makeObject(recipeID: "tuckCarton")
    var inside = try project.makeObject(recipeID: "artboard")
    var frame = ArtworkElement(kind: "text", x: 3, y: 4, width: 50, height: 30, text: "Inside original")
    frame.typography = .init(); frame.typography!.frameMode = "area"
    let story = TextStory(source: frame, frames: [.init(objectID: inside.id, elementID: frame.id)])
    frame.storyFrame = .init(storyID: story.id)
    inside.artwork = .init(elements: [frame])
    var construction = try PaperConstruction.definition(for: paper)
    construction.insideArtworkSourceID = inside.id; paper.paperConstruction = construction
    project.objects = [paper, inside]; project.textStories = [story]
    let baseline = LinkedObjectViewRenderer.state(paper, in: project)
    XCTAssertEqual(baseline.inside?.elements[0].storyFrame?.resolved?.story.text, "Inside original")
    var changed = project; changed.textStories![0].text = "Current shared story"
    XCTAssertEqual(changed.objects, project.objects)
    let current = LinkedObjectViewRenderer.state(paper, in: changed)
    XCTAssertNotEqual(baseline, current)
    XCTAssertEqual(current.inside?.elements[0].storyFrame?.resolved?.story.text, "Current shared story")
    XCTAssertEqual(current.inside?.elements[0].storyFrame?.frame?.objectID, inside.id)
  }

  func testPaperValueStateKeepsConstructionParametersStockAndRuntimeFontRevision() throws {
    var project = Project(name: "Paper shape and font dependencies")
    var paper = try project.makeObject(recipeID: "tuckCarton")
    paper.artwork = artwork(); paper.paperConstruction = try PaperConstruction.definition(for: paper)
    project.objects = [paper]
    let baseline = LinkedObjectViewRenderer.state(paper, in: project)
    var changed = project; changed.objects[0].parameters["width"]! += 5
    XCTAssertNotEqual(baseline, LinkedObjectViewRenderer.state(changed.objects[0], in: changed))
    changed = project
    changed.objects[0].parameters["stock"]! += 0.05
    changed.objects[0].paperConstruction!.stock.thicknessMM += 0.05
    XCTAssertNotEqual(baseline, LinkedObjectViewRenderer.state(changed.objects[0], in: changed))
    let font = try XCTUnwrap(baseline.paperFontRevision)
    GeometryFactory.invalidateFontResources()
    let reloadedFonts = LinkedObjectViewRenderer.state(paper, in: project)
    XCTAssertEqual(reloadedFonts.paperFontRevision, font + 1)
    XCTAssertNotEqual(baseline, reloadedFonts, "An async capture made with old fonts must not publish into the new font state.")
    XCTAssertEqual(project.objects, [paper])
  }

  func testCanvasPlacementDoesNotStartRenderButSubsequentPaintEditDoes() async throws {
    let (before, _, _) = try project()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("linked-placement-" + UUID().uuidString)
    let store = StudioStore(repository: try ProjectRepository(root: directory), seedLibrary: false)
    store.engine.project = before
    var captures = 0
    let captured = expectation(description: "Actual paint edit captures current source")
    let renderer = LinkedObjectViewRenderer(store: store) { _, _, _, _, _, _, _ in
      captures += 1; captured.fulfill(); return Data("current rendered source".utf8)
    }
    defer { renderer.reset(); store.engine.project = nil; try? FileManager.default.removeItem(at: directory) }
    renderer.synchronize(before)
    var moved = before
    moved.objects[0].canvasProjectionPositions = ["front": .init(200, 100)]
    moved.objects[0].artwork?.canvasPosition = .init(-100, 400)
    store.engine.project = moved; renderer.synchronize(moved)
    for _ in 0..<20 { await Task.yield() }
    XCTAssertEqual(captures, 0)
    XCTAssertEqual(store.project?.objects[1], before.objects[1])
    moved.objects[0].artwork!.elements[0].color = "#A32976"
    store.engine.project = moved; renderer.synchronize(moved)
    await fulfillment(of: [captured], timeout: 5)
    XCTAssertEqual(captures, 1)
  }
}
