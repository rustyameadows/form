import AppKit
import CryptoKit
import ImageIO
import FormGeometry
import SwiftUI
import XCTest
@testable import FormApp
@testable import FormCore

private final class StudioShotFrameProbe {var frames:[String:CGRect]=[:]}

@MainActor final class StudioShotEditingTests:XCTestCase {
  private var frameProbes:[ObjectIdentifier:StudioShotFrameProbe]=[:]
  private func panelHost(_ store:StudioStore)->NSHostingView<AnyView> {
    let probe=StudioShotFrameProbe()
    let content=StudioShotsPanel(controller:store.studioShots).padding(20).background(Color(nsColor:.windowBackgroundColor))
      .environmentObject(store).overlayPreferenceValue(StudioShotControlAnchors.self){anchors in
        GeometryReader {geometry in
          let frames=anchors.mapValues{geometry[$0]}
          Color.clear.onAppear{probe.frames=frames}.onChange(of:frames){_,value in probe.frames=value}
        }.allowsHitTesting(false)
      }
    let host=NSHostingView(rootView:AnyView(content));frameProbes[ObjectIdentifier(host)]=probe;return host
  }

  func fixture()throws->StudioStore {
    _=NSApplication.shared
    let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
    addTeardownBlock{try? FileManager.default.removeItem(at:root)}
    let s=StudioStore(repository:try ProjectRepository(root:root),seedLibrary:false);var p=Project(name:"Studio proof")
    p.objects=[try p.makeObject(recipeID:"box",name:"Original product",parameters:["width":180,"depth":120,"height":100])];p.camera.viewportAspect=1.5;p.camera.distance=8
    s.engine.project=p;s.mode = .studio;s.scene=TableSceneController(store:s);s.synchronizeScene();s.studioShots.reconcile();return s
  }
  func shot(_ s:StudioStore,width:Int=480,height:Int=320)->StudioShot {
    var shot=StudioShot(name:"Hero",camera:s.project!.camera,referenceAspect:1.5);shot.pixels = .init(width:width,height:height);return shot
  }
  func imagePNG()->Data {let rep=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:64,pixelsHigh:64,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!;return rep.representation(using:.png,properties:[:])!}
  func record(_ data:Data)->[String:Any] {["png_sha256":StudioRenderFolder.hash(data),"width":64,"height":64]}
  func testExclusiveAtomicFolderRejectsAllFailuresAndDestinationRaces()throws {
    let s=try fixture(),root=s.repository.root,png=imagePNG(),r=record(png),fm=FileManager.default
    for (i,phase) in [StudioRenderFolder.Phase.pngWritten,.recordWritten,.beforeRename].enumerated() {
      let target=root.appendingPathComponent("Failure\(i).render")
      XCTAssertThrowsError(try StudioRenderFolder.write(png:png,record:r,to:target,hook:{p in if p==phase {throw FormError.invalid("Injected failure")}}));XCTAssertFalse(fm.fileExists(atPath:target.path))
    }
    let target=root.appendingPathComponent("Race.render")
    XCTAssertThrowsError(try StudioRenderFolder.write(png:png,record:r,to:target,hook:{phase in if phase == .beforeRename {try fm.createDirectory(at:target,withIntermediateDirectories:false);try Data("Keep".utf8).write(to:target.appendingPathComponent("owner.txt"))}}))
    XCTAssertEqual(try Data(contentsOf:target.appendingPathComponent("owner.txt")),Data("Keep".utf8))
    XCTAssertThrowsError(try StudioRenderFolder.write(png:png,record:r,to:target));XCTAssertEqual(try fm.contentsOfDirectory(atPath:target.path),["owner.txt"])
    let invalid=root.appendingPathComponent("Invalid.render");var bad=r;bad["width"]=200;XCTAssertThrowsError(try StudioRenderFolder.write(png:png,record:bad,to:invalid));XCTAssertFalse(fm.fileExists(atPath:invalid.path))
    XCTAssertFalse(try fm.contentsOfDirectory(atPath:root.path).contains{$0.hasPrefix(".form-shot-")})
  }
  func testSavedExportIsPhysicalPixelsPortableRecordAndLeavesSourceAndCameraExact()async throws {
    let s=try fixture(),before=s.project!,viewBuilds=s.scene!.geometryBuilds,shot=shot(s)
    let folder=s.repository.root.appendingPathComponent("Hero.render"),url=try await s.studioShots.export(shot,to:folder)
    let data=try Data(contentsOf:url),source=try XCTUnwrap(CGImageSourceCreateWithData(data as CFData,nil)),props=try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any]),record=try JSONSerialization.jsonObject(with:Data(contentsOf:folder.appendingPathComponent("render.json"))) as! [String:Any]
    XCTAssertEqual(props[kCGImagePropertyPixelWidth] as? Int,480);XCTAssertEqual(props[kCGImagePropertyPixelHeight] as? Int,320)
    XCTAssertEqual(record["presentation_renderer_version"] as? Int,2);XCTAssertNotNil(record["os_version"] as? String);XCTAssertEqual(record["png_sha256"] as? String,StudioRenderFolder.hash(data));XCTAssertEqual(record["design_sha256"] as? String,try before.studioDesignDigest());XCTAssertEqual(record["included_object_ids"] as? [String],[before.objects[0].id.uuidString])
    let json=String(decoding:try Data(contentsOf:folder.appendingPathComponent("render.json")),as:UTF8.self);XCTAssertFalse(json.contains("/Users/"));XCTAssertFalse(json.contains(s.repository.root.path))
    XCTAssertEqual(s.project,before);XCTAssertTrue(s.engine.undoStack.isEmpty);XCTAssertEqual(s.scene!.geometryBuilds,viewBuilds)
    let second=s.repository.root.appendingPathComponent("Same.render");_=try await s.studioShots.export(shot,to:second);XCTAssertEqual(s.studioShots.renderer.geometryBuilds,1)
  }
  func testConcurrentStudioCapturesKeepTheirOwnFramingWarnings()async throws {
    let store=try fixture(),project=store.project!,renderer=store.studioShots.renderer
    let normal=shot(store),assets=store.repository.url(for:project.id).appendingPathComponent("Assets")
    var outside=normal;outside.camera.target.x+=100_000
    let first=Task {try await renderer.renderResult(project:project,shot:normal,assets:assets,preview:true)}
    let second=Task {try await renderer.renderResult(project:project,shot:outside,assets:assets,preview:true)}
    let visible=try await first.value,offscreen=try await second.value
    XCTAssertTrue(visible.framingWarnings.isEmpty)
    XCTAssertEqual(offscreen.framingWarnings.count,1)
    XCTAssertEqual(offscreen.framingWarnings.first?["object_id"] as? String,project.objects[0].id.uuidString)
    XCTAssertEqual(store.project,project)
  }
  func testPerspectiveAndOrthographicPreviewMatchOutputWithoutLiveFramingMutation()async throws {
    let s=try fixture(),before=s.project!,render=s.studioShots.renderer
    for projection in ["perspective","orthographic"] {for pixels in [StudioPixels(width:450,height:300),.init(width:300,height:450),.init(width:900,height:300)] {
      var shot=shot(s);shot.camera.projection=projection;shot.pixels=pixels
      let small=try await render.render(project:before,shot:shot,assets:s.repository.url(for:before.id).appendingPathComponent("Assets"),preview:true)
      let full=try await render.render(project:before,shot:shot,assets:s.repository.url(for:before.id).appendingPathComponent("Assets"),preview:false)
      XCTAssertEqual(small.pngData(),full.pngData());XCTAssertEqual(s.project,before)
    }}
    XCTAssertEqual(render.geometryBuilds,1);XCTAssertGreaterThan(render.maximumProcessRSSBytes,0);XCTAssertGreaterThan(render.maximumMilliseconds,0)
  }
  func testRecallDoesNotAddHistoryAndResizedReferenceViewportKeepsPose()throws {
    let s=try fixture();s.studioShots.name="Reference";try s.studioShots.save(capture:true)
    let saved=s.project!,id=saved.studioPresentation!.shots[0].id
    XCTAssertNil(s.studioShots.referenceAspect);try s.studioShots.recall(id)
    XCTAssertEqual(s.studioShots.referenceAspect,1.5);XCTAssertEqual(s.engine.undoStack.count,1)
    let frame=NSWindow(contentRect:.init(x:-10000,y:-10000,width:1300,height:900),styleMask:[.titled],backing:.buffered,defer:false);frame.isReleasedWhenClosed=false
    let host=NSHostingView(rootView:StudioFramedTable(controller:s.studioShots).environmentObject(s));frame.contentView=host;frame.orderBack(nil);defer{frame.close()}
    let original=s.project!.camera
    for size in [NSSize(width:1300,height:900),NSSize(width:800,height:800),NSSize(width:1600,height:700),NSSize(width:1300,height:900)] {
      frame.setContentSize(size);host.layoutSubtreeIfNeeded();RunLoop.main.run(until:Date().addingTimeInterval(0.03));host.layoutSubtreeIfNeeded()
      XCTAssertEqual(s.scene!.camera.target,original.target);XCTAssertEqual(s.scene!.camera.distance,original.distance);XCTAssertEqual(s.scene!.view!.bounds.width/s.scene!.view!.bounds.height,1.5,accuracy:0.01)
    }
    XCTAssertEqual(s.project!.objects,saved.objects);XCTAssertEqual(s.project!.history,saved.history)
    s.scene!.preset("front");XCTAssertNil(s.studioShots.referenceAspect);XCTAssertEqual(s.scene!.camera.projection,"orthographic")
    let once=s.scene!.camera
    host.layoutSubtreeIfNeeded();RunLoop.main.run(until:Date().addingTimeInterval(0.03));s.scene!.preset("front")
    XCTAssertEqual(s.scene!.camera.distance,once.distance,accuracy:1e-9,"Leaving review must settle the ordinary viewport before unchanged preset framing.")
  }
  func testStalePreviewJobsAreDiscardedAcrossSourceAndProjectChanges()async throws {
    let s=try fixture(),c=s.studioShots;c.name="Preview";c.width="600";c.height="400"
    c.requestPreview();s.engine.project!.objects[0].name="Changed source"
    await Task.yield();await Task.yield();try await Task.sleep(nanoseconds:100_000_000)
    XCTAssertNil(c.preview);XCTAssertGreaterThan(c.staleResults,0)
    c.requestPreview();s.engine.project=Project(name:"Other project");c.reconcile()
    await Task.yield();await Task.yield();XCTAssertNil(c.preview);XCTAssertEqual(c.cacheBytes,0)
  }
  func testMissingVisibleSourceAndRuntimeClothRejectWithoutResetOrMutation()throws {
    let s=try fixture();var shot=shot(s);shot.visibility = .init(mode:.objects,objectIDs:[UUID()]);XCTAssertThrowsError(try s.studioShots.runtimePreflight(s.project!,shot))
    var p=s.project!,cloth=try p.makeObject(recipeID:"clothPanel");cloth.cloth!.settings.frameStepSeconds=1/60;p.objects.append(cloth);s.engine.project=p
    try s.cloth.activate(cloth.id);try s.cloth.preview.stepImmediately(frames:1)
    let frame=s.cloth.preview.frame!,source=s.project!;shot=StudioShot(name:"Cloth",camera:source.camera,referenceAspect:1.5)
    XCTAssertThrowsError(try s.studioShots.runtimePreflight(source,shot));XCTAssertThrowsError(try s.engine.call("form_set_view",arguments:["view":"studio","studio_command":"capture"]));XCTAssertEqual(s.cloth.preview.frame,frame);XCTAssertEqual(s.project,source)
    shot.visibility = .init(mode:.objects,objectIDs:[source.objects[0].id]);XCTAssertNoThrow(try s.studioShots.runtimePreflight(source,shot))
  }
}

extension StudioShotEditingTests {
  private func descendants<T:NSView>(_ view:NSView,_ type:T.Type)->[T] {([view as? T].compactMap{$0})+view.subviews.flatMap{descendants($0,type)}}
  private func enter(_ text:String,placeholder:String,window:NSWindow,host:NSView)throws {
    let field=try XCTUnwrap(descendants(host,NSTextField.self).first{$0.isEditable && $0.placeholderString==placeholder})
    window.makeFirstResponder(field);let editor=try XCTUnwrap(window.firstResponder as? NSTextView)
    editor.selectAll(nil);editor.insertText(text,replacementRange:.init(location:NSNotFound,length:0));RunLoop.main.run(until:Date().addingTimeInterval(0.02))
  }
  private func click(_ title:String,window:NSWindow,host:NSView)throws {
    let point:NSPoint
    if let button=descendants(host,NSButton.self).first(where:{$0.title==title}) {point=button.convert(.init(x:button.bounds.midX,y:button.bounds.midY),to:nil)}
    else {
      // Read actual rendered button bounds; observations never invoke actions.
      host.layoutSubtreeIfNeeded();RunLoop.main.run(until:Date().addingTimeInterval(0.02))
      let key=["Capture shot":"capture","Update":"update","Export shot folder (PNG + record)":"export"][title] ?? title
      let frame=try XCTUnwrap(frameProbes[ObjectIdentifier(host)]?.frames[key],"Missing rendered button bounds: \(title)")
      XCTAssertGreaterThan(frame.width,0);XCTAssertGreaterThan(frame.height,0)
      let widthAnchor=try XCTUnwrap(frameProbes[ObjectIdentifier(host)]?.frames["width"])
      let widthField=try XCTUnwrap(descendants(host,NSTextField.self).first{$0.placeholderString=="Width"})
      let native=widthField.convert(widthField.bounds,to:host),sign:CGFloat=host.isFlipped ? 1:-1
      // Anchor differences avoid transient hosting-root origin changes as its
      // intrinsic height settles. Both anchors share the same geometry epoch.
      point=host.convert(.init(x:native.midX+frame.midX-widthAnchor.midX,y:native.midY+sign*(frame.midY-widthAnchor.midY)),to:nil)
    }
    let t=ProcessInfo.processInfo.systemUptime
    let down=try XCTUnwrap(NSEvent.mouseEvent(with:.leftMouseDown,location:point,modifierFlags:[],timestamp:t,windowNumber:window.windowNumber,context:nil,eventNumber:1,clickCount:1,pressure:1))
    let up=try XCTUnwrap(NSEvent.mouseEvent(with:.leftMouseUp,location:point,modifierFlags:[],timestamp:t+0.01,windowNumber:window.windowNumber,context:nil,eventNumber:2,clickCount:1,pressure:0))
    NSApp.postEvent(up,atStart:false);NSApp.sendEvent(down);NSApp.sendEvent(up);RunLoop.main.run(until:Date().addingTimeInterval(0.03))
  }
  func testActualMouseCaptureAndExportCommitActivePixelDraftWithoutExtraUndo()async throws {
    let s=try fixture(),c=s.studioShots
    let window=NSWindow(contentRect:.init(x:-10000,y:-10000,width:264,height:780),styleMask:[.titled],backing:.buffered,defer:false);window.isReleasedWhenClosed=false
    let host=panelHost(s);window.contentView=host;window.orderBack(nil);window.makeKey();host.layoutSubtreeIfNeeded();RunLoop.main.run(until:Date().addingTimeInterval(0.05));defer{window.close()}
    try enter("640",placeholder:"Width",window:window,host:host)
    try click("Capture shot",window:window,host:host)
    let captured=try XCTUnwrap(s.project?.studioPresentation?.shots.first,"The actual Capture mouse event must save a shot.")
    XCTAssertNil(c.error);XCTAssertEqual(captured.pixels.width,640);XCTAssertEqual(s.engine.undoStack.count,1);XCTAssertNil(c.referenceAspect)
    let saved=s.project!,count=s.engine.undoStack.count
    try enter("512",placeholder:"Width",window:window,host:host)
    c.exportDestination={_ in s.repository.root.appendingPathComponent("Native.render")}
    try click("Export shot folder (PNG + record)",window:window,host:host)
    for _ in 0..<200 where c.lastExport==nil && c.error==nil {try await Task.sleep(nanoseconds:10_000_000)}
    XCTAssertNil(c.error);let url=try XCTUnwrap(c.lastExport),data=try Data(contentsOf:url),source=try XCTUnwrap(CGImageSourceCreateWithData(data as CFData,nil))
    let props=CGImageSourceCopyPropertiesAtIndex(source,0,nil) as! [CFString:Any];XCTAssertEqual(props[kCGImagePropertyPixelWidth] as? Int,512)
    XCTAssertEqual(s.project,saved);XCTAssertEqual(s.engine.undoStack.count,count)
    if let path=ProcessInfo.processInfo.environment["FORM_STUDIO_PROOF_DIR"] {
      let folder=URL(fileURLWithPath:path);try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
      host.layoutSubtreeIfNeeded();let bitmap=try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in:host.bounds));host.cacheDisplay(in:host.bounds,to:bitmap)
      try XCTUnwrap(bitmap.representation(using:.png,properties:[:])).write(to:folder.appendingPathComponent("native-active-field-panel.png"))
    }
    s.engine.undo();XCTAssertNil(s.project!.studioPresentation)
  }
  func testReadOnlyShotInspectionPreservesNativeDraftCaretAndDoesNotOpenStudio()throws {
    let s=try fixture();_=try s.engine.call("form_set_view",arguments:["view":"studio","studio_command":"capture"]);let id=s.project!.studioPresentation!.shots[0].id
    let c=s.studioShots,window=NSWindow(contentRect:.init(x:-10000,y:-10000,width:264,height:780),styleMask:[.titled],backing:.buffered,defer:false);window.isReleasedWhenClosed=false
    let host=panelHost(s);window.contentView=host;window.orderBack(nil);window.makeKey();host.layoutSubtreeIfNeeded();RunLoop.main.run(until:Date().addingTimeInterval(0.04));defer{window.close()}
    try enter("789",placeholder:"Width",window:window,host:host);let editor=try XCTUnwrap(window.firstResponder as? NSTextView);editor.setSelectedRange(.init(location:1,length:1));let selected=editor.selectedRange(),p=s.project!
    for op in ["list","get"] {_=try s.engine.call("form_set_view",arguments:["view":"studio","studio_command":op,"shot_id":id.uuidString])}
    XCTAssertTrue(window.firstResponder === editor);XCTAssertEqual(editor.selectedRange(),selected);XCTAssertEqual(editor.string,"789");XCTAssertEqual(s.project,p)
  }
}

extension StudioShotEditingTests {
  private func redBounds(_ image:NSImage)throws->[Double] {
    let cg=try XCTUnwrap(image.cgImage(forProposedRect:nil,context:nil,hints:nil)),w=cg.width,h=cg.height
    let context=try XCTUnwrap(CGContext(data:nil,width:w,height:h,bitsPerComponent:8,bytesPerRow:w*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue));context.draw(cg,in:.init(x:0,y:0,width:w,height:h))
    let bytes=context.data!.assumingMemoryBound(to:UInt8.self);var lowX=w,lowY=h,highX=0,highY=0
    for y in 0..<h {for x in 0..<w {let i=(y*w+x)*4,r=Int(bytes[i]),g=Int(bytes[i+1]),b=Int(bytes[i+2]);if r>40 && r*10>g*13 && r*10>b*13 {lowX=min(lowX,x);lowY=min(lowY,y);highX=max(highX,x);highY=max(highY,y)}}}
    XCTAssertLessThan(lowX,highX);return [Double(lowX)/Double(w),Double(lowY)/Double(h),Double(highX)/Double(w),Double(highY)/Double(h)]
  }
  func testLargePreviewCompositionAndLegacyDefaultPixelsAgreeOnActualRenderedProduct()async throws {
    let s=try fixture();s.engine.project!.objects[0].color="#D7444D";s.synchronizeScene();let original=s.project!
    var shot=shot(s,width:3000,height:2000)
    for pixels in [StudioPixels(width:3000,height:2000),.init(width:2000,height:3000),.init(width:3000,height:1500)] {
      shot.pixels=pixels
      let preview=try await s.studioShots.renderer.render(project:original,shot:shot,assets:s.repository.root,preview:true),full=try await s.studioShots.renderer.render(project:original,shot:shot,assets:s.repository.root,preview:false)
      XCTAssertLessThanOrEqual(preview.representations[0].pixelsWide*preview.representations[0].pixelsHigh,2_000_000)
      let a=try redBounds(preview),b=try redBounds(full);for i in a.indices {XCTAssertEqual(a[i],b[i],accuracy:0.002)}
      if pixels.width==3000 && pixels.height==2000 {
        let url=s.repository.root.appendingPathComponent("Legacy.png");_=try await s.exportAsync(format:"png",arguments:["path":url.path])
        let legacy=try XCTUnwrap(NSImage(contentsOf:url));XCTAssertEqual(legacy.representations[0].pixelsWide,3000);XCTAssertEqual(legacy.representations[0].pixelsHigh,2000)
        XCTAssertEqual(try redBounds(legacy),b)
      }
    }
    XCTAssertEqual(s.project,original);XCTAssertEqual(s.engine.undoStack.count,0)
    print("STUDIO43_MEASURED_COST",s.studioShots.diagnostics)
  }
  func testActualMerchandiseLightingProofAndDependencyHashAreSourcePreserving()async throws {
    let s=try fixture();var p=try Samples.merchandiseCollection();p.camera.viewportAspect=1.5;s.engine.project=p;s.studioShots.reconcile()
    var shot=StudioShot(name:"ORBITAL collection",camera:p.camera,referenceAspect:1.5);shot.pixels = .init(width:1200,height:800)
    shot.visibility = .init(mode:.objects,objectIDs:p.objects.filter{$0.recipeID != "artboard" && !$0.isCanvasWorkspace}.map(\.id))
    let assets=s.repository.url(for:p.id).appendingPathComponent("Assets"),resources=try StudioShotRenderer.resources(project:p,assets:assets)
    XCTAssertTrue(resources.allSatisfy{!($0["id"] ?? "").contains("/") || ($0["id"] ?? "").hasPrefix("asset:")})
    var images=[Data]()
    for light in StudioShot.lightingIDs {
      shot.lighting=light;let image=try await s.studioShots.renderer.render(project:p,shot:shot,assets:assets,preview:false),data=try StudioPNG.encode(image,designDigest:p.studioDesignDigest());images.append(data)
      if let path=ProcessInfo.processInfo.environment["FORM_STUDIO_PROOF_DIR"] {let folder=URL(fileURLWithPath:path);try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true);try data.write(to:folder.appendingPathComponent("merchandise-"+light+".png"));let render=s.repository.root.appendingPathComponent(light+".render");let output=try await s.studioShots.export(shot,to:render);try FileManager.default.copyItem(at:render,to:folder.appendingPathComponent(light+".render"));XCTAssertTrue(FileManager.default.fileExists(atPath:output.path))}
    }
    XCTAssertEqual(Set(images.map{StudioRenderFolder.hash($0)}).count,3);XCTAssertEqual(s.project,p)
    print("STUDIO43_MERCHANDISE_COST",s.studioShots.diagnostics)
  }
  func testPartialStagedFileAndForeignStageNeverDamageExistingContent()throws {
    let s=try fixture(),root=s.repository.root,png=imagePNG(),target=root.appendingPathComponent("Partial.render"),foreign=root.appendingPathComponent(".form-shot-foreign.stage")
    try FileManager.default.createDirectory(at:foreign,withIntermediateDirectories:false);try Data("Keep".utf8).write(to:foreign.appendingPathComponent("mine"))
    XCTAssertThrowsError(try StudioRenderFolder.write(png:png,record:record(png),to:target,hook:{phase in
      if phase == .pngWritten {let stage=try FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:nil).first{$0.lastPathComponent.hasPrefix(".form-shot-") && $0.lastPathComponent != foreign.lastPathComponent}!;let image=stage.appendingPathComponent("Partial.png");try png.prefix(20).write(to:image)}
    }))
    XCTAssertFalse(FileManager.default.fileExists(atPath:target.path));XCTAssertEqual(try Data(contentsOf:foreign.appendingPathComponent("mine")),Data("Keep".utf8))
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:root.path).filter{$0.hasPrefix(".form-shot-")},[foreign.lastPathComponent])
  }
}

extension StudioShotEditingTests {
  func testPreviewCacheIsBoundedDependencyAwareAndPurgedOnDelete()async throws {
    let s=try fixture(),c=s.studioShots;c.name="Cache";c.width="640";c.height="480";try c.save(capture:true)
    let id=s.project!.studioPresentation!.shots[0].id;try c.recall(id)
    func settle()async throws {for _ in 0..<100 {await Task.yield();if !c.busy{return};try await Task.sleep(nanoseconds:10_000_000)};XCTFail("Preview did not settle")}
    try await settle();XCTAssertNotNil(c.preview);let renders=c.renderer.renders
    c.requestPreview();try await settle();XCTAssertEqual(c.renderer.renders,renders)
    let assets=s.repository.url(for:s.project!.id).appendingPathComponent("Assets");try FileManager.default.createDirectory(at:assets,withIntermediateDirectories:true)
    try Data("Resource revision".utf8).write(to:assets.appendingPathComponent("revision.txt"));c.requestPreview();try await settle();XCTAssertEqual(c.renderer.renders,renders+1)
    for i in 0..<10 {c.width=String(640+i*16);c.requestPreview();try await settle()}
    XCTAssertLessThanOrEqual(c.diagnostics["preview_cache_count"] as! Int,8);XCTAssertLessThanOrEqual(c.cacheBytes,32*1024*1024);XCTAssertEqual(c.renderer.geometryBuilds,1)
    c.width="800";XCTAssertNil(c.preview);c.requestPreview();try await settle();XCTAssertNotNil(c.preview)
    s.cameraChanged();XCTAssertNil(c.preview);c.requestPreview();try await settle()
    s.engine.project!.objects[0].name="New source revision";c.reconcile();XCTAssertNil(c.preview)
    try c.delete(id);XCTAssertNil(c.referenceAspect);XCTAssertEqual(c.cacheBytes,0)
  }
}

extension StudioShotEditingTests {
  func testMouseUpdateUsesActiveFieldAsOneUndoAutosavesAndInvalidDraftRollsBack()throws {
    let s=try fixture(),c=s.studioShots;c.width="640";c.height="480";try c.save(capture:true);let id=s.project!.studioPresentation!.shots[0].id;try c.recall(id)
    let window=NSWindow(contentRect:.init(x:-10000,y:-10000,width:264,height:850),styleMask:[.titled],backing:.buffered,defer:false);window.isReleasedWhenClosed=false
    let host=panelHost(s);window.contentView=host;window.orderBack(nil);window.makeKey();host.layoutSubtreeIfNeeded();RunLoop.main.run(until:Date().addingTimeInterval(0.05));defer{window.close()}
    let before=s.project!,history=s.engine.undoStack.count
    try enter("720",placeholder:"Width",window:window,host:host);try click("Update",window:window,host:host)
    XCTAssertNil(c.error);XCTAssertEqual(s.project!.studioPresentation!.shots[0].pixels.width,720);XCTAssertEqual(s.engine.undoStack.count,history+1);XCTAssertEqual(s.project!.objects,before.objects)
    RunLoop.main.run(until:Date().addingTimeInterval(0.4));let disk=try s.repository.load(before.id);XCTAssertEqual(disk.studioPresentation,s.project!.studioPresentation)
    if let path=ProcessInfo.processInfo.environment["FORM_STUDIO_PROOF_DIR"] {
      host.layoutSubtreeIfNeeded();let rep=try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in:host.bounds));host.cacheDisplay(in:host.bounds,to:rep)
      try XCTUnwrap(rep.representation(using:.png,properties:[:])).write(to:URL(fileURLWithPath:path).appendingPathComponent("native-recalled-panel.png"))
    }
    let valid=s.project!
    try enter("3.5",placeholder:"Width",window:window,host:host);try click("Update",window:window,host:host)
    XCTAssertNotNil(c.error);XCTAssertEqual(c.width,"3.5");XCTAssertEqual(s.project,valid);XCTAssertEqual(s.engine.undoStack.count,history+1)
    s.engine.undo();XCTAssertEqual(s.project!.studioPresentation,before.studioPresentation);XCTAssertEqual(s.project!.objects,before.objects)
  }
}

extension StudioShotEditingTests {
  func testMissingSubjectsRemainEditableDeletableAndRepairableWithoutCameraFallback()throws {
    let s=try fixture();var p=s.project!,other=try p.makeObject(recipeID:"box",name:"Independent surviving product");other.position.x=400;p.objects.append(other);s.engine.project=p
    let subject=p.objects[0].id
    _=try s.engine.call("form_set_view",arguments:["view":"studio","studio_command":"capture","name":"Missing subject","visibility":["mode":"objects","objectIDs":[subject.uuidString]]])
    let id=s.project!.studioPresentation!.shots[0].id
    try s.engine.edit("Deleted original subject"){$0.objects.removeAll{$0.id==subject}}
    let original=s.project!,camera=s.scene!.camera,c=s.studioShots
    XCTAssertThrowsError(try c.recall(id));XCTAssertNil(c.referenceAspect);XCTAssertNil(c.reviewingID);XCTAssertEqual(c.editingID,id);XCTAssertEqual(c.subjectSummary,"0 of 1 saved objects present.")
    XCTAssertEqual(s.project,original);XCTAssertEqual(s.scene!.camera,camera);XCTAssertNil(c.preview)
    c.name="Repair this source link";try c.rename(id);XCTAssertEqual(s.project!.objects,original.objects)
    try c.delete(id);XCTAssertNil(s.project!.studioPresentation);XCTAssertEqual(s.project!.objects,original.objects)
    s.engine.undo();XCTAssertThrowsError(try c.recall(id));XCTAssertEqual(c.editingID,id)
    c.visibilityMode="project";try c.save(capture:false)
    let fixed=s.project!.studioPresentation!.shots[0];XCTAssertEqual(fixed.id,id);XCTAssertEqual(fixed.visibility.mode,.project);XCTAssertEqual(s.project!.objects,original.objects)
    XCTAssertNil(c.referenceAspect);XCTAssertEqual(s.scene!.camera.target,camera.target);XCTAssertEqual(s.scene!.camera.distance,camera.distance)
  }
}


extension StudioShotEditingTests {
  func testRecallRejectsUnknownArgumentsBeforeChangingCameraOrWorkingDraft() throws {
    let store = try fixture()
    _ = try store.engine.call("form_set_view", arguments: ["view": "studio", "studio_command": "capture", "name": "Saved reference"])
    let id = store.project!.studioPresentation!.shots[0].id
    store.studioShots.name = "Keep this unsaved draft"
    store.studioShots.width = "777"
    store.mode = .artwork
    let before = store.project!, camera = store.scene!.camera, undoCount = store.engine.undoStack.count
    for extra: [String: Any] in [["width": 640, "height": 480], ["visibility": ["mode": "project"]], ["unexpected": true]] {
      let arguments: [String: Any] = ["view": "studio", "studio_command": "recall", "shot_id": id.uuidString]
      XCTAssertThrowsError(try store.engine.call("form_set_view", arguments: arguments.merging(extra) { _, value in value }))
      XCTAssertEqual(store.project, before)
      XCTAssertEqual(store.scene!.camera, camera)
      XCTAssertEqual(store.mode, .artwork)
      XCTAssertEqual(store.studioShots.name, "Keep this unsaved draft")
      XCTAssertEqual(store.studioShots.width, "777")
      XCTAssertNil(store.studioShots.referenceAspect)
      XCTAssertEqual(store.engine.undoStack.count, undoCount)
    }
  }
}


extension StudioShotEditingTests {
  func testNativeCaptureSelectsNewDefinitionAndUndoSynchronizesOnlyCleanOptions() throws {
    let store=try fixture(),controller=store.studioShots,source=store.project!
    controller.name="First";controller.width="640";try controller.save(capture:true)
    let first=try XCTUnwrap(controller.editingID)
    XCTAssertNil(controller.referenceAspect)
    controller.name="Second";controller.width="777";try controller.save(capture:true)
    let second=try XCTUnwrap(controller.editingID)
    XCTAssertNotEqual(first,second);XCTAssertNil(controller.referenceAspect)
    controller.width="901";try controller.save(capture:false)
    XCTAssertEqual(store.project!.studioPresentation!.shots.first{$0.id==first}?.pixels.width,640)
    XCTAssertEqual(store.project!.studioPresentation!.shots.first{$0.id==second}?.pixels.width,901)
    store.engine.undo();controller.reconcile()
    XCTAssertEqual(controller.width,"777")
    store.engine.redo();controller.reconcile()
    XCTAssertEqual(controller.width,"901")
    controller.width="999.5";store.engine.undo();controller.reconcile()
    XCTAssertEqual(controller.width,"999.5","An independent unsaved/invalid field must survive document Undo.")
    XCTAssertEqual(store.project!.studioPresentation!.shots.first{$0.id==second}?.pixels.width,777)
    XCTAssertEqual(store.project!.objects,source.objects);XCTAssertEqual(store.project!.camera,source.camera)
  }
  func testCaptureAndMetadataUndoNeverRecallOrRetargetAnExistingReferenceFrame() throws {
    let store=try fixture(),controller=store.studioShots
    controller.name="Reference";try controller.save(capture:true)
    let original=try XCTUnwrap(controller.editingID);try controller.recall(original)
    let before=store.project!,camera=store.scene!.camera
    controller.name="Independent";controller.width="777";try controller.save(capture:true)
    let independent=try XCTUnwrap(controller.editingID)
    XCTAssertNotEqual(original,independent)
    XCTAssertEqual(controller.reviewingID,original);XCTAssertEqual(controller.referenceAspect,1.5)
    XCTAssertEqual(store.scene!.camera,camera)
    store.engine.undo();controller.reconcile()
    XCTAssertNil(controller.editingID);XCTAssertEqual(controller.reviewingID,original)
    XCTAssertEqual(controller.referenceAspect,1.5);XCTAssertEqual(store.project,before)
    XCTAssertEqual(store.scene!.camera,camera)
    store.engine.redo();controller.reconcile();try controller.recall(independent)
    _=try store.engine.call("form_set_view",arguments:["view":"studio","studio_command":"delete","shot_id":independent.uuidString])
    controller.reconcile();XCTAssertNil(controller.editingID);XCTAssertNil(controller.reviewingID)
    XCTAssertNil(controller.referenceAspect);XCTAssertEqual(store.scene!.camera,camera)
  }
}


extension StudioShotEditingTests {
  func testHistoryReconciliationPreservesActualFocusedEditorBeforeItsBindingUpdates() throws {
    let store=try fixture(),controller=store.studioShots
    controller.name="Focused draft";controller.width="777";controller.height="555";try controller.save(capture:true)
    controller.width="901";controller.height="601";try controller.save(capture:false)
    let window=NSWindow(contentRect:.init(x:-10000,y:-10000,width:320,height:850),styleMask:[.titled],backing:.buffered,defer:false)
    window.isReleasedWhenClosed=false
    let host=panelHost(store)
    window.contentView=host;window.orderBack(nil);window.makeKey();host.layoutSubtreeIfNeeded()
    RunLoop.main.run(until:Date().addingTimeInterval(0.03));defer{window.close()}
    let field=try XCTUnwrap(descendants(host,NSTextField.self).first{$0.placeholderString=="Width"})
    window.makeFirstResponder(field)
    let editor=try XCTUnwrap(window.firstResponder as? NSTextView)
    XCTAssertTrue(editor.isFieldEditor)
    editor.string="3.5";editor.setSelectedRange(.init(location:1,length:1))
    XCTAssertEqual(controller.width,"901","This fixture deliberately leaves the binding behind the field editor.")
    let camera=store.project!.camera
    store.engine.undo();controller.reconcile()
    XCTAssertTrue(window.firstResponder === editor)
    XCTAssertEqual(editor.string,"3.5");XCTAssertEqual(editor.selectedRange(),.init(location:1,length:1))
    XCTAssertEqual(controller.width,"901");XCTAssertEqual(controller.height,"601")
    controller.width=editor.string;window.makeFirstResponder(nil);controller.reconcile()
    XCTAssertEqual(controller.width,"3.5");XCTAssertEqual(controller.height,"555")
    XCTAssertEqual(store.project!.studioPresentation!.shots[0].pixels,.init(width:777,height:555))
    XCTAssertEqual(store.project!.camera,camera)
  }
}
