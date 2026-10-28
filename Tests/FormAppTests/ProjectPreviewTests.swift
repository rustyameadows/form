import AppKit
import FormCore
import XCTest
@testable import FormApp

@MainActor final class ProjectPreviewTests:XCTestCase {
  func testPublicationThumbnailUsesOrderedCoverRatherThanPhysicalObjectOrder() throws {
    var project = Project(name: "Ordered booklet")
    var blue = try project.makeObject(recipeID: "artboard"), red = try project.makeObject(recipeID: "artboard")
    blue.artwork = Artwork(background: "#2266CC"); red.artwork = Artwork(background: "#D4492E")
    project.objects = [blue, red]
    project.publications = [.init(name: "Booklet", pages: [.init(objectID: red.id), .init(objectID: blue.id)])]
    let before = project
    func center(_ project: Project) throws -> NSColor {
      let image = ProjectPreview.image(project: project, size: .init(width: 1000, height: 650), assets: FileManager.default.temporaryDirectory)
      let cg = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
      XCTAssertEqual(cg.width, 1000); XCTAssertEqual(cg.height, 650)
      let bitmap = NSBitmapImageRep(cgImage: cg)
      let edge = try XCTUnwrap(bitmap.colorAt(x: 5, y: 5)?.usingColorSpace(.sRGB))
      XCTAssertGreaterThan(edge.greenComponent, 0.8)
      return try XCTUnwrap(bitmap.colorAt(x: 500, y: 325)?.usingColorSpace(.sRGB))
    }
    let redCover = try center(project)
    XCTAssertGreaterThan(redCover.redComponent, redCover.blueComponent * 2)
    XCTAssertEqual(project, before)
    project.publications![0].pages.reverse()
    let blueCover = try center(project)
    XCTAssertGreaterThan(blueCover.blueComponent, blueCover.redComponent * 2)
  }
  func testNegativeCoordinateCanvasThumbnailContainsArtworkAndPreservesTheProject() throws {
    var project = Project(name:"Loose artwork")
    _ = try project.ensureCanvasWorkspace()
    project.objects[0].artwork!.elements = [ArtworkElement(kind:"rectangle",x:-250,y:-150,
      width:100,height:60,color:"#D4492E")]
    let before = project
    let image = ProjectPreview.image(project:project,size:.init(width:1000,height:650),
      assets:FileManager.default.temporaryDirectory)
    let cg = try XCTUnwrap(image.cgImage(forProposedRect:nil,context:nil,hints:nil))
    XCTAssertEqual(cg.width,1000); XCTAssertEqual(cg.height,650)
    let pixels = NSBitmapImageRep(cgImage:cg)
    let center = try XCTUnwrap(pixels.colorAt(x:500,y:325)?.usingColorSpace(.deviceRGB))
    let edge = try XCTUnwrap(pixels.colorAt(x:5,y:5)?.usingColorSpace(.deviceRGB))
    XCTAssertGreaterThan(center.redComponent,center.greenComponent*2)
    XCTAssertGreaterThan(edge.greenComponent,0.8)
    XCTAssertEqual(project,before)
    if let path = ProcessInfo.processInfo.environment["FORM_CANVAS_PREVIEW_PROOF"] {
      try image.pngData()?.write(to:URL(fileURLWithPath:path))
    }
  }

  func testEmptyCanvasHasABoundedOpaquePreviewAtTheRequestedAspect() throws {
    var project = Project(name:"Blank Canvas"); _ = try project.ensureCanvasWorkspace()
    let image = ProjectPreview.image(project:project,size:.init(width:1000,height:650),
      assets:FileManager.default.temporaryDirectory)
    let cg = try XCTUnwrap(image.cgImage(forProposedRect:nil,context:nil,hints:nil))
    XCTAssertEqual(cg.width,1000); XCTAssertEqual(cg.height,650)
    let pixel = try XCTUnwrap(NSBitmapImageRep(cgImage:cg).colorAt(x:500,y:325))
    XCTAssertEqual(pixel.alphaComponent,1,accuracy:0.001)
  }
}
