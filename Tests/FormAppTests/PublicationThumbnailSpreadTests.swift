import AppKit
import SwiftUI
import XCTest
@testable import FormApp
@testable import FormCore

@MainActor final class PublicationThumbnailSpreadTests:XCTestCase {
  private func asymmetricPNG()throws->Data {
    let space=try XCTUnwrap(CGColorSpace(name:CGColorSpace.sRGB))
    let context=try XCTUnwrap(CGContext(data:nil,width:120,height:80,bitsPerComponent:8,bytesPerRow:0,
      space:space,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(try XCTUnwrap(CGColor(colorSpace:space,components:[1,0,0,1])));context.fill(.init(x:0,y:0,width:60,height:80))
    context.setFillColor(try XCTUnwrap(CGColor(colorSpace:space,components:[0,0,1,1])));context.fill(.init(x:60,y:0,width:60,height:80))
    let bitmap=NSBitmapImageRep(cgImage:try XCTUnwrap(context.makeImage()))
    let data=try XCTUnwrap(bitmap.representation(using:.png,properties:[:])),decoded=try XCTUnwrap(NSBitmapImageRep(data:data))
    let red=try XCTUnwrap(decoded.colorAt(x:15,y:40)?.usingColorSpace(.sRGB)),blue=try XCTUnwrap(decoded.colorAt(x:90,y:40)?.usingColorSpace(.sRGB))
    XCTAssertGreaterThan(red.redComponent,red.blueComponent+0.8);XCTAssertGreaterThan(blue.blueComponent,blue.redComponent+0.8)
    return data
  }
  private func bluePixels(_ image:NSImage)throws->Int {
    let pixels=NSBitmapImageRep(cgImage:try XCTUnwrap(image.cgImage(forProposedRect:nil,context:nil,hints:nil)))
    var count=0
    for y in stride(from:0,to:pixels.pixelsHigh,by:2) {
      for x in stride(from:0,to:pixels.pixelsWide,by:2) {
        let color=try XCTUnwrap(pixels.colorAt(x:x,y:y)?.usingColorSpace(.sRGB))
        if color.alphaComponent>0.9,color.blueComponent>0.7,color.redComponent<0.2,color.greenComponent<0.2 {count+=1}
      }
    }
    return count
  }
  func testMountedRightPageThumbnailIncludesCanonicalNeighborCropAndTracksMoveResizeUndoWithoutSourceCopies()throws {
    _=NSApplication.shared
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("publication-thumbnail-spread-"+UUID().uuidString)
    let store=StudioStore(repository:try ProjectRepository(root:root),seedLibrary:false)
    store.fontLibraryPreferences = .init(file:root.appendingPathComponent("Fonts.json"))
    var project=Project(name:"One asymmetric source across a reader gutter")
    for index in 0..<3 {
      var page=try project.makeObject(recipeID:"artboard",name:"Physical page \(index+1)",parameters:["width":100,"depth":140])
      page.artwork = .init(background:"#FFFFFF",elements:[],bleed:0);page.artwork?.canvasPosition = .init(Double(index)*136+36,40)
      project.objects.append(page)
    }
    let pages=project.objects.map(\.id)
    let publication=try PublicationCommands.createPublication(in:&project,name:"Reader crop thumbnails",pages:pages)
    var document=try XCTUnwrap(project.publications?.first);document.layout = .init(facingPages:true)
    try PublicationCommands.setPublication(in:&project,document:document)
    let image=ArtworkElement(kind:"image",x:70,y:20,width:60,height:40,asset:"asymmetric.png")
    project.objects[1].artwork!.elements=[image]
    try store.repository.save(project)
    let assets=store.repository.url(for:project.id).appendingPathComponent("Assets")
    try FileManager.default.createDirectory(at:assets,withIntermediateDirectories:true)
    try asymmetricPNG().write(to:assets.appendingPathComponent("asymmetric.png"))
    try store.engine.open(project.id);store.showingHome=false
    let session=store.artworkSession,controller=session.publicationWorkspace;controller.open(publication)
    let before=try XCTUnwrap(store.project),undo=store.engine.undoStack.count
    let window=NSWindow(contentRect:.init(x:-10000,y:-10000,width:260,height:650),styleMask:[.titled],backing:.buffered,defer:false);window.isReleasedWhenClosed=false
    let host=NSHostingView(rootView:PublicationNavigator(session:session,controller:controller,maxHeight:630).environmentObject(store))
    host.sizingOptions=[];window.contentView=host;host.frame=window.contentView!.bounds
    defer{window.contentView=nil;window.close();session.canvas?.finishText();store.engine.project=nil;try? FileManager.default.removeItem(at:root)}
    func descendants(_ view:NSView)->[NSView]{[view]+view.subviews.flatMap(descendants)}
    func thumbnail()throws->NSImage {
      host.layoutSubtreeIfNeeded();RunLoop.main.run(until:Date().addingTimeInterval(0.04));host.layoutSubtreeIfNeeded()
      let button=try XCTUnwrap(descendants(host).compactMap{$0 as? PublicationPageNativeButton}.first{$0.accessibilityIdentifier()=="publication-page-"+pages[2].uuidString})
      return try XCTUnwrap(button.thumbnail)
    }
    // This is the actual image supplied to the mounted native right-page tile,
    // not a direct resolver test that could miss the navigator's source choice.
    let original=try thumbnail(),initialBlue=try bluePixels(original)
    XCTAssertGreaterThan(initialBlue,100,"The right thumbnail must show the blue half owned only by its left neighbor")
    XCTAssertEqual(store.project,before);XCTAssertEqual(store.engine.undoStack.count,undo)
    XCTAssertTrue(try XCTUnwrap(store.project?.objects.first{$0.id==pages[2]}?.artwork).elements.isEmpty)
    try store.engine.edit("Moved the one cross-gutter source") {value in
      let owner=try XCTUnwrap(value.objects.firstIndex{$0.id==pages[1]});value.objects[owner].artwork!.elements[0].x=50
    }
    store.changed();let moved=try XCTUnwrap(store.project),movedImage=try thumbnail(),movedBlue=try bluePixels(movedImage)
    XCTAssertFalse(original === movedImage);XCTAssertGreaterThan(movedBlue,20)
    XCTAssertLessThan(Double(movedBlue),Double(initialBlue)*0.55,"Moving the owner left reduces the real neighboring crop from30mm to10mm")
    try store.engine.edit("Resized the same canonical source") {value in
      let owner=try XCTUnwrap(value.objects.firstIndex{$0.id==pages[1]});value.objects[owner].artwork!.elements[0].width=100
    }
    store.changed();let resized=try XCTUnwrap(store.project),resizedBlue=try bluePixels(thumbnail())
    XCTAssertGreaterThan(Double(resizedBlue),Double(movedBlue)*3,"Resizing the source must update the unchanged neighbor thumbnail")
    XCTAssertEqual(store.engine.undoStack.count,undo+2)
    XCTAssertEqual(resized.objects.first{$0.id==pages[2]},before.objects.first{$0.id==pages[2]})
    XCTAssertEqual(resized.objects.flatMap{$0.artwork?.elements ?? []}.filter{$0.kind=="image"}.map(\.id),[image.id])
    store.engine.undo();store.changed();XCTAssertEqual(store.project,moved)
    XCTAssertEqual(try bluePixels(thumbnail()),movedBlue)
    store.engine.undo();store.changed();XCTAssertEqual(store.project,before)
    let restored=try thumbnail();XCTAssertTrue(restored === original,"Exact Undo may reuse the previous composed-source preview")
    XCTAssertEqual(try bluePixels(restored),initialBlue)
    try store.engine.flush();let reopened=try store.repository.load(before.id)
    XCTAssertEqual(reopened.objects,before.objects);XCTAssertEqual(reopened.publications,before.publications)
  }
}
