import AppKit
import FormCADModel
import FormCore
import XCTest
@testable import FormApp

@MainActor final class CanvasPaperFaceAppearanceTests: XCTestCase {
  private func bitmap(_ image: NSImage) throws -> NSBitmapImageRep {
    NSBitmapImageRep(cgImage: try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil)))
  }
  private func assertColor(_ bitmap: NSBitmapImageRep, hex: String, predominantly: Bool = true,
    file: StaticString = #filePath, line: UInt = #line) throws {
    // AppKit's colorAt/deviceRGB roundtrip depends on the display profile and
    // HDR working space. Normalize the actual tagged pixels once to sRGB; the
    // expected color is independent of either production color helper.
    let value = try XCTUnwrap(UInt32(hex.dropFirst(), radix: 16))
    let expected = NSColor(srgbRed: Double((value >> 16) & 255) / 255,
      green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255, alpha: 1)
    let image = try XCTUnwrap(bitmap.cgImage), width = image.width, height = image.height
    let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
      bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.draw(image, in: .init(x: 0, y: 0, width: width, height: height))
    let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
    func color(_ x: Int, _ y: Int) -> [Double] {
      let index = (y * width + x) * 4
      return (0..<3).map { Double(bytes[index + $0]) / 255 }
    }
    func matches(_ actual: [Double]) -> Bool {
      abs(actual[0] - expected.redComponent) < 0.025
        && abs(actual[1] - expected.greenComponent) < 0.025
        && abs(actual[2] - expected.blueComponent) < 0.025
    }
    let center = color(width / 2, height / 2)
    if !predominantly {
      XCTAssertTrue(matches(center), "Expected sRGB \(hex), got \(center)", file: file, line: line)
      return
    }
    var total = 0, matching = 0
    for y in stride(from: height / 10, to: height * 9 / 10, by: 2) {
      for x in stride(from: width / 10, to: width * 9 / 10, by: 2) {
        total += 1; if matches(color(x, y)) { matching += 1 }
      }
    }
    XCTAssertGreaterThan(total, 100, file: file, line: line)
    XCTAssertGreaterThan(Double(matching) / Double(max(1, total)), 0.7,
      "Actual Canvas substrate must show sRGB \(hex), including the Bottom face; center=\(center).", file: file, line: line)
  }

  func testBothCanvasFacesAndProofsMatchPhysicalPlyProfileAndTintWithoutMutatingArtwork() throws {
    _ = NSApplication.shared
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("canvas-paper-color-" + UUID().uuidString)
    let store = StudioStore(repository: try ProjectRepository(root: directory), seedLibrary: false)
    var project = Project(name: "Forest duplex face color")
    let source = PlanarConstructionDefinition(name: "Duplex window card", size: .init(40, 25), stockThickness: 0.4,
      panels: [.init(id: "sheet", name: "Sheet", polygon: [.init(0, 0), .init(40, 0), .init(40, 25), .init(0, 25)],
        cutouts: [.init(id: "window", polygon: [.init(28, 3), .init(33, 3), .init(33, 8), .init(28, 8)], kind: .window)])], rootPanelID: "sheet")
    project.recipes.append(.init("face-color-source", source.name, "square", "Generic authored card", [
      .init("fold", "Fold", 100, 0...100), .init("opening", "Opening", 0, 0...100)]))
    var object = try project.makeObject(recipeID: "face-color-source")
    var outside = Artwork(background: "#FFFFFF", bleed: 0); outside.backgroundOpacity = 0; outside.showGuides = false
    var inside = outside
    inside.elements = [.init(kind: "rectangle", x: 4, y: 4, width: 7, height: 4, color: "#F3E9CF")]
    var paper = PaperConstruction(kind: .authored, dimensions: .init(width: 40, height: 25, depth: 0.4), stock: .init(thicknessMM: 0.4))
    paper.authored = source; paper.insideArtwork = inside
    paper.stock.profile = .init(texture: .smooth, color: "#FFFFFF", textureDepthMM: 0)
    paper.stock.plies = [.init(name: "Forest back", color: "#173E32", thicknessMM: 0.2),
      .init(name: "Cream front", color: "#F1E5C8", thicknessMM: 0.2)]
    object.paperConstruction = paper; object.artwork = outside; object.color = nil
    project.objects = [object]; project.schemaVersion = project.minimumSchemaVersion
    store.engine.project = project; store.showingHome = false; store.mode = .artwork; store.paperShowingGuides = false
    let session = store.artworkSession; session.activate(object.id)
    let window = NSWindow(contentRect: .init(x: -10000, y: -10000, width: 1000, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let scroll = ArtworkScrollView(frame: window.contentView!.bounds), canvas = VectorCanvasView(frame: .zero)
    scroll.allowsMagnification = true; scroll.minMagnification = 0.08; scroll.maxMagnification = 24
    canvas.session = session; session.canvas = canvas; scroll.documentView = canvas; window.contentView = scroll
    defer { window.contentView = nil; window.close(); store.engine.project = nil; try? FileManager.default.removeItem(at: directory) }
    canvas.synchronize(); canvas.fit(all: true); canvas.setZoom(1)

    func check(_ value: Project, outsideColor: String, insideColor: String) throws {
      store.engine.project = value; canvas.synchronize()
      let before = try XCTUnwrap(store.project), history = store.engine.undoStack.count
      let frames = session.frames.filter { $0.projection?.constructionID == object.id }
      XCTAssertEqual(frames.count, 4)
      for frame in frames {
        let a = canvas.documentPoint(frame.rect.origin), b = canvas.documentPoint(.init(x: frame.rect.maxX, y: frame.rect.maxY))
        let rect = CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y)
        let image = try XCTUnwrap(canvas.bitmapImageRepForCachingDisplay(in: rect))
        canvas.cacheDisplay(in: rect, to: image)
        try assertColor(image, hex: frame.projection?.inside == true ? insideColor : outsideColor)
      }
      // The actual 3D face maps use the same precedence, with a deliberately
      // small texture budget; this test does not rebuild archival viewing maps.
      let root = try PaperGeometry.make(before.objects[0], project: before, assets: directory, limit: 128)
      let mesh = try XCTUnwrap(root.childNode(withName: PaperGeometry.panelPrefix + "sheet", recursively: true)?.geometry)
      try assertColor(bitmap(try XCTUnwrap(mesh.materials[0].diffuse.contents as? NSImage)), hex: outsideColor, predominantly: false)
      try assertColor(bitmap(try XCTUnwrap(mesh.materials[1].diffuse.contents as? NSImage)), hex: insideColor, predominantly: false)
      XCTAssertEqual(store.project, before); XCTAssertEqual(store.engine.undoStack.count, history)
    }
    try check(project, outsideColor: "#F1E5C8", insideColor: "#173E32")
    var profile = project
    profile.objects[0].paperConstruction!.stock.plies![0].profile = .init(texture: .smooth, color: "#24493A", textureDepthMM: 0)
    try check(profile, outsideColor: "#F1E5C8", insideColor: "#24493A")
    var tinted = profile; tinted.objects[0].color = "#526DA1"
    try check(tinted, outsideColor: "#526DA1", insideColor: "#526DA1")
    var single = project; single.objects[0].paperConstruction!.stock.plies = nil
    single.objects[0].paperConstruction!.stock.profile!.color = "#AB8E69"
    try check(single, outsideColor: "#AB8E69", insideColor: "#AB8E69")
    var printed = project
    printed.objects[0].artwork!.background = "#C84E35"; printed.objects[0].artwork!.backgroundOpacity = 1
    printed.objects[0].paperConstruction!.insideArtwork!.background = "#356FA2"
    printed.objects[0].paperConstruction!.insideArtwork!.backgroundOpacity = 1
    try check(printed, outsideColor: "#C84E35", insideColor: "#356FA2")
  }
}
