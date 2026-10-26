import AppKit
import CryptoKit
import FormCore
import FormGraphics
import SwiftUI
import XCTest
@testable import FormApp

@MainActor final class HomeTechnicalPreviewTests:XCTestCase {
  private func fixture()throws->(ProjectRepository,Project,ProjectSummary) {
    _=NSApplication.shared
    let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);addTeardownBlock{try? FileManager.default.removeItem(at:root)}
    let repository=try ProjectRepository(root:root);var project:Project
    if let path=ProcessInfo.processInfo.environment["FORM_HOME46_FIXTURE"] {project=try repository.load(url:URL(fileURLWithPath:path))}
    else {project=Project(name:"FIELD / Native size chart");project.updatedAt=Date(timeIntervalSince1970:1_720_000_000);let owner=try project.ensureCanvasWorkspace();var block=GarmentBlock();block.body.hip=1000;project.objects[project.objects.firstIndex{$0.id==owner.id}!].artwork=try GarmentBlockCommands.preview(block)}
    try repository.save(project)
    let preview=ProjectPreview.image(project:project,size:.init(width:1000,height:650),assets:repository.url(for:project.id).appendingPathComponent("Assets"))
    try XCTUnwrap(preview.pngData()).write(to:repository.url(for:project.id).appendingPathComponent("Preview.png"))
    return(repository,project,try XCTUnwrap(repository.list().first))
  }
  private func hashes(_ root:URL)throws->[String:String] {
    var result=[String:String]();for case let url as URL in FileManager.default.enumerator(at:root,includingPropertiesForKeys:[.isRegularFileKey])! {if (try url.resourceValues(forKeys:[.isRegularFileKey])).isRegularFile==true {result[String(url.path.dropFirst(root.path.count))]=SHA256.hash(data:try Data(contentsOf:url)).map{String(format:"%02x",$0)}.joined()}};return result
  }
  private func rgba(_ image:NSImage)throws->Data {let cg=try XCTUnwrap(image.cgImage(forProposedRect:nil,context:nil,hints:nil)),c=try XCTUnwrap(CGContext(data:nil,width:cg.width,height:cg.height,bitsPerComponent:8,bytesPerRow:cg.width*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue));c.draw(cg,in:.init(x:0,y:0,width:cg.width,height:cg.height));return Data(bytes:c.data!,count:cg.width*cg.height*4)}
  private func strokeLeaf(_ art:Artwork)throws->ArtworkElement {var e=try XCTUnwrap(art.elements.first{$0.kind=="path"});e.parentID=nil;e.affine=nil;e.x=0;e.y=0;return e}
  func testAllGradeFramingSourceCameraCacheAndPhysicalOutputStayExact()async throws {
    let(repo,p,summary)=try fixture(),folder=repo.url(for:p.id),before=try hashes(folder),json=try JSONEncoder.form.encode(p),art=try XCTUnwrap(p.canvasWorkspace?.artwork),assets=folder.appendingPathComponent("Assets")
    let old=ProjectPreview.image(project:p,size:HomeTechnicalInk.size,assets:assets),originalFrame=ProjectPreview.canvasComposition(artwork:art,size:HomeTechnicalInk.size),result=HomeTechnicalInk.evaluate(art)
    let frame=try XCTUnwrap(result.composition);XCTAssertEqual(result.reason,"enhanced");XCTAssertLessThanOrEqual(result.work,50_000)
    XCTAssertEqual(frame.width,originalFrame.width);XCTAssertEqual(frame.height,originalFrame.height);XCTAssertEqual(frame.artwork.elements.filter{$0.parentID==nil}.count,3)
    for (a,b) in zip(originalFrame.artwork.elements,frame.artwork.elements) {var expected=a;expected.stroke?.width=b.stroke?.width ?? a.stroke?.width ?? 0;XCTAssertEqual(expected,b)}
    let output=try SewingPatternOutput(source:art),svg=try output.svg(assets:assets),pdf=try output.pdf(assets:assets)
    let loader=HomeTechnicalPreview(),loaded=await loader.image(for:summary),image=try XCTUnwrap(loaded);XCTAssertNotEqual(try rgba(image),try rgba(old));XCTAssertEqual(try hashes(folder),before);XCTAssertEqual(try JSONEncoder.form.encode(p),json)
    XCTAssertEqual(try SewingPatternOutput(source:art).svg(assets:assets),svg);XCTAssertEqual(p.camera,try repo.load(p.id).camera)
    if let path=ProcessInfo.processInfo.environment["FORM_HOME46_PROOF_DIR"] {let dir=URL(fileURLWithPath:path);try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true);try XCTUnwrap(old.pngData()).write(to:dir.appendingPathComponent("before-1000.png"));try XCTUnwrap(image.pngData()).write(to:dir.appendingPathComponent("after-1000.png"));try Data(svg.utf8).write(to:dir.appendingPathComponent("physical-before.svg"));try pdf.write(to:dir.appendingPathComponent("physical-before.pdf"));try Data(SewingPatternOutput(source:art).svg(assets:assets).utf8).write(to:dir.appendingPathComponent("physical-after.svg"));try SewingPatternOutput(source:art).pdf(assets:assets).write(to:dir.appendingPathComponent("physical-after.pdf"))}
  }
  func testConformalRotationReflectionAndUniformScaleKeepCenterlines()throws {
    let(_,p,_)=try fixture(),art=p.canvasWorkspace!.artwork!
    for scale in [0.5,1.0,2.0] {for flip in [false,true] {
      var e=try strokeLeaf(art);e.affine=Affine2.translation(-600,300).followed(by:.rotation(37)).followed(by:.scale(flip ? -scale:scale,scale));e.transformOrigin = .init(0.1,0.8)
      let source=Artwork(elements:[e]),base=ProjectPreview.canvasComposition(artwork:source,size:HomeTechnicalInk.size),value=try XCTUnwrap(HomeTechnicalInk.evaluate(source).composition),next=value.artwork.elements[0]
      XCTAssertEqual(next.path,base.artwork.elements[0].path);XCTAssertEqual(next.affine,base.artwork.elements[0].affine);XCTAssertEqual(next.transformOrigin,e.transformOrigin)
      XCTAssertEqual(next.stroke!.width*scale*value.density,1,accuracy:1e-8)
    }}
    var wide=try strokeLeaf(art);wide.stroke!.width=100;let legible=HomeTechnicalInk.evaluate(.init(elements:[wide]));XCTAssertNil(legible.composition);XCTAssertEqual(legible.reason,"already-legible")
  }
  func testMasksFillsHolesDashesEffectsMixedGraphicsAndNonuniformTransformsDecline()throws {
    let(_,p,_)=try fixture();let leaf=try strokeLeaf(p.canvasWorkspace!.artwork!)
    var cases=[Artwork]()
    var e=leaf;e.fillEnabled=true;cases.append(.init(elements:[e]))
    e=leaf;e.clipID=UUID();cases.append(.init(elements:[e]))
    e=leaf;e.path!.contours.append(e.path!.contours[0]);cases.append(.init(elements:[e]))
    e=leaf;e.path!.contours[0].nodes[0].outgoing = .init(10,40);cases.append(.init(elements:[e]))
    e=leaf;e.path!.contours[0].nodes.append(.init(.init(e.path!.width/2,e.path!.height/2)));cases.append(.init(elements:[e]))
    e=leaf;e.path!.contours[0].nodes = [.init(.init(0,0)),.init(.init(e.path!.width-0.001,0)),.init(.init(e.path!.width,0.001)),.init(.init(e.path!.width,e.path!.height)),.init(.init(0,e.path!.height))];cases.append(.init(elements:[e])) // subpixel bevel must not be widened into an apparent feature
    e=leaf;e.stroke!.dash=[4,2];cases.append(.init(elements:[e]))
    e=leaf;e.stroke!.alignment="inside";cases.append(.init(elements:[e]))
    e=leaf;e.opacity=0.5;cases.append(.init(elements:[e]))
    e=leaf;e.blendMode="multiply";cases.append(.init(elements:[e]))
    e=leaf;e.blur = .init();cases.append(.init(elements:[e]))
    e=leaf;e.shadow = .init();cases.append(.init(elements:[e]))
    e=leaf;e.affine = .scale(2,0.5);cases.append(.init(elements:[e]))
    e=leaf;e.affine = .init(a:1,b:0,c:0.4,d:1);cases.append(.init(elements:[e]))
    e=leaf;e.hidden=true;cases.append(.init(elements:[e]))
    cases.append(.init(elements:[leaf,ArtworkElement(kind:"rectangle",x:700,y:0)]))
    e=leaf;e.id=UUID();cases.append(.init(elements:[leaf,e])) // overlapping outlines must not merge
    for source in cases {let before=source;let result=HomeTechnicalInk.evaluate(source);XCTAssertNil(result.composition);XCTAssertEqual(source,before);XCTAssertLessThanOrEqual(result.work,50_000)}
  }
  func testWorkAndFeatureLimitsAreExplicitAndFailClosed()throws {
    let(_,p,_)=try fixture(),art=p.canvasWorkspace!.artwork!
    for budget in [0,5,40] {var limits=HomeTechnicalInk.Limits();limits.maximumWork=budget;let result=HomeTechnicalInk.evaluate(art,limits:limits);XCTAssertNil(result.composition);XCTAssertEqual(result.reason,"work-budget");XCTAssertLessThanOrEqual(result.work,budget)}
    var tiny=try strokeLeaf(art);tiny.height=0.001;XCTAssertNil(HomeTechnicalInk.evaluate(.init(elements:[tiny])).composition)
    var cycle=try strokeLeaf(art);cycle.parentID=cycle.id;XCTAssertNil(HomeTechnicalInk.evaluate(.init(elements:[cycle])).composition)
    var crowded=[ArtworkElement]();let leaf=try strokeLeaf(art)
    for i in 0..<129 {var e=leaf;e.id=UUID();e.x=Double(i)*1000;crowded.append(e)}
    XCTAssertNil(HomeTechnicalInk.evaluate(.init(elements:crowded)).composition)
    let nodes=(0..<128).map { i in let angle=Double(i)*2*Double.pi/128;return BezierNode(.init(250+250*cos(angle),250+250*sin(angle))) }
    let path=VectorPath(width:500,height:500,contours:[.init(nodes)])
    let dense=(0..<128).map {i in var e=leaf;e.id=UUID();e.width=500;e.height=500;e.x=Double(i%16)*1000;e.y=Double(i/16)*1000;e.path=path;return e}
    var limits=HomeTechnicalInk.Limits();limits.maximumWork=5000
    let stopped=HomeTechnicalInk.evaluate(.init(elements:dense),limits:limits)
    XCTAssertNil(stopped.composition);XCTAssertEqual(stopped.reason,"work-budget");XCTAssertLessThanOrEqual(stopped.work,5000)
    let bounded=HomeTechnicalInk.evaluate(.init(elements:dense));XCTAssertNil(bounded.composition);XCTAssertEqual(bounded.reason,"unsupported");XCTAssertLessThanOrEqual(bounded.work,50_000) // 128-node shapes have subpixel edges at this whole-project scale
    let separated=(0..<128).map{i in var e=leaf;e.id=UUID();e.x=Double(i%16)*1000;e.y=Double(i/16)*1000;return e}
    limits.maximumWork=4000;let spacing=HomeTechnicalInk.evaluate(.init(elements:separated),limits:limits);XCTAssertNil(spacing.composition);XCTAssertEqual(spacing.reason,"work-budget");XCTAssertLessThanOrEqual(spacing.work,4000)

  }
  func testAggregateBytesAreRejectedBeforeObjectDecodeAndManifestRacesDecline()throws {
    let(repo,_,summary)=try fixture(),manifest=summary.url.appendingPathComponent("Manifest.json"),original=try Data(contentsOf:manifest)
    let raw=try JSONSerialization.jsonObject(with:original) as! [String:Any],ref=(raw["objects"] as! [[String:Any]])[0],object=summary.url.appendingPathComponent("Objects").appendingPathComponent(ref["file"] as! String)
    var padded=original;padded.append(Data(repeating:32,count:800_000));try padded.write(to:manifest)
    try Data(repeating:65,count:1_500_000).write(to:object) // deliberately invalid JSON; size rejection must happen first
    XCTAssertThrowsError(try HomeTechnicalPreview.snapshot(summary)){error in XCTAssertEqual((error as? CocoaError)?.code,.fileReadTooLarge)}
    _=repo;try original.write(to:manifest)
    let source=try GarmentBlockCommands.preview(.init());var p=Project(name:"Race");let owner=try p.ensureCanvasWorkspace();p.objects[0].artwork=source;try repo.save(p);let row=try XCTUnwrap(repo.list().first{$0.id==p.id})
    XCTAssertThrowsError(try HomeTechnicalPreview.snapshot(row,afterActiveRead:{try Data("Changed manifest".utf8).write(to:row.url.appendingPathComponent("Manifest.json"))}))
    _=owner
  }
  func testCacheBoundedInvalidatedPurgedAndCancelledJobsCannotPublish()async throws {
    let(repo,p,summary)=try fixture(),loader=HomeTechnicalPreview(),before=try hashes(repo.url(for:p.id))
    let first=await loader.image(for:summary),second=await loader.image(for:summary);XCTAssertNotNil(first);XCTAssertNotNil(second);XCTAssertEqual(loader.renders,1);XCTAssertEqual(loader.hits,1)
    XCTAssertEqual(try hashes(repo.url(for:p.id)),before)
    var changed=p;let i=changed.objects[0].artwork!.elements.firstIndex{$0.kind=="path"}!;changed.objects[0].artwork!.elements[i].stroke!.color="#445566";try repo.save(changed)
    let refreshed=await loader.image(for:summary);XCTAssertNotNil(refreshed);XCTAssertEqual(loader.renders,2);XCTAssertEqual(loader.count,1)
    for n in 0..<9 {var copy=p;copy.id=UUID();copy.name="Study \(n)";try repo.save(copy);let s=try XCTUnwrap(repo.list().first{$0.id==copy.id});let image=await loader.image(for:s);XCTAssertNotNil(image)}
    XCTAssertLessThanOrEqual(loader.count,8);XCTAssertLessThanOrEqual(loader.retainedBytes,32*1024*1024)
    loader.retain(projectIDs:[p.id]);XCTAssertLessThanOrEqual(loader.count,1)
    let cancelled=HomeTechnicalPreview(),task=Task{await cancelled.image(for:summary)};task.cancel();let result=await task.value;XCTAssertNil(result);XCTAssertEqual(cancelled.count,0);XCTAssertEqual(cancelled.renders,0)
    print("HOME46_COST",["cold_max_ms":loader.maximumColdMs,"warm_max_ms":loader.maximumWarmMs,"last_work":loader.lastWork,"last_source_bytes":loader.lastSourceBytes,"cache_bytes":loader.retainedBytes,"main_actor_max_ms":loader.maximumMainMs])
  }
  func testLateSourceAndDeletedProjectRequestsCannotReplaceCurrentImage()async throws {
    let(repo,p,summary)=try fixture(),old=try HomeTechnicalPreview.snapshot(summary)
    var changed=p;let i=changed.objects[0].artwork!.elements.firstIndex{$0.kind=="path"}!;changed.objects[0].artwork!.elements[i].stroke!.color="#223344";try repo.save(changed)
    let fresh=try HomeTechnicalPreview.snapshot(summary),gate=HeldHomeSnapshot(old:old,fresh:fresh)
    let loader=HomeTechnicalPreview(readSnapshot:{_ in await gate.read()})
    let late=Task{await loader.image(for:summary)};await gate.waitUntilStarted()
    let current=await loader.image(for:summary);XCTAssertNotNil(current);XCTAssertEqual(loader.renders,1)
    await gate.release();let stale=await late.value;XCTAssertNil(stale);XCTAssertEqual(loader.renders,1);XCTAssertEqual(loader.count,1)
    let sameGate=HeldHomeSnapshot(old:fresh,fresh:fresh),shared=HomeTechnicalPreview(readSnapshot:{_ in await sameGate.read()})
    let earlierCard=Task{await shared.image(for:summary)};await sameGate.waitUntilStarted();let laterCard=await shared.image(for:summary);await sameGate.release();let earlierImage=await earlierCard.value
    XCTAssertNotNil(laterCard);XCTAssertNotNil(earlierImage);XCTAssertEqual(shared.renders,1);XCTAssertEqual(shared.hits,1)
    let secondGate=HeldHomeSnapshot(old:old,fresh:fresh),deleted=HomeTechnicalPreview(readSnapshot:{_ in await secondGate.read()})
    let removed=Task{await deleted.image(for:summary)};await secondGate.waitUntilStarted();deleted.retain(projectIDs:[]);await secondGate.release()
    let result=await removed.value;XCTAssertNil(result);XCTAssertEqual(deleted.count,0);XCTAssertEqual(deleted.renders,0)
  }
  func testUnsupportedAndPhysicalProjectsKeepTheirCachedPreview()async throws {
    let(repo,p,summary)=try fixture();var changed=p
    let i=changed.objects[0].artwork!.elements.firstIndex{$0.kind=="path"}!;changed.objects[0].artwork!.elements[i].fillEnabled=true;try repo.save(changed)
    let before=try hashes(summary.url),loader=HomeTechnicalPreview(),image=await loader.image(for:summary)
    XCTAssertNil(image);XCTAssertEqual(loader.renders,0);XCTAssertEqual(try hashes(summary.url),before)
    var physical=try Samples.make("merchandise");physical.id=UUID();try repo.save(physical)
    let row=try XCTUnwrap(repo.list().first{$0.id==physical.id}),ignored=await loader.image(for:row)
    XCTAssertNil(ignored);XCTAssertEqual(loader.renders,0)
  }
  func testActualNativeProjectCardAndHomeUseDisplayOnlyInkWithBoundedWarmCost()async throws {
    let(repo,p,summary)=try fixture(),before=try hashes(summary.url),store=StudioStore(repository:repo,seedLibrary:false),loader=HomeTechnicalPreview()
    let window=NSWindow(contentRect:.init(x:0,y:0,width:345,height:300),styleMask:[.titled],backing:.buffered,defer:false);window.isReleasedWhenClosed=false
    var calls=0
    let enhanced:@MainActor (ProjectSummary) async->NSImage? = {row in calls+=1;return await loader.image(for:row)}
    func card(_ provider:@escaping @MainActor (ProjectSummary) async->NSImage?)->NSHostingView<AnyView> {
      let view=NSHostingView(rootView:AnyView(ProjectCard(project:summary).environmentObject(store).environment(\.homeTechnicalImage,provider).preferredColorScheme(.light).padding(.top,1).background(Palette.paper).foregroundStyle(Palette.ink)))
      view.frame = .init(x:0,y:0,width:345,height:300);window.contentView=view;view.layoutSubtreeIfNeeded();return view
    }
    func png(_ view:NSView)throws->Data {view.layoutSubtreeIfNeeded();view.displayIfNeeded();let bitmap=try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in:view.bounds));view.cacheDisplay(in:view.bounds,to:bitmap);return try XCTUnwrap(bitmap.representation(using:.png,properties:[:]))}
    defer{window.contentView=nil;window.close()}
    let original=card({_ in nil});try await Task.sleep(nanoseconds:150_000_000);let old=try png(original)
    let updated=card(enhanced);try await Task.sleep(nanoseconds:150_000_000);let new=try png(updated)
    XCTAssertEqual(calls,1);XCTAssertEqual(loader.renders,1);XCTAssertNotEqual(old,new);XCTAssertFalse(window.isVisible)
    store.previewVersion+=1;try await Task.sleep(nanoseconds:150_000_000);let warmed=try png(updated)
    XCTAssertEqual(calls,2);XCTAssertEqual(loader.renders,1);XCTAssertEqual(loader.hits,1);XCTAssertEqual(new,warmed)
    XCTAssertNil(store.project);XCTAssertEqual(try hashes(summary.url),before);XCTAssertEqual(p.camera,try repo.load(p.id).camera)
    if let path=ProcessInfo.processInfo.environment["FORM_HOME46_PROOF_DIR"] {
      let dir=URL(fileURLWithPath:path);try old.write(to:dir.appendingPathComponent("native-card-before.png"));try new.write(to:dir.appendingPathComponent("native-card-after.png"))
      let oldHome=NSHostingView(rootView:HomeView().environmentObject(store).environment(\.homeTechnicalImage,{_ in nil}).preferredColorScheme(.light).frame(width:1280,height:980).background(Palette.paper).foregroundStyle(Palette.ink))
      window.setContentSize(.init(width:1280,height:980));window.contentView=oldHome;oldHome.frame = .init(x:0,y:0,width:1280,height:980);oldHome.layoutSubtreeIfNeeded();try await Task.sleep(nanoseconds:500_000_000)
      try png(oldHome).write(to:dir.appendingPathComponent("native-home-before.png"))
      let home=NSHostingView(rootView:HomeView().environmentObject(store).environment(\.homeTechnicalImage,enhanced).preferredColorScheme(.light).frame(width:1280,height:980).background(Palette.paper).foregroundStyle(Palette.ink))
      window.setContentSize(.init(width:1280,height:980));window.contentView=home;home.frame = .init(x:0,y:0,width:1280,height:980);home.layoutSubtreeIfNeeded();try await Task.sleep(nanoseconds:500_000_000)
      try png(home).write(to:dir.appendingPathComponent("native-home-after.png"))
      let record:[String:Any] = ["cold_max_ms":loader.maximumColdMs,"warm_max_ms":loader.maximumWarmMs,"work":loader.lastWork,"source_bytes":loader.lastSourceBytes,"cache_bytes":loader.retainedBytes,"main_actor_max_ms":loader.maximumMainMs,"render_count":loader.renders,"source_and_disk_preview_unchanged":try hashes(summary.url)==before,"hosted_window_visible":window.isVisible]
      try JSONSerialization.data(withJSONObject:record,options:[.prettyPrinted,.sortedKeys]).write(to:dir.appendingPathComponent("native-card-cost.json"))
    }
    print("HOME46_NATIVE_COST",["cold_max_ms":loader.maximumColdMs,"warm_max_ms":loader.maximumWarmMs,"work":loader.lastWork,"source_bytes":loader.lastSourceBytes,"cache_bytes":loader.retainedBytes,"main_actor_max_ms":loader.maximumMainMs])
  }

}


private actor HeldHomeSnapshot {
  let old:HomeTechnicalPreview.Snapshot,fresh:HomeTechnicalPreview.Snapshot
  var started=false,releaseContinuation:CheckedContinuation<HomeTechnicalPreview.Snapshot,Never>?,startContinuation:CheckedContinuation<Void,Never>?
  init(old:HomeTechnicalPreview.Snapshot,fresh:HomeTechnicalPreview.Snapshot){self.old=old;self.fresh=fresh}
  func read()async->HomeTechnicalPreview.Snapshot {
    if started{return fresh};started=true;startContinuation?.resume();startContinuation=nil
    return await withCheckedContinuation{releaseContinuation=$0}
  }
  func waitUntilStarted()async {if started{return};await withCheckedContinuation{startContinuation=$0}}
  func release(){releaseContinuation?.resume(returning:old);releaseContinuation=nil}
}
