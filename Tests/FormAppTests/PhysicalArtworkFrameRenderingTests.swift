import AppKit
import FormCore
import FormGeometry
import FormGraphics
import LabRendering
import MetalKit
import simd
import XCTest
@testable import FormApp

@MainActor final class PhysicalArtworkFrameRenderingTests:XCTestCase {
  private func fixture() throws -> (StudioStore,UUID,UUID) {
    _ = NSApplication.shared
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("inside-frame-render-"+UUID().uuidString)
    let store=StudioStore(repository:try ProjectRepository(root:root),seedLibrary:false)
    store.engine.project=Project(name:"Registered inside face")
    let definition=PlanarConstructionDefinition(name:"Asymmetric shared sheet",size:.init(70,40),panels:[
      .init(id:"front",name:"Front",polygon:[.init(0,0),.init(40,0),.init(40,40),.init(0,40)]),
      .init(id:"wing",name:"Wing",polygon:[.init(40,0),.init(70,0),.init(40,40)])],
      hinges:[.init(id:"crease",parentPanelID:"front",childPanelID:"wing",start:.init(40,0),end:.init(40,40),angleDegrees:90)],rootPanelID:"front")
    let created=try XCTUnwrap(store.engine.call("form_construction",arguments:["command":"create","definition":try jsonObject(definition)]) as? [String:Any])
    let id=try XCTUnwrap(UUID(uuidString:try XCTUnwrap(created["object_id"] as? String)))
    _ = try store.engine.call("form_construction",arguments:["command":"parameter","object_id":id.uuidString,"values":["fold":0]])
    _ = try store.engine.call("form_paper",arguments:["command":"ensure_inside","object_id":id.uuidString])
    let inside=try XCTUnwrap(store.project?.objects.first{$0.id==id}?.paperConstruction?.insideArtworkSourceID)
    store.showingHome=false;store.mode = .artwork;store.select(id)
    addTeardownBlock{@MainActor in store.engine.project=nil;try? FileManager.default.removeItem(at:root)}
    return (store,id,inside)
  }
  func testUprightInsideArtworkUsesUnchangedGlobalUVAndActualReverseFacePixels() async throws {
    guard MTLCreateSystemDefaultDevice() != nil else{throw XCTSkip("This proof requires the native Metal renderer")}
    let (store,id,_)=try fixture()
    let normal:[ArtworkElement]=[
      .init(kind:"rectangle",x:4,y:4,width:4,height:4,color:"#FF0000"),
      .init(kind:"rectangle",x:32,y:4,width:4,height:4,color:"#0000FF"),
      .init(kind:"rectangle",x:32,y:32,width:4,height:4,color:"#00FF00"),
      .init(kind:"text",x:13,y:12,width:20,height:24,text:"R",color:"#151515",fontSize:48)]
    for side in ["outside","inside"] {
      _ = try store.engine.call("form_edit_artwork",arguments:["object_id":id.uuidString,
        "physical_frame":["surface_id":"front","side":side],"command":"add","elements":try normal.map{value in var element=value;if side=="inside"{element.id=UUID()};return try jsonObject(element)}])
    }
    let project=try XCTUnwrap(store.project),object=try XCTUnwrap(project.objects.first{$0.id==id})
    let source=try PaperConstruction.definition(for:object),net=try source.net()
    let paper=try PaperGeometry.make(object,project:project,assets:store.artworkSession.assets,limit:1536)
    let panel=try XCTUnwrap(paper.childNodes.first{$0.name==PaperGeometry.panelPrefix+"front"})
    panel.removeFromParentNode()
    for material in panel.geometry?.materials ?? [] {material.lightingModel = .constant}
    let root=MeshNode();root.name="object:"+id.uuidString;root.addChildNode(panel)
    let scene=MeshScene();scene.rootNode.addChildNode(root)
    let renderer=try RealityKitSceneRenderer(),adapter=GeometryPayloadAdapter()
    for payload in adapter.renderables(scene:scene){try renderer.upsert(payload)}
    let geometry=try XCTUnwrap(panel.geometry),vertices=try XCTUnwrap(geometry.sources(for:.vertex).first).vectors
    let uv=try XCTUnwrap(geometry.sources(for:.texcoord).first).points
    for i in vertices.indices {
      XCTAssertEqual(uv[i].x,vertices[i].x*100/net.size.x,accuracy:1e-10)
      XCTAssertEqual(uv[i].y,-vertices[i].y*100/net.size.y,accuracy:1e-10)
    }
    for inside in [false,true] {
      let frame=try PhysicalArtworkFrame.paper(net:net,panelID:"front",inside:inside)
      let inverse=try XCTUnwrap(frame.sourceToLocal.inverse),z=(inside ? -1.0:1.0)*source.stock.thicknessMM/2
      func world(_ q:Point2) -> SIMD3<Double> {
        let p=inverse.apply(q)
        return panel.convertPosition(.init(p.x/100,-p.y/100,z/100),to:nil).simd*100
      }
      let center=world(.init(20,20)),right=simd_normalize(world(.init(21,20))-center)
      let up=simd_normalize(center-world(.init(20,21))),normal=simd_normalize(simd_cross(right,up))
      let camera=SceneCameraPayload.looking(from:center+normal*1000,at:center,up:up,projection:.orthographic(verticalSpanMM:46))
      try renderer.setCamera(camera)
      let cg=try await renderer.capture(width:640,height:640,transparent:true),bitmap=NSBitmapImageRep(cgImage:cg)
      let leftPixel=try XCTUnwrap(SceneProjection.project(world(.init(6,6)),camera:camera,viewport:.init(width:640,height:640)))
      let rightPixel=try XCTUnwrap(SceneProjection.project(world(.init(34,6)),camera:camera,viewport:.init(width:640,height:640)))
      XCTAssertLessThan(leftPixel.x,rightPixel.x,"The camera must use the same readable face frame as artwork authoring")
      for (q,channel) in [(Point2(6,6),0),(Point2(34,6),2),(Point2(34,34),1)] {
        let pixel=try XCTUnwrap(SceneProjection.project(world(q),camera:camera,viewport:.init(width:640,height:640)))
        let color=try XCTUnwrap(bitmap.colorAt(x:Int(pixel.x),y:Int(pixel.y))?.usingColorSpace(.deviceRGB))
        let components=[color.redComponent,color.greenComponent,color.blueComponent]
        XCTAssertGreaterThan(components[channel],0.7)
        XCTAssertTrue(components.enumerated().filter{$0.offset != channel}.allSatisfy{$0.element<0.3})
      }
      if let folder=ProcessInfo.processInfo.environment["FORM_PHYSICAL_FRAME_PROOF_DIR"] {
        let output=URL(fileURLWithPath:folder);try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        try XCTUnwrap(bitmap.representation(using:.png,properties:[:])).write(to:output.appendingPathComponent(inside ? "inside-readable-R.png":"outside-readable-R.png"))
      }
    }
    XCTAssertEqual(store.project,project)
  }
  func testInsideWholeNetCanvasReflectsCutClipAndGuidesWithoutChangingRegisteredExport() throws {
    let (store,id,insideID)=try fixture()
    try store.engine.edit("Registered source"){p in
      var art=Artwork(background:"#FF0000",elements:[.init(kind:"rectangle",x:5,y:5,width:5,height:5,color:"#0000FF")],bleed:0)
      art.showGrid=false;try p.setArtwork(art,for:insideID)
    }
    let object=try XCTUnwrap(store.project?.objects.first{$0.id==id}),net=try PaperConstruction.definition(for:object).net()
    let raw=try XCTUnwrap(store.project?.paperArtwork(for:object,inside:true)),assets=store.artworkSession.assets
    let exported=try PaperOutput.svg(net,artwork:raw,assets:assets,guides:true,title:"Registered inside source")
    let before=try XCTUnwrap(store.project),undo=store.engine.undoStack.count
    store.setPaperInside(true,object:object);store.paperShowingGuides=true
    let session=store.artworkSession,proof=try XCTUnwrap(session.frames.first{$0.projection?.inside == true && $0.projection?.isProof == true})
    session.activate(proof.id)
    let scroll=NSScrollView(frame:.init(x:0,y:0,width:800,height:600)),canvas=VectorCanvasView()
    scroll.allowsMagnification=true;scroll.documentView=canvas;canvas.session=session;session.canvas=canvas;canvas.synchronize()
    let a=canvas.documentPoint(proof.rect.origin),b=canvas.documentPoint(.init(x:proof.rect.maxX,y:proof.rect.maxY))
    let rect=CGRect(x:a.x,y:a.y,width:b.x-a.x,height:b.y-a.y),bitmap=try XCTUnwrap(canvas.bitmapImageRepForCachingDisplay(in:rect))
    canvas.cacheDisplay(in:rect,to:bitmap)
    func color(_ q:Point2) throws -> NSColor {
      try XCTUnwrap(bitmap.colorAt(x:min(bitmap.pixelsWide-1,max(0,Int(q.x/70*Double(bitmap.pixelsWide)))),
        y:min(bitmap.pixelsHigh-1,max(0,Int(q.y/40*Double(bitmap.pixelsHigh)))))?.usingColorSpace(.deviceRGB))
    }
    let reflected=try color(.init(65,35)),outside=try color(.init(5,35))
    XCTAssertGreaterThan(reflected.redComponent,0.7);XCTAssertLessThan(reflected.greenComponent,0.3)
    XCTAssertGreaterThan(outside.greenComponent,0.7,"The artwork clip must follow the reflected asymmetric cut boundary")
    func darkNear(_ q:Point2) throws -> Bool {
      for dx in [-0.7,-0.35,0,0.35,0.7] {for dy in [-0.7,-0.35,0,0.35,0.7] {
        let c=try color(.init(q.x+dx,q.y+dy));if max(c.redComponent,max(c.greenComponent,c.blueComponent))<0.7{return true}
      }};return false
    }
    XCTAssertTrue(try darkNear(.init(15,20)),"The reflected sloping cut guide belongs at x15")
    XCTAssertFalse(try darkNear(.init(55,20)),"The old unreflected guide must not remain at x55")
    XCTAssertEqual(store.project,before);XCTAssertEqual(store.engine.undoStack.count,undo)
    XCTAssertEqual(try PaperOutput.svg(net,artwork:raw,assets:assets,guides:true,title:"Registered inside source"),exported)
    let text=ArtworkElement(kind:"text",x:3,y:3,text:"INSIDE R")
    session.add([text])
    XCTAssertEqual(store.engine.undoStack.count,undo+1)
    XCTAssertLessThan(try XCTUnwrap(store.project?.objects.first{$0.id==insideID}?.artwork?.elements.last?.affine).a,0)
    var path=ArtworkElement(kind:"path",x:12,y:12,width:10,height:10,color:"#151515")
    path.path = .init(width:10,height:10,contours:[.init([.init(.init(0,0)),.init(.init(10,0)),.init(.init(0,10))])])
    session.add([path]);session.choose([path.id]);session.nodes=Set(try XCTUnwrap(path.path).contours.flatMap(\.nodes).map(\.id))
    let previous=try XCTUnwrap(session.nodeBounds)
    _ = session.beginGesture()
    session.transformNodes(.translation(1,0));session.transformNodes(.translation(1,0))
    session.endGesture()
    XCTAssertNil(store.error)
    XCTAssertEqual(try XCTUnwrap(session.nodeBounds).x,previous.x+2,accuracy:1e-8,"Whole-net node edits must use the same inverse frame as Add")
    XCTAssertEqual(store.engine.undoStack.count,undo+3)
    store.engine.undo();store.engine.undo();store.engine.undo()
    XCTAssertEqual(store.project?.objects,before.objects)
  }
}
