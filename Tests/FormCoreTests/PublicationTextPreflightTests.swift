import AppKit
import XCTest
@testable import FormCore
@testable import FormGraphics

@MainActor final class PublicationTextPreflightTests: XCTestCase {
  private let assets = FileManager.default.temporaryDirectory

  private func text(_ value: String = "A complete masthead", height: Double = 1) -> ArtworkElement {
    var element = ArtworkElement(kind: "text", x: 10, y: 10,
      width: 80, height: height, text: value, color: "#000000", fontSize: 36)
    element.name = "Cover masthead"
    var style = Typography(); style.fontName = "Helvetica"; style.frameMode = "area"
    element.typography = style
    return element
  }

  private func fixture(_ elements: [ArtworkElement], pages count: Int = 1) throws -> (Project, UUID) {
    var project = Project(name: "Complete text capacity")
    for i in 0..<count {
      var page = try project.makeObject(recipeID: "artboard", name: "Page \(i + 1)",
        parameters: ["width": 100, "depth": 140])
      page.artwork = .init(background: "#FFFFFF", elements: i == 0 ? elements : [], bleed: 0)
      project.objects.append(page)
    }
    let id = try PublicationCommands.createPublication(in: &project, name: "Every text frame", pages: project.objects.map(\.id))
    return (project, id)
  }

  private func issues(_ report: [String: Any], code: String = "overset") -> [[String: Any]] {
    (report["issues"] as? [[String: Any]] ?? []).filter { $0["code"] as? String == code }
  }

  private func frames(_ report: [String: Any]) -> [[String: Any]] { report["text_frames"] as? [[String: Any]] ?? [] }

  private func darkPixels(_ artwork: Artwork) throws -> Int {
    let image = ArtworkRenderer.image(artwork, width: 100, height: 140, assets: assets, pixelsPerMM: 2)
    let bitmap = try XCTUnwrap(image.representations.first as? NSBitmapImageRep)
    var dark = 0
    for y in 0..<bitmap.pixelsHigh { for x in 0..<bitmap.pixelsWide {
      if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), color.redComponent < 0.8 { dark += 1 }
    } }
    return dark
  }

  func testInvisibleStandaloneMastheadFailsBeforePaintBoundsAndResizeRestoresRealInk() throws {
    for paragraph in [false, true] {
      var element = text()
      if paragraph { element.typography?.hyphenation = 1 }
      var (project, id) = try fixture([element])
      let original = project, page = project.publications![0].pages[0]
      let capacity = TypographyEngine.capacity(element)
      XCTAssertEqual(capacity.displayRange.length, 0)
      XCTAssertEqual(capacity.oversetRange, NSRange(location: 0, length: element.text.utf16.count))
      XCTAssertEqual(try darkPixels(project.surfaceArtwork(project.objects[0])!), 0)
      let report = PublicationOutput.preflight(project, documentID: id)
      XCTAssertEqual(report["can_export"] as? Bool, false)
      let issue = try XCTUnwrap(issues(report).first)
      XCTAssertEqual(issues(report).count, 1)
      XCTAssertEqual(issue["object_id"] as? String, page.objectID.uuidString)
      XCTAssertEqual(issue["element_id"] as? String, element.id.uuidString)
      XCTAssertEqual(issue["page_object_id"] as? String, page.objectID.uuidString)
      XCTAssertEqual(issue["publication_page_id"] as? String, page.id.uuidString)
      XCTAssertEqual(frames(report).count, 1)
      XCTAssertEqual(frames(report)[0]["visible_source_length"] as? Int, 0)
      for outlined in [false, true] {
        XCTAssertThrowsError(try PublicationOutput.pdf(project, documentID: id, assets: assets, outlineText: outlined))
        let reviewed = try PublicationOutput.pdf(project, documentID: id, assets: assets, outlineText: outlined, allowOverset: true)
        XCTAssertEqual(CGPDFDocument(CGDataProvider(data: reviewed as CFData)!)?.numberOfPages, 1)
      }
      XCTAssertEqual(project, original)
      project.objects[0].artwork!.elements[0].height = 45
      let repaired = project, fixed = PublicationOutput.preflight(project, documentID: id)
      XCTAssertTrue(issues(fixed).isEmpty)
      XCTAssertEqual(fixed["can_export"] as? Bool, true)
      XCTAssertEqual(frames(fixed)[0]["visible_source_length"] as? Int, element.text.utf16.count)
      XCTAssertGreaterThan(try darkPixels(project.surfaceArtwork(project.objects[0])!), 150)
      XCTAssertNoThrow(try PublicationOutput.pdf(project, documentID: id, assets: assets, outlineText: true))
      XCTAssertEqual(project, repaired)
    }
  }

  func testCapacityMapsRichCaseExpandedEmojiAndRTLBackToAuthoredUTF16() throws {
    for paragraph in [false, true] {
      let words = "straße 👩🏽‍💻 שלום\n" + String(repeating: "Original words and formatting remain intact. ", count: 7)
      var element = text(words, height: 9); element.width = 75; element.fontSize = 14
      element.typography?.caseTreatment = "uppercase"; element.typography?.language = "de"
      element.typography?.hyphenation = paragraph ? 1 : 0
      element.typography?.tracking = 0.4; element.typography?.leading = 19
      var run = element.typography!; run.tracking = 1.2
      element.textRuns = [.init(location: 0, length: "straße".utf16.count, typography: run, fontSize: 20, color: "#000000")]
      let before = element, capacity = TypographyEngine.capacity(element)
      XCTAssertTrue(capacity.overflows)
      XCTAssertEqual(capacity.sourceLength, words.utf16.count)
      XCTAssertGreaterThan(capacity.displayLength, capacity.sourceLength)
      XCTAssertEqual(NSMaxRange(capacity.oversetRange), words.utf16.count)
      XCTAssertEqual(NSMaxRange(capacity.sourceRange), capacity.oversetRange.location)
      XCTAssertEqual(element, before)
      element.height = 220
      let fitting = TypographyEngine.capacity(element)
      XCTAssertFalse(fitting.overflows)
      XCTAssertEqual(fitting.sourceRange, NSRange(location: 0, length: words.utf16.count))
      XCTAssertEqual(fitting.oversetRange.length, 0)
    }
    var expansion = text("ß", height: 20); expansion.typography?.caseTreatment = "uppercase"
    let display = TypographyEngine.attributed(expansion)
    XCTAssertEqual(display.string, "SS")
    let partial = TypographyEngine.independentCapacity(expansion, display: display,
      visible: NSRange(location: 0, length: 1), widthOverflow: false)
    XCTAssertEqual(partial.sourceRange.length, 0)
    XCTAssertEqual(partial.oversetRange, NSRange(location: 0, length: 1))
  }

  func testMasterTokenOverflowIdentifiesOriginalElementAndOnlyAffectedLogicalPage() throws {
    var (project, id) = try fixture([], pages: 2)
    var master = try project.makeObject(recipeID: "artboard", name: "Running title source",
      parameters: ["width": 100, "depth": 140])
    var group = ArtworkElement(kind: "group", x: 0, y: 0, width: 100, height: 140)
    group.contentSize = .init(100, 140); group.rotation = 5
    var title = text("{{chapter.title}}", height: 15); title.width = 65; title.fontSize = 18; title.parentID = group.id
    master.artwork = .init(elements: [group, title]); project.objects.append(master)
    var document = project.publications![0]
    let binding = PublicationMaster(name: "Running title", sourceObjectID: master.id)
    document.masters = [binding]
    document.pages[0].chapterTitle = "Opening"
    document.pages[1].chapterTitle = String(repeating: "A much longer chapter title ", count: 15)
    try PublicationCommands.setPublication(in: &project, document: document)
    let before = project, report = PublicationOutput.preflight(project, documentID: id)
    let issue = try XCTUnwrap(issues(report).first)
    XCTAssertEqual(issues(report).count, 1)
    XCTAssertEqual(issue["object_id"] as? String, master.id.uuidString)
    XCTAssertEqual(issue["element_id"] as? String, title.id.uuidString)
    XCTAssertEqual(issue["master_id"] as? String, binding.id.uuidString)
    XCTAssertEqual(issue["page_object_id"] as? String, document.pages[1].objectID.uuidString)
    XCTAssertEqual(issue["publication_page_id"] as? String, document.pages[1].id.uuidString)
    let renderedID = try XCTUnwrap((issue["rendered_element_id"] as? String).flatMap(UUID.init(uuidString:)))
    XCTAssertNotEqual(renderedID, title.id)
    let rendered = try XCTUnwrap(project.surfaceArtwork(project.objects[1])?.elements.first { $0.id == renderedID })
    XCTAssertEqual(rendered.text, document.pages[1].chapterTitle)
    XCTAssertEqual(Set(frames(report).compactMap { $0["kind"] as? String }), ["master"])
    XCTAssertEqual(frames(report).map { $0["status"] as? String }, ["fit", "overset"])
    XCTAssertEqual(project, before)
    XCTAssertEqual(project.objects.last?.artwork?.elements.last?.text, "{{chapter.title}}")
  }

  func testNestedComponentTextInMasterHasEditableSourceAndOccurrenceAddresses() throws {
    var (project, id) = try fixture([])
    var source = try project.makeObject(recipeID: "artboard", name: "Editable component text")
    let title = text("Overflow in a component")
    source.componentDefinition = true; source.artwork = .init(elements: [title])
    var nestedSource = try project.makeObject(recipeID: "artboard", name: "Nested component")
    var nested = ArtworkElement(kind: "group", x: 0, y: 0, width: source.artworkSize.x, height: source.artworkSize.y)
    nested.component = .init(sourceObjectID: source.id)
    nestedSource.componentDefinition = true; nestedSource.artwork = .init(elements: [nested])
    var master = try project.makeObject(recipeID: "artboard", name: "Master component source")
    var instance = ArtworkElement(kind: "group", x: 0, y: 0, width: nestedSource.artworkSize.x, height: nestedSource.artworkSize.y)
    instance.component = .init(sourceObjectID: nestedSource.id); master.artwork = .init(elements: [instance])
    project.objects += [source, nestedSource, master]
    var document = project.publications![0]
    document.masters = [.init(sourceObjectID: master.id)]
    try PublicationCommands.setPublication(in: &project, document: document)
    let before = project, report = PublicationOutput.preflight(project, documentID: id)
    let issue = try XCTUnwrap(issues(report).first)
    XCTAssertEqual(issue["object_id"] as? String, source.id.uuidString)
    XCTAssertEqual(issue["element_id"] as? String, title.id.uuidString)
    XCTAssertEqual(issue["master_source_object_id"] as? String, master.id.uuidString)
    XCTAssertEqual(issue["instance_object_id"] as? String, master.id.uuidString)
    XCTAssertEqual(issue["instance_element_id"] as? String, instance.id.uuidString)
    XCTAssertEqual(issues(report, code: "text_source_unavailable").count, 0)
    XCTAssertEqual(project, before)
  }

  func testStoryTailIsReportedOnceOnTerminalFrameWithAllFrameRangesInventoried() throws {
    var first = text(String(repeating: "One intact global story. ", count: 12), height: 1)
    first.fontSize = 14
    var (project, id) = try fixture([first], pages: 2)
    let second = text("", height: 1)
    project.objects[1].artwork!.elements = [second]
    let linked = [StoryFrameID(objectID: project.objects[0].id, elementID: first.id),
      StoryFrameID(objectID: project.objects[1].id, elementID: second.id)]
    let story = try PublicationCommands.createStory(in: &project, frames: linked, name: "Main story", publicationID: id)
    let composition = StoryComposition(try XCTUnwrap(project.resolvedTextStory(story)))
    for index in linked.indices {
      let box = composition.containers[index]
      var lines: [String] = []
      composition.layout.enumerateLineFragments(forGlyphRange: composition.glyphRange(index)) { rect, used, _, range, _ in
        lines.append("glyphs=\(range) rect=\(rect) used=\(used)")
      }
      XCTAssertEqual(composition.context.frames[index].height, 1)
      XCTAssertEqual(composition.sourceRange(index).length, 0,
        "A 1mm frame cannot fit 14pt text: frame=\(index) box=\(box.size) glyphs=\(composition.glyphRange(index)) display=\(composition.displayRange(index)) used=\(composition.layout.usedRect(for: box)) lines=\(lines)")
      XCTAssertEqual(try darkPixels(try XCTUnwrap(project.surfaceArtwork(project.objects[index]))), 0)
    }
    let before = project, report = PublicationOutput.preflight(project, documentID: id)
    let issue = try XCTUnwrap(issues(report).first)
    XCTAssertEqual(issues(report).count, 1)
    XCTAssertEqual(issue["story_id"] as? String, story.uuidString)
    XCTAssertEqual(issue["object_id"] as? String, linked[1].objectID.uuidString)
    XCTAssertEqual(issue["element_id"] as? String, second.id.uuidString)
    XCTAssertEqual(issue["publication_page_id"] as? String, project.publications![0].pages[1].id.uuidString)
    XCTAssertEqual(frames(report).count, 2)
    XCTAssertEqual(frames(report).map { $0["terminal_story_frame"] as? Bool }, [false, true])
    XCTAssertEqual(frames(report)[0]["overset_length"] as? Int, 0)
    XCTAssertEqual(frames(report)[1]["overset_length"] as? Int, first.text.utf16.count)
    XCTAssertEqual(project, before)
    for i in 0..<2 { project.objects[i].artwork!.elements[0].height = 80 }
    XCTAssertTrue(issues(PublicationOutput.preflight(project, documentID: id)).isEmpty)
    XCTAssertEqual(project.textStories?.first?.text, first.text)
  }

  func testHiddenNonprintingAndEmptyFramesAreInventoriedButRequiredTextMasksAreChecked() throws {
    var parent = ArtworkElement(kind: "group", x: 0, y: 0, width: 100, height: 140); parent.hidden = true
    var hidden = text(); hidden.parentID = parent.id
    var guide = text(); guide.productionRole = ArtworkProductionRole.guide.rawValue
    var transparent = text(); transparent.opacity = 0
    let empty = text("")
    var mask = text(); mask.hidden = true
    var clipped = ArtworkElement(kind: "rectangle", x: 10, y: 10, width: 80, height: 30)
    clipped.clipID = mask.id; clipped.clipMode = "alpha"
    let (project, id) = try fixture([parent, hidden, guide, transparent, empty, mask, clipped])
    let report = PublicationOutput.preflight(project, documentID: id), inventory = frames(report)
    XCTAssertEqual(inventory.count, 5)
    XCTAssertEqual(issues(report).compactMap { $0["element_id"] as? String }, [mask.id.uuidString])
    for excluded in [hidden, guide, transparent] {
      let row = try XCTUnwrap(inventory.first { $0["element_id"] as? String == excluded.id.uuidString })
      XCTAssertEqual(row["included_in_output"] as? Bool, false)
      XCTAssertEqual(row["status"] as? String, "excluded")
      XCTAssertEqual(row["layout_status"] as? String, "overset")
    }
    XCTAssertEqual(inventory.first { $0["element_id"] as? String == empty.id.uuidString }?["status"] as? String, "fit")
  }

  func testCapacityErrorsAndReviewedPartialExportAgreeAcrossAllPublicationRoutes() throws {
    let element = text()
    var (project, id) = try fixture([element], pages: 4)
    let pages = project.publications![0].pages
    let stock = PaperStock(thicknessMM: 0.15)
    var definition = SheetAssemblyDefinition(publicationID: id, stock: stock)
    definition.parentSheets = [.init(frontPageIDs: [pages[3].id, pages[0].id], backPageIDs: [pages[1].id, pages[2].id],
      stock: stock, sizeMM: .init(200, 140))]
    let physical = try SheetAssemblyCommands.create(in: &project, definition: definition)
    let assembly = try XCTUnwrap(project.objects.first { $0.id == physical }), before = project
    for layout in [PublicationPDFLayout.pages, .spreads, .booklet] {
      let arranged = PublicationOutput.arrangedPreflight(project, documentID: id, assets: assets, layout: layout, inkOutput: .preview)
      let physical = PublicationOutput.physicalPreflight(project, documentID: id, assembly: assembly, assets: assets, layout: layout, previewOnly: true)
      for report in [arranged, physical] {
        XCTAssertEqual(report["can_export"] as? Bool, false)
        XCTAssertEqual(issues(report).compactMap { $0["element_id"] as? String }, [element.id.uuidString])
        XCTAssertEqual(frames(report).count, 1)
      }
      XCTAssertThrowsError(try PublicationOutput.arrangedPDF(project, documentID: id, assets: assets, layout: layout))
      XCTAssertThrowsError(try PublicationOutput.physicalPDF(project, documentID: id, assembly: assembly, assets: assets, layout: layout, previewOnly: true))
      XCTAssertNoThrow(try PublicationOutput.arrangedPDF(project, documentID: id, assets: assets, allowOverset: true, layout: layout))
      XCTAssertNoThrow(try PublicationOutput.physicalPDF(project, documentID: id, assembly: assembly, assets: assets, allowOverset: true, layout: layout, previewOnly: true))
    }
    XCTAssertEqual(project, before)
    XCTAssertFalse(issues(PublicationOutput.preflight(project, documentID: id)).isEmpty,
      "Reviewed partial export must never suppress future preflight diagnostics.")
  }

  func testNoPaintFramesStayExcludedWhileStrokeAndCharacterPaintsRemainRequired() throws {
    var disabled = text(); disabled.fillEnabled = false
    var transparent = text(); transparent.fillOpacity = 0
    var emptyStack = text(); emptyStack.paintStack = []
    var disabledLayer = text(); var layer = ArtworkPaintLayer(.init(color: "#000000")); layer.enabled = false
    disabledLayer.paintStack = [layer]
    var transparentStroke = text(); transparentStroke.fillEnabled = false
    var stroke = ArtworkStroke(color: "#000000", width: 0.5); stroke.opacity = 0
    transparentStroke.paintStack = [.init(.init(color: "#000000"), stroke: stroke)]
    var coveredBase = text()
    coveredBase.textRuns = [.init(location: 0, length: coveredBase.text.utf16.count,
      typography: coveredBase.typography!, fontSize: coveredBase.fontSize, color: coveredBase.color)]
    coveredBase.textRuns![0].paintStack = []
    var noPaintMask = text(); noPaintMask.hidden = true; noPaintMask.paintStack = []
    var clipped = ArtworkElement(kind: "rectangle", x: 10, y: 10, width: 70, height: 20)
    clipped.clipID = noPaintMask.id; clipped.clipMode = "alpha"
    var outlined = text(); outlined.fillEnabled = false
    outlined.paintStack = [.init(.init(color: "#000000"), stroke: .init(color: "#000000", width: 0.5))]
    var runPaint = text(); runPaint.fillEnabled = false; runPaint.paintStack = []
    runPaint.textRuns = [.init(location: 0, length: 1, typography: runPaint.typography!, fontSize: runPaint.fontSize, color: "#000000")]
    runPaint.textRuns![0].paintStack = [.init(.init(color: "#000000"))]
    var shadowStroke = outlined; shadowStroke.id = UUID()
    var shadow = ArtworkShadow(); shadow.enabled = true; shadowStroke.shadow = shadow
    let excluded = [disabled, transparent, emptyStack, disabledLayer, transparentStroke, coveredBase, noPaintMask]
    let included = [outlined, runPaint, shadowStroke]
    let (project, id) = try fixture(excluded + included + [clipped])
    let before = project, report = PublicationOutput.preflight(project, documentID: id)
    XCTAssertEqual(Set(issues(report).compactMap { $0["element_id"] as? String }), Set(included.map { $0.id.uuidString }))
    for element in excluded {
      let row = try XCTUnwrap(frames(report).first { $0["element_id"] as? String == element.id.uuidString })
      XCTAssertEqual(row["status"] as? String, "excluded")
      XCTAssertEqual(row["layout_status"] as? String, "overset")
      XCTAssertFalse(TextPaintRenderer.hasEnabledPaint(element))
    }
    for element in included { XCTAssertTrue(TextPaintRenderer.hasEnabledPaint(element)) }
    XCTAssertEqual(project, before)
  }

  func testRetainedStoryWithoutAnyFrameStillBlocksDefaultExport() throws {
    var (project, id) = try fixture([])
    let story = TextStory(source: text("Retained unplaced source"), publicationID: id)
    project.textStories = [story]
    let report = PublicationOutput.preflight(project, documentID: id)
    XCTAssertEqual(report["can_export"] as? Bool, false)
    XCTAssertEqual(issues(report).first?["story_id"] as? String, story.id.uuidString)
    XCTAssertTrue(frames(report).isEmpty)
    XCTAssertThrowsError(try PublicationOutput.pdf(project, documentID: id, assets: assets))
  }
}
