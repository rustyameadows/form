import AppKit
import FormCore
import SwiftUI
import XCTest
@testable import FormApp

@MainActor final class ProjectLibraryWorkspaceTests:XCTestCase {
  private func descendants(_ root:NSView)->[NSView] {[root]+root.subviews.flatMap(descendants)}
  private func topRect(_ view:NSView,in host:NSView)->CGRect {
    let frame=view.convert(view.bounds,to:host)
    return host.isFlipped ? frame:.init(x:frame.minX,y:host.bounds.height-frame.maxY,width:frame.width,height:frame.height)
  }
  private func luminance(_ image:NSBitmapImageRep,x:Int,y:Int)->Double {
    guard let color=image.colorAt(x:x,y:y)?.usingColorSpace(.sRGB) else{return 1}
    return 0.2126*color.redComponent+0.7152*color.greenComponent+0.0722*color.blueComponent
  }
  private func snapshot(_ host:NSView)throws->NSBitmapImageRep {
    let image=try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in:host.bounds))
    host.cacheDisplay(in:host.bounds,to:image)
    return image
  }
  private func headerRule(_ image:NSBitmapImageRep,host:NSView,near expected:CGFloat)->Double? {
    let scale=Double(image.pixelsHigh)/host.bounds.height
    var candidates=[Double]()
    // Native bitmap row order differs between cache targets. Search both ends;
    // select the long separator adjacent to the measured header controls.
    for distance in 1...Int(60*scale) {
      for y in [distance,image.pixelsHigh-1-distance] where y>=0 && y<image.pixelsHigh {
        let background=luminance(image,x:2,y:max(0,min(image.pixelsHigh-1,y>image.pixelsHigh/2 ? image.pixelsHigh-3:2)))
        let dark=(1..<80).filter {column in
          let x=Int(Double(image.pixelsWide-4)*Double(column)/80)+2
          return background-luminance(image,x:x,y:y)>0.035
        }.count
        if dark>=65 {candidates.append(Double(distance)/scale)}
      }
    }
    return candidates.min{abs($0-Double(expected))<abs($1-Double(expected))}
  }

  func testCompactHeaderRemainsOneRowAndEmptyStateIsVisibleAt880And1120Points()async throws {
    _ = NSApplication.shared
    let directory=FileManager.default.temporaryDirectory.appendingPathComponent("project-library-header-"+UUID().uuidString)
    try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
    defer{try? FileManager.default.removeItem(at:directory)}
    let owner=UUID(),library=StudioAssetLibrary(root:directory,projectID:owner)
    var closed=0
    for width in [CGFloat(880),1120] {
      let host=NSHostingView(rootView:AssetLibraryWorkspace(library:library,projectName:"Empty project",onClose:{closed+=1}).labInterface())
      let window=NSWindow(contentRect:.init(x:-10000,y:-10000,width:width,height:580),styleMask:[.titled,.resizable],backing:.buffered,defer:false)
      window.isReleasedWhenClosed=false;window.contentView=host;window.makeKeyAndOrderFront(nil)
      defer{window.makeFirstResponder(nil);window.contentView=nil;window.close()}
      host.layoutSubtreeIfNeeded();try await Task.sleep(nanoseconds:120_000_000);host.layoutSubtreeIfNeeded();host.displayIfNeeded()
      XCTAssertEqual(library.projectID,owner);XCTAssertFalse(library.isLoading);XCTAssertTrue(library.visibleItems.isEmpty)
      let views=descendants(host)
      let importButton=try XCTUnwrap(views.compactMap{$0 as? WorkspaceToolbarNativeButton}.first{$0.accessibilityIdentifier()=="project-library-import"})
      let search=try XCTUnwrap(views.compactMap{$0 as? NSTextField}.first{$0.placeholderString=="Search assets"})
      let close=try XCTUnwrap(views.compactMap{$0 as? AppCloseNativeButton}.first{$0.accessibilityLabel()=="Close Asset Library"})
      let importFrame=topRect(importButton,in:host),searchFrame=topRect(search,in:host),closeFrame=topRect(close,in:host)
      XCTAssertEqual(importButton.bounds.size,.init(width:32,height:32))
      XCTAssertLessThanOrEqual(importFrame.minY,8);XCTAssertLessThanOrEqual(importFrame.maxY,44.5)
      XCTAssertEqual(importFrame.midY,searchFrame.midY,accuracy:1.5)
      XCTAssertEqual(importFrame.midY,closeFrame.midY,accuracy:1.5)
      XCTAssertLessThan(searchFrame.maxX,importFrame.minX)
      XCTAssertFalse(searchFrame.intersects(closeFrame));XCTAssertFalse(importFrame.intersects(closeFrame))
      let popupTitles=views.compactMap{$0 as? NSPopUpButton}.filter{!$0.isHiddenOrHasHiddenAncestor && $0.bounds.height>1}.flatMap(\.itemTitles)
      XCTAssertFalse(popupTitles.contains("All projects"));XCTAssertFalse(popupTitles.contains("All assets"));XCTAssertFalse(popupTitles.contains("All types"),"Filters belong in the compact menu, not extra visible rows")
      let image=try snapshot(host),rule=try XCTUnwrap(headerRule(image,host:host,near:importFrame.maxY+6),"The header must end with a real full-width separator")
      XCTAssertGreaterThanOrEqual(rule,40);XCTAssertLessThanOrEqual(rule,50,"Compact Library header must remain at most 50pt at both widths")
      let sx=Double(image.pixelsWide)/host.bounds.width,sy=Double(image.pixelsHigh)/host.bounds.height
      var emptyInk=0
      for y in stride(from:Int((host.bounds.midY-100)*sy),through:Int((host.bounds.midY+100)*sy),by:3) {
        for x in stride(from:Int((host.bounds.midX-250)*sx),through:Int((host.bounds.midX+250)*sx),by:3) {
          if luminance(image,x:x,y:y)<0.6 {emptyInk+=1}
        }
      }
      XCTAssertGreaterThan(emptyInk,60,"The empty-state heading, icon and guidance must actually draw in the visible body")
      XCTAssertTrue(close.accessibilityPerformPress());XCTAssertEqual(closed,width==880 ? 1:2)
    }
  }
}
