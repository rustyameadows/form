import AppKit
import FormCore
import SwiftUI
import XCTest
@testable import FormApp

@MainActor final class CanvasFloatingWorkspaceTests:XCTestCase {
  private func verify(width:CGFloat,worstCase:Bool=false)async throws {
    _=NSApplication.shared
    let directory=FileManager.default.temporaryDirectory.appendingPathComponent("floating-canvas-"+UUID().uuidString)
    let repository=try ProjectRepository(root:directory)
    var project=Project(name:"Floating Canvas hit regions")
    let source=try project.ensureCanvasWorkspace()
    let store=StudioStore(repository:repository,seedLibrary:false)
    store.engine.project=project;store.showingHome=false;store.environment = .form;store.mode = .artwork
    store.surfaceLayout=width<900 ? .split:.single
    let session=store.artworkSession;session.activate(source.id)
    let before=try XCTUnwrap(store.project),history=store.engine.undoStack.count
    let window=NSWindow(contentRect:.init(x:-10000,y:-10000,width:width,height:700),styleMask:[.titled,.closable],backing:.buffered,defer:false)
    window.isReleasedWhenClosed=false
    let host=NSHostingView(rootView:ArtworkStudio(session:session).environmentObject(store).preferredColorScheme(.light))
    window.contentView=host;window.orderBack(nil)
    defer{window.contentView=nil;window.close();store.engine.project=nil;try? FileManager.default.removeItem(at:directory)}
    for _ in 0..<200 {
      host.layoutSubtreeIfNeeded()
      if let scroll=session.canvas?.enclosingScrollView,abs(scroll.bounds.width-width)<0.5,abs(scroll.bounds.height-700)<0.5{break}
      try await Task.sleep(nanoseconds:10_000_000)
    }
    if worstCase {
      session.tool = .eyedropper;session.setZoom(24)
      try await Task.sleep(nanoseconds:100_000_000);host.layoutSubtreeIfNeeded()
    }
    let canvas=try XCTUnwrap(session.canvas),scroll=try XCTUnwrap(canvas.enclosingScrollView)
    XCTAssertTrue(canvas.session === session)
    let frame=host.convert(scroll.bounds,from:scroll)
    XCTAssertEqual(frame.minX,host.bounds.minX,accuracy:0.5);XCTAssertEqual(frame.minY,host.bounds.minY,accuracy:0.5)
    XCTAssertEqual(frame.width,host.bounds.width,accuracy:0.5);XCTAssertEqual(frame.height,host.bounds.height,accuracy:0.5)
    XCTAssertFalse(scroll.rulersVisible);XCTAssertFalse(scroll.hasHorizontalRuler);XCTAssertFalse(scroll.hasVerticalRuler)
    // Full and split canvases retain the same open cards at every width.
    // These are the actual transient occlusions consumed by the native view.
    XCTAssertEqual(canvas.fittingInsets.left,266);XCTAssertEqual(canvas.fittingInsets.right,318)
    XCTAssertEqual(canvas.fittingInsets.top,16);XCTAssertEqual(canvas.fittingInsets.bottom,72)
    let clip=scroll.convert(scroll.contentView.bounds,from:scroll.contentView)
    XCTAssertEqual(clip.width,scroll.bounds.width,accuracy:0.5);XCTAssertEqual(clip.height,scroll.bounds.height,accuracy:0.5)
    // Window coordinates have their origin at the lower left. At700pt high the
    // left card ends above204pt, the right above100pt, and tools end below64pt.
    // These points therefore exercise actual empty overlay space, not cards.
    var points=[CGPoint(x:100,y:80),CGPoint(x:width-100,y:80)]
    // At narrow widths the same cards can cover the center; it is no longer
    // blank Canvas space and must not be treated as a pass-through region.
    if width>=900 {points.append(CGPoint(x:width/2,y:350))}
    for point in points {
      let parentPoint=host.superview?.convert(point,from:nil) ?? point
      let hit=host.hitTest(parentPoint)
      XCTAssertTrue(hit === canvas || hit?.isDescendant(of:canvas)==true,"Floating overlay whitespace at \(point) must reach the native Canvas, got \(String(describing:hit)).")
    }
    XCTAssertEqual(store.project,before);XCTAssertEqual(store.engine.undoStack.count,history)
  }
  func testFullWidthFloatingCardsLeaveNativeCanvasWhitespaceInteractive()async throws {try await verify(width:1020)}
  func testNarrowCanvasesRetainTheSamePanelsAndInteractiveWhitespace()async throws {
    try await verify(width:640)
    try await verify(width:440,worstCase:true)
  }
}
