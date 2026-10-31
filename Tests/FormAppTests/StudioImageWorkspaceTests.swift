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
    project.objects=[object];store.engine.project=project;store.showingHome=false;store.studioComposition.reconcile();store.studioComposition.stage.fitAll()
    let library=StudioAssetLibrary(root:directory)
    let controller=StudioImageGenerationController(store:store,library:library,provider:provider ?? LocalStudioImageGenerationProvider(delayNanoseconds:0),captureLimit:160)
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
    let asset=try XCTUnwrap(f.library.asset(id:id)),bytes=try Data(contentsOf:f.library.fileURL(for:asset))
    XCTAssertTrue(asset.isMock)
    XCTAssertTrue(try action(host,"studio-result-favorite").accessibilityPerformPress());settle(host)
    XCTAssertTrue(f.library.asset(id:id)?.favorite==true)
    XCTAssertEqual(try Data(contentsOf:f.library.fileURL(for:asset)),bytes)
    XCTAssertTrue(try action(host,"studio-result-canvas").accessibilityPerformPress());XCTAssertEqual(canvas,[id])
    window.setContentSize(.init(width:1440,height:900));settle(host)
    for name in ["studio-image-back","studio-image-connection","studio-result-reference","studio-run-details"] {
      let button=try action(host,name)
      XCTAssertTrue(window.convertToScreen(host.bounds).insetBy(dx:-2,dy:-2).intersects(button.accessibilityFrame()))
    }
    XCTAssertTrue(try action(host,"studio-result-reference").accessibilityPerformPress());settle(host)
    XCTAssertNil(f.controller.currentRun);XCTAssertTrue(f.controller.references.contains{$0.assetID==id && $0.role == .style})
    XCTAssertEqual(f.controller.history.first{$0.id==run.id},run)
    XCTAssertEqual(f.store.project,before);XCTAssertTrue(f.store.engine.undoStack.isEmpty)
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
