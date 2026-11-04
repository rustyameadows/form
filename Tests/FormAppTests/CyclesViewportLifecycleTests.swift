import AppKit
import FormCore
import XCTest
@testable import FormApp

@MainActor final class CyclesViewportLifecycleTests:XCTestCase {
  private func fixture()->(TableSceneController,NSWindow,NSView) {
    _ = NSApplication.shared
    let controller=TableSceneController(),project=Project(name:"Viewport lifecycle")
    controller.sync(project,selection:[],isolated:[],showGrid:false,studio:true,preset:"Daylight",assets:FileManager.default.temporaryDirectory)
    var settings=CyclesRenderSettings();settings.renderer = .realtime;controller.cyclesSettingsOverride=settings
    let container=NSView(frame:.init(x:0,y:0,width:320,height:240))
    let window=NSWindow(contentRect:.init(x:-10000,y:-10000,width:320,height:240),styleMask:[.titled],backing:.buffered,defer:false)
    window.isReleasedWhenClosed=false;window.contentView=container;window.orderBack(nil)
    addTeardownBlock { @MainActor in controller.cyclesPreview.suspend();window.contentView=nil;window.close() }
    return(controller,window,container)
  }
  private func mount(_ controller:TableSceneController,in container:NSView)->TableSceneView {
    let view=TableSceneView(frame:container.bounds);view.controller=controller;controller.view=view;container.addSubview(view)
    return view
  }
  private func enable(_ controller:TableSceneController) {
    var settings=CyclesRenderSettings();settings.renderer = .cycles;controller.cyclesSettingsOverride=settings
    controller.cyclesPreview.sceneChanged();XCTAssertEqual(controller.cyclesPreview.phase,"Preparing")
  }
  private func settleVisibility() {RunLoop.main.run(until:Date(timeIntervalSinceNow:0.025))}
  func testStatusUsesRequestedTotalDuringSamplingAndActualAdaptiveCountOnCompletion() {
    XCTAssertEqual(CyclesViewportController.statusText(phase:"Rendering / Path Tracing Sample 32/256",sample:32,totalSamples:256),"Rendering · 32/256")
    XCTAssertEqual(CyclesViewportController.statusText(phase:"denoising",sample:64,totalSamples:256),"Denoising · 64/256")
    XCTAssertEqual(CyclesViewportController.statusText(phase:"Complete",sample:64,totalSamples:256),"Complete · 64")
    XCTAssertEqual(CyclesViewportController.statusText(phase:"Preparing CPU after Metal initialization failure",sample:0,totalSamples:256),"Preparing · 0/256")
  }
  func testRetiredViewportDetachDoesNotPauseItsMountedReplacement() {
    let (controller,_,container)=fixture(),old=mount(controller,in:container)
    let current=mount(controller,in:container);enable(controller)
    old.removeFromSuperview()
    XCTAssertTrue(controller.view === current);XCTAssertEqual(controller.cyclesPreview.phase,"Preparing")
    // An outgoing SwiftUI workspace reconciles the current source rather than
    // unconditionally suspending whichever viewport now owns the controller.
    controller.cyclesPreview.sceneChanged();XCTAssertEqual(controller.cyclesPreview.phase,"Preparing")
    controller.cyclesPreview.suspend()
  }
  func testCurrentViewportUnhideAndReattachRestartWithoutChangingExplicitPause() {
    let (controller,_,container)=fixture(),view=mount(controller,in:container);enable(controller)
    container.isHidden=true;XCTAssertEqual(controller.cyclesPreview.phase,"Paused")
    container.isHidden=false;settleVisibility();XCTAssertEqual(controller.cyclesPreview.phase,"Preparing")
    view.removeFromSuperview();XCTAssertEqual(controller.cyclesPreview.phase,"Paused")
    container.addSubview(view);settleVisibility();XCTAssertEqual(controller.cyclesPreview.phase,"Preparing")
    controller.cyclesPreview.pause();container.isHidden=true;container.isHidden=false;settleVisibility()
    XCTAssertTrue(controller.cyclesPreview.isPaused);XCTAssertEqual(controller.cyclesPreview.phase,"Paused")
    view.removeFromSuperview();container.addSubview(view);settleVisibility()
    XCTAssertTrue(controller.cyclesPreview.isPaused);XCTAssertEqual(controller.cyclesPreview.phase,"Paused")
    controller.cyclesPreview.suspend()
  }
}
