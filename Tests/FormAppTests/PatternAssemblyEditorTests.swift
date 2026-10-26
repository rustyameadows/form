import AppKit
import SwiftUI
import XCTest
@testable import FormCore
@testable import FormApp

@MainActor final class PatternAssemblyEditorTests:XCTestCase {
  private func fixture()throws -> (StudioStore,URL,UUID,PatternAssemblyDefinition) {
    _ = NSApplication.shared
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("assembly-editor-\(UUID().uuidString)")
    let repository=try ProjectRepository(root:root)
    var (project,definition)=try PatternAssemblySamples.roundedPouch();definition.maximumEdgeMm=42;definition.settings.substeps=3;definition.settings.iterations=3
    definition.panels[0].textureOriginMm.x=0.12345678912345679
    definition.settings.warpComplianceMPerN=0.000001234567891234
    let id=try project.addPatternAssembly(definition);try repository.save(project)
    let store=StudioStore(repository:repository,seedLibrary:false);try store.engine.open(project.id);store.showingHome=false
    return(store,root,id,definition)
  }
  private func editor(_ store:StudioStore,_ id:UUID,_ definition:PatternAssemblyDefinition)->(NSWindow,NSView) {
    let window=NSWindow(contentRect:.init(x:-10000,y:-10000,width:680,height:760),styleMask:[.titled],backing:.buffered,defer:false);window.isReleasedWhenClosed=false
    let view=NSHostingView(rootView:PatternAssemblyEditor(objectID:id,definition:definition).environmentObject(store).preferredColorScheme(.light).background(Palette.paper).foregroundStyle(Palette.ink));window.contentView=view
    window.setFrameOrigin(.init(x:-10000,y:-10000));window.orderBack(nil)
    view.layoutSubtreeIfNeeded();RunLoop.main.run(until:Date().addingTimeInterval(0.15));view.layoutSubtreeIfNeeded();view.displayIfNeeded()
    if let bitmap=view.bitmapImageRepForCachingDisplay(in:view.bounds) {view.cacheDisplay(in:view.bounds,to:bitmap);if let directory=ProcessInfo.processInfo.environment["FORM_ASSEMBLY_PROOF_DIR"] {try? bitmap.representation(using:.png,properties:[:])?.write(to:URL(fileURLWithPath:directory).appendingPathComponent("assembly-editor-initial.png"))}}
    return(window,view)
  }
  private func fields(_ view:NSView)->[NSTextField] {([view as? NSTextField].compactMap{$0})+view.subviews.flatMap{fields($0)}}
  private func enter(_ value:String,title:String,window:NSWindow,view:NSView)throws {
    let field=try XCTUnwrap(fields(view).first{$0.isEditable && ($0.placeholderString==title || title=="X" && $0.stringValue=="-130" || title=="Maximum edge (mm)" && $0.stringValue=="42")})
    XCTAssertTrue(window.makeFirstResponder(field))
    let editor=try XCTUnwrap(window.firstResponder as? NSTextView)
    editor.selectAll(nil);editor.insertText(value,replacementRange:NSRange(location:NSNotFound,length:0))
    RunLoop.main.run(until:Date().addingTimeInterval(0.02))
  }
  private func press(apply:Bool,window:NSWindow,view:NSView)throws {
    view.layoutSubtreeIfNeeded()
    let point=NSPoint(x:view.bounds.maxX-(apply ? 55:128),y:view.isFlipped ? view.bounds.maxY-34:view.bounds.minY+34),location=view.convert(point,to:nil),stamp=ProcessInfo.processInfo.systemUptime
    let down=try XCTUnwrap(NSEvent.mouseEvent(with:.leftMouseDown,location:location,modifierFlags:[],timestamp:stamp,windowNumber:window.windowNumber,context:nil,eventNumber:1,clickCount:1,pressure:1))
    let up=try XCTUnwrap(NSEvent.mouseEvent(with:.leftMouseUp,location:location,modifierFlags:[],timestamp:stamp+0.02,windowNumber:window.windowNumber,context:nil,eventNumber:2,clickCount:1,pressure:0))
    NSApp.postEvent(up,atStart:false);NSApp.sendEvent(down);NSApp.sendEvent(up);RunLoop.main.run(until:Date().addingTimeInterval(0.08))
  }
  func testActualApplyButtonCommitsFocusedPoseFieldAndPreservesEveryUntouchedValue()throws {
    let(store,root,id,definition)=try fixture();defer{store.cloth.clear();try? FileManager.default.removeItem(at:root)}
    let baseline=store.project!,count=store.engine.undoStack.count,(window,view)=editor(store,id,definition);defer{window.contentView=nil;window.close()}
    try enter("-120.125",title:"X",window:window,view:view)
    try press(apply:true,window:window,view:view)
    var expected=definition;expected.panels[0].pose.originMm.x = -120.125
    XCTAssertEqual(store.project!.objects.first{$0.id==id}!.patternAssembly,expected)
    XCTAssertEqual(store.project!.camera,baseline.camera);XCTAssertEqual(store.engine.undoStack.count,count+1)
    store.undo();XCTAssertEqual(store.project,baseline)
  }
  func testActualCancelButtonWithFocusedPoseFieldLeavesDocumentAndUndoExact()throws {
    let(store,root,id,definition)=try fixture();defer{store.cloth.clear();try? FileManager.default.removeItem(at:root)}
    let baseline=store.project!,undo=store.engine.undoStack,(window,view)=editor(store,id,definition);defer{window.contentView=nil;window.close()}
    try enter("-118.25",title:"X",window:window,view:view)
    try press(apply:false,window:window,view:view)
    XCTAssertEqual(store.project,baseline);XCTAssertEqual(store.engine.undoStack,undo)
  }
}
