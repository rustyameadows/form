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
  func testCustomBlankFrameDrivesPixelShapeAndResultPreservesPhysicalGeometryAndUndo() async throws {
    let f = try Fixture(); defer { f.close() }; let id = try f.begin()
    try f.store.engine.edit("Resize blank image frame") { project in
      let index = project.objects.firstIndex { $0.id == id }!
      project.objects[index].parameters["width"] = 240
      project.objects[index].parameters["depth"] = 96
      project.objects[index].artwork?.canvasPosition = .init(-35,72)
    }
    f.store.changed()
    XCTAssertEqual(f.controller.destinationSizeMM,.init(240,96))
    XCTAssertEqual(f.controller.outputPixels,.init(width:512,height:204))
    XCTAssertNil(f.controller.shapePreset); XCTAssertTrue(f.controller.canGenerate)
    let resized = try XCTUnwrap(f.store.project), undoCount = f.store.engine.undoStack.count
    await f.controller.generate()
    XCTAssertEqual(f.controller.draft?.status,.succeeded,f.controller.error ?? "")
    let board = try XCTUnwrap(f.store.project?.objects.first { $0.id == id }), image = try XCTUnwrap(board.artwork?.elements.first)
    XCTAssertEqual(board["width"],240); XCTAssertEqual(board["depth"],96)
    XCTAssertEqual(board.artwork?.canvasPosition,.init(-35,72)); XCTAssertEqual(image.width,240); XCTAssertEqual(image.height,96)
    XCTAssertEqual(image.imageGeneration?.pixelWidth,512); XCTAssertEqual(image.imageGeneration?.pixelHeight,204)
    XCTAssertEqual(image.imageGeneration?.settings["aspect"],"custom")
    XCTAssertEqual(f.controller.destinationSizeMM,.init(240,96))
    XCTAssertEqual(f.controller.outputPixels,.init(width:512,height:204))
    XCTAssertEqual(image.imageGeneration?.settings["canvas_width_mm"],"240.0")
    XCTAssertEqual(f.store.engine.undoStack.count,undoCount+1)
    let completed = f.store.project
    f.store.undo(); XCTAssertEqual(f.store.project,resized); XCTAssertTrue(f.controller.canGenerate)
    f.store.redo(); XCTAssertEqual(f.store.project,completed)
  }
  func testShapePresetsResizeBlankBoardAsOneUndoAndExtremeCustomShapeIsRecoverable() throws {
    let f = try Fixture(); defer { f.close() }; let id = try f.begin(), original = f.store.project
    XCTAssertTrue(f.controller.updateShape(.portrait))
    XCTAssertEqual(try XCTUnwrap(f.controller.destinationSizeMM).x,160*2.0/3,accuracy:0.000001)
    XCTAssertEqual(f.controller.destinationSizeMM?.y,160)
    XCTAssertEqual(f.controller.outputPixels,.init(width:341,height:512)); XCTAssertEqual(f.controller.shapePreset,.portrait)
    XCTAssertEqual(f.store.engine.undoStack.count,2)
    XCTAssertEqual(f.store.project?.objects.first { $0.id == id }?.artwork?.canvasPosition,.init(130,240))
    f.store.undo(); XCTAssertEqual(f.store.project,original); XCTAssertEqual(f.controller.shapePreset,.landscape)
    try f.store.engine.edit("Extreme custom frame") { project in
      let index = project.objects.firstIndex { $0.id == id }!
      project.objects[index].parameters["width"] = 1000; project.objects[index].parameters["depth"] = 10
    }
    f.store.changed(); XCTAssertFalse(f.controller.canGenerate); XCTAssertNil(f.controller.outputPixels)
    XCTAssertTrue(f.controller.outputSizeError?.contains("1:8") == true)
    XCTAssertTrue(f.controller.updateShape(.square))
    XCTAssertEqual(f.controller.destinationSizeMM,.init(1000,1000)); XCTAssertEqual(f.controller.outputPixels,.init(width:512,height:512))
    XCTAssertTrue(f.controller.canGenerate); XCTAssertNil(f.controller.error)
  }
  func testResizeDuringPendingGenerationDiscardsOldRatioAndRetryUsesCurrentFrame() async throws {
    let provider = PausedProvider(), f = try Fixture(provider:provider); defer { provider.release(); f.close() }
    let id = try f.begin(), work = Task { await f.controller.generate() }; try await wait { provider.entered }
    XCTAssertEqual(provider.request?.canvasOutputPixels,.init(width:512,height:341))
    try f.store.engine.edit("Change pending frame shape") { project in
      let index = project.objects.firstIndex { $0.id == id }!
      project.objects[index].parameters["width"] = 100; project.objects[index].parameters["depth"] = 200
    }
    f.store.changed(); let resized = f.store.project
    provider.release(); await work.value
    XCTAssertFalse(f.controller.busy); XCTAssertTrue(f.library.items.isEmpty); XCTAssertEqual(f.store.project,resized)
    XCTAssertEqual(f.controller.draft?.prompt,"A calm geometric composition")
    XCTAssertTrue(f.controller.canGenerate); XCTAssertEqual(f.controller.outputPixels,.init(width:256,height:512))
    provider.entered = false
    let retry = Task { await f.controller.retry() }; try await wait { provider.entered }
    XCTAssertEqual(provider.request?.canvasOutputPixels,.init(width:256,height:512))
    provider.release(); await retry.value
    XCTAssertEqual(f.controller.draft?.status,.succeeded,f.controller.error ?? "")
    XCTAssertEqual(f.element(id)?.width,100); XCTAssertEqual(f.element(id)?.height,200)
    XCTAssertEqual(f.element(id)?.imageGeneration?.pixelWidth,256)
    XCTAssertEqual(f.element(id)?.imageGeneration?.pixelHeight,512)
  }
  func testGuideAwareTopLeftResizeKeepsDraftUsableAndResultPreservesWorldGuidesAndUndo() async throws {
    let f = try Fixture(); defer { f.close() }; let id = try f.begin(), session = f.store.artworkSession
    try f.store.engine.edit("Add layout guides") { project in
      let index = project.objects.firstIndex { $0.id == id }!
      project.objects[index].artwork?.guides = [.init(axis:"x",position:25),.init(axis:"y",position:35)]
      project.objects[index].artwork?.unit = .inches; project.objects[index].artwork?.showGrid = true
      project.objects[index].artwork?.gridSpacing = 5; project.objects[index].artwork?.snapEnabled = false
    }
    f.store.changed(); XCTAssertTrue(f.controller.canGenerate,f.controller.error ?? "")
    let withGuides = try XCTUnwrap(f.store.project), frame = try XCTUnwrap(session.frames.first { $0.id == id })
    let snapshot = session.art, token = try XCTUnwrap(session.beginGesture())
    let resizedRect = CGRect(x:frame.rect.minX-20,y:frame.rect.minY-10,width:frame.rect.width+20,height:frame.rect.height+10)
    session.resizeCanvasArtboard(to:resizedRect,from:frame.rect,artwork:snapshot,expectedFrameID:id,gestureToken:token)
    session.endGesture()
    XCTAssertTrue(f.controller.canGenerate,f.controller.error ?? "")
    let resized = try XCTUnwrap(f.store.project), beforeArt = try XCTUnwrap(resized.objects.first { $0.id == id }?.artwork)
    XCTAssertEqual(beforeArt.guides?[0].position,45); XCTAssertEqual(beforeArt.guides?[1].position,45)
    XCTAssertEqual((beforeArt.canvasPosition?.x ?? 0)+(beforeArt.guides?[0].position ?? 0),155,accuracy:0.000001)
    XCTAssertEqual((beforeArt.canvasPosition?.y ?? 0)+(beforeArt.guides?[1].position ?? 0),275,accuracy:0.000001)
    await f.controller.generate()
    XCTAssertEqual(f.controller.draft?.status,.succeeded,f.controller.error ?? "")
    var afterArt = try XCTUnwrap(f.store.project?.objects.first { $0.id == id }?.artwork)
    afterArt.elements = []; XCTAssertEqual(afterArt,beforeArt)
    f.store.undo(); XCTAssertEqual(f.store.project,resized)
    f.store.undo(); XCTAssertEqual(f.store.project,withGuides)
  }
  func testRedoPresentsSavedRequestWithoutOverwritingNewerTransientDraft() async throws {
    let f = try Fixture(); defer { f.close() }; _ = try f.begin(reference:true)
    let originalPrompt = f.controller.presentationPrompt, originalOptions = f.controller.presentationOptions
    let originalReferences = f.controller.presentationReferences
    await f.controller.generate()
    XCTAssertEqual(f.controller.draft?.status,.succeeded,f.controller.error ?? "")
    f.store.undo()
    f.controller.updatePrompt("Next image, a different idea")
    var nextOptions = f.controller.draft!.options
    nextOptions.model = .flare; nextOptions.size = .large; nextOptions.quality = .draft
    f.controller.updateOptions(nextOptions)
    f.controller.removeReference(id:try XCTUnwrap(originalReferences.first?.id))
    XCTAssertEqual(f.controller.presentationPrompt,"Next image, a different idea")
    f.store.redo()
    XCTAssertEqual(f.controller.draft?.status,.succeeded)
    XCTAssertEqual(f.controller.presentationPrompt,originalPrompt)
    XCTAssertEqual(f.controller.presentationOptions,originalOptions)
    XCTAssertEqual(f.controller.presentationReferences,originalReferences)
    XCTAssertEqual(f.controller.outputPixels,.init(width:512,height:341))
    XCTAssertEqual(f.controller.draft?.prompt,"Next image, a different idea")
    XCTAssertEqual(f.controller.draft?.options,nextOptions); XCTAssertTrue(f.controller.draft?.references.isEmpty == true)
    f.store.undo()
    XCTAssertEqual(f.controller.presentationPrompt,"Next image, a different idea")
    XCTAssertEqual(f.controller.presentationOptions,nextOptions); XCTAssertTrue(f.controller.presentationReferences.isEmpty)
    XCTAssertEqual(f.controller.outputPixels,.init(width:1024,height:682)); XCTAssertTrue(f.controller.canGenerate)
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
