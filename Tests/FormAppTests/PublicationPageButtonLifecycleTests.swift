import AppKit
import CoreText
import SwiftUI
import XCTest
@testable import FormApp
@testable import FormCore
@testable import FormGraphics

@MainActor final class PublicationPageButtonLifecycleTests:XCTestCase {
  func testRetainedSFFolioFontsAndRawCoreTextColorsTruncateWithoutAppKitParagraphAttributes()throws {
    _=NSApplication.shared
    for selected in [false,true] {
      let font=selected ? PublicationPageNativeButton.selectedLabelFont:PublicationPageNativeButton.regularLabelFont
      XCTAssertEqual(CTFontGetSize(font),10,accuracy:0.001)
      XCTAssertTrue(CTFontGetSymbolicTraits(font).contains(.traitMonoSpace))
      let color=NSColor.systemBlue.usingColorSpace(.sRGB)!.cgColor
      let line=try XCTUnwrap(PublicationPageNativeButton.labelLine("Inside front cover / 00052",selected:selected,width:72,color:color))
      XCTAssertLessThanOrEqual(CTLineGetTypographicBounds(line,nil,nil,nil),72.01)
      let runs=CTLineGetGlyphRuns(line) as! [CTRun]
      XCTAssertFalse(runs.isEmpty)
      for run in runs {
        let attributes=CTRunGetAttributes(run) as NSDictionary
        let storedFont=try XCTUnwrap(attributes[kCTFontAttributeName as String])
        let storedColor=try XCTUnwrap(attributes[kCTForegroundColorAttributeName as String])
        XCTAssertEqual(CFGetTypeID(storedFont as AnyObject),CTFontGetTypeID())
        XCTAssertEqual(CFGetTypeID(storedColor as AnyObject),CGColor.typeID)
        XCTAssertNil(attributes[NSAttributedString.Key.paragraphStyle.rawValue])
      }
    }
    XCTAssertNil(PublicationPageNativeButton.labelLine("1",selected:false,width:0,color:NSColor.black.cgColor))
    XCTAssertNil(PublicationPageNativeButton.labelLine("1",selected:false,width:.nan,color:NSColor.black.cgColor))
    XCTAssertNil(PublicationPageNativeButton.labelLine("",selected:false,width:72,color:NSColor.black.cgColor))
  }

  func testMountedNavigatorRedrawAfterNativeImageReplacementUndoRetainsSourceActionAndAccessibleButton()throws {
    _=NSApplication.shared
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("publication-button-lifecycle-"+UUID().uuidString)
    let store=StudioStore(repository:try ProjectRepository(root:root),seedLibrary:false)
    store.fontLibraryPreferences = .init(file:root.appendingPathComponent("Fonts.json"))
    let project=Project(name:"Native folio reuse")
    try store.repository.save(project);try store.engine.open(project.id);store.showingHome=false
    let controller=store.artworkSession.publicationWorkspace
    let publicationID=try XCTUnwrap(controller.create(name:"52-page native folio lifecycle",width:215.9,height:279.4,pageCount:52,facingPages:true,linkedBody:false))
    let page=try XCTUnwrap(store.project?.publications?.first{$0.id==publicationID}?.pages.first)
    func png(_ name:String,_ color:NSColor)throws->URL {
      let bitmap=try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:32,pixelsHigh:24,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0))
      for y in 0..<24 {for x in 0..<32 {bitmap.setColor(x<16 ? color:.white,atX:x,y:y)}}
      let url=root.appendingPathComponent(name+".png");try XCTUnwrap(bitmap.representation(using:.png,properties:[:])).write(to:url);return url
    }
    let original=try png("original",.systemBlue),replacement=try png("replacement",.systemOrange)
    let imported=try store.importImage(["object_id":page.objectID.uuidString,"path":original.path,"x":18,"y":24,"width":150,"height":100])
    let imageID=try XCTUnwrap((imported["selected_elements"] as? [String])?.first)
    store.changed();controller.open(publicationID);store.artworkSession.activate(page.objectID)
    let baseline=try XCTUnwrap(store.project),undoCount=store.engine.undoStack.count
    let window=NSWindow(contentRect:.init(x:-10000,y:-10000,width:260,height:580),styleMask:[.titled],backing:.buffered,defer:false)
    window.isReleasedWhenClosed=false
    let host=NSHostingView(rootView:PublicationNavigator(session:store.artworkSession,controller:controller,maxHeight:560).environmentObject(store))
    host.sizingOptions=[];window.contentView=host;host.frame=window.contentView!.bounds
    defer {
      window.contentView=nil;window.close();store.artworkSession.canvas?.finishText();store.engine.project=nil
      try? FileManager.default.removeItem(at:root)
    }
    func descendants(_ view:NSView)->[NSView]{[view]+view.subviews.flatMap(descendants)}
    func drawVisibleButtons()throws->PublicationPageNativeButton {
      host.layoutSubtreeIfNeeded();RunLoop.main.run(until:Date().addingTimeInterval(0.025))
      let buttons=descendants(host).compactMap{$0 as? PublicationPageNativeButton}
      XCTAssertFalse(buttons.isEmpty)
      for button in buttons where button.bounds.width>10 && button.bounds.height>22 {
        let rep=try XCTUnwrap(button.bitmapImageRepForCachingDisplay(in:button.bounds))
        for selected in [false,true,false] {button.selected=selected;button.needsDisplay=true;button.cacheDisplay(in:button.bounds,to:rep)}
        XCTAssertGreaterThan(rep.pixelsWide,0);XCTAssertGreaterThan(rep.pixelsHigh,0)
      }
      return try XCTUnwrap(buttons.first{$0.accessibilityIdentifier()=="publication-page-"+page.objectID.uuidString})
    }
    let first=try drawVisibleButtons()
    XCTAssertEqual(first.accessibilityRole(),.button);XCTAssertTrue(first.isEnabled)
    XCTAssertTrue(first.accessibilityPerformPress());XCTAssertEqual(controller.currentPageID,page.objectID)
    for _ in 0..<4 {
      _=try store.importImage(["object_id":page.objectID.uuidString,"element_id":imageID,"path":replacement.path])
      store.changed();_=try drawVisibleButtons()
      let edited=store.project;store.engine.undo();store.historyRecordsChanged(from:edited)
      XCTAssertEqual(store.project,baseline,"A redraw must not write or alter the restored canonical source")
      _=try drawVisibleButtons();XCTAssertEqual(store.engine.undoStack.count,undoCount)
    }
    let button=try drawVisibleButtons();XCTAssertTrue(button.accessibilityPerformPress())
    XCTAssertEqual(controller.currentPageID,page.objectID);XCTAssertEqual(store.project,baseline)
  }
}
