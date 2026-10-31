import AppKit
import FigmaTestSupport
import FormCore
import FormGraphics
import XCTest
@testable import FormApp

/// Synthetic public-protocol bytes only. Every pasteboard is private to this
/// test; these tests neither launch Figma nor read the user's clipboard.
@MainActor final class FigmaClipboardPasteTests: XCTestCase {
  private struct Fixture {
    let store: StudioStore, window: NSWindow, canvas: VectorCanvasView, board: NSPasteboard
    let ownerID: UUID
  }
  private final class Gate {
    var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    func hold() async { await withCheckedContinuation { continuation = $0; entered = true } }
    func release() { let pending = continuation; continuation = nil; pending?.resume() }
  }
  private func fixture(text: Bool = false) throws -> Fixture {
    _ = NSApplication.shared
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("figma-paste-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let store = StudioStore(repository: try ProjectRepository(root: directory), seedLibrary: false)
    store.fontLibraryPreferences = .init(file: directory.appendingPathComponent("Fonts.json"))
    var project = Project(name: "Synthetic native paste")
    let owner = try project.ensureCanvasWorkspace()
    if text {
      var layer = ArtworkElement(kind: "text", x: 12, y: 12, width: 140, height: 60, text: "Original words", fontSize: 24)
      var typography = Typography(); typography.fontName = "Helvetica"; typography.frameMode = "area"; layer.typography = typography
      project.objects[0].artwork!.elements = [layer]
    }
    project.schemaVersion = project.minimumSchemaVersion
    store.engine.project = project; try store.engine.flush(); store.mode = .artwork; store.showingHome = false
    let window = NSWindow(contentRect: .init(x: -10000, y: -10000, width: 900, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let canvas = VectorCanvasView(frame: .init(x: 0, y: 0, width: 900, height: 700))
    canvas.session = store.artworkSession; store.artworkSession.canvas = canvas; store.artworkSession.objectID = owner.id
    window.contentView = canvas; window.orderBack(nil); canvas.synchronize(); window.makeFirstResponder(canvas)
    let board = NSPasteboard.withUniqueName(); store.artworkSession.transferPasteboard = board
    addTeardownBlock { MainActor.assumeIsolated {
      store.artworkTransferStageCheckpoint = nil; store.artworkSession.cancelArtworkTransfer(); canvas.finishText()
      store.engine.project = nil; window.close(); board.releaseGlobally(); try? FileManager.default.removeItem(at: directory)
    } }
    return .init(store: store, window: window, canvas: canvas, board: board, ownerID: owner.id)
  }
  private func command(_ key: String, fixture f: Fixture) throws {
    let paste = key == "v", menu = NSMenu()
    let item = NSMenuItem(title: paste ? "Paste" : "Copy", action: paste ? #selector(VectorCanvasView.paste(_:)) : #selector(VectorCanvasView.copy(_:)), keyEquivalent: key)
    item.keyEquivalentModifierMask = .command; item.target = f.canvas; menu.addItem(item)
    let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
      timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: f.window.windowNumber, context: nil,
      characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: paste ? 9 : 8))
    XCTAssertTrue(menu.performKeyEquivalent(with: event))
  }
  private func paste(_ html: String, into f: Fixture) async throws {
    f.board.clearContents(); XCTAssertTrue(f.board.setString(html, forType: .html))
    try command("v", fixture: f); await f.store.artworkSession.transferTask?.value
    XCTAssertNil(f.store.artworkSession.lastTransferError)
    XCTAssertFalse(f.store.artworkSession.transferInFlight)
  }
  private func art(_ f: Fixture) throws -> Artwork { try XCTUnwrap(f.store.project?.objects.first { $0.id == f.ownerID }?.artwork) }
  private func draft(_ f: Fixture, text: ArtworkElement) throws -> CanvasTextView {
    f.canvas.synchronize(); f.canvas.beginText(text)
    let editor = try XCTUnwrap(f.window.firstResponder as? CanvasTextView)
    editor.textStorage!.replaceCharacters(in: .init(location: 0, length: editor.string.utf16.count), with: "Unpublished replacement 😀")
    editor.setSelectedRange(.init(location: 3, length: 4)); return editor
  }
  private func heldPaste(_ f: Fixture, gate: Gate) async throws -> Task<Void, Never> {
    f.store.artworkTransferStageCheckpoint = { await gate.hold() }
    f.board.clearContents(); f.board.setString(FigmaWireFixture.html(nodes: [FigmaWireFixture.sampleText(id: 90, parent: nil)]), forType: .html)
    try command("v", fixture: f)
    let task = try XCTUnwrap(f.store.artworkSession.transferTask)
    for _ in 0..<1000 { if gate.entered { return task }; try await Task.sleep(nanoseconds: 5_000_000) }
    throw FormError.invalid("Synthetic Figma paste did not reach its publication checkpoint.")
  }
  private func assertNoPublishedSource(_ f: Fixture, projectID: UUID) throws {
    let assets = f.store.repository.url(for: projectID).appendingPathComponent("Assets")
    let entries = try FileManager.default.contentsOfDirectory(at: assets, includingPropertiesForKeys: nil)
    XCTAssertFalse(entries.contains { $0.pathExtension == "figma" })
  }

  func testNativeCommandVPastes1500SourceLayersWithHierarchyTypographyAndOneExactUndo() async throws {
    let f = try fixture(), before = try XCTUnwrap(f.store.project)
    let html = FigmaWireFixture.html(nodes: FigmaWireFixture.denseNodes())
    try await paste(html, into: f)
    let artwork = try art(f), result = try XCTUnwrap(f.store.project)
    // Each painted frame adds a native background shape, not an opaque image.
    XCTAssertEqual(artwork.elements.count, 1525)
    XCTAssertEqual(artwork.elements.filter { $0.kind == "group" }.count, 50)
    XCTAssertEqual(artwork.elements.filter { $0.kind == "text" }.count, 250)
    XCTAssertEqual(artwork.elements.filter { $0.name == "Frame background" }.count, 25)
    XCTAssertEqual(artwork.elements.compactMap(\.sourceMetadata).count, 1500)
    XCTAssertFalse(artwork.elements.contains { $0.kind == "image" })
    let byName = Dictionary(uniqueKeysWithValues: artwork.elements.filter { $0.sourceMetadata != nil }.map { ($0.name, $0) })
    let unit = 25.4 / 96.0
    for card in 0..<25 {
      let frame = try XCTUnwrap(byName["Card \(card)"]), group = try XCTUnwrap(byName["Contents \(card)"])
      XCTAssertNil(frame.parentID); XCTAssertEqual(group.parentID, frame.id)
      XCTAssertEqual(group.affine?.tx ?? -1, 12 * unit, accuracy: 1e-8)
      XCTAssertEqual(group.affine?.ty ?? -1, 24 * unit, accuracy: 1e-8)
      XCTAssertEqual(frame.sourceMetadata?.nodeID, "7:\(100 + card * 60)")
      for index in 0..<48 {
        let tile = try XCTUnwrap(byName["Tile \(card).\(index)"])
        XCTAssertEqual(tile.parentID, group.id); XCTAssertEqual(tile.kind, index % 3 == 0 ? "ellipse" : "rectangle")
        XCTAssertEqual(tile.width, 28 * unit, accuracy: 1e-8); XCTAssertEqual(tile.height, 18 * unit, accuracy: 1e-8)
        XCTAssertEqual(tile.sourceMetadata?.nodeID, "7:\(102 + card * 60 + index)")
      }
      for index in 0..<10 { XCTAssertEqual(byName["Label \(card).\(index)"]?.parentID, group.id) }
    }
    let label = try XCTUnwrap(byName["Label 0.0"]), runs = try XCTUnwrap(label.textRuns)
    XCTAssertEqual(label.text, "A😀\nאב"); XCTAssertEqual(label.fontSize, 12, accuracy: 1e-10)
    XCTAssertEqual(label.typography?.frameMode, "area"); XCTAssertEqual(label.typography?.leading ?? -1, 18, accuracy: 1e-8)
    XCTAssertEqual(label.typography?.tracking ?? -1, 1.2, accuracy: 1e-8)
    let emoji = try XCTUnwrap(runs.first { $0.location == 1 })
    XCTAssertEqual(emoji.length, 2); XCTAssertEqual(emoji.fontSize, 24, accuracy: 1e-8); XCTAssertTrue(emoji.typography.underline)
    XCTAssertEqual(emoji.typography.leading, 36, accuracy: 1e-8); XCTAssertEqual(emoji.typography.tracking, 2.4, accuracy: 1e-8)
    let rtl = try XCTUnwrap(runs.first { $0.location == 4 })
    XCTAssertEqual(rtl.length, 2); XCTAssertEqual(rtl.typography.direction, "rtl")
    XCTAssertEqual(rtl.typography.alignment, "right"); XCTAssertEqual(rtl.typography.paragraphAfter, 9, accuracy: 1e-8)
    let source = try XCTUnwrap(label.sourceMetadata)
    let properties = try JSONDecoder().decode(FigmaValue.self, from: source.properties)
    XCTAssertEqual(properties["textData"]?["characters"]?.stringValue, "A😀\nאב")
    XCTAssertEqual(source.nodeID, "7:150")
    XCTAssertEqual(f.store.artworkSession.selection.count, 25)
    XCTAssertEqual(f.store.engine.undoStack.count, 1); XCTAssertEqual(result.camera, before.camera)
    let provenance = try XCTUnwrap(artwork.imports?.first)
    XCTAssertEqual(provenance.format, "figma"); XCTAssertEqual(Set(provenance.elementIDs ?? []), Set(artwork.elements.map(\.id)))
    let assets = f.store.repository.url(for: result.id).appendingPathComponent("Assets")
    XCTAssertEqual(try Data(contentsOf: assets.appendingPathComponent(provenance.asset)), Data(html.utf8))
    f.store.engine.undo(); XCTAssertTrue(f.store.project == before, "Undo must restore the complete pre-paste project")
    f.store.engine.redo(); XCTAssertTrue(f.store.project == result, "Redo must restore the same layer identities and source settings")
    try f.store.engine.flush(); let reopened = try f.store.repository.load(result.id)
    XCTAssertTrue(reopened.objects[0].artwork == artwork, "Save/reopen must preserve exact editable layers, text settings, source metadata and import provenance")
    try exportValidationFixture(f, html: html)
  }

  private func exportValidationFixture(_ f: Fixture, html: String, name: String = "dense-1500") throws {
    let project = try XCTUnwrap(f.store.project)
    let bundle = try ArtworkTransferGraph.capture(project: project, objectID: f.ownerID, ids: f.store.artworkSession.selection,
      readAsset: { name, limit in
        let data = try Data(contentsOf: f.store.repository.url(for: project.id).appendingPathComponent("Assets/" + name))
        guard data.count <= limit else { throw FormError.invalid("Fixture asset exceeds budget") }; return data
      })
    let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let directory = repo.appendingPathComponent(".local/validation/figma-paste")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data(html.utf8).write(to: directory.appendingPathComponent(name + ".html"), options: .atomic)
    try bundle.encoded().write(to: directory.appendingPathComponent(name + ".formart"), options: .atomic)
  }

  func testPreferredLABThenFigmaPayloadsWinOverOverlappingSVG() async throws {
    let html = FigmaWireFixture.html(nodes: [FigmaWireFixture.sampleText(id: 90, parent: nil)])
    let svg = Data("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"40\" height=\"30\"><rect width=\"40\" height=\"30\" fill=\"red\"/></svg>".utf8)
    for useLAB in [true, false] {
      let f = try fixture()
      f.board.clearContents(); f.board.setString(html, forType: .html); f.board.setData(svg, forType: .init("public.svg-image"))
      if useLAB {
        var source = Project(name: "Preferred LAB"); let owner = try source.ensureCanvasWorkspace()
        var shape = ArtworkElement(kind: "ellipse", x: 0, y: 0, width: 30, height: 20); shape.name = "Preferred native shape"
        source.objects[0].artwork!.elements = [shape]
        let bundle = try ArtworkTransferGraph.capture(project: source, objectID: owner.id, ids: [shape.id], readAsset: { _, _ in Data() })
        f.board.setData(try bundle.encoded(), forType: ArtworkTransferPasteboard.type)
      }
      try command("v", fixture: f); await f.store.artworkSession.transferTask?.value
      XCTAssertNil(f.store.artworkSession.lastTransferError)
      let artwork = try art(f); XCTAssertEqual(artwork.elements.count, 1)
      XCTAssertEqual(artwork.elements[0].kind, useLAB ? "ellipse" : "text")
      XCTAssertEqual(artwork.elements[0].name, useLAB ? "Preferred native shape" : "Unicode specimen")
      XCTAssertEqual(f.store.engine.undoStack.count, 1)
    }
  }

  func testInvalidPreferredPayloadDoesNotFallbackOrCommitLiveText() async throws {
    for invalidLAB in [true, false] {
      let f = try fixture(text: true), before = try XCTUnwrap(f.store.project)
      let editor = try draft(f, text: art(f).elements[0]), caret = editor.selectedRange()
      f.board.clearContents()
      f.board.setString(invalidLAB ? FigmaWireFixture.html(nodes: [FigmaWireFixture.sampleText(id: 90, parent: nil)]) : "<span>(figma)bad!(/figma)</span>", forType: .html)
      f.board.setData(Data("<svg xmlns=\"http://www.w3.org/2000/svg\"><rect width=\"10\" height=\"10\"/></svg>".utf8), forType: .init("public.svg-image"))
      if invalidLAB { f.board.setData(Data("bad preferred LAB".utf8), forType: ArtworkTransferPasteboard.type) }
      try command("v", fixture: f); await f.store.artworkSession.transferTask?.value
      XCTAssertNotNil(f.store.artworkSession.lastTransferError); XCTAssertTrue(f.store.project == before)
      XCTAssertTrue(f.window.firstResponder === editor); XCTAssertEqual(editor.string, "Unpublished replacement 😀")
      XCTAssertEqual(editor.selectedRange(), caret); XCTAssertTrue(f.store.engine.undoStack.isEmpty)
      try assertNoPublishedSource(f, projectID: before.id)
    }
  }

  func testScopeRoundTripCancelsHeldFigmaPasteAndPreservesNewerLiveText() async throws {
    let f = try fixture(text: true), gate = Gate(); defer { gate.release() }
    var group = ArtworkElement(kind: "group", x: 0, y: 0, width: 180, height: 110); group.contentSize = .init(180, 110)
    var other = group; other.id = UUID(); other.x = 20
    var text = try art(f).elements[0]; text.parentID = group.id
    f.store.engine.project!.objects[0].artwork!.elements = [group, other, text]
    try f.store.engine.flush(); f.store.artworkSession.scopeID = group.id; f.canvas.synchronize()
    let task = try await heldPaste(f, gate: gate)
    f.store.artworkSession.scopeID = other.id; f.store.artworkSession.scopeID = group.id
    let editor = try draft(f, text: text), caret = editor.selectedRange(), before = try XCTUnwrap(f.store.project)
    let history = f.store.engine.undoStack, selection = f.store.artworkSession.selection
    gate.release(); await task.value
    XCTAssertTrue(f.store.project == before); XCTAssertTrue(f.store.engine.undoStack == history)
    XCTAssertEqual(f.store.artworkSession.selection, selection); XCTAssertEqual(f.store.artworkSession.scopeID, group.id)
    XCTAssertTrue(f.window.firstResponder === editor); XCTAssertEqual(editor.string, "Unpublished replacement 😀"); XCTAssertEqual(editor.selectedRange(), caret)
    try assertNoPublishedSource(f, projectID: before.id)
  }

  func testProjectRoundTripCannotPublishHeldFigmaPasteIntoReopenedLifetime() async throws {
    let f = try fixture(text: true), gate = Gate(); defer { gate.release() }
    let original = try XCTUnwrap(f.store.project), text = try art(f).elements[0], other = Project(name: "Other project")
    try f.store.repository.save(other)
    let task = try await heldPaste(f, gate: gate)
    try f.store.engine.open(other.id); try f.store.engine.open(original.id)
    let editor = try draft(f, text: text), caret = editor.selectedRange(), before = try XCTUnwrap(f.store.project), history = f.store.engine.undoStack
    gate.release(); await task.value
    XCTAssertTrue(f.store.project == before); XCTAssertTrue(f.store.engine.undoStack == history)
    XCTAssertTrue(f.window.firstResponder === editor); XCTAssertEqual(editor.string, "Unpublished replacement 😀"); XCTAssertEqual(editor.selectedRange(), caret)
    try assertNoPublishedSource(f, projectID: original.id)
  }

  func testValidFigmaPasteCommitsLaggingTextThenUndoRemovesOnlyPaste() async throws {
    let f = try fixture(text: true), oldText = try art(f).elements[0]
    _ = try draft(f, text: oldText)
    try await paste(FigmaWireFixture.html(nodes: [FigmaWireFixture.sampleText(id: 90, parent: nil)]), into: f)
    XCTAssertEqual(try art(f).elements.count, 2); XCTAssertEqual(f.store.engine.undoStack.count, 2)
    f.store.engine.undo()
    XCTAssertEqual(try art(f).elements.count, 1); XCTAssertEqual(try art(f).elements[0].text, "Unpublished replacement 😀")
    f.store.engine.undo(); XCTAssertEqual(try art(f).elements[0].text, "Original words")
  }

  func testCopyOfOneImportedGroupKeepsItsSourceSettingsWithoutSiblingSourceBytes() async throws {
    let f = try fixture()
    try await paste(FigmaWireFixture.html(nodes: FigmaWireFixture.denseNodes(cards: 2)), into: f)
    let original = try art(f), card = try XCTUnwrap(original.elements.first { $0.name == "Card 0" })
    f.store.artworkSession.choose([card.id]); try command("c", fixture: f)
    let payload = try XCTUnwrap(f.board.data(forType: ArtworkTransferPasteboard.type)), copied = try ArtworkTransferBundle.decode(payload)
    XCTAssertEqual(copied.metadata.artwork.elements.count, 61)
    XCTAssertEqual(copied.metadata.artwork.elements.compactMap(\.sourceMetadata).count, 60)
    XCTAssertTrue(copied.metadata.artwork.imports?.isEmpty ?? true); XCTAssertTrue(copied.metadata.assets.isEmpty)
    XCTAssertFalse(copied.metadata.artwork.elements.contains { $0.name == "Card 1" })
    let expected = Dictionary(uniqueKeysWithValues: original.elements.compactMap { e in e.sourceMetadata.map { ($0.nodeID, $0.properties) } })
    for metadata in copied.metadata.artwork.elements.compactMap(\.sourceMetadata) { XCTAssertEqual(metadata.properties, expected[metadata.nodeID]) }
    let destination = try fixture(); destination.board.clearContents(); destination.board.setData(payload, forType: ArtworkTransferPasteboard.type)
    try command("v", fixture: destination); await destination.store.artworkSession.transferTask?.value
    XCTAssertNil(destination.store.artworkSession.lastTransferError)
    let pasted = try art(destination); XCTAssertEqual(pasted.elements.count, 61)
    XCTAssertEqual(Set(pasted.elements.compactMap { $0.sourceMetadata?.nodeID }), Set(copied.metadata.artwork.elements.compactMap { $0.sourceMetadata?.nodeID }))
    XCTAssertTrue(Set(pasted.elements.map(\.id)).isDisjoint(with: Set(copied.metadata.artwork.elements.map(\.id))))
    XCTAssertEqual(destination.store.engine.undoStack.count, 1)
  }

  func testCoherentComplexShowcasePastesEditableCurvesClipsImageGradientsAndLinkedComponents() async throws {
    let f = try fixture(), before = try XCTUnwrap(f.store.project), html = FigmaWireFixture.showcaseHTML()
    try await paste(html, into: f)
    let artwork = try art(f), after = try XCTUnwrap(f.store.project)
    XCTAssertGreaterThan(artwork.elements.count, 900)
    XCTAssertGreaterThan(artwork.elements.filter { $0.sourceMetadata != nil }.count, 990)
    XCTAssertEqual(artwork.elements.filter { $0.kind == "path" }.count, 260)
    XCTAssertGreaterThanOrEqual(artwork.elements.filter { $0.clipID != nil }.count, 8)
    XCTAssertGreaterThanOrEqual(artwork.elements.filter { $0.gradient != nil }.count, 10)
    XCTAssertGreaterThanOrEqual(artwork.elements.filter { $0.kind == "text" }.count, 25)
    XCTAssertEqual(f.store.artworkSession.selection.count, 1)
    let image = try XCTUnwrap(artwork.elements.first { $0.kind == "image" })
    XCTAssertNotNil(image.affine); XCTAssertNotNil(image.clipID)
    let asset = try XCTUnwrap(image.asset)
    let imageBytes = try Data(contentsOf: f.store.repository.url(for: after.id).appendingPathComponent("Assets/" + asset))
    XCTAssertEqual(Array(imageBytes.prefix(8)), [137,80,78,71,13,10,26,10])
    for curve in artwork.elements.filter({ $0.kind == "path" }) {
      let contour = try XCTUnwrap(curve.path?.contours.first)
      XCTAssertTrue(contour.closed); XCTAssertEqual(contour.nodes.count, 4)
      XCTAssertTrue(contour.nodes.allSatisfy { $0.incoming != nil && $0.outgoing != nil })
      XCTAssertNotNil(curve.stroke)
    }
    let instances = artwork.elements.compactMap(\.component)
    XCTAssertEqual(instances.count, 12); XCTAssertEqual(Set(instances.map(\.sourceObjectID)).count, 1)
    let definition = try XCTUnwrap(after.objects.first { $0.id == instances.first?.sourceObjectID })
    XCTAssertEqual(definition.componentDefinition, true)
    XCTAssertTrue(definition.artwork?.elements.contains { $0.kind == "text" && $0.text == "FIELD / 01" } == true)
    let specimen = try XCTUnwrap(artwork.elements.first { $0.name == "Rich Unicode specimen" })
    XCTAssertEqual(specimen.text, "A😀\nאב"); XCTAssertTrue(specimen.textRuns?.contains { $0.location == 1 && $0.length == 2 } == true)
    let paintedText=try XCTUnwrap(artwork.elements.first{$0.name=="Live stacked gradient headline"})
    XCTAssertEqual(paintedText.kind,"text");XCTAssertEqual(paintedText.text,"INK / 05")
    XCTAssertEqual(paintedText.paintStack?.count,2);XCTAssertEqual(paintedText.effectStack?.effects.count,2)
    let groupMask=try XCTUnwrap(artwork.elements.first{$0.name=="Editable overlapping group mask"})
    XCTAssertEqual(groupMask.kind,"group");XCTAssertEqual(groupMask.opacity ?? 0,0.65,accuracy:1e-6)
    XCTAssertTrue(artwork.elements.contains{$0.clipID==groupMask.id && $0.clipMode=="alpha"})
    XCTAssertEqual(artwork.elements.filter{$0.name?.hasPrefix("Diamond disc ")==true && $0.effectStack?.effects.count==2}.count,8)
    XCTAssertEqual(f.store.engine.undoStack.count, 1)
    f.store.engine.undo(); XCTAssertTrue(f.store.project == before)
    f.store.engine.redo(); XCTAssertTrue(f.store.project == after)
    try f.store.engine.flush()
    XCTAssertTrue(try f.store.repository.load(after.id).objects.first { $0.id == f.ownerID }?.artwork == artwork)
    try exportValidationFixture(f, html: html, name: "systems-in-motion")
  }
  func testRepeatedNativePointerNavigationAndGroupingAfterDenseFigmaPaste()async throws {
    let f=try fixture();try await paste(FigmaWireFixture.html(nodes:FigmaWireFixture.denseNodes()),into:f)
    let scroll=ArtworkScrollView(frame:f.window.contentView!.bounds)
    scroll.allowsMagnification=true;scroll.minMagnification=0.08;scroll.maxMagnification=24
    f.window.contentView=nil;scroll.documentView=f.canvas;f.window.contentView=scroll
    f.window.makeFirstResponder(f.canvas);f.canvas.synchronize();f.canvas.fit(all:true)
    let session=f.store.artworkSession,before=try XCTUnwrap(f.store.project),original=try art(f)
    let byName=Dictionary(uniqueKeysWithValues:original.elements.filter{$0.sourceMetadata != nil}.map{($0.name!,$0)})
    func point(_ name:String)throws->CGPoint {
      let e=try XCTUnwrap(byName[name]),p=original.worldTransform(e).apply(.init(e.width/2,e.height/2))
      return .init(x:p.x,y:p.y)
    }
    func event(_ type:NSEvent.EventType,_ p:CGPoint,_ count:Int=1,_ modifiers:NSEvent.ModifierFlags=[])->NSEvent {
      NSEvent.mouseEvent(with:type,location:f.canvas.convert(f.canvas.documentPoint(p),to:nil),modifierFlags:modifiers,
        timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:f.window.windowNumber,context:nil,eventNumber:1,clickCount:count,
        pressure:type == .leftMouseUp ? 0:1)!
    }
    func click(_ p:CGPoint,_ count:Int=1,_ modifiers:NSEvent.ModifierFlags=[]) {
      f.canvas.mouseDown(with:event(.leftMouseDown,p,count,modifiers));f.canvas.mouseUp(with:event(.leftMouseUp,p,count,modifiers))
    }
    for zoom in [0.4,1.6] {
      f.canvas.setZoom(zoom);session.leaveGroup(toRoot:true);session.choose([])
      for card in [0,6,12,18,24,3,9,15,21,7] {
        let p=try point("Tile \(card).1")
        f.canvas.ensureViewportCoverage(preserving:p)
        click(p);XCTAssertEqual(session.selection,[byName["Card \(card)"]!.id])
        click(p,2);XCTAssertEqual(session.scopeID,byName["Card \(card)"]!.id)
        click(p);click(p,2);XCTAssertEqual(session.scopeID,byName["Contents \(card)"]!.id)
        click(p);XCTAssertEqual(session.selection,[byName["Tile \(card).1"]!.id])
        click(try point("Tile \(card).2"),1,.shift)
        XCTAssertEqual(session.selection,[byName["Tile \(card).1"]!.id,byName["Tile \(card).2"]!.id])
        let next=(card+1)%25,outside=try point("Tile \(next).1")
        f.canvas.ensureViewportCoverage(preserving:outside);click(outside)
        XCTAssertNil(session.scopeID);XCTAssertEqual(session.selection,[byName["Card \(next)"]!.id])
        session.choose([])
        f.canvas.mouseMoved(with:event(.mouseMoved,outside))
        XCTAssertEqual(f.canvas.hoveredElementID,byName["Card \(next)"]!.id)
      }
    }
    XCTAssertTrue(f.store.project==before);XCTAssertEqual(f.store.engine.undoStack.count,1)
    let p=try point("Tile 12.1");f.canvas.ensureViewportCoverage(preserving:p)
    click(p);click(p,2);click(p);click(p,2);click(p);click(try point("Tile 12.2"),1,.shift)
    let menu=try XCTUnwrap(f.canvas.menu(for:event(.rightMouseDown,p)))
    let groupIndex=try XCTUnwrap(menu.items.firstIndex{$0.title=="Group"});menu.performActionForItem(at:groupIndex)
    XCTAssertNil(f.store.error)
    let group=try XCTUnwrap(session.primary);XCTAssertEqual(group.kind,"group")
    XCTAssertEqual(Set(session.art.elements.filter{$0.parentID==group.id}.map(\.id)),[byName["Tile 12.1"]!.id,byName["Tile 12.2"]!.id])
    let grouped=try XCTUnwrap(f.store.project)
    f.store.undo();XCTAssertTrue(f.store.project==before)
    f.store.redo();XCTAssertTrue(f.store.project==grouped)
    session.leaveGroup(toRoot:true);click(try point("Tile 24.1"));XCTAssertNil(session.scopeID)
    XCTAssertEqual(session.selection,[byName["Card 24"]!.id])
  }
}
