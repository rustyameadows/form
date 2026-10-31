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
  private func row(_ host:NSView,_ identifier:String)throws->StudioSceneThumbnailNativeButton {
    try XCTUnwrap(descendants(host).compactMap{$0 as? StudioSceneThumbnailNativeButton}.first{$0.accessibilityIdentifier()==identifier},"Missing visible Studio row "+identifier)
  }
  private func pick(_ f:Fixture,_ id:UUID)throws {
    let view=try XCTUnwrap(f.controller.stage.view)
    let node=try XCTUnwrap(f.controller.stage.logicalNode(for:id)),bounds=try XCTUnwrap(f.controller.stage.localBounds(for:id))
    let projected=view.projectPoint(node.convertPosition(.init((bounds.min.x+bounds.max.x)/2,(bounds.min.y+bounds.max.y)/2,(bounds.min.z+bounds.max.z)/2),to:nil))
    var point:NSPoint?
    for y in stride(from:-20.0,through:20,by:4) {for x in stride(from:-20.0,through:20,by:4) {
      let candidate=NSPoint(x:projected.x+x,y:projected.y+y)
      if f.controller.stage.objectID(at:candidate)==id {point=candidate;break}
    };if point != nil {break}}
    let hit=try XCTUnwrap(point,"Pick the real rendered instance, without an instance sidebar")
    let location=view.convert(hit,to:nil)
    for kind in [NSEvent.EventType.leftMouseDown,.leftMouseUp] {
      let event=try XCTUnwrap(NSEvent.mouseEvent(with:kind,location:location,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:f.window.windowNumber,context:nil,eventNumber:1,clickCount:1,pressure:kind == .leftMouseUp ? 0:1))
      if kind == .leftMouseDown {view.mouseDown(with:event)}else{view.mouseUp(with:event)}
    }
    settle(f.host)
  }
  private func textField(_ host:NSView,_ title:String)->NSTextField? {
    descendants(host).compactMap{$0 as? NSTextField}.first{$0.placeholderString==title || $0.accessibilityLabel()==title}
  }
  private let cameraFieldLabels=["Camera yaw","Camera elevation","Camera distance","Camera target X","Camera target Y","Camera target Z"]
  private let outputFieldLabels=["Studio scene name","Output width","Output height"]
  private func fields(_ host:NSView,_ labels:[String])throws->[NSTextField] {
    try labels.map{label in
      let field=try XCTUnwrap(textField(host,label),"Missing continuous inspector field: "+label)
      XCTAssertTrue(field.isEditable,"The named inspector control is an actual editable field: "+label)
      return field
    }
  }
  private func assertNoInspectorTabs(_ host:NSView,file:StaticString=#filePath,line:UInt=#line) {
    XCTAssertFalse(descendants(host).compactMap{$0 as? NSSegmentedControl}.contains {control in
      (0..<control.segmentCount).map{control.label(forSegment:$0) ?? ""} == ["Camera","Instance","Light"]
    },"Camera, instance and lighting belong to one continuous inspector",file:file,line:line)
  }
  private func insideScrollView(_ view:NSView,until host:NSView)->Bool {
    var parent=view.superview
    while let current=parent,current !== host {
      if current is NSScrollView {return true}
      parent=current.superview
    }
    return false
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

  func testNativeStagePickKeepsCameraAndOutputAlongsidePlacementWithoutInspectorTabs()throws {
    let f=try fixture(),before=try XCTUnwrap(f.store.project),instance=try XCTUnwrap(f.first.instances.first)
    f.controller.gizmoVisible=false
    let camera=try fields(f.host,cameraFieldLabels),output=try fields(f.host,outputFieldLabels)
    let draft=f.controller.draft
    assertNoInspectorTabs(f.host);XCTAssertNil(textField(f.host,"Rotation"))
    try pick(f,instance.id)
    XCTAssertEqual(f.controller.selectedInstanceID,instance.id)
    XCTAssertNotNil(textField(f.host,"Height (Y)"));XCTAssertNotNil(textField(f.host,"Rotation"))
    XCTAssertTrue(try toolbar(f.host,"studio-focus-selection").isEnabled)
    XCTAssertEqual(try fields(f.host,cameraFieldLabels).map(ObjectIdentifier.init),camera.map(ObjectIdentifier.init),"Selection must retain the camera editors")
    XCTAssertEqual(try fields(f.host,outputFieldLabels).map(ObjectIdentifier.init),output.map(ObjectIdentifier.init),"Selection must retain the pinned output editors")
    assertNoInspectorTabs(f.host)
    f.controller.selectInstance(instance.id);settle(f.host)
    XCTAssertNotNil(textField(f.host,"Rotation"));XCTAssertNotNil(textField(f.host,"Camera yaw"))
    XCTAssertEqual(f.controller.draft,draft);XCTAssertEqual(f.store.project,before);XCTAssertTrue(f.store.engine.undoStack.isEmpty)

    let previous=try XCTUnwrap(f.controller.draft)
    XCTAssertTrue(try toolbar(f.host,"studio-duplicate-instance").accessibilityPerformPress());settle(f.host)
    let copy=try XCTUnwrap(f.controller.selected)
    XCTAssertNotEqual(copy.id,instance.id);XCTAssertEqual(copy.sourceObjectID,instance.sourceObjectID)
    XCTAssertEqual(f.controller.draft?.instances.count,2);XCTAssertEqual(f.controller.selectedInstanceID,copy.id)
    XCTAssertTrue(f.controller.undoDraft());settle(f.host)
    XCTAssertEqual(f.controller.draft,previous);XCTAssertEqual(f.store.project,before);XCTAssertTrue(f.store.engine.undoStack.isEmpty)
  }

  func testFocusedHeightCommitsToItsOriginalInstanceBeforeNativeStageSelectionAndDuplicate()throws {
    let f=try fixture(),first=try XCTUnwrap(f.first.instances.first)
    f.controller.gizmoVisible=false
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
    try pick(f,second.id)
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
    XCTAssertEqual(target.rowTitle,f.second.name);XCTAssertNil(target.subtitle)
    XCTAssertEqual(target.bounds.height,108,accuracy:1);XCTAssertEqual(target.toolTip,f.second.name)
    XCTAssertTrue(target.accessibilityPerformPress())
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

  func testSavedThumbnailUsesItsOwnRendererCoalescesAndInvalidatesForLinkedSourceChanges()async throws {
    let f=try fixture(),project=try XCTUnwrap(f.store.project)
    f.controller.change{$0.instances[0].rotationDegrees=67;$0.instances[0].positionMM.x=35}
    let draft=f.controller.draft,camera=f.controller.stage.camera,undo=f.store.engine.undoStack.count
    let cache=StudioSceneThumbnailCache(),assets=f.store.repository.url(for:project.id).appendingPathComponent("Assets")
    defer{cache.reset()}
    cache.synchronize(project:project,assets:assets)
    let key=cache.key(for:f.first)
    async let first=cache.image(for:f.first,preflight:{_,_ in})
    async let second=cache.image(for:f.first,preflight:{_,_ in})
    let (image,repeatImage)=try await(first,second)
    XCTAssertEqual(cache.renderCount,1,"Concurrent requests for a saved scene share one native capture")
    XCTAssertEqual(image.tiffRepresentation,repeatImage.tiffRepresentation)
    let pixels=try XCTUnwrap(image.cgImage(forProposedRect:nil,context:nil,hints:nil)),bitmap=NSBitmapImageRep(cgImage:pixels)
    XCTAssertLessThanOrEqual(bitmap.pixelsWide,512);XCTAssertLessThanOrEqual(bitmap.pixelsHigh,512)
    var bluePixels=0
    for y in stride(from:0,to:bitmap.pixelsHigh,by:4) {for x in stride(from:0,to:bitmap.pixelsWide,by:4) {
      if let color=bitmap.colorAt(x:x,y:y)?.usingColorSpace(.deviceRGB),color.blueComponent>color.redComponent*1.2,color.blueComponent>color.greenComponent*1.1 {bluePixels+=1}
    }}
    XCTAssertGreaterThan(bluePixels,10,"The native thumbnail contains the actual blue product, not a placeholder")
    _ = try await cache.image(for:f.first,preflight:{_,_ in});XCTAssertEqual(cache.renderCount,1)
    var changed=project;changed.camera.distance+=1;changed.history=[]
    cache.synchronize(project:changed,assets:assets)
    XCTAssertEqual(cache.key(for:f.first),key,"Unrelated design-camera navigation does not regenerate scene thumbnails")
    changed.objects[0].color="#B14E36";cache.synchronize(project:changed,assets:assets)
    XCTAssertNotEqual(cache.key(for:f.first),key)
    let red=try await cache.image(for:f.first,preflight:{_,_ in})
    XCTAssertNotEqual(red.tiffRepresentation,image.tiffRepresentation,"Linked source changes must be rendered")
    XCTAssertEqual(cache.renderCount,2)
    var alternate=f.first;alternate.camera.azimuth+=0.3
    XCTAssertNotEqual(cache.key(for:alternate),cache.key(for:f.first),"Full saved camera state participates even without a revision bump")
    XCTAssertEqual(f.controller.draft,draft);XCTAssertEqual(f.controller.stage.camera,camera)
    XCTAssertEqual(f.store.project,project);XCTAssertEqual(f.store.engine.undoStack.count,undo)
  }

  func testThumbnailRuntimeGuardAlsoRejectsCachedImagesAndEmptyScenesStayReadOnly()async throws {
    let f=try fixture(),project=try XCTUnwrap(f.store.project),draft=f.controller.draft
    let cache=StudioSceneThumbnailCache(),assets=f.store.repository.url(for:project.id).appendingPathComponent("Assets")
    defer{cache.reset()};cache.synchronize(project:project,assets:assets)
    _ = try await cache.image(for:f.first,preflight:{_,_ in})
    do {_ = try await cache.image(for:f.first,preflight:{_,_ in throw FormError.invalid("Unpersisted cloth preview")});XCTFail("Cached committed thumbnails still respect the current cloth guard")}
    catch {XCTAssertTrue(error.localizedDescription.contains("Unpersisted cloth"))}
    var empty=f.first;empty.instances=[]
    do {_ = try await cache.image(for:empty,preflight:{_,_ in});XCTFail("An empty scene is a labeled placeholder")}
    catch {XCTAssertTrue(error.localizedDescription.contains("Empty scene"))}
    XCTAssertEqual(cache.renderCount,1);XCTAssertEqual(f.controller.draft,draft);XCTAssertEqual(f.store.project,project)
    XCTAssertTrue(f.store.engine.undoStack.isEmpty)
  }

  func testContinuousInspectorPinsOutputAndRetainsCameraAtNarrowAndWideSizesBeforeAndAfterPick()throws {
    let f=try fixture(),project=try XCTUnwrap(f.store.project),draft=f.controller.draft
    let instance=try XCTUnwrap(f.first.instances.first);f.controller.gizmoVisible=false
    for size in [CGSize(width:1020,height:700),CGSize(width:1440,height:940)] {
      f.controller.selectInstance(nil);f.window.setContentSize(size);settle(f.host)
      let cameras=try fields(f.host,cameraFieldLabels),outputs=try fields(f.host,outputFieldLabels)
      let boundsBefore=outputs.map{$0.convert($0.bounds,to:nil)}
      for selected in [false,true] {
        if selected {try pick(f,instance.id)}
        assertNoInspectorTabs(f.host)
        XCTAssertEqual(try fields(f.host,cameraFieldLabels).map(ObjectIdentifier.init),cameras.map(ObjectIdentifier.init))
        XCTAssertEqual(try fields(f.host,outputFieldLabels).map(ObjectIdentifier.init),outputs.map(ObjectIdentifier.init))
        if selected {XCTAssertNotNil(textField(f.host,"Height (Y)"));XCTAssertNotNil(textField(f.host,"Rotation"))}
        let save=try XCTUnwrap(descendants(f.host).compactMap{$0 as? NSButton}.first{$0.accessibilityIdentifier()=="studio-save-still"})
        let generate=try XCTUnwrap(descendants(f.host).compactMap{$0 as? NSButton}.first{$0.accessibilityIdentifier()=="studio-generate-image"})
        let savedRect=save.convert(save.bounds,to:nil),generatedRect=generate.convert(generate.bounds,to:nil),hostRect=f.host.convert(f.host.bounds,to:nil)
        XCTAssertEqual(savedRect.minX,generatedRect.minX,accuracy:1)
        XCTAssertGreaterThan(savedRect.width,200);XCTAssertLessThan(savedRect.width,290)
        XCTAssertEqual(generatedRect.width,savedRect.width,accuracy:1)
        XCTAssertEqual(abs(savedRect.midY-generatedRect.midY),40,accuracy:1)
        XCTAssertFalse(savedRect.intersects(generatedRect));XCTAssertTrue(save.isEnabled);XCTAssertTrue(generate.isEnabled)
        XCTAssertTrue(hostRect.insetBy(dx:-1,dy:-1).contains(savedRect));XCTAssertTrue(hostRect.insetBy(dx:-1,dy:-1).contains(generatedRect))
        XCTAssertFalse(insideScrollView(save,until:f.host));XCTAssertFalse(insideScrollView(generate,until:f.host))
        for (index,field) in outputs.enumerated() {
          let frame=field.convert(field.bounds,to:nil)
          XCTAssertEqual(frame,boundsBefore[index],"Instance selection must not displace pinned output fields")
          XCTAssertGreaterThan(frame.width,20);XCTAssertGreaterThan(frame.height,10)
          XCTAssertTrue(hostRect.insetBy(dx:-1,dy:-1).contains(frame),"Pinned output remains visible at \(size)")
          XCTAssertGreaterThanOrEqual(frame.minX,hostRect.maxX-290)
          XCTAssertFalse(insideScrollView(field,until:f.host),"Output fields stay outside the scrolling inspector")
          XCTAssertFalse(field.isHiddenOrHasHiddenAncestor)
        }
        XCTAssertNotNil(try row(f.host,"studio-scene-"+f.first.id.uuidString))
        XCTAssertFalse(descendants(f.host).compactMap{$0 as? WorkspaceNavigationNativeButton}.contains{($0.accessibilityIdentifier() ?? "").hasPrefix("studio-instance-")})
        XCTAssertFalse(descendants(f.host).compactMap{$0 as? NSButton}.contains{["Capture start","Capture end","Export video…"].contains($0.title)})
      }
    }
    XCTAssertEqual(f.controller.draft,draft,"Layout and selection retain camera, placement, pixels and saved motion")
    XCTAssertEqual(f.store.project,project);XCTAssertTrue(f.store.engine.undoStack.isEmpty)
  }
}
