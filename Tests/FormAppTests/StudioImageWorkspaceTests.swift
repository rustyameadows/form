import AppKit
import FormCore
import SwiftUI
import XCTest
@testable import FormApp

/// SwiftUI's virtual AX children can implement the legacy NSObject selectors
/// without declaring the full NSAccessibilityProtocol conformance.
@MainActor private struct WorkflowAXNode {
  let object:NSObject
  var modern:(any NSAccessibilityProtocol)? {object as? any NSAccessibilityProtocol}
  func objectValue(_ name:String)->Any? {
    let selector=NSSelectorFromString(name)
    guard object.responds(to:selector) else{return nil}
    return object.perform(selector)?.takeUnretainedValue()
  }
  func legacy(_ name:String)->Any? {
    guard object.responds(to:NSSelectorFromString("accessibilityAttributeValue:")) else{return nil}
    return object.accessibilityAttributeValue(.init(rawValue:name))
  }
  func accessibilityRole()->NSAccessibility.Role? {
    modern?.accessibilityRole() ?? ((objectValue("accessibilityRole") ?? legacy("AXRole")) as? String).map{.init(rawValue:$0)}
  }
  func accessibilityIdentifier()->String? {modern?.accessibilityIdentifier() ?? (objectValue("accessibilityIdentifier") ?? legacy("AXIdentifier")) as? String}
  func accessibilityLabel()->String? {modern?.accessibilityLabel() ?? (objectValue("accessibilityLabel") ?? legacy("AXDescription")) as? String}
  func accessibilityTitle()->String? {modern?.accessibilityTitle() ?? (objectValue("accessibilityTitle") ?? legacy("AXTitle")) as? String}
  func accessibilityChildren()->[Any] {
    var result=modern?.accessibilityChildren() ?? []
    // AppKit may return heterogeneous cells despite the SDK's narrower
    // NSAccessibilityElement array declaration. Read the raw NSArray getter.
    if let navigation=objectValue("accessibilityChildrenInNavigationOrder") as? NSArray {result += navigation.map{$0}}
    if modern==nil {
      result += objectValue("accessibilityChildren") as? [Any] ?? []
    }
    if result.isEmpty {
      result += legacy("AXChildren") as? [Any] ?? []
      result += legacy("AXChildrenInNavigationOrder") as? [Any] ?? []
    }
    return result
  }
  func accessibilityFrame()->CGRect {
    if let frame=modern?.accessibilityFrame(),frame.width>0,frame.height>0 {return frame}
    let position=(legacy("AXPosition") as? NSValue)?.pointValue ?? .zero
    let size=(legacy("AXSize") as? NSValue)?.sizeValue ?? .zero
    return .init(origin:position,size:size)
  }
  func isAccessibilityEnabled()->Bool {modern?.isAccessibilityEnabled() ?? (legacy("AXEnabled") as? NSNumber)?.boolValue ?? true}
  func accessibilityPerformPress()->Bool {
    guard accessibilityRole() == .button || accessibilityRole() == .radioButton,isAccessibilityEnabled() else{return false}
    if let modern {return modern.accessibilityPerformPress()}
    let selector=NSSelectorFromString("accessibilityPerformPress")
    if object.responds(to:selector),let implementation=object.method(for:selector) {
      typealias Press = @convention(c)(AnyObject,Selector)->Bool
      return unsafeBitCast(implementation,to:Press.self)(object,selector)
    }
    guard object.responds(to:NSSelectorFromString("accessibilityPerformAction:")),
      object.accessibilityActionNames().contains(.init(rawValue:"AXPress")) else{return false}
    object.accessibilityPerformAction(.init(rawValue:"AXPress"));return true
  }
}

@MainActor private struct WorkflowUIAction {
  let enabled:()->Bool
  let press:()->Bool
  var frame:()->CGRect = {.zero}
  func accessibilityFrame()->CGRect {frame()}
  func isAccessibilityEnabled()->Bool {enabled()}
  func accessibilityPerformPress()->Bool {press()}
}

@MainActor final class StudioImageWorkspaceTests:XCTestCase {
  private var reportedAXTypes=Set<String>()
  @MainActor private final class HeldProvider:StudioImageGenerationProvider {
    var entered=false
    private var continuation:CheckedContinuation<Void,Never>?
    func generate(_ request:StudioGenerationRequest,progress:@escaping(Double)->Void)async throws->[Data] {
      entered=true;progress(0.2)
      await withCheckedContinuation{continuation=$0}
      try Task.checkCancellation()
      return try await LocalStudioImageGenerationProvider(delayNanoseconds:0).generate(request,progress:progress)
    }
    func release(){let pending=continuation;continuation=nil;pending?.resume()}
  }
  private struct Fixture {
    let directory:URL,store:StudioStore,library:StudioAssetLibrary,controller:StudioImageGenerationController
  }
  private func fixture(provider:(any StudioImageGenerationProvider)?=nil)throws->Fixture {
    _ = NSApplication.shared
    let directory=FileManager.default.temporaryDirectory.appendingPathComponent("studio-image-ui-"+UUID().uuidString)
    let store=StudioStore(repository:try ProjectRepository(root:directory),seedLibrary:false)
    var project=Project(name:"Local image workflow")
    var object=try project.makeObject(recipeID:"box",parameters:["width":100,"height":80,"depth":60]);object.color="#426A84"
    project.objects=[object];store.engine.project=project;store.showingHome=false;store.studioComposition.reconcile();store.studioComposition.change{$0.pixels = .init(width:300,height:200)};store.studioComposition.stage.fitAll()
    let library=StudioAssetLibrary(root:directory,projectID:project.id)
    let controller=StudioImageGenerationController(store:store,library:library,provider:provider ?? LocalStudioImageGenerationProvider(delayNanoseconds:0))
    controller.options.size = .small;controller.prompt="A faithful product view."
    addTeardownBlock{@MainActor in
      controller.cancel();store.studioComposition.reset();store.engine.project=nil;try? FileManager.default.removeItem(at:directory)
    }
    return .init(directory:directory,store:store,library:library,controller:controller)
  }
  private func descendants(_ root:NSView)->[NSView] {[root]+root.subviews.flatMap(descendants)}
  private func accessibility(_ value:Any,depth:Int=0)->[WorkflowAXNode] {
    var seen=Set<ObjectIdentifier>()
    return accessibility(value,depth:depth,seen:&seen)
  }
  private func accessibility(_ value:Any,depth:Int,seen:inout Set<ObjectIdentifier>)->[WorkflowAXNode] {
    guard depth<40,seen.count<3000 else{return []}
    let object=(value as? WorkflowAXNode)?.object ?? value as? NSObject
    let type=String(reflecting:Swift.type(of:value))
    if !(value is any NSAccessibilityProtocol),reportedAXTypes.count<24,reportedAXTypes.insert(type).inserted {
      print("StudioImageAX child_type=\(type) NSObject=\(object != nil) children_selector=\(object?.responds(to:NSSelectorFromString("accessibilityChildren")) ?? false) legacy_getter=\(object?.responds(to:NSSelectorFromString("accessibilityAttributeValue:")) ?? false) press_selector=\(object?.responds(to:NSSelectorFromString("accessibilityPerformAction:")) ?? false)")
    }
    guard let object,seen.insert(ObjectIdentifier(object)).inserted else{return []}
    let item=WorkflowAXNode(object:object)
    var result=[item]
    for child in item.accessibilityChildren() {result += accessibility(child,depth:depth+1,seen:&seen)}
    return result
  }
  private func action(_ host:NSView,_ id:String)throws->WorkflowUIAction {
    let nodes=descendants(host).flatMap{accessibility($0)}
    if let direct=nodes.first(where:{
      $0.accessibilityRole() == .button && $0.accessibilityIdentifier()==id
    }) {return .init(enabled:{direct.isAccessibilityEnabled()},press:{direct.accessibilityPerformPress()},frame:{direct.accessibilityFrame()})}
    // SwiftUI can attach its identifier to a semantic group around a native
    // button. Still require a real AX button and exercise its actual action.
    for marker in nodes where marker.accessibilityIdentifier()==id {
      let buttons=accessibility(marker).filter{$0.accessibilityRole() == .button}
      if buttons.count==1,let button=buttons.first {
        reportAction(button,id:id,via:"identifier ancestor "+(marker.accessibilityRole()?.rawValue ?? "nil"))
        return .init(enabled:{button.isAccessibilityEnabled()},press:{button.accessibilityPerformPress()},frame:{button.accessibilityFrame()})
      }
    }
    let titles:[String]
    switch id {
    case "studio-image-generate":titles=["Generate demo image","Generate 2 demo images","Generate 4 demo images"]
    case "studio-preview-key-continue":titles=["Continue with demo setup"]
    case "studio-image-library":titles=["Library"]
    default:titles=[]
    }
    if let button=nodes.first(where:{$0.accessibilityRole() == .button && titles.contains($0.accessibilityLabel() ?? $0.accessibilityTitle() ?? "")}) {
      reportAction(button,id:id,via:"visible button title")
      return .init(enabled:{button.isAccessibilityEnabled()},press:{button.accessibilityPerformPress()},frame:{button.accessibilityFrame()})
    }
    if let mouse=nativeMouseAction(host,id:id,titles:titles) {return mouse}
    for node in nodes.filter({$0.accessibilityRole() == .button || $0.accessibilityIdentifier() != nil}).prefix(70) {
      print("StudioImageAX missing=\(id) role=\(node.accessibilityRole()?.rawValue ?? "nil") id=\(node.accessibilityIdentifier() ?? "nil") title=\(node.accessibilityLabel() ?? node.accessibilityTitle() ?? "nil") frame=\(node.accessibilityFrame())")
    }
    return try XCTUnwrap(nil as WorkflowUIAction?,"Missing native image workflow control "+id)
  }
  private func nativeMouseAction(_ host:NSView,id:String,titles:[String])->WorkflowUIAction? {
    guard let window=host.window else{return nil}
    let buttons=descendants(host).compactMap{$0 as? NSButton}.filter {
      !$0.isHiddenOrHasHiddenAncestor && $0.bounds.width>12 && $0.bounds.height>12
        && (titles.contains($0.title) || titles.contains($0.attributedTitle.string) || $0.accessibilityIdentifier()==id)
    }
    if let button=buttons.first {
      let point=button.convert(.init(x:button.bounds.midX,y:button.bounds.midY),to:nil)
      return .init(enabled:{button.isEnabled},press:{self.mouseClick(window,point:point,id:id)})
    }
    // These are the observed positions in this exact hosted fixture, in native
    // window coordinates. A real hit-tested mouse event still drives SwiftUI.
    let rect=host.convert(host.bounds,to:nil),point:NSPoint
    switch id {
    case "studio-image-generate":point = .init(x:rect.maxX-160,y:rect.minY+64)
    case "studio-image-library":
      // The style editor is the lower of the two real multiline fields. Anchor
      // to its native scroll frame so capture-card presence cannot shift us.
      let editors=descendants(host).compactMap{$0 as? NSTextView}.filter{!$0.isFieldEditor && $0.isEditable}
      guard let style=editors.min(by:{$0.convert($0.bounds,to:nil).midY<$1.convert($1.bounds,to:nil).midY}) else{return nil}
      var ancestor=style.superview,styleScroll:NSScrollView?
      while let view=ancestor {
        if let scroll=view as? NSScrollView {styleScroll=scroll;break}
        ancestor=view.superview
      }
      guard let styleScroll else{return nil}
      let frame=styleScroll.convert(styleScroll.bounds,to:nil)
      point = .init(x:rect.maxX-190,y:frame.minY-137)
    case "studio-preview-key-continue":
      guard let secure=descendants(host).compactMap({$0 as? NSSecureTextField}).first else{return nil}
      let frame=secure.convert(secure.bounds,to:nil)
      let hasText = !(secure.currentEditor()?.string ?? secure.stringValue).isEmpty
      point = .init(x:frame.minX+90,y:frame.minY-(hasText ? 65:31))
    default:return nil
    }
    guard let content=window.contentView,content.bounds.contains(content.convert(point,from:nil)),
      let hit=content.hitTest(content.superview?.convert(point,from:nil) ?? point),!hit.isHiddenOrHasHiddenAncestor else{return nil}
    return .init(enabled:{(hit as? NSControl)?.isEnabled ?? true},press:{self.mouseClick(window,point:point,id:id)})
  }
  private func mouseClick(_ window:NSWindow,point:NSPoint,id:String)->Bool {
    guard let content=window.contentView,let hit=content.hitTest(content.superview?.convert(point,from:nil) ?? point),
      !hit.isHiddenOrHasHiddenAncestor,(hit as? NSControl)?.isEnabled != false else{return false}
    let time=ProcessInfo.processInfo.systemUptime
    guard let down=NSEvent.mouseEvent(with:.leftMouseDown,location:point,modifierFlags:[],timestamp:time,windowNumber:window.windowNumber,context:nil,eventNumber:81,clickCount:1,pressure:1),
      let up=NSEvent.mouseEvent(with:.leftMouseUp,location:point,modifierFlags:[],timestamp:time+0.01,windowNumber:window.windowNumber,context:nil,eventNumber:82,clickCount:1,pressure:0) else{return false}
    print("StudioImageNativeMouse action=\(id) point=\(point) hit=\(String(reflecting:type(of:hit)))")
    // NSButton may enter synchronous tracking during down; queue its release
    // first so that tracking receives a genuine mouse-up rather than hanging.
    window.makeKeyAndOrderFront(nil)
    NSApp.postEvent(up,atStart:false);window.sendEvent(down)
    // The XCTest AppKit host does not run NSApplication.run. If synchronous
    // tracking did not consume release, dispatch that queued event ourselves.
    if let pending=NSApp.nextEvent(matching:.leftMouseUp,until:.distantPast,inMode:.default,dequeue:true) {window.sendEvent(pending)}
    return true
  }
  private func reportAction(_ node:WorkflowAXNode,id:String,via:String) {
    print("StudioImageAX resolved=\(id) via=\(via) role=\(node.accessibilityRole()?.rawValue ?? "nil") actual_id=\(node.accessibilityIdentifier() ?? "nil") title=\(node.accessibilityLabel() ?? node.accessibilityTitle() ?? "nil")")
  }
  private func settle(_ host:NSView) {
    host.layoutSubtreeIfNeeded();RunLoop.main.run(until:Date().addingTimeInterval(0.04));host.layoutSubtreeIfNeeded()
  }
  private func mount<V:View>(_ root:V,size:NSSize)->(NSWindow,NSView) {
    let host=NSHostingView(rootView:root.labInterface())
    let window=NSWindow(contentRect:.init(origin:.init(x:-10000,y:-10000),size:size),styleMask:[.titled,.resizable],backing:.buffered,defer:false)
    window.isReleasedWhenClosed=false;window.contentView=host;window.makeKeyAndOrderFront(nil);settle(host)
    addTeardownBlock{@MainActor in
      for preview in NSApp.windows where preview.identifier==StudioImageReviewPresenter.windowIdentifier {preview.close()}
      if let sheet=window.attachedSheet {window.endSheet(sheet)}
      window.makeFirstResponder(nil);window.contentView=nil;window.close()
    }
    return(window,host)
  }
  private func waitUntil(_ condition:()->Bool)async throws {
    for _ in 0..<1600 {if condition(){return};try await Task.sleep(nanoseconds:5_000_000)}
    XCTFail("The bounded local demo UI action did not finish")
  }

  func testNativeCredentialPreviewIsMaskedClearsOnCloseAndOnlyEnablesDemoConnection()throws {
    _ = NSApplication.shared
    let controller=OpenAIConnectionPreviewController()
    var closes=0
    let (_,host)=mount(OpenAIConnectionPreviewView(controller:controller){closes+=1},size:.init(width:500,height:640))
    let continueAction=try action(host,"studio-preview-key-continue")
    _ = continueAction.accessibilityPerformPress();settle(host)
    XCTAssertEqual(controller.state,.disconnected);XCTAssertEqual(closes,0,"An empty key preview cannot continue")
    let secure=try XCTUnwrap(descendants(host).compactMap{$0 as? NSSecureTextField}.first)
    secure.selectText(nil)
    let editor=try XCTUnwrap(secure.currentEditor() as? NSTextView)
    editor.insertText("preview text only",replacementRange:.init(location:0,length:editor.string.utf16.count));settle(host)
    XCTAssertFalse(secure.stringValue.isEmpty)
    XCTAssertEqual(controller.state,.disconnected)
    let readyContinue=try action(host,"studio-preview-key-continue")
    XCTAssertTrue(readyContinue.isAccessibilityEnabled())
    XCTAssertTrue(readyContinue.accessibilityPerformPress());settle(host)
    XCTAssertEqual(controller.state,.demoReady);XCTAssertEqual(closes,1);XCTAssertTrue(secure.stringValue.isEmpty)
    XCTAssertTrue(controller.detail?.contains("no AI request")==true)
  }

  func testNativeGenerateReviewFavoriteReferenceAndCanvasCallbacksPreserveTheDesign()async throws {
    let f=try fixture();f.controller.connection.useDemoConnection();await f.controller.captureScene()
    XCTAssertNotNil(f.controller.capture);XCTAssertNil(f.controller.error)
    let before=try XCTUnwrap(f.store.project),input=try XCTUnwrap(f.controller.capture)
    f.controller.options.count=2
    var canvas=[UUID]()
    let (window,host)=mount(StudioImageWorkspace(controller:f.controller,library:f.library,onUseInCanvas:{canvas.append($0)}),size:.init(width:1020,height:780))
    let editor=try XCTUnwrap(descendants(host).compactMap{$0 as? NSTextView}.first{!$0.isFieldEditor && $0.isEditable && $0.string==f.controller.prompt})
    let prompt="Warm editorial view; <script> is plain prompt text."
    window.makeFirstResponder(editor);editor.insertText(prompt,replacementRange:.init(location:0,length:editor.string.utf16.count));settle(host)
    XCTAssertEqual(f.controller.prompt,prompt)
    XCTAssertTrue(try action(host,"studio-image-generate").accessibilityPerformPress())
    try await waitUntil{!f.controller.busy && f.controller.currentRun?.status == .succeeded};settle(host)
    let run=try XCTUnwrap(f.controller.currentRun),id=try XCTUnwrap(run.outputAssetIDs.first)
    XCTAssertEqual(run.outputAssetIDs.count,2);XCTAssertEqual(run.capture,input);XCTAssertEqual(run.prompt,prompt)
    XCTAssertTrue(input.hasExactStudioPixels);XCTAssertEqual(run.options.outputPixels,input.scene.pixels)
    let asset=try XCTUnwrap(f.library.asset(id:id)),bytes=try Data(contentsOf:f.library.fileURL(for:asset))
    XCTAssertTrue(asset.isMock)
    let bitmap=try XCTUnwrap(NSBitmapImageRep(data:bytes))
    XCTAssertEqual(bitmap.pixelsWide,input.scene.pixels.width);XCTAssertEqual(bitmap.pixelsHigh,input.scene.pixels.height)
    XCTAssertTrue(try action(host,"studio-image-preview-"+id.uuidString).accessibilityPerformPress());settle(host)
    let expectedPreview=try f.library.fileURL(for:asset).standardizedFileURL.resolvingSymlinksInPath()
    let preview=try XCTUnwrap(NSApp.windows.first{$0.identifier==StudioImageReviewPresenter.windowIdentifier && $0.isVisible && $0.representedURL?.standardizedFileURL.resolvingSymlinksInPath()==expectedPreview})
    let review=try XCTUnwrap(preview.contentView)
    XCTAssertTrue(try action(review,"studio-result-favorite").accessibilityPerformPress());settle(review)
    XCTAssertTrue(f.library.asset(id:id)?.favorite==true)
    XCTAssertEqual(try Data(contentsOf:f.library.fileURL(for:asset)),bytes)
    XCTAssertTrue(try action(review,"studio-result-canvas").accessibilityPerformPress());XCTAssertEqual(canvas,[id])
    window.setContentSize(.init(width:1440,height:900));settle(host)
    for name in ["studio-image-back","studio-image-connection"] {
      let button=try action(host,name)
      XCTAssertTrue(window.convertToScreen(host.bounds).insetBy(dx:-2,dy:-2).intersects(button.accessibilityFrame()))
    }
    for name in ["studio-result-reference","studio-run-details"] {
      XCTAssertTrue(preview.convertToScreen(review.convert(review.bounds,to:nil)).intersects(try action(review,name).accessibilityFrame()))
    }
    XCTAssertTrue(try action(review,"studio-result-reference").accessibilityPerformPress());settle(host)
    XCTAssertNil(f.controller.currentRun);XCTAssertTrue(f.controller.references.contains{$0.assetID==id && $0.role == .style})
    XCTAssertEqual(f.controller.history.first{$0.id==run.id},run)
    XCTAssertEqual(f.store.project,before);XCTAssertTrue(f.store.engine.undoStack.isEmpty)
  }

  func testNativePromptPresetFillsSameEditorAndThreeColumnControlsRemainReachableAtBothWidths()async throws {
    let f=try fixture();await f.controller.captureScene()
    let source=try XCTUnwrap(f.store.project),capture=try XCTUnwrap(f.controller.capture),options=f.controller.options,style=f.controller.style
    XCTAssertTrue(capture.hasExactStudioPixels);XCTAssertEqual(options.outputPixels,capture.scene.pixels)
    let (window,host)=mount(VStack(spacing:0) {
      Color.clear.frame(height:56)
      StudioImageWorkspace(controller:f.controller,library:f.library)
    },size:.init(width:1020,height:700))
    let preset=try XCTUnwrap(f.controller.promptPresets.first)
    let editor=try XCTUnwrap(descendants(host).compactMap{$0 as? NSTextView}.first{!$0.isFieldEditor && $0.isEditable && $0.string==f.controller.prompt})
    for size in [NSSize(width:1020,height:700),.init(width:1440,height:940)] {
      window.setContentSize(size);settle(host)
      for id in ["studio-image-back","studio-image-connection","studio-image-library","studio-image-upload","studio-image-settings","studio-image-generate","studio-image-recapture"] {
        let button=try action(host,id)
        XCTAssertTrue(window.convertToScreen(host.convert(host.bounds,to:nil)).insetBy(dx:-1,dy:-1).intersects(button.accessibilityFrame()),id)
      }
      let viewport=try XCTUnwrap(editor.enclosingScrollView)
      XCTAssertGreaterThanOrEqual(viewport.bounds.height,159,"The padded 180pt prompt field retains its native text viewport.")
      XCTAssertTrue(try action(host,"studio-image-preset-"+preset.id.uuidString).accessibilityPerformPress());settle(host)
      XCTAssertEqual(f.controller.prompt,preset.prompt);XCTAssertEqual(editor.string,preset.prompt)
      XCTAssertTrue(descendants(host).contains{$0===editor},"Choosing a preset retains the composing native text editor.")
    }
    XCTAssertEqual(f.controller.capture,capture);XCTAssertEqual(f.controller.options,options);XCTAssertEqual(f.controller.style,style)
    XCTAssertTrue(f.controller.references.isEmpty);XCTAssertTrue(f.controller.history.isEmpty)
    XCTAssertEqual(f.store.project,source);XCTAssertTrue(f.store.engine.undoStack.isEmpty)
  }

  func testProductionMinimumHeightKeepsPromptAndFooterInsideWithReferenceFailureAndBusyState()async throws {
    @MainActor func check(_ host:NSView,_ id:String)throws {
      let button=try XCTUnwrap(descendants(host).compactMap{$0 as? WorkspaceToolbarNativeButton}.first{$0.accessibilityIdentifier()==id})
      let buttonRect=button.convert(button.bounds,to:host)
      XCTAssertTrue(host.bounds.insetBy(dx:-0.5,dy:-0.5).contains(buttonRect),"The entire \(id) target stays inside the 700pt production window: \(buttonRect)")
      let editor=try XCTUnwrap(descendants(host).compactMap{$0 as? NSTextView}.first{!$0.isFieldEditor})
      let viewport=try XCTUnwrap(editor.enclosingScrollView),field=viewport.convert(viewport.bounds,to:host).insetBy(dx:-10,dy:-10)
      XCTAssertGreaterThanOrEqual(viewport.bounds.height,159)
      XCTAssertTrue(host.bounds.insetBy(dx:-1,dy:-1).contains(field),"The whole 180pt prompt field remains visible: \(field)")
    }
    let f=try fixture();f.controller.connection.useDemoConnection();await f.controller.captureScene()
    f.controller.addReference(assetID:try XCTUnwrap(f.controller.capture?.inputAssetID))
    f.controller.options.failureFixture = .offline;await f.controller.generate()
    XCTAssertNotNil(f.controller.error)
    let source=try XCTUnwrap(f.store.project)
    let (window,host)=mount(VStack(spacing:0){Color.clear.frame(height:56);StudioImageWorkspace(controller:f.controller,library:f.library)},size:.init(width:1020,height:700))
    for size in [NSSize(width:1020,height:700),.init(width:1440,height:940)] {
      window.setContentSize(size);settle(host)
      try check(host,"studio-image-generate");try check(host,"studio-image-retry")
    }
    XCTAssertEqual(f.store.project,source);XCTAssertTrue(f.store.engine.undoStack.isEmpty)
    let provider=HeldProvider(),busy=try fixture(provider:provider)
    defer{provider.release()}
    busy.controller.connection.useDemoConnection();await busy.controller.captureScene()
    busy.controller.addReference(assetID:try XCTUnwrap(busy.controller.capture?.inputAssetID))
    let work=Task {await busy.controller.generate()}
    try await waitUntil{provider.entered}
    let (busyWindow,busyHost)=mount(VStack(spacing:0){Color.clear.frame(height:56);StudioImageWorkspace(controller:busy.controller,library:busy.library)},size:.init(width:1020,height:700))
    for size in [NSSize(width:1020,height:700),.init(width:1440,height:940)] {
      busyWindow.setContentSize(size);settle(busyHost);try check(busyHost,"studio-image-cancel")
    }
    provider.release();await work.value
  }

  func testNativePriorOutputPreviewKeepsUnsentPromptCaretInputAndActiveRunAndClosesOnProjectChange()async throws {
    let f=try fixture();f.controller.connection.useDemoConnection();await f.controller.captureScene()
    f.controller.prompt="First saved image";await f.controller.generate()
    let first=try XCTUnwrap(f.controller.currentRun),firstID=try XCTUnwrap(first.outputAssetIDs.first)
    f.controller.prompt="Second saved image";await f.controller.generate()
    let currentID=f.controller.selectedRunID,capture=f.controller.capture,style=f.controller.style,options=f.controller.options,references=f.controller.references
    let source=try XCTUnwrap(f.store.project),history=f.controller.history
    let (window,host)=mount(StudioImageWorkspace(controller:f.controller,library:f.library),size:.init(width:1440,height:940))
    // Corelibs XCTest finishes launching AppKit without NSApplication.run;
    // it cannot establish real application activation. Preserve its actual key
    // state here; the foreground NSApplication.run proof requires key=true.
    let keyBefore=window.isKeyWindow
    let editor=try XCTUnwrap(descendants(host).compactMap{$0 as? NSTextView}.first{!$0.isFieldEditor && $0.isEditable && $0.string==f.controller.prompt})
    XCTAssertTrue(window.makeFirstResponder(editor))
    let draft="Unsent next image prompt"
    editor.insertText(draft,replacementRange:.init(location:0,length:editor.string.utf16.count));editor.setSelectedRange(.init(location:7,length:3));settle(host)
    let caret=editor.selectedRange()
    let button=try XCTUnwrap(descendants(host).compactMap{$0 as? WorkspaceToolbarNativeButton}.first{$0.accessibilityIdentifier()=="studio-image-preview-"+firstID.uuidString})
    XCTAssertTrue(mouseClick(window,point:button.convert(.init(x:button.bounds.midX,y:button.bounds.midY),to:nil),id:"prior output preview"));settle(host)
    let expected=try f.library.fileURL(for:try XCTUnwrap(f.library.asset(id:firstID))).standardizedFileURL.resolvingSymlinksInPath()
    let visiblePreviews=NSApp.windows.filter{$0.identifier==StudioImageReviewPresenter.windowIdentifier && $0.isVisible}
    XCTAssertEqual(visiblePreviews.count,1,"There must be exactly one current preview; closed autoreleased windows are not candidates.")
    let preview=try XCTUnwrap(visiblePreviews.first{$0.representedURL?.standardizedFileURL.resolvingSymlinksInPath()==expected})
    XCTAssertTrue(preview.isVisible);XCTAssertNil(preview.sheetParent);XCTAssertNil(NSApp.modalWindow);XCTAssertEqual(window.isKeyWindow,keyBefore)
    XCTAssertTrue(window.firstResponder===editor);XCTAssertEqual(editor.selectedRange(),caret)
    XCTAssertEqual(f.controller.prompt,draft);XCTAssertEqual(f.controller.selectedRunID,currentID)
    XCTAssertEqual(f.controller.capture,capture);XCTAssertEqual(f.controller.style,style);XCTAssertEqual(f.controller.options,options)
    XCTAssertEqual(f.controller.references,references);XCTAssertEqual(f.controller.history,history)
    let represented=try XCTUnwrap(preview.representedURL).standardizedFileURL.resolvingSymlinksInPath()
    XCTAssertEqual(represented,expected)
    XCTAssertEqual(f.store.project,source);XCTAssertTrue(f.store.engine.undoStack.isEmpty)
    let another=Project(name:"Another project");try f.store.repository.save(another)
    f.store.openProject(another.id);try await waitUntil{!preview.isVisible}
    XCTAssertFalse(preview.isVisible,"A preview cannot survive its owning project.")
  }

  func testBackToCompositionLeavesSameProjectJobRunningAndFrozen()async throws {
    let provider=HeldProvider(),f=try fixture(provider:provider)
    defer{provider.release()}
    f.controller.connection.useDemoConnection();await f.controller.captureScene()
    let source=try XCTUnwrap(f.store.project)
    var back=0
    let (_,host)=mount(StudioImageWorkspace(controller:f.controller,library:f.library,onBack:{back+=1}),size:.init(width:1020,height:760))
    XCTAssertTrue(try action(host,"studio-image-generate").accessibilityPerformPress())
    try await waitUntil{provider.entered}
    XCTAssertTrue(try action(host,"studio-image-back").accessibilityPerformPress())
    XCTAssertEqual(back,1);XCTAssertTrue(f.controller.busy);XCTAssertEqual(f.controller.currentRun?.status,.running)
    provider.release();try await waitUntil{!f.controller.busy}
    XCTAssertEqual(f.controller.currentRun?.status,.succeeded);XCTAssertEqual(f.store.project,source)
  }

  func testEmptyReferenceChooserHasNativeCloseWithoutChangingTheNextFormOrProject()async throws {
    let f=try fixture(),source=try XCTUnwrap(f.store.project),prompt=f.controller.prompt
    let (window,host)=mount(StudioImageWorkspace(controller:f.controller,library:f.library),size:.init(width:1020,height:780))
    XCTAssertTrue(try action(host,"studio-image-library").accessibilityPerformPress())
    try await waitUntil{window.attachedSheet != nil}
    let sheet=try XCTUnwrap(window.attachedSheet),content=try XCTUnwrap(sheet.contentView)
    settle(content)
    let close=try XCTUnwrap(descendants(content).compactMap{$0 as? AppCloseNativeButton}.first{$0.accessibilityLabel()=="Close reference picker"})
    XCTAssertTrue(close.isEnabled);XCTAssertTrue(close.accessibilityPerformPress())
    try await waitUntil{window.attachedSheet == nil}
    XCTAssertTrue(f.controller.references.isEmpty);XCTAssertEqual(f.controller.prompt,prompt)
    XCTAssertNil(f.controller.capture);XCTAssertEqual(f.store.project,source);XCTAssertTrue(f.store.engine.undoStack.isEmpty)
  }
}
