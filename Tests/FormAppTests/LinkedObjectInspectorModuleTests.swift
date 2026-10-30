import AppKit
import FormCADModel
import FormCore
import FormGraphics
import XCTest
@testable import FormApp

@MainActor final class LinkedObjectInspectorModuleTests: XCTestCase {
  private func makeStore(_ project: Project) throws -> StudioStore {
    _ = NSApplication.shared
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("linked-inspector-" + UUID().uuidString)
    let store = StudioStore(repository: try ProjectRepository(root: directory), seedLibrary: false)
    store.engine.project = project; store.showingHome = false; store.environment = .form
    addTeardownBlock { @MainActor in store.engine.project = nil; try? FileManager.default.removeItem(at: directory) }
    return store
  }

  private func linkedPrimitives() throws -> (Project, UUID, UUID, UUID) {
    var project = Project(name: "One canonical artwork source")
    var source = try project.makeObject(recipeID: "artboard", parameters: ["width": 100, "depth": 50])
    source.artwork = .init(elements: [.init(kind: "rectangle", x: 5, y: 5, width: 30, height: 20, color: "#D43C35")])
    let first = try project.makeObject(recipeID: "box"), second = try project.makeObject(recipeID: "box")
    project.objects = [source, first, second]
    try project.linkArtwork(first.id, sourceID: source.id); try project.linkArtwork(second.id, sourceID: source.id)
    return (project, source.id, first.id, second.id)
  }

  func testSharedPrimitiveSourceListsAllConsumersWithoutChangingSourceOrSelection() throws {
    let (project, source, first, second) = try linkedPrimitives(), store = try makeStore(project)
    store.artworkSession.activate(source)
    let before = try XCTUnwrap(store.project), selection = store.engine.selection
    let links = LinkedInspectorRelationships.canvas(store.artworkSession, in: before)
    XCTAssertEqual(Set(links.map(\.objectID)), [first, second])
    XCTAssertEqual(Set(links.compactMap(\.sourceID)), [source])
    XCTAssertEqual(Set(links.map(\.id)).count, 2)
    XCTAssertEqual(LinkedInspectorRelationships.canvas(store.artworkSession, in: before), links)
    XCTAssertEqual(store.project, before); XCTAssertEqual(store.engine.selection, selection)
    XCTAssertTrue(store.engine.undoStack.isEmpty)
  }

  func testExistingSourceNavigationDoesNotCreateWorkspaceOrUndoAndRetainsSplitDirection() throws {
    let (project, source, first, _) = try linkedPrimitives(), store = try makeStore(project)
    let target = try XCTUnwrap(project.objects.first { $0.id == first })
    let link = try XCTUnwrap(LinkedInspectorRelationships.table(target, in: project).first)
    XCTAssertNil(project.canvasWorkspace)
    let before = project.objects
    for layout in [DesignSurfaceLayout.single, .split] {
      store.surfaceLayout = layout; store.splitDirection = .stacked; store.mode = .table
      let tableSelection = store.engine.selection
      XCTAssertTrue(LinkedInspectorRelationships.openCanvas(link, store: store))
      XCTAssertEqual(store.surfaceLayout, layout); XCTAssertEqual(store.splitDirection, .stacked)
      XCTAssertEqual(store.artworkSession.objectID, source); XCTAssertEqual(store.artworkSession.linkedTargetID, first)
      XCTAssertEqual(store.engine.selection, tableSelection)
      XCTAssertTrue(LinkedInspectorRelationships.openTable(link, store: store))
      XCTAssertEqual(store.surfaceLayout, layout); XCTAssertEqual(store.mode, .table)
      XCTAssertEqual(store.project?.objects, before); XCTAssertNil(store.project?.canvasWorkspace)
      XCTAssertTrue(store.engine.undoStack.isEmpty)
    }
  }

  func testSourceSharedByPaperAndAnotherObjectKeepsItsCanonicalEditorForThatObject() throws {
    var (project, sourceID, targetID, _) = try linkedPrimitives()
    let paper = try project.makeObject(recipeID: "tuckCarton")
    project.objects.append(paper); try project.linkArtwork(paper.id, sourceID: sourceID)
    let store = try makeStore(project), target = try XCTUnwrap(project.objects.first { $0.id == targetID })
    let link = try XCTUnwrap(LinkedInspectorRelationships.table(target, in: project).first)
    let before = project.objects
    store.select(targetID)
    XCTAssertTrue(LinkedInspectorRelationships.openCanvas(link, store: store))
    XCTAssertEqual(store.primary?.id, targetID); XCTAssertEqual(store.artworkSession.objectID, sourceID)
    XCTAssertNil(store.artworkSession.activeProjection)
    XCTAssertEqual(store.artworkSession.linkedTargetID, targetID)
    XCTAssertTrue(store.artworkSession.frames.contains { $0.object.id == sourceID && $0.projection == nil })
    XCTAssertEqual(store.project?.objects, before); XCTAssertTrue(store.engine.undoStack.isEmpty)
  }

  func testPaperInsideThumbnailAndNavigationUseTheRegisteredCanonicalSource() throws {
    let project = try PaperSamples.cosmetics(), store = try makeStore(project)
    let paper = try XCTUnwrap(project.objects.first { PaperConstruction.isPaper($0) })
    let insideID = try XCTUnwrap(paper.paperConstruction?.insideArtworkSourceID)
    let link = try XCTUnwrap(LinkedInspectorRelationships.table(paper, in: project).first { $0.kind == .paper(inside: true) })
    let before = project.objects
    let content = try XCTUnwrap(LinkedInspectorArtwork.content(link, in: project))
    let source = try XCTUnwrap(project.objects.first { $0.id == insideID })
    XCTAssertEqual(content.artwork, project.surfaceArtwork(source))
    let transform = try XCTUnwrap(content.frame).sourceToLocal
    XCTAssertLessThan(transform.a * transform.d - transform.b * transform.c, 0)
    store.surfaceLayout = .split; store.mode = .table
    XCTAssertTrue(LinkedInspectorRelationships.openCanvas(link, store: store))
    XCTAssertEqual(store.artworkSession.objectID, insideID)
    XCTAssertEqual(store.artworkSession.activeProjection?.constructionID, paper.id)
    XCTAssertEqual(store.artworkSession.activeProjection?.inside, true)
    XCTAssertEqual(store.artworkSession.activeProjection?.isProof, true)
    XCTAssertEqual(store.artworkSession.physicalObject?.id, paper.id)
    XCTAssertTrue(store.engine.selection.isEmpty); XCTAssertEqual(store.surfaceLayout, .split)
    XCTAssertEqual(store.project?.objects, before); XCTAssertTrue(store.engine.undoStack.isEmpty)
  }

  func testSewnPreviewKeepsTheOriginalAssemblySourceAndNavigatesToIt() throws {
    let project = try PatternAssemblySamples.project(), store = try makeStore(project)
    let assembly = try XCTUnwrap(project.objects.first { $0.patternAssembly != nil })
    let sourceID = try XCTUnwrap(assembly.patternAssembly?.sourceObjectID)
    let link = try XCTUnwrap(LinkedInspectorRelationships.table(assembly, in: project).first)
    XCTAssertEqual(link.sourceID, sourceID); XCTAssertEqual(link.kind, .cuttingSource)
    let preview = LinkedInspectorRelationships.previewProject(object: assembly, in: project)
    XCTAssertEqual(preview.objects.count, project.objects.count)
    XCTAssertEqual(preview.objects.first { $0.id == sourceID }, project.objects.first { $0.id == sourceID })
    XCTAssertEqual(preview.objects.first { $0.id == assembly.id }?.patternAssembly, assembly.patternAssembly)
    XCTAssertEqual(preview.objects.first { $0.id == assembly.id }?.position, .init())
    XCTAssertTrue(LinkedInspectorRelationships.openCanvas(link, store: store))
    XCTAssertEqual(store.artworkSession.objectID, sourceID); XCTAssertEqual(store.artworkSession.physicalObject?.id, assembly.id)
    XCTAssertTrue(store.engine.selection.isEmpty)
    XCTAssertEqual(store.artworkSession.linkedTargetID, assembly.id)
    let canvasLinks = LinkedInspectorRelationships.canvas(store.artworkSession, in: project)
    XCTAssertEqual(canvasLinks.map(\.objectID), [assembly.id])
    XCTAssertEqual(store.project?.objects, project.objects); XCTAssertTrue(store.engine.undoStack.isEmpty)
  }

  private func mappedCAD() throws -> (Project, UUID, UUID) {
    var project = Project(name: "Named surface source")
    var source = try project.makeObject(recipeID: "artboard", parameters: ["width": 100, "depth": 50])
    source.artwork = .init(elements: [.init(kind: "rectangle", x: 4, y: 5, width: 30, height: 20, color: "#1649D8")])
    let feature = CADFeatureNode(name: "Body", operation: .init(.box, values: ["width": 100, "height": 20, "depth": 50]))
    let surface = CADPlanarSurface(id: "top", name: "Top face", outputFeatureID: feature.id,
      selection: .faceAtMaximum(axis: "y"), origin: .init(0, 20, 50), uAxis: .xAxis,
      vAxis: .init(0, 0, -1), width: 100, height: 50)
    let definition = CADModelDefinition(name: "Body", features: [feature], outputs: [feature.id], surfaces: [surface])
    var representation = CADRepresentation(modelID: definition.id,
      definitionSHA256: try CADRepresentation.definitionHash(definition), kernelVersion: "test", components: [])
    var resolved = try surface.resolved(using: [:]); resolved.faceIndex = 1; resolved.fingerprint = String(repeating: "a", count: 64)
    representation.resolvedSurfaces = [resolved]
    var model = ProductObject(name: "Mapped body", recipeID: "cadModel", parameters: [:])
    model.cadModel = definition; model.cadRepresentation = representation
    model.surfaceArtworkBindings = [.init(surfaceID: "top", sourceObjectID: source.id, widthMM: 100, heightMM: 50)]
    project.objects = [source, model]
    return (project, model.id, source.id)
  }

  func testNamedCADSurfaceUsesItsExistingProjectedFrameAndCanonicalArtwork() throws {
    let (project, id, sourceID) = try mappedCAD(), store = try makeStore(project)
    let object = try XCTUnwrap(project.objects.first { $0.id == id })
    let link = try XCTUnwrap(LinkedInspectorRelationships.table(object, in: project).first)
    XCTAssertEqual(link.kind, .surface("top")); XCTAssertEqual(link.sourceID, sourceID)
    let content = try XCTUnwrap(LinkedInspectorArtwork.content(link, in: project))
    XCTAssertEqual(content.artwork, project.physicalSurfaceArtwork(object.surfaceArtworkBindings![0]))
    XCTAssertEqual(content.size, .init(100, 50)); XCTAssertFalse(content.boundary.isEmpty)
    store.surfaceLayout = .split; store.mode = .table
    XCTAssertTrue(LinkedInspectorRelationships.openCanvas(link, store: store))
    XCTAssertEqual(store.artworkSession.objectID, sourceID)
    XCTAssertEqual(store.artworkSession.activeProjection?.constructionID, id)
    XCTAssertEqual(store.artworkSession.activeProjection?.panelID, "top")
    XCTAssertEqual(store.surfaceLayout, .split); XCTAssertEqual(store.project?.objects, project.objects)
    XCTAssertTrue(store.engine.undoStack.isEmpty)
  }

  func testUnassignedSurfaceKeepsReviewContextWithoutInventingArtworkOrNavigating() throws {
    var (project, id, _) = try mappedCAD()
    project.objects[project.objects.firstIndex { $0.id == id }!].surfaceArtworkBindings = nil
    let store = try makeStore(project), object = try XCTUnwrap(project.objects.first { $0.id == id })
    let link = try XCTUnwrap(LinkedInspectorRelationships.table(object, in: project).first)
    let selection = store.engine.selection
    XCTAssertNotNil(link.review); XCTAssertNil(LinkedInspectorArtwork.content(link, in: project))
    XCTAssertFalse(LinkedInspectorRelationships.canOpenCanvas(link, in: project))
    XCTAssertFalse(LinkedInspectorRelationships.openCanvas(link, store: store))
    XCTAssertEqual(store.project, project); XCTAssertEqual(store.engine.selection, selection)
    XCTAssertTrue(store.engine.undoStack.isEmpty)
  }

  func testThumbnailCachesCurrentArtworkAndClearsInvalidatedContent() throws {
    _ = NSApplication.shared
    let original = Artwork(background: "#FFFFFF", elements: [.init(kind: "rectangle", x: 0, y: 0, width: 40, height: 20, color: "#FF0000")])
    var content = LinkedInspectorArtworkContent(artwork: original, size: .init(40, 20))
    let view = LinkedInspectorArtworkView(), assets = FileManager.default.temporaryDirectory
    view.update(content, assets: assets)
    let first = try XCTUnwrap(view.renderedImage())
    view.setFrameSize(.init(width: 254, height: 140)); view.update(content, assets: assets)
    XCTAssertTrue(view.renderedImage() === first); XCTAssertEqual(view.builds, 1)
    let red = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(first.tiffRepresentation))?.colorAt(x: 20, y: 20)?.usingColorSpace(.deviceRGB))
    XCTAssertGreaterThan(red.redComponent, 0.9); XCTAssertLessThan(red.blueComponent, 0.1)
    content.artwork.elements[0].color = "#0000FF"; view.update(content, assets: assets)
    let updated = try XCTUnwrap(view.renderedImage())
    let blue = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(updated.tiffRepresentation))?.colorAt(x: 20, y: 20)?.usingColorSpace(.deviceRGB))
    XCTAssertGreaterThan(blue.blueComponent, 0.9); XCTAssertLessThan(blue.redComponent, 0.1)
    XCTAssertEqual(view.builds, 2)
    view.update(nil, assets: assets); XCTAssertNil(view.renderedImage()); XCTAssertEqual(view.builds, 2)
    XCTAssertEqual(original.elements[0].color, "#FF0000")
  }
}
