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

  func testPublicationLinksExposeActualFacesAndFindHiddenCanonicalPagesOnlyOnExplicitAction()throws {
    var project=Project(name:"Linked physical pages"),sources=[UUID]()
    for number in 1...6 {
      var page=try project.makeObject(recipeID:"artboard",parameters:["width":100,"depth":140])
      page.artwork = .init(elements:[.init(kind:"text",x:8,y:8,width:80,height:15,text:"PAGE \(number)",fontSize:12)])
      project.objects.append(page);sources.append(page.id)
    }
    let documentID=try PublicationCommands.createPublication(in:&project,name:"One canonical document",pages:sources)
    var document=project.publications![0];document.layout = .init();try PublicationCommands.setPublication(in:&project,document:document)
    let objectID=try SheetAssemblyCommands.create(in:&project,definition:.init(publicationID:documentID,openingDegrees:180,activeSpread:1))
    let object=try XCTUnwrap(project.objects.first{$0.id==objectID}),resolved=try project.resolvedSheetAssembly(object)
    let exposed=Set(resolved.leaves.flatMap{leaf in [leaf.frontVisible ? leaf.front?.sourceObjectID:nil,leaf.backVisible ? leaf.back?.sourceObjectID:nil].compactMap{$0}})
    let links=LinkedInspectorRelationships.table(object,in:project)
    XCTAssertEqual(Set(links.compactMap(\.sourceID)),exposed);XCTAssertEqual(Set(links.map(\.id)).count,links.count)
    XCTAssertTrue(LinkedInspectorRelationships.hasPhysicalView(object,in:project))
    let store=try makeStore(project);store.surfaceLayout = .split;store.splitDirection = .stacked
    let tableSelection:Set<UUID>=[objectID];store.engine.selection=tableSelection
    let hidden=try XCTUnwrap(sources.first{!exposed.contains($0)})
    store.artworkSession.activate(hidden)
    let backLinks=LinkedInspectorRelationships.canvas(store.artworkSession,in:project)
    XCTAssertEqual(backLinks.map(\.objectID),[objectID]);XCTAssertEqual(backLinks.compactMap(\.sourceID),[hidden])
    XCTAssertEqual(store.engine.selection,tableSelection);XCTAssertEqual(store.project,project)
    let link=try XCTUnwrap(links.first),content=try XCTUnwrap(LinkedInspectorArtwork.content(link,in:project))
    XCTAssertEqual(content.artwork,project.surfaceArtwork(project.objects.first{$0.id==link.sourceID}!))
    XCTAssertTrue(LinkedInspectorRelationships.openCanvas(link,store:store))
    XCTAssertEqual(store.artworkSession.objectID,link.sourceID);XCTAssertEqual(store.artworkSession.publicationWorkspace.publicationID,documentID)
    XCTAssertEqual(store.engine.selection,tableSelection);XCTAssertEqual(store.project,project)
    XCTAssertEqual(store.surfaceLayout,.split);XCTAssertEqual(store.splitDirection,.stacked);XCTAssertTrue(store.engine.undoStack.isEmpty)
  }
  func testEnclosureAssociationsHaveStableFaceIDsAndPreviewThePhysicalCropWithoutScaling()throws {
    var project=Project(name:"Canonical cover crops")
    var page=try project.makeObject(recipeID:"artboard",parameters:["width":60,"depth":80]);page.artwork = .init()
    var cover=try project.makeObject(recipeID:"artboard",parameters:["width":120,"depth":80])
    cover.artwork = .init(elements:[.init(kind:"rectangle",x:0,y:0,width:60,height:80,color:"#FF0000"),.init(kind:"rectangle",x:60,y:0,width:60,height:80,color:"#0000FF")])
    project.objects=[page,cover]
    let id=try PublicationCommands.createPublication(in:&project,name:"Cover crops",pages:[page.id])
    let plane=SheetAssemblyPlane(id:"cover",name:"Cover",size:.init(.init(60),.init(80)),front:.init(sourceObjectID:cover.id,sourceOriginMM:.init(.init(60),.init(0))),back:.init(sourceObjectID:cover.id))
    let objectID=try SheetAssemblyCommands.create(in:&project,definition:.init(publicationID:id,enclosure:[plane]))
    let object=try XCTUnwrap(project.objects.first{$0.id==objectID}),before=project
    let links=LinkedInspectorRelationships.table(object,in:project).filter{$0.sourceID==cover.id}
    XCTAssertEqual(links.count,2);XCTAssertEqual(Set(links.map(\.id)).count,2)
    for (title,color) in [("Front",NSColor.blue),("Back",NSColor.red)] {
      let link=try XCTUnwrap(links.first{$0.title.hasSuffix(title)}),content=try XCTUnwrap(LinkedInspectorArtwork.content(link,in:project))
      XCTAssertEqual(content.size,.init(60,80));XCTAssertEqual(content.sourceSize,.init(120,80))
      let view=LinkedInspectorArtworkView();view.update(content,assets:FileManager.default.temporaryDirectory)
      let image=try XCTUnwrap(view.renderedImage()),bitmap=try XCTUnwrap(NSBitmapImageRep(data:try XCTUnwrap(image.tiffRepresentation)))
      let pixel=try XCTUnwrap(bitmap.colorAt(x:bitmap.pixelsWide/2,y:bitmap.pixelsHigh/2)?.usingColorSpace(.deviceRGB))
      XCTAssertEqual(pixel.redComponent,color.redComponent,accuracy:0.03);XCTAssertEqual(pixel.blueComponent,color.blueComponent,accuracy:0.03)
      XCTAssertTrue(LinkedInspectorRelationships.canOpenCanvas(link,in:project))
    }
    XCTAssertEqual(project,before)
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
