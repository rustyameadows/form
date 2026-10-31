import AppKit
import FormCore
import SwiftUI
import XCTest
@testable import FormApp

@MainActor final class StudioCompositionWorkspaceTests:XCTestCase {
  private struct Fixture {
    let store:StudioStore
    let controller:StudioCompositionController
    let first:StudioComposition
    let second:StudioComposition
    let window:NSWindow
    let host:NSView
  }
  private func fixture()throws->Fixture {
    _ = NSApplication.shared
    let directory=FileManager.default.temporaryDirectory.appendingPathComponent("studio-composition-ui-"+UUID().uuidString)
    let store=StudioStore(repository:try ProjectRepository(root:directory),seedLibrary:false)
    var project=Project(name:"Native composition controls")
    var source=try project.makeObject(recipeID:"box",name:"Carton source",parameters:["width":100,"height":80,"depth":60])
    source.color="#426DB2";project.objects=[source];project.camera.viewportAspect=1.5
    var first=StudioComposition(name:"Five identical cartons",camera:project.camera)
    first.camera.distance=4;first.camera.target = .init(0,0.4,0)
    first.instances=[.init(name:"Carton one",sourceObjectID:source.id)]
    var second=StudioComposition(name:"Turned design alternatives",camera:first.camera)
    second.instances=[.init(name:"Turned carton",sourceObjectID:source.id,rotationDegrees:30)]
    project.studioPresentation = .init();project.studioPresentation?.scenes=[first,second]
    project.schemaVersion=project.minimumSchemaVersion
    store.engine.project=project;store.showingHome=false;store.showEnvironment(.studio)
    let controller=store.studioComposition;controller.load(first.id)
    let host=NSHostingView(rootView:StudioCompositionWorkspace(controller:controller).environmentObject(store).labInterface())
    let window=NSWindow(contentRect:.init(x:-10000,y:-10000,width:1180,height:900),styleMask:[.titled],backing:.buffered,defer:false)
    window.isReleasedWhenClosed=false;window.contentView=host;window.makeKeyAndOrderFront(nil);settle(host)
    addTeardownBlock{@MainActor in
      controller.cancelSceneSelection();controller.reset();window.makeFirstResponder(nil);window.contentView=nil;window.close()
      controller.stage.view=nil;store.engine.project=nil;try? FileManager.default.removeItem(at:directory)
    }
    return .init(store:store,controller:controller,first:first,second:second,window:window,host:host)
  }
  private func descendants(_ root:NSView)->[NSView] {[root]+root.subviews.flatMap(descendants)}
  private func settle(_ host:NSView) {
    host.layoutSubtreeIfNeeded();RunLoop.main.run(until:Date().addingTimeInterval(0.04));host.layoutSubtreeIfNeeded()
  }
  private func toolbar(_ host:NSView,_ identifier:String)throws->WorkspaceToolbarNativeButton {
    try XCTUnwrap(descendants(host).compactMap{$0 as? WorkspaceToolbarNativeButton}.first{$0.accessibilityIdentifier()==identifier},"Missing Studio tool "+identifier)
  }
  private func row(_ host:NSView,_ identifier:String)throws->WorkspaceNavigationNativeButton {
    try XCTUnwrap(descendants(host).compactMap{$0 as? WorkspaceNavigationNativeButton}.first{$0.accessibilityIdentifier()==identifier},"Missing visible Studio row "+identifier)
  }
  private func textField(_ host:NSView,_ title:String)->NSTextField? {
    descendants(host).compactMap{$0 as? NSTextField}.first{$0.placeholderString==title || $0.accessibilityLabel()==title}
  }
  private func inspector(_ host:NSView)throws->NSSegmentedControl {
    try XCTUnwrap(descendants(host).compactMap{$0 as? NSSegmentedControl}.first { control in
      (0..<control.segmentCount).map{control.label(forSegment:$0) ?? ""} == ["Camera","Instance","Light"]
    },"Studio retains a real segmented inspector control")
  }

  func testNativeSharedPlacementToolsChangeModeWithoutEditingSceneOrDesign()throws {
    let f=try fixture(),before=try XCTUnwrap(f.store.project),draft=f.controller.draft
    XCTAssertEqual(f.controller.tool,.move)
    let choices:[(String,StudioCompositionTool)]=[("orbit",.orbit),("move",.move)]
    for (name,mode) in choices {
      let button=try toolbar(f.host,"studio-tool-"+name)
      XCTAssertEqual(button.bounds.size,.init(width:32,height:32));XCTAssertFalse(button.toolTip?.isEmpty ?? true)
      XCTAssertTrue(button.accessibilityPerformPress());settle(f.host)
      XCTAssertEqual(f.controller.tool,mode);XCTAssertTrue(button.isAccessibilitySelected())
      for (other,_) in choices where other != name {XCTAssertFalse(try toolbar(f.host,"studio-tool-"+other).isAccessibilitySelected())}
    }
    XCTAssertFalse(try toolbar(f.host,"studio-focus-selection").isEnabled)
    XCTAssertTrue(try toolbar(f.host,"studio-frame-scene").isEnabled)
    XCTAssertEqual(f.controller.draft,draft);XCTAssertEqual(f.store.project,before)
    XCTAssertTrue(f.store.engine.undoStack.isEmpty)
  }

  func testNativeTransformHandleToggleDefaultsOnAndPreservesSelectedSceneAndDesign()throws {
    let f=try fixture(),instance=try XCTUnwrap(f.first.instances.first)
    f.controller.selectInstance(instance.id);settle(f.host)
    let before=try XCTUnwrap(f.store.project),draft=try XCTUnwrap(f.controller.draft),camera=f.controller.stage.camera
    let control=try toolbar(f.host,"studio-transform-handles")
    XCTAssertTrue(f.controller.gizmoVisible);XCTAssertTrue(control.isAccessibilitySelected())
    XCTAssertEqual(control.accessibilityValue() as? String,"Shown")
    XCTAssertEqual(control.bounds.size,.init(width:32,height:32))
    XCTAssertFalse(control.toolTip?.isEmpty ?? true)
    XCTAssertTrue(control.accessibilityPerformPress());settle(f.host)
    XCTAssertFalse(f.controller.gizmoVisible);XCTAssertFalse(control.isAccessibilitySelected())
    XCTAssertEqual(control.accessibilityValue() as? String,"Hidden")
    XCTAssertTrue(control.accessibilityPerformPress());settle(f.host)
    XCTAssertTrue(f.controller.gizmoVisible);XCTAssertTrue(control.isAccessibilitySelected())
    XCTAssertEqual(f.controller.selectedInstanceID,instance.id);XCTAssertEqual(f.controller.draft,draft)
    XCTAssertEqual(f.controller.stage.camera,camera);XCTAssertEqual(f.store.project,before)
    XCTAssertFalse(f.controller.canUndoDraft);XCTAssertTrue(f.store.engine.undoStack.isEmpty)
    XCTAssertNotNil(textField(f.host,"Height (Y)"));XCTAssertNotNil(textField(f.host,"Rotation"))
  }

  func testNativeInstanceRowsRevealPlacementAndRepeatedSelectionRespectsUserCameraChoice()throws {
    let f=try fixture(),before=try XCTUnwrap(f.store.project),instance=try XCTUnwrap(f.first.instances.first)
    XCTAssertNil(textField(f.host,"Rotation"))
    XCTAssertTrue(try row(f.host,"studio-instance-"+instance.id.uuidString).accessibilityPerformPress());settle(f.host)
    XCTAssertEqual(f.controller.selectedInstanceID,instance.id)
    XCTAssertEqual(try inspector(f.host).selectedSegment,1)
    XCTAssertNotNil(textField(f.host,"Rotation"));XCTAssertTrue(try toolbar(f.host,"studio-focus-selection").isEnabled)
    let control=try inspector(f.host);control.selectedSegment=0
    XCTAssertTrue(control.sendAction(control.action,to:control.target));settle(f.host)
    XCTAssertEqual(try inspector(f.host).selectedSegment,0)
    XCTAssertNil(textField(f.host,"Rotation"),"Selection does not keep forcing the user away from Camera")
    f.controller.selectInstance(instance.id);settle(f.host)
    XCTAssertEqual(try inspector(f.host).selectedSegment,1,"An explicit repeat pick reveals the selected instance again")
    XCTAssertEqual(f.store.project,before);XCTAssertTrue(f.store.engine.undoStack.isEmpty)

    let previous=try XCTUnwrap(f.controller.draft)
    XCTAssertTrue(try toolbar(f.host,"studio-duplicate-instance").accessibilityPerformPress());settle(f.host)
    let copy=try XCTUnwrap(f.controller.selected)
    XCTAssertNotEqual(copy.id,instance.id);XCTAssertEqual(copy.sourceObjectID,instance.sourceObjectID)
    XCTAssertEqual(f.controller.draft?.instances.count,2)
    XCTAssertTrue(try row(f.host,"studio-instance-"+copy.id.uuidString).selected)
    XCTAssertTrue(f.controller.undoDraft());settle(f.host)
    XCTAssertEqual(f.controller.draft,previous);XCTAssertEqual(f.store.project,before);XCTAssertTrue(f.store.engine.undoStack.isEmpty)
  }

  func testFocusedHeightCommitsToItsOriginalInstanceBeforeNativeRowSelectionAndDuplicate()throws {
    let f=try fixture(),first=try XCTUnwrap(f.first.instances.first)
    f.controller.add(try XCTUnwrap(f.store.project?.objects.first))
    let second=try XCTUnwrap(f.controller.selected)
    f.controller.save();f.controller.selectInstance(first.id);settle(f.host)
    let source=try XCTUnwrap(f.store.project),documentUndo=f.store.engine.undoStack.count
    func typeHeight(_ value:String)throws {
      let field=try XCTUnwrap(textField(f.host,"Height (Y)"))
      field.selectText(nil)
      let editor=try XCTUnwrap(field.currentEditor() as? NSTextView,"Use the actual numeric field editor without Return or Tab")
      editor.insertText(value,replacementRange:.init(location:0,length:editor.string.utf16.count));settle(f.host)
    }
    try typeHeight("27")
    XCTAssertEqual(f.controller.selected?.positionMM.y,0,"Typing retains a draft until the native edit is committed")
    XCTAssertTrue(try row(f.host,"studio-instance-"+second.id.uuidString).accessibilityPerformPress());settle(f.host)
    XCTAssertEqual(f.controller.selectedInstanceID,second.id)
    XCTAssertEqual(f.controller.draft?.instances.first{$0.id==first.id}?.positionMM.y,27)
    XCTAssertEqual(f.controller.selected?.positionMM.y,0,"The old field's value must not move the newly selected instance")

    try typeHeight("36")
    XCTAssertEqual(f.controller.selected?.positionMM.y,0)
    XCTAssertTrue(try toolbar(f.host,"studio-duplicate-instance").accessibilityPerformPress());settle(f.host)
    let copy=try XCTUnwrap(f.controller.selected),after=try XCTUnwrap(f.controller.draft)
    XCTAssertNotEqual(copy.id,second.id);XCTAssertEqual(copy.positionMM.y,36)
    XCTAssertEqual(after.instances.first{$0.id==second.id}?.positionMM.y,36,"Commit the source field before taking the duplicate snapshot")
    XCTAssertEqual(after.instances.first{$0.id==first.id}?.positionMM.y,27)
    f.window.makeFirstResponder(nil);settle(f.host)
    XCTAssertEqual(f.controller.draft,after,"A delayed focus-loss callback cannot write an old draft into the new copy")

    XCTAssertTrue(f.controller.undoDraft());settle(f.host)
    let undone=try XCTUnwrap(f.controller.draft)
    XCTAssertEqual(undone.instances.count,2);XCTAssertFalse(undone.instances.contains{$0.id==copy.id})
    XCTAssertEqual(undone.instances.first{$0.id==second.id}?.positionMM.y,36,"Duplicate is one Undo, separate from the preceding field edit")
    XCTAssertEqual(undone.instances.first{$0.id==first.id}?.positionMM.y,27)
    XCTAssertEqual(f.store.project,source);XCTAssertEqual(f.store.engine.undoStack.count,documentUndo)
  }

  func testDirectSavedSceneRowsPreserveDirtySwitchContract()async throws {
    let f=try fixture(),before=try XCTUnwrap(f.store.project)
    let target=try row(f.host,"studio-scene-"+f.second.id.uuidString)
    XCTAssertEqual(target.rowTitle,f.second.name);XCTAssertTrue(target.accessibilityPerformPress())
    for _ in 0..<12 {await Task.yield()};settle(f.host)
    XCTAssertEqual(f.controller.draft?.id,f.second.id)
    XCTAssertTrue(try row(f.host,"studio-scene-"+f.second.id.uuidString).selected)
    f.controller.change{$0.name="Uncommitted placement study"};settle(f.host)
    let draft=f.controller.draft
    XCTAssertTrue(try row(f.host,"studio-scene-"+f.first.id.uuidString).accessibilityPerformPress())
    for _ in 0..<12 {await Task.yield()};settle(f.host)
    XCTAssertEqual(f.controller.pendingSceneID,f.first.id);XCTAssertEqual(f.controller.draft,draft)
    f.controller.cancelSceneSelection();settle(f.host)
    XCTAssertNil(f.controller.pendingSceneID);XCTAssertEqual(f.controller.draft,draft)
    XCTAssertEqual(f.store.project,before);XCTAssertTrue(f.store.engine.undoStack.isEmpty)
  }
}
