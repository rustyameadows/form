import AppKit
import FormCore
import XCTest
@testable import FormApp

@MainActor final class CanvasImageGenerationControllerTests: XCTestCase {
  @MainActor private final class PausedProvider: StudioImageGenerationProvider {
    var entered = false
    var request: StudioGenerationRequest?
    var continuation: CheckedContinuation<Void,Never>?
    func generate(_ request: StudioGenerationRequest, progress: @escaping (Double)->Void) async throws -> [Data] {
      self.request = request
      let result = try await LocalStudioImageGenerationProvider(delayNanoseconds: 0).generate(request, progress: progress)
      entered = true
      await withCheckedContinuation { continuation = $0 }
      // Deliberately ignores cancellation, exercising the controller's late-result fence.
      return result
    }
    func release() { let pending = continuation; continuation = nil; pending?.resume() }
  }
  @MainActor private final class InvalidProvider: StudioImageGenerationProvider {
    func generate(_ request: StudioGenerationRequest, progress: @escaping (Double)->Void) async throws -> [Data] { [Data("not PNG".utf8)] }
  }
  @MainActor private final class Fixture {
    let root: URL, store: StudioStore, library: StudioAssetLibrary, controller: CanvasImageGenerationController
    let sourceID: UUID
    init(provider: (any StudioImageGenerationProvider)? = nil) throws {
      _ = NSApplication.shared
      root = FileManager.default.temporaryDirectory.appendingPathComponent("canvas-generation-controller-" + UUID().uuidString)
      store = StudioStore(repository: try ProjectRepository(root: root), seedLibrary: false)
      var project = Project(name: "Canvas generation tests")
      _ = try project.ensureCanvasWorkspace()
      var source = try project.makeObject(recipeID: "artboard", name: "Reference", parameters: ["width":80,"depth":60])
      source.artwork = Artwork(elements: [ArtworkElement(kind: "rectangle", x: 5, y: 6, width: 25, height: 30, color: "#287A9B")])
      sourceID = source.id; project.objects.append(source)
      store.engine.project = project; store.showingHome = false; store.mode = .artwork
      library = StudioAssetLibrary(root: root, projectID: project.id)
      controller = CanvasImageGenerationController(store: store, library: library, provider: provider ?? LocalStudioImageGenerationProvider(delayNanoseconds: 0))
    }
    func begin(reference: Bool = false) throws -> UUID {
      let id = try controller.begin(at: .init(130,240), reference: reference ? .init(objectID: sourceID, title: "Reference") : nil)
      controller.updatePrompt("A calm geometric composition")
      var options = StudioImageGenerationOptions(); options.size = .small; controller.updateOptions(options)
      return id
    }
    func close() { controller.resetForProjectChange(); store.artworkSession.editingText = false; store.engine.project = nil; try? FileManager.default.removeItem(at: root) }
    func element(_ id: UUID) -> ArtworkElement? { store.project?.objects.first { $0.id == id }?.artwork?.elements.first }
  }
  private func wait(_ predicate: ()->Bool) async throws {
    for _ in 0..<1000 { if predicate() { return }; try await Task.sleep(nanoseconds: 1_000_000) }
    XCTFail("Expected asynchronous workflow state was not reached")
  }
  func testResultIsOrdinaryImageWithTwoUndoStepsAndExactProvenanceAcrossReopenAndPixelReplacement() async throws {
    let f = try Fixture(); defer { f.close() }
    let original = f.store.project!, id = try f.begin(), blank = f.store.project!
    XCTAssertEqual(f.store.engine.undoStack.count, 1)
    XCTAssertTrue(f.controller.canGenerate)
    await f.controller.generate()
    XCTAssertEqual(f.controller.draft?.status, .succeeded, f.controller.error ?? "")
    let image = try XCTUnwrap(f.element(id)), metadata = try XCTUnwrap(image.imageGeneration)
    XCTAssertEqual(image.kind, "image"); XCTAssertTrue(metadata.isDemo)
    XCTAssertEqual(metadata.prompt, "A calm geometric composition"); XCTAssertEqual(metadata.settings["transport"], "none")
    XCTAssertEqual(metadata.pixelWidth, 512); XCTAssertEqual(metadata.pixelHeight, 341)
    XCTAssertEqual(f.store.engine.undoStack.count, 2)
    XCTAssertEqual(f.library.items.filter { $0.origin == .generated }.count, 1)
    let result = f.store.project!, imageURL = f.store.repository.url(for: result.id).appendingPathComponent("Assets/" + image.asset!)
    XCTAssertNotNil(NSBitmapImageRep(data: try Data(contentsOf: imageURL)))
    f.store.undo(); XCTAssertEqual(f.store.project, blank); XCTAssertEqual(f.controller.draft?.status, .draft); XCTAssertTrue(f.controller.canGenerate)
    f.store.redo(); XCTAssertEqual(f.store.project, result); XCTAssertEqual(f.controller.draft?.status, .succeeded)
    try f.store.repository.save(result)
    let loaded = try f.store.repository.load(result.id)
    XCTAssertEqual(loaded.objects.first { $0.id == id }?.artwork?.elements.first?.imageGeneration, metadata)
    _ = try f.store.importImage(["object_id": id.uuidString,"element_id": image.id.uuidString,"path": imageURL.path])
    XCTAssertNil(f.element(id)?.imageGeneration)
    f.store.undo(); XCTAssertEqual(f.element(id)?.imageGeneration, metadata)
    f.store.undo(); f.store.undo(); XCTAssertEqual(f.store.project, original)
  }
  func testCapturedReferencesStayFrozenAndMovedDestinationDoesNotStealAnotherSelection() async throws {
    let provider = PausedProvider(), f = try Fixture(provider: provider); defer { provider.release(); f.close() }
    let id = try f.begin(reference: true)
    let sourceBefore = try XCTUnwrap(f.store.project?.objects.first { $0.id == f.sourceID })
    let work = Task { await f.controller.generate() }; try await wait { provider.entered }
    let request = try XCTUnwrap(provider.request), payload = try XCTUnwrap(request.referenceImages.first)
    XCTAssertNil(request.inputPNG); XCTAssertEqual(request.source, .canvas)
    XCTAssertEqual(request.references.count, 1)
    try f.store.engine.edit("Continue designing") { project in
      let source = project.objects.firstIndex { $0.id == f.sourceID }!
      project.objects[source].artwork?.elements[0].color = "#FC9723"
      let destination = project.objects.firstIndex { $0.id == id }!
      project.objects[destination].name = "Moved image"; project.objects[destination].artwork?.canvasPosition = .init(330,450)
    }
    f.store.changed(); f.store.artworkSession.activate(f.sourceID)
    let selected = sourceBefore.artwork!.elements[0].id; f.store.artworkSession.choose([selected])
    provider.release(); await work.value
    XCTAssertEqual(f.controller.draft?.status, .succeeded, f.controller.error ?? "")
    XCTAssertEqual(f.store.artworkSession.activeFrameID, f.sourceID)
    XCTAssertEqual(f.store.artworkSession.selection, [selected])
    let current = try XCTUnwrap(f.store.project?.objects.first { $0.id == id })
    XCTAssertEqual(current.name, "Moved image"); XCTAssertEqual(current.artwork?.canvasPosition, .init(330,450))
    let metadata = try XCTUnwrap(current.artwork?.elements.first?.imageGeneration)
    XCTAssertEqual(metadata.references.first?.objectID, f.sourceID)
    XCTAssertEqual(metadata.references.first?.renderedSHA256, ArtworkTransferBundle.digest(payload.png))
    XCTAssertEqual(f.store.project?.objects.first { $0.id == f.sourceID }?.artwork?.elements[0].color, "#FC9723")
    f.store.undo()
    XCTAssertTrue(f.store.project?.objects.first { $0.id == id }?.artwork?.elements.isEmpty == true)
    XCTAssertEqual(f.store.project?.objects.first { $0.id == f.sourceID }?.artwork?.elements[0].color, "#FC9723")
  }
  func testFailureRetryAndLateCancelledProviderKeepBlankDraftWithoutPartialFiles() async throws {
    let f = try Fixture(); defer { f.close() }; let id = try f.begin(), blank = f.store.project!
    var options = f.controller.draft!.options; options.failureFixture = .offline; f.controller.updateOptions(options)
    await f.controller.generate()
    XCTAssertEqual(f.controller.draft?.status, .failed); XCTAssertEqual(f.store.project, blank); XCTAssertTrue(f.library.items.isEmpty)
    options.failureFixture = .none; f.controller.updateOptions(options); await f.controller.retry()
    XCTAssertEqual(f.controller.draft?.status, .succeeded); XCTAssertNotNil(f.element(id))
    let provider = PausedProvider(), cancelled = try Fixture(provider: provider); defer { provider.release(); cancelled.close() }
    _ = try cancelled.begin(); let unchanged = cancelled.store.project!
    let work = Task { await cancelled.controller.generate() }; try await wait { provider.entered }
    XCTAssertThrowsError(try cancelled.controller.begin(at: .init()))
    cancelled.controller.cancel(); provider.release(); await work.value
    XCTAssertEqual(cancelled.controller.draft?.status, .cancelled); XCTAssertEqual(cancelled.store.project, unchanged)
    XCTAssertTrue(cancelled.library.items.isEmpty); XCTAssertTrue(cancelled.controller.canGenerate)
    XCTAssertEqual(cancelled.store.engine.undoStack.count, 1)
  }
  func testDeletedLockedEditedAndChangedProjectRejectLateResults() async throws {
    for change in 0..<4 {
      let provider = PausedProvider(), f = try Fixture(provider: provider); defer { provider.release(); f.close() }
      let id = try f.begin(), work = Task { await f.controller.generate() }; try await wait { provider.entered }
      if change == 3 { f.store.engine.project = Project(name: "Switched project") }
      else {
        try f.store.engine.edit("Change destination") { project in
          let index = project.objects.firstIndex { $0.id == id }!
          if change == 0 { project.objects.remove(at: index) }
          if change == 1 { project.objects[index].locked = true }
          if change == 2 { project.objects[index].artwork?.elements = [ArtworkElement(kind: "ellipse", x: 0,y: 0)] }
        }
      }
      f.store.changed(); let expected = f.store.project!
      provider.release(); await work.value
      XCTAssertEqual(f.store.project, expected); XCTAssertTrue(f.library.items.isEmpty); XCTAssertFalse(f.controller.busy)
      XCTAssertNotEqual(f.controller.draft?.status, .succeeded)
    }
  }
  func testPublicationWaitsForNativeTextEditingWithoutEndingItOrStealingSelection() async throws {
    let provider = PausedProvider(), f = try Fixture(provider: provider); defer { provider.release(); f.close() }
    let id = try f.begin(), work = Task { await f.controller.generate() }; try await wait { provider.entered }
    f.store.artworkSession.activate(f.sourceID); f.store.artworkSession.editingText = true
    provider.release(); try await wait { f.controller.phase == .waitingForEditor }
    XCTAssertTrue(f.store.artworkSession.editingText); XCTAssertNil(f.element(id)); XCTAssertTrue(f.library.items.isEmpty)
    XCTAssertEqual(f.store.engine.undoStack.count, 1)
    f.store.artworkSession.editingText = false; await work.value
    XCTAssertEqual(f.controller.draft?.status, .succeeded); XCTAssertEqual(f.store.artworkSession.activeFrameID, f.sourceID)
  }
  func testCompletedResultWaitsThroughHeldNativeDragAndPreservesSeparateUndoSteps() async throws {
    let provider = PausedProvider(), f = try Fixture(provider: provider)
    defer { provider.release(); f.close() }
    f.store.engine.project?.objects[1].artwork?.canvasPosition = .init(0,0)
    f.store.engine.project?.objects[1].artwork?.snapEnabled = false
    let destinationID = try f.begin(), session = f.store.artworkSession
    let shapeID = try XCTUnwrap(f.element(f.sourceID)?.id)
    session.activate(f.sourceID)
    let window = NSWindow(contentRect: .init(x:-10000,y:-10000,width:900,height:650),
      styleMask:[.titled],backing:.buffered,defer:false)
    window.isReleasedWhenClosed = false
    let scroll = ArtworkScrollView(frame:window.contentView!.bounds)
    scroll.allowsMagnification = true; scroll.minMagnification = 0.08; scroll.maxMagnification = 24
    let canvas = VectorCanvasView(frame:scroll.bounds)
    canvas.session = session; session.canvas = canvas; scroll.documentView = canvas
    window.contentView = scroll; window.makeFirstResponder(canvas)
    canvas.synchronize(); canvas.fit(all:true); canvas.setZoom(1)
    defer { window.contentView = nil; window.close() }
    func mouse(_ type:NSEvent.EventType,_ point:CGPoint)->NSEvent {
      NSEvent.mouseEvent(with:type,location:point,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,
        windowNumber:window.windowNumber,context:nil,eventNumber:1,clickCount:1,pressure:type == .leftMouseUp ? 0:1)!
    }
    let beforeDrag = try XCTUnwrap(f.store.project)
    let work = Task { await f.controller.generate() }; try await wait { provider.entered }
    let frame = try XCTUnwrap(session.frames.first { $0.id == f.sourceID })
    let start = canvas.convert(canvas.documentPoint(.init(x:frame.rect.minX+17.5,y:frame.rect.minY+21)),to:nil)
    let middle = CGPoint(x:start.x+40,y:start.y), end = CGPoint(x:start.x+80,y:start.y)
    canvas.mouseDown(with:mouse(.leftMouseDown,start))
    canvas.mouseDragged(with:mouse(.leftMouseDragged,middle))
    XCTAssertTrue(f.store.engine.hasActiveInteraction)
    XCTAssertEqual(session.selection,[shapeID])
    provider.release(); try await wait { f.controller.phase == .waitingForEditor }
    XCTAssertTrue(f.controller.busy); XCTAssertNil(f.element(destinationID)); XCTAssertTrue(f.library.items.isEmpty)
    XCTAssertTrue(f.store.engine.hasActiveInteraction,"Completion must not invalidate the held drag token")
    canvas.mouseDragged(with:mouse(.leftMouseDragged,end))
    canvas.mouseUp(with:mouse(.leftMouseUp,end))
    XCTAssertFalse(f.store.engine.hasActiveInteraction)
    let dragged = try XCTUnwrap(f.element(f.sourceID)), afterDrag = try XCTUnwrap(f.store.project)
    XCTAssertEqual(session.art.bounds(of:dragged).x,5+80*25.4/72,accuracy:0.000001)
    XCTAssertEqual(f.store.engine.undoStack.count,2,"Artboard creation and one entire native drag")
    await work.value
    XCTAssertEqual(f.controller.draft?.status,.succeeded,f.controller.error ?? "")
    XCTAssertEqual(session.activeFrameID,f.sourceID); XCTAssertEqual(session.selection,[shapeID])
    XCTAssertEqual(f.store.engine.undoStack.count,3)
    let completed = f.store.project
    f.store.undo(); XCTAssertEqual(f.store.project,afterDrag)
    f.store.undo(); XCTAssertEqual(f.store.project,beforeDrag)
    f.store.redo(); XCTAssertEqual(f.store.project,afterDrag)
    f.store.redo(); XCTAssertEqual(f.store.project,completed)
  }
  func testUnsupportedReferencesAndMalformedProviderFailWithoutUnexpectedDocumentOrLibraryChanges() async throws {
    let f = try Fixture(provider: InvalidProvider()); defer { f.close() }
    f.store.engine.project?.objects[1].canvasSourceOnly = true
    let before = f.store.project!
    XCTAssertThrowsError(try f.controller.begin(at: .init(), reference: .init(objectID: f.sourceID, title: "Unsupported")))
    XCTAssertEqual(f.store.project, before); XCTAssertTrue(f.store.engine.undoStack.isEmpty)
    _ = try f.begin(); let blank = f.store.project!
    await f.controller.generate()
    XCTAssertEqual(f.controller.draft?.status, .failed); XCTAssertNotNil(f.controller.error)
    XCTAssertEqual(f.store.project, blank); XCTAssertTrue(f.library.items.isEmpty)
  }
}
