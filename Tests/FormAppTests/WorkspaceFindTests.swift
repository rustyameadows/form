import AppKit
import FormCADModel
import FormCore
import FormGraphics
import XCTest
@testable import FormApp

@MainActor final class WorkspaceFindTests: XCTestCase {
  @MainActor private final class Fixture {
    let directory: URL, store: StudioStore, window: NSWindow
    let scroll: ArtworkScrollView, canvas: VectorCanvasView
    var session: ArtworkSession { store.artworkSession }

    init(_ project: Project, sourceID: UUID) throws {
      _ = NSApplication.shared
      directory = FileManager.default.temporaryDirectory.appendingPathComponent("workspace-find-" + UUID().uuidString)
      store = StudioStore(repository: try ProjectRepository(root: directory), seedLibrary: false)
      store.engine.project = project; store.showingHome = false; store.environment = .form; store.mode = .artwork
      store.surfaceLayout = .split; store.splitDirection = .stacked
      window = NSWindow(contentRect: .init(x: -10000, y: -10000, width: 1000, height: 700),
        styleMask: [.titled], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      scroll = ArtworkScrollView(frame: window.contentView!.bounds)
      scroll.allowsMagnification = true; scroll.minMagnification = 0.08; scroll.maxMagnification = 24
      canvas = VectorCanvasView(frame: scroll.bounds)
      canvas.session = store.artworkSession; store.artworkSession.canvas = canvas
      scroll.documentView = canvas; window.contentView = scroll
      store.artworkSession.activate(sourceID)
      canvas.synchronize(); canvas.fit(all: true)
    }

    func close() {
      canvas.finishText(); window.contentView = nil; window.close(); store.engine.project = nil
      try? FileManager.default.removeItem(at: directory)
    }

    func elementResults(_ query: String) -> [WorkspaceFindResult] {
      store.workspaceFindResults(for: .artwork, query: query).filter {
        if case .canvasElement = $0.target { return true }; return false
      }
    }
  }

  private func text(_ value: String, x: Double = 8, y: Double = 8) -> ArtworkElement {
    .init(kind: "text", x: x, y: y, width: 24, height: 8, text: value, color: "#24353D", fontSize: 12)
  }

  private func plainProject() throws -> (Project, UUID, UUID, ArtworkElement) {
    var project = Project(name: "Search preserves canonical documents")
    let element = text("Amber needle 742")
    var source = try project.makeObject(recipeID: "artboard", name: "Pearl layout", parameters: ["width": 160, "depth": 100])
    source.artwork = Artwork(elements: [element], bleed: 0)
    let physical = try project.makeObject(recipeID: "box", name: "Measuring block")
    project.objects = [source, physical]
    project.camera.distance = 19; project.camera.azimuth = 0.91
    return (project, source.id, physical.id, element)
  }

  private func paperProject(insideSource: Bool) throws -> (Project, UUID, UUID, ArtworkElement) {
    var project = Project(name: "One source, several physical views")
    let authored = PlanarConstructionDefinition(name: "Search folded paper", size: .init(70, 30), stockThickness: 1,
      panels: [
        .init(id: "left", name: "Left", polygon: [.init(0, 0), .init(40, 0), .init(40, 30), .init(0, 30)]),
        .init(id: "right", name: "Right", polygon: [.init(40, 0), .init(70, 0), .init(70, 30), .init(40, 30)], artworkRotationDegrees: 90)
      ], hinges: [.init(id: "crease", parentPanelID: "left", childPanelID: "right", start: .init(40, 0), end: .init(40, 30), angleDegrees: 90)],
      rootPanelID: "left")
    let recipe = Recipe("search-fold", "Search folded paper", "square", "Data-authored search fixture", [])
    project.recipes = [recipe]
    var paper = try project.makeObject(recipeID: recipe.id, name: "Folded sample")
    var construction = PaperConstruction(kind: .authored, dimensions: .init(width: 70, height: 30, depth: 1))
    construction.authored = authored; construction.stock.thicknessMM = 1
    let element = text("Quartz cross-panel 983", x: 36, y: 8)
    paper.artwork = Artwork(elements: [element], bleed: 0)
    var sourceID = paper.id
    if insideSource {
      var inside = try project.makeObject(recipeID: "artboard", name: "Registered inside", parameters: ["width": 70, "depth": 30])
      inside.artwork = Artwork(elements: [element], bleed: 0); inside.canvasSourceOnly = true
      sourceID = inside.id; construction.insideArtworkSourceID = inside.id
      // Each side has its own canonical source. The query must only match the
      // inside source in this variant, even though both physical views exist.
      paper.artwork = Artwork(bleed: 0); project.objects.append(inside)
    }
    paper.paperConstruction = construction; project.objects.insert(paper, at: 0)
    let physical = try project.makeObject(recipeID: "box", name: "Unrelated Table selection")
    project.objects.append(physical)
    return (project, paper.id, sourceID, element)
  }

  func testInventoriesHaveStableIdentitiesAndReadingSearchDoesNotSelectOrSave() throws {
    let (project, sourceID, physicalID, element) = try plainProject()
    let f = try Fixture(project, sourceID: sourceID); defer { f.close() }
    f.store.select(physicalID)
    let before = f.store.project, selection = f.store.engine.selection, history = f.store.engine.undoStack.count
    let canvas = f.store.workspaceFindResults(for: .artwork, query: "pearl")
    XCTAssertTrue(canvas.contains { $0.target == .canvasFrame(sourceID) })
    let content = f.elementResults("NEEDLE 742")
    XCTAssertEqual(content.count, 1)
    XCTAssertEqual(content.first?.target, .canvasElement(frameID: sourceID, sourceID: sourceID, elementID: element.id))
    XCTAssertEqual(content.map(\.id), f.elementResults("needle 742").map(\.id))
    let table = f.store.workspaceFindResults(for: .table, query: "measuring")
    XCTAssertTrue(table.contains { $0.target == .tableObject(physicalID) })
    XCTAssertTrue(table.allSatisfy { if case .tableObject = $0.target { return true }; return false })
    XCTAssertEqual(f.store.project, before); XCTAssertEqual(f.store.engine.selection, selection)
    XCTAssertEqual(f.store.engine.undoStack.count, history)
  }

  func testProjectionMatchesDeduplicateAndRevealTheActiveRotatedOrReflectedFrame() throws {
    for inside in [false, true] {
      let (project, paperID, sourceID, element) = try paperProject(insideSource: inside)
      let f = try Fixture(project, sourceID: sourceID); defer { f.close() }
      let target = try XCTUnwrap(f.session.frames.first {
        $0.projection?.constructionID == paperID && $0.projection?.inside == inside && $0.projection?.panelID == "right"
      })
      f.session.activate(target.id); f.canvas.synchronize()
      let physicalID = try XCTUnwrap(project.objects.last?.id)
      f.store.select(physicalID)
      let before = f.store.project, history = f.store.engine.undoStack.count, selection = f.store.engine.selection
      let matches = f.elementResults("quartz cross-panel")
      XCTAssertEqual(matches.count, 1, "Proof and panel representations must not repeat one canonical text result.")
      let match = try XCTUnwrap(matches.first)
      XCTAssertEqual(match.target, .canvasElement(frameID: target.id, sourceID: sourceID, elementID: element.id))
      XCTAssertTrue(f.store.revealFindResult(match))
      XCTAssertEqual(f.session.activeFrameID, target.id); XCTAssertEqual(f.session.objectID, sourceID)
      XCTAssertEqual(f.session.selection, [element.id]); XCTAssertEqual(f.session.activeProjection?.inside, inside)
      let shown = try XCTUnwrap(f.session.art.elements.first { $0.id == element.id })
      let box = f.session.art.bounds(of: shown)
      let center = CGPoint(x: target.rect.minX + box.x + box.width / 2, y: target.rect.minY + box.y + box.height / 2)
      XCTAssertTrue(f.canvas.visibleCanvasRect.contains(center), "Find must reveal displayed coordinates, including inside parity and panel rotation.")
      XCTAssertEqual(f.store.engine.selection, selection); XCTAssertEqual(f.store.project, before)
      XCTAssertEqual(f.store.engine.undoStack.count, history)
      XCTAssertEqual(f.store.surfaceLayout, .split); XCTAssertEqual(f.store.splitDirection, .stacked)
    }
  }

  func testNestedComponentTextAndSharedStorySearchUseSelectableCanonicalTargets() throws {
    var (project, sourceID, _, _) = try plainProject()
    var group = ArtworkElement(kind: "group", x: 10, y: 12, width: 80, height: 40)
    group.name = "Nested group"
    var nested = text("Nested thimble phrase"); nested.parentID = group.id
    var componentText = text("Reusable spool phrase", x: 100, y: 10)
    componentText.name = "Component lettering"
    project.objects[0].artwork?.elements = [group, nested, componentText]
    let component = try ComponentCommands.create(in: &project, objectID: sourceID, elements: [componentText.id], name: "Reusable mark")
    let first = text("Shared shuttle phrase", x: 12, y: 60), second = text("", x: 70, y: 60)
    project.objects[0].artwork?.elements.append(contentsOf: [first, second])
    _ = try PublicationCommands.createStory(in: &project,
      frames: [.init(objectID: sourceID, elementID: first.id), .init(objectID: sourceID, elementID: second.id)], name: "Shared story")
    let f = try Fixture(project, sourceID: sourceID); defer { f.close() }
    let before = f.store.project, history = f.store.engine.undoStack.count
    let nestedResult = try XCTUnwrap(f.elementResults("thimble phrase").first)
    f.session.scopeID = nil
    XCTAssertTrue(f.store.revealFindResult(nestedResult))
    XCTAssertEqual(f.session.scopeID, group.id); XCTAssertEqual(f.session.selection, [nested.id])
    // The separately editable component definition is another legitimate
    // source result. The containing artboard must expose its own instance,
    // rather than selecting an uneditable generated descendant there.
    let componentMatches = f.elementResults("spool phrase").filter {
      if case .canvasElement(_, let owner, _) = $0.target { return owner == sourceID }; return false
    }
    XCTAssertEqual(componentMatches.count, 1)
    XCTAssertEqual(componentMatches.first?.target, .canvasElement(frameID: sourceID, sourceID: sourceID, elementID: component.instance))
    XCTAssertTrue(f.store.revealFindResult(try XCTUnwrap(componentMatches.first)))
    XCTAssertEqual(f.session.selection, [component.instance])
    XCTAssertNil(f.session.componentReturn, "Find selects the existing instance instead of inventing a derived child selection.")
    XCTAssertEqual(f.elementResults("shuttle phrase").count, 1, "One story should not duplicate its complete text in every connected frame.")
    XCTAssertEqual(f.store.project, before); XCTAssertEqual(f.store.engine.undoStack.count, history)
  }

  func testRevealingAnUncreatedInsideFaceDoesNotCreateItsCanonicalSource() throws {
    let (project, paperID, sourceID, _) = try paperProject(insideSource: false)
    let f = try Fixture(project, sourceID: sourceID); defer { f.close() }
    let inside = try XCTUnwrap(f.session.frames.first {
      $0.projection?.constructionID == paperID && $0.projection?.inside == true && $0.projection?.isProof == true
    })
    XCTAssertEqual(inside.projection?.requiresInsideSource, true)
    let before = f.store.project, history = f.store.engine.undoStack.count
    let match = try XCTUnwrap(f.store.workspaceFindResults(for: .artwork, query: inside.title).first { $0.target == .canvasFrame(inside.id) })
    XCTAssertTrue(f.store.revealFindResult(match))
    XCTAssertEqual(f.session.activeFrameID, inside.id); XCTAssertEqual(f.session.activeProjection?.inside, true)
    XCTAssertTrue(f.session.selection.isEmpty)
    XCTAssertNil(f.store.project?.objects.first { $0.id == paperID }?.paperConstruction?.insideArtworkSourceID)
    XCTAssertEqual(f.store.project, before); XCTAssertEqual(f.store.engine.undoStack.count, history)
  }

  func testResultsRejectRemovedElementsAndDifferentProjectsBeforeChangingViewState() throws {
    let (project, sourceID, physicalID, element) = try plainProject()
    let f = try Fixture(project, sourceID: sourceID); defer { f.close() }
    f.store.select(physicalID)
    let match = try XCTUnwrap(f.elementResults("needle 742").first)
    f.store.engine.project?.objects[0].artwork?.elements.removeAll { $0.id == element.id }
    let before = f.store.project, selection = f.store.engine.selection, frameID = f.session.activeFrameID
    XCTAssertFalse(f.store.revealFindResult(match))
    XCTAssertEqual(f.store.project, before); XCTAssertEqual(f.store.engine.selection, selection)
    XCTAssertEqual(f.session.activeFrameID, frameID)
    let frameResult = try XCTUnwrap(f.store.workspaceFindResults(for: .artwork, query: "Pearl layout").first { $0.target == .canvasFrame(sourceID) })
    var replacement = project; replacement.id = UUID(); replacement.name = "A different document with copied object IDs"
    f.store.engine.project = replacement
    let replacementSelection = f.store.engine.selection, replacementFrame = f.session.activeFrameID
    XCTAssertFalse(f.store.revealFindResult(frameResult)); XCTAssertEqual(f.store.project, replacement)
    XCTAssertEqual(f.store.engine.selection, replacementSelection); XCTAssertEqual(f.session.activeFrameID, replacementFrame)
    XCTAssertTrue(f.store.engine.undoStack.isEmpty)
  }

  func testSearchFocusRequestsRetainIndependentQueriesSourcesAndExistingLayouts() throws {
    let (project, sourceID, physicalID, element) = try plainProject()
    let f = try Fixture(project, sourceID: sourceID); defer { f.close() }
    f.session.choose([element.id]); f.session.tool = .pen
    f.canvas.setZoom(1.7); f.store.select(physicalID)
    f.store.canvasSearchQuery = "Canvas phrase"; f.store.tableSearchQuery = "Table phrase"
    let before = f.store.project, history = f.store.engine.undoStack.count
    let selection = f.store.engine.selection, frame = f.session.activeFrameID
    for layout in [DesignSurfaceLayout.single, .split, .detached] {
      f.store.surfaceLayout = layout; f.store.splitDirection = .stacked
      let canvasRequest = f.store.canvasSearchFocusRequest
      f.store.requestWorkspaceFind(.artwork)
      XCTAssertTrue(f.store.canvasFindVisible); XCTAssertGreaterThan(f.store.canvasSearchFocusRequest, canvasRequest)
      let tableRequest = f.store.tableSearchFocusRequest
      f.store.requestWorkspaceFind(.table)
      XCTAssertTrue(f.store.tableNavigatorVisible); XCTAssertGreaterThan(f.store.tableSearchFocusRequest, tableRequest)
      XCTAssertEqual(f.store.surfaceLayout, layout); XCTAssertEqual(f.store.splitDirection, .stacked)
      XCTAssertEqual(f.store.canvasSearchQuery, "Canvas phrase"); XCTAssertEqual(f.store.tableSearchQuery, "Table phrase")
      XCTAssertEqual(f.session.activeFrameID, frame); XCTAssertEqual(f.session.selection, [element.id])
      XCTAssertEqual(f.session.tool, .pen); XCTAssertEqual(f.canvas.zoom, 1.7, accuracy: 1e-9)
    }
    XCTAssertEqual(f.store.engine.selection, selection); XCTAssertEqual(f.store.project, before)
    XCTAssertEqual(f.store.engine.undoStack.count, history)
  }

  func testSharedStoryContentAcrossDifferentPagesAppearsOnce() throws {
    var (project, sourceID, _, first) = try plainProject()
    first.text = "Global bobbin story phrase"
    project.objects[0].artwork?.elements = [first]
    var page = try project.makeObject(recipeID: "artboard", name: "Second page", parameters: ["width": 160, "depth": 100])
    let second = text("")
    page.artwork = Artwork(elements: [second], bleed: 0); project.objects.append(page)
    _ = try PublicationCommands.createStory(in: &project, frames: [
      .init(objectID: sourceID, elementID: first.id), .init(objectID: page.id, elementID: second.id)
    ], name: "A story on two physical pages")
    let f = try Fixture(project, sourceID: sourceID); defer { f.close() }
    let before = f.store.project
    let matches = f.elementResults("global bobbin story")
    XCTAssertEqual(matches.count, 1, "A story is one source even when its text flows through separate page objects.")
    XCTAssertEqual(matches.first?.target, .canvasElement(frameID: sourceID, sourceID: sourceID, elementID: first.id))
    XCTAssertEqual(f.store.project, before); XCTAssertTrue(f.store.engine.undoStack.isEmpty)
  }

  func testLinkedConsumerAndItsCanonicalSourceDoNotDuplicateTheSameElement() throws {
    var (project, sourceID, physicalID, element) = try plainProject()
    try project.linkArtwork(physicalID, sourceID: sourceID)
    let f = try Fixture(project, sourceID: physicalID); defer { f.close() }
    XCTAssertTrue(f.session.frames.contains { $0.id == sourceID })
    XCTAssertTrue(f.session.frames.contains { $0.id == physicalID })
    let before = f.store.project
    let matches = f.elementResults("needle 742")
    XCTAssertEqual(matches.count, 1)
    XCTAssertEqual(matches.first?.target, .canvasElement(frameID: physicalID, sourceID: sourceID, elementID: element.id))
    XCTAssertTrue(f.store.revealFindResult(try XCTUnwrap(matches.first)))
    XCTAssertEqual(f.session.selection, [element.id]); XCTAssertEqual(f.session.activeFrameID, physicalID)
    XCTAssertEqual(f.store.project, before); XCTAssertTrue(f.store.engine.undoStack.isEmpty)
  }

  func testSewingPieceNameFindsItsUnnamedCanonicalContourWithoutChangingPatternGeometry() throws {
    var (project, sourceID, physicalID, _) = try plainProject()
    var piece = ArtworkElement(kind: "rectangle", x: 15, y: 18, width: 100, height: 60)
    piece.sewingPiece = .init(name: "Canvas gusset lining")
    piece.sewingPiece!.seamAllowance = 5
    piece.fillEnabled = false; piece.stroke = .init(color: "#43718A", width: 0.3)
    XCTAssertNil(piece.name)
    project.objects[0].artwork?.elements = [piece]
    let f = try Fixture(project, sourceID: sourceID); defer { f.close() }
    f.store.select(physicalID)
    let before = f.store.project, selection = f.store.engine.selection
    let source = try XCTUnwrap(project.objects[0].artwork)
    let geometry = try SewingPatterns.geometry(piece, in: source)
    let matches = f.elementResults("GUSSET lining")
    XCTAssertEqual(matches.count, 1)
    let match = try XCTUnwrap(matches.first)
    XCTAssertEqual(match.target, .canvasElement(frameID: sourceID, sourceID: sourceID, elementID: piece.id))
    XCTAssertEqual(match.title, "Canvas gusset lining")
    XCTAssertTrue(f.store.revealFindResult(match))
    XCTAssertEqual(f.session.activeFrameID, sourceID); XCTAssertEqual(f.session.selection, [piece.id])
    let current = try XCTUnwrap(f.store.project?.objects.first { $0.id == sourceID }?.artwork)
    let contour = try XCTUnwrap(current.elements.first { $0.id == piece.id })
    XCTAssertEqual(try SewingPatterns.geometry(contour, in: current), geometry)
    XCTAssertEqual(f.store.engine.selection, selection); XCTAssertEqual(f.store.project, before)
    XCTAssertTrue(f.store.engine.undoStack.isEmpty)
  }

  func testCachedProjectionResultsRejectNowHiddenOrOffSurfaceLayersWithoutNavigation() throws {
    for hidden in [true, false] {
      let (project, paperID, sourceID, element) = try paperProject(insideSource: false)
      let f = try Fixture(project, sourceID: sourceID); defer { f.close() }
      let panel = try XCTUnwrap(f.session.frames.first {
        $0.projection?.constructionID == paperID && $0.projection?.inside == false && $0.projection?.panelID == "right"
      })
      f.session.activate(panel.id); f.canvas.synchronize(); f.canvas.setZoom(1.3)
      let match = try XCTUnwrap(f.elementResults("quartz cross-panel").first)
      var changed = try XCTUnwrap(f.store.project)
      let objectIndex = try XCTUnwrap(changed.objects.firstIndex { $0.id == sourceID })
      var artwork = try XCTUnwrap(changed.objects[objectIndex].artwork)
      let elementIndex = try XCTUnwrap(artwork.elements.firstIndex { $0.id == element.id })
      if hidden { artwork.elements[elementIndex].hidden = true }
      else { artwork.elements[elementIndex].x = 1000; artwork.elements[elementIndex].y = 1000 }
      changed.objects[objectIndex].artwork = artwork; f.store.engine.project = changed
      let selected = f.session.selection, frame = f.session.activeFrameID, tableSelection = f.store.engine.selection
      let viewport = f.canvas.visibleCanvasRect, history = f.store.engine.undoStack.count
      XCTAssertFalse(f.store.revealFindResult(match), "Cached results must recheck current visibility and physical material before changing view state.")
      XCTAssertEqual(f.session.activeFrameID, frame); XCTAssertEqual(f.session.selection, selected)
      XCTAssertEqual(f.canvas.visibleCanvasRect, viewport); XCTAssertEqual(f.canvas.zoom, 1.3, accuracy: 1e-9)
      XCTAssertEqual(f.store.engine.selection, tableSelection); XCTAssertEqual(f.store.project, changed)
      XCTAssertEqual(f.store.engine.undoStack.count, history)
    }
  }
}
