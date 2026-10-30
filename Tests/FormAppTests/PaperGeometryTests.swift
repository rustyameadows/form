import AppKit
import FormCore
import FormGeometry
import LabRendering
import Metal
import simd
import XCTest
@testable import FormApp

@MainActor final class PaperGeometryTests:XCTestCase {
  private func project(_ recipe:String,fold:Double=100)throws->(Project,ProductObject) {
    var project=Project(name:"Physical paper proof"),object=try project.makeObject(recipeID:recipe)
    object.parameters["fold"]=fold;project.objects=[object];return(project,object)
  }
  private func panels(_ root:MeshNode)->[MeshNode] {
    var result=[MeshNode]();root.enumerateChildNodes{node,_ in if node.name?.hasPrefix(PaperGeometry.panelPrefix)==true {result.append(node)}};return result
  }
  private func world(_ node:MeshNode,_ p:Point2,z:Double=0)->SIMD3<Double> {
    let q=node.convertPosition(.init(p.x/100,-p.y/100,z/100),to:nil);return q.simd*100
  }
  func testEnvelopeAndCartonAreSoftEdgedHollowPanelShellsWithRealCaliper()throws {
    for recipe in ["paperEnvelope","tuckCarton"] {
      let (project,object)=try project(recipe),definition=try PaperConstruction.definition(for:object),net=try definition.net()
      let root=try PaperGeometry.make(object,project:project,assets:FileManager.default.temporaryDirectory,limit:128),nodes=panels(root)
      XCTAssertEqual(nodes.count,net.panels.count)
      for required in ["front","back","side-right","side-left","glue","top-tuck","bottom-tuck"] {XCTAssertNotNil(nodes.first{$0.name==PaperGeometry.panelPrefix+required})}
      XCTAssertEqual(net.panels.filter{$0.role == .dust}.count,recipe=="tuckCarton" ? 4:0)
      for node in nodes {
        let geometry=try XCTUnwrap(node.geometry),vertices=try XCTUnwrap(geometry.sources(for:.vertex).first).vectors
        XCTAssertEqual(geometry.elements.count,3);XCTAssertTrue(geometry.elements.allSatisfy{$0.primitiveCount>0})
        XCTAssertEqual(geometry.materials.count,3)
        XCTAssertEqual((vertices.map(\.z).max()!-vertices.map(\.z).min()!)*100,definition.stock.thicknessMM,accuracy:1e-8)
        let normals=try XCTUnwrap(geometry.sources(for:.normal).first).vectors
        XCTAssertTrue(normals.contains{abs($0.z)>0.1 && abs($0.z)<0.99},"Soft edge arcs need real intermediate normals.")
        XCTAssertTrue(geometry.materials[0].roughness.contents is NSImage,"Paper roughness includes the physical stock field.")
        XCTAssertTrue(geometry.materials[0].metalness.contents is NSImage,"Localized finishes use an independent metallic coverage map.")
        var edges:[String:Int]=[:],volume=0.0
        func key(_ p:MeshVector3)->String {"\(Int((p.x*1e8).rounded())),\(Int((p.y*1e8).rounded())),\(Int((p.z*1e8).rounded()))"}
        for element in geometry.elements {
          let indices=element.indices
          for i in stride(from:0,to:indices.count,by:3) {
            let a=vertices[Int(indices[i])],b=vertices[Int(indices[i+1])],c=vertices[Int(indices[i+2])]
            if simd_length_squared(simd_cross(b.simd-a.simd,c.simd-a.simd))<1e-25 {continue}
            volume+=simd_dot(a.simd,simd_cross(b.simd,c.simd))/6
            for (l,r) in [(a,b),(b,c),(c,a)] {edges[[key(l),key(r)].sorted().joined(separator:"|") ,default:0]+=1}
          }
        }
        XCTAssertTrue(edges.values.allSatisfy{$0==2},node.name ?? "panel")
        XCTAssertGreaterThan(volume,0)
      }
      let front=try XCTUnwrap(nodes.first{$0.name==PaperGeometry.panelPrefix+"front"}),frontPanel=try XCTUnwrap(net.panels.first{$0.id=="front"}),b=frontPanel.bounds
      let cavity=world(front,.init(b.x+b.width/2,b.y+b.height/2),z:-definition.dimensions.depth/2)
      for node in nodes {
        let vertices=try XCTUnwrap(node.geometry?.sources(for:.vertex).first).vectors.map{node.convertPosition($0,to:nil).simd*100}
        var lo=vertices[0],hi=lo;for p in vertices.dropFirst(){lo=simd_min(lo,p);hi=simd_max(hi,p)}
        XCTAssertFalse((0..<3).allSatisfy{cavity[$0]>=lo[$0]-1e-5 && cavity[$0]<=hi[$0]+1e-5},"The usable cavity must remain empty, not be modeled as a solid cuboid.")
      }
      XCTAssertThrowsError(try PrintMeshBuilder.mesh(object:object,project:project,assets:FileManager.default.temporaryDirectory,configuration:.init())) {XCTAssertTrue($0.localizedDescription.contains("Paper Fabricate"))}
    }
  }
  func testCanonicalOutsideAndInsideUVsUsePhysicalNetCoordinatesWithoutPanelStretching()throws {
    let (_,object)=try project("tuckCarton"),definition=try PaperConstruction.definition(for:object),net=try definition.net()
    for panel in net.panels {
      let geometry=try PaperGeometry.panelMesh(panel,netSize:net.size,thicknessMM:definition.stock.thicknessMM)
      let points=try XCTUnwrap(geometry.sources(for:.vertex).first).vectors,uv=try XCTUnwrap(geometry.sources(for:.texcoord).first).points
      for i in points.indices {XCTAssertEqual(uv[i].x,points[i].x*100/net.size.x,accuracy:1e-10);XCTAssertEqual(uv[i].y,-points[i].y*100/net.size.y,accuracy:1e-10)}
      XCTAssertLessThan(uv.map(\.x).max()!-uv.map(\.x).min()!,0.6,"A panel is a crop of one net, not a stretched full artwork image.")
    }
  }
  func testFoldAndPanelSelectionUpdateTransformsWithoutMeshOrTextureRebuilds()throws {
    var (project,object)=try project("paperEnvelope")
    let controller=TableSceneController();controller.sync(project,selection:[],isolated:[],showGrid:false,studio:false,preset:"Daylight",assets:FileManager.default.temporaryDirectory,textureLimit:128)
    let builds=controller.geometryBuilds,uploads=controller.renderer!.diagnostics.meshBuilds,textures=PaperGeometry.textureBuilds
    let original=try XCTUnwrap(controller.logicalNode(for:object.id)),geometry=try XCTUnwrap(panels(original).first?.geometry),foldedHeight=original.boundingBox.max.y
    let closed=Dictionary(uniqueKeysWithValues:panels(original).map{($0.name!,$0.transform)})
    object.parameters["opening"]=100;project.objects=[object]
    controller.sync(project,selection:[],isolated:[],showGrid:false,studio:false,preset:"Daylight",assets:FileManager.default.temporaryDirectory,textureLimit:128)
    XCTAssertTrue(panels(original).first?.geometry === geometry)
    XCTAssertEqual(controller.geometryBuilds,builds);XCTAssertEqual(controller.renderer!.diagnostics.meshBuilds,uploads);XCTAssertEqual(PaperGeometry.textureBuilds,textures)
    let open=Dictionary(uniqueKeysWithValues:panels(original).map{($0.name!,$0.transform)})
    for id in ["front","back","side-right","side-left","glue","bottom-bridge","bottom-tuck"] {
      let key=PaperGeometry.panelPrefix+id,a=try XCTUnwrap(open[key]).raw,b=try XCTUnwrap(closed[key]).raw
      for column in 0..<4 {for row in 0..<4 {XCTAssertEqual(a[column,row],b[column,row],"Opening the top must leave the body and bottom assembled.")}}
    }
    let a=try XCTUnwrap(open[PaperGeometry.panelPrefix+"top-tuck"]).raw,b=try XCTUnwrap(closed[PaperGeometry.panelPrefix+"top-tuck"]).raw
    XCTAssertTrue((0..<4).contains{column in (0..<4).contains{row in a[column,row] != b[column,row]}})
    object.parameters["fold"]=0;project.objects=[object]
    controller.sync(project,selection:[],isolated:[],showGrid:false,studio:false,preset:"Daylight",assets:FileManager.default.temporaryDirectory,textureLimit:128)
    XCTAssertTrue(panels(original).first?.geometry === geometry)
    XCTAssertEqual(controller.geometryBuilds,builds);XCTAssertEqual(controller.renderer!.diagnostics.meshBuilds,uploads);XCTAssertEqual(PaperGeometry.textureBuilds,textures)
    XCTAssertLessThan(original.boundingBox.max.y,foldedHeight/10)
    try PaperGeometry.updatePose(original,object:object,foldPercent:47.5,selectedPanelID:"top-tuck")
    XCTAssertEqual(panels(original).filter{$0.childNode(withName:PaperGeometry.highlightName,recursively:false)?.isHidden==false}.count,1)
    XCTAssertTrue(panels(original).first?.geometry === geometry)
    XCTAssertEqual(PaperGeometry.textureBuilds,textures)
  }
  func testLinkedOutsideInsideSourceAndPanelPickSurviveNativeGPUProjection()async throws {
    guard MTLCreateSystemDefaultDevice() != nil else{throw XCTSkip("Actual folded paper pixels require Metal.")}
    var (project,object)=try project("paperEnvelope",fold:0)
    let net=try project.paperNet(for:object),frontPanel=try XCTUnwrap(net.panels.first{$0.id=="front"}),bounds=frontPanel.bounds
    var outside=try project.makeObject(recipeID:"artboard"),inside=outside;inside.id=UUID()
    outside.parameters=["width":net.size.x,"depth":net.size.y];inside.parameters=outside.parameters
    outside.artwork = .init(background:"#FFFFFF",elements:[.init(kind:"rectangle",x:bounds.x,y:bounds.y,width:bounds.width,height:bounds.height/2,color:"#FF0000"),.init(kind:"rectangle",x:bounds.x,y:bounds.y+bounds.height/2,width:bounds.width,height:bounds.height/2,color:"#0000FF")])
    inside.artwork = .init(background:"#FFFFFF",elements:[.init(kind:"rectangle",x:bounds.x,y:bounds.y,width:bounds.width,height:bounds.height,color:"#00FF00")])
    object.artwork=nil;object.artworkSourceID=outside.id;object.artworkFit="actual"
    object.paperConstruction=try PaperConstruction.definition(for:object);object.paperConstruction!.insideArtworkSourceID=inside.id
    project.objects=[object,outside,inside];let before=project
    let root=MeshNode(),paper=try PaperGeometry.make(object,project:project,assets:FileManager.default.temporaryDirectory,limit:768,selectedPanelID:"front")
    root.name="object:"+object.id.uuidString;root.addChildNode(paper)
    let front=try XCTUnwrap(panels(root).first{$0.name==PaperGeometry.panelPrefix+"front"})
    let scene=MeshScene();scene.rootNode.addChildNode(root)
    let adapter=GeometryPayloadAdapter(),renderer=try RealityKitSceneRenderer()
    for payload in adapter.renderables(scene:scene){try renderer.upsert(payload)}
    let size=CGSize(width:640,height:480),span=max(net.size.y,net.size.x/(size.width/size.height))*1.15
    let samples=[Point2(bounds.x+bounds.width/2,bounds.y+bounds.height/4),.init(bounds.x+bounds.width/2,bounds.y+bounds.height*3/4)]
    for (outsideView,eye,up) in [(true,SIMD3<Double>(0,1000,0),SIMD3<Double>(0,0,-1)),(false,SIMD3<Double>(0,-1000,0),SIMD3<Double>(0,0,1))] {
      let camera=SceneCameraPayload.looking(from:eye,at:.zero,up:up,projection:.orthographic(verticalSpanMM:span));try renderer.setCamera(camera)
      let image=try await renderer.capture(width:640,height:480,transparent:true),bitmap=NSBitmapImageRep(cgImage:image)
      for (index,sample) in samples.enumerated() {
        let point=world(front,sample),pixel=try XCTUnwrap(SceneProjection.project(point,camera:camera,viewport:size)),color=try XCTUnwrap(bitmap.colorAt(x:Int(pixel.x),y:Int(pixel.y))?.usingColorSpace(.sRGB))
        if outsideView,index==0 {XCTAssertGreaterThan(color.redComponent,color.blueComponent+0.25)}
        else if outsideView {XCTAssertGreaterThan(color.blueComponent,color.redComponent+0.25)}
        else {XCTAssertGreaterThan(color.greenComponent,max(color.redComponent,color.blueComponent)+0.25)}
        XCTAssertEqual(renderer.pick(atTopLeft:pixel,viewport:size)?.objectID,object.id)
      }
    }
    XCTAssertEqual(project,before)
  }
  func testArtworkInsideAndStockEditsReusePhysicalUploadsWithoutRecoloringAnotherObject()async throws {
    guard MTLCreateSystemDefaultDevice() != nil else{throw XCTSkip("Actual paper appearance edits require Metal.")}
    var (project,first)=try project("paperEnvelope",fold:0)
    let net=try project.paperNet(for:first),bounds=try XCTUnwrap(net.panels.first{$0.id=="front"}).bounds
    var other=try project.makeObject(recipeID:"paperEnvelope"),outside=try project.makeObject(recipeID:"artboard"),inside=try project.makeObject(recipeID:"artboard")
    other.parameters["fold"]=0;first.position.x = -net.size.x*0.58;other.position.x=net.size.x*0.58
    outside.parameters=["width":net.size.x,"depth":net.size.y];inside.parameters=outside.parameters
    outside.artwork = .init(background:"#FFFFFF",elements:[.init(kind:"rectangle",x:bounds.x,y:bounds.y,width:bounds.width,height:bounds.height/2,color:"#FF0000")])
    inside.artwork = .init(background:"#FFFFFF",elements:[.init(kind:"rectangle",x:bounds.x,y:bounds.y,width:bounds.width,height:bounds.height/2,color:"#00FF00")])
    outside.artwork!.backgroundOpacity=0;inside.artwork!.backgroundOpacity=0
    first.artwork=nil;first.artworkSourceID=outside.id;first.artworkFit="actual"
    first.paperConstruction=try PaperConstruction.definition(for:first);first.paperConstruction!.insideArtworkSourceID=inside.id
    project.objects=[first,other,outside,inside]
    let assets=FileManager.default.temporaryDirectory,scene=MeshScene(),adapter=GeometryPayloadAdapter(),renderer=try RealityKitSceneRenderer()
    func root(_ object:ProductObject)->MeshNode {
      let node=GeometryFactory.object(object,project:project,assets:assets,textureLimit:768)
      node.name="object:"+object.id.uuidString;node.position.x=object.position.x/100;return node
    }
    var firstRoot=root(first);let otherRoot=root(other);scene.rootNode.addChildNode(firstRoot);scene.rootNode.addChildNode(otherRoot)
    func front(_ node:MeshNode)throws->MeshNode {try XCTUnwrap(panels(node).first{$0.name==PaperGeometry.panelPrefix+"front"})}
    let original=try XCTUnwrap(front(firstRoot).geometry),neighbor=try XCTUnwrap(front(otherRoot).geometry),neighborMaterial=try XCTUnwrap(neighbor.materials.first)
    XCTAssertFalse(original === neighbor);XCTAssertFalse(original.materials[0] === neighborMaterial)
    XCTAssertTrue(original.sources[0] === neighbor.sources[0],"Appearance wrappers must share immutable physical buffers.")
    XCTAssertEqual(original.name,neighbor.name)
    var payloads=adapter.renderables(scene:scene);for payload in payloads {try renderer.upsert(payload)}
    let uploads=renderer.diagnostics.meshBuilds,physicalBuilds=PaperGeometry.physicalMeshBuilds
    XCTAssertEqual(uploads,Set(payloads.map{$0.mesh.id+"|"+$0.mesh.revision}).count)
    let size=CGSize(width:1000,height:480),span=max(net.size.y,(2*abs(first.position.x)+net.size.x)/(size.width/size.height))*1.12
    let upper=Point2(bounds.x+bounds.width/2,bounds.y+bounds.height/4),lower=Point2(bounds.x+bounds.width/2,bounds.y+bounds.height*3/4)
    func pixels(insideView:Bool=false)async throws->[NSColor] {
      let camera=SceneCameraPayload.looking(from:.init(0,insideView ? -1000:1000,0),at:.zero,up:.init(0,0,insideView ? 1:-1),projection:.orthographic(verticalSpanMM:span))
      try renderer.setCamera(camera);let bitmap=NSBitmapImageRep(cgImage:try await renderer.capture(width:1000,height:480,transparent:true))
      let points=[world(try front(firstRoot),upper),world(try front(firstRoot),lower),world(try front(otherRoot),lower)]
      return try points.map{let point=try XCTUnwrap(SceneProjection.project($0,camera:camera,viewport:size));return try XCTUnwrap(bitmap.colorAt(x:Int(point.x),y:Int(point.y))?.usingColorSpace(.sRGB))}
    }
    func assertSameColor(_ a:NSColor,_ b:NSColor,file:StaticString=#filePath,line:UInt=#line) {
      XCTAssertEqual(a.redComponent,b.redComponent,accuracy:0.01,file:file,line:line);XCTAssertEqual(a.greenComponent,b.greenComponent,accuracy:0.01,file:file,line:line);XCTAssertEqual(a.blueComponent,b.blueComponent,accuracy:0.01,file:file,line:line)
    }
    func refreshFirst()throws {
      let source=project;firstRoot.removeFromParentNode();firstRoot=root(project.objects[0]);scene.rootNode.addChildNode(firstRoot)
      payloads=adapter.renderables(scene:scene);for payload in payloads {try renderer.upsert(payload)}
      XCTAssertEqual(renderer.diagnostics.meshBuilds,uploads,"Appearance edits must not reupload panel or highlight geometry.")
      XCTAssertEqual(PaperGeometry.physicalMeshBuilds,physicalBuilds,"Appearance edits must not retessellate physical panels.")
      let current=try XCTUnwrap(front(firstRoot).geometry)
      XCTAssertTrue(current.sources[0] === original.sources[0]);XCTAssertTrue(neighbor.materials[0] === neighborMaterial)
      XCTAssertEqual(project,source,"Rendering must preserve linked artwork and construction sources.")
    }
    let initial=try await pixels(),initialInside=try await pixels(insideView:true)
    XCTAssertGreaterThan(initial[0].redComponent,initial[0].blueComponent+0.25)
    XCTAssertGreaterThan(initialInside[0].greenComponent,max(initialInside[0].redComponent,initialInside[0].blueComponent)+0.25)
    project.objects[2].artwork!.elements[0].color="#0000FF";try refreshFirst()
    let outsideEdited=try await pixels();XCTAssertGreaterThan(outsideEdited[0].blueComponent,outsideEdited[0].redComponent+0.25)
    assertSameColor(outsideEdited[1],initial[1]);assertSameColor(outsideEdited[2],initial[2])
    project.objects[3].artwork!.elements[0].color="#FF00FF";try refreshFirst()
    let insideEdited=try await pixels(insideView:true)
    XCTAssertGreaterThan(insideEdited[0].redComponent,insideEdited[0].greenComponent+0.25);XCTAssertGreaterThan(insideEdited[0].blueComponent,insideEdited[0].greenComponent+0.25)
    assertSameColor(insideEdited[2],initialInside[2])
    project.objects[0].color="#202020";try refreshFirst()
    let recolored=try await pixels()
    XCTAssertGreaterThan(initial[1].redComponent-recolored[1].redComponent,0.25)
    assertSameColor(recolored[0],outsideEdited[0]);assertSameColor(recolored[2],initial[2])
    XCTAssertEqual(project.objects[2].artwork!.elements[0].color,"#0000FF");XCTAssertEqual(project.objects[3].artwork!.elements[0].color,"#FF00FF")
  }
  func testPhysicalMeshIdentityIncludesCaliperNetUVAndChannelGroups()throws {
    let (project,object)=try project("paperEnvelope",fold:0),definition=try PaperConstruction.definition(for:object),net=try definition.net(),panel=try XCTUnwrap(net.panels.first)
    let a=try PaperGeometry.panelMesh(panel,netSize:net.size,thicknessMM:definition.stock.thicknessMM),b=try PaperGeometry.panelMesh(panel,netSize:net.size,thicknessMM:definition.stock.thicknessMM)
    XCTAssertFalse(a === b);XCTAssertTrue(a.sources[0] === b.sources[0]);XCTAssertTrue(a.elements[0] === b.elements[0]);XCTAssertEqual(a.name,b.name)
    XCTAssertNotEqual(a.name,try PaperGeometry.panelMesh(panel,netSize:.init(net.size.x+1,net.size.y),thicknessMM:definition.stock.thicknessMM).name)
    XCTAssertNotEqual(a.name,try PaperGeometry.panelMesh(panel,netSize:net.size,thicknessMM:definition.stock.thicknessMM+0.1).name)
    let root=try PaperGeometry.make(object,project:project,assets:FileManager.default.temporaryDirectory,limit:128),node=try XCTUnwrap(panels(root).first)
    XCTAssertNotEqual(node.geometry?.name,node.childNode(withName:PaperGeometry.highlightName,recursively:false)?.geometry?.name)
  }
  func testNativeDielineTextDragKeepsClosedPanelGeometryAndRenderedSilhouette()async throws {
    guard MTLCreateSystemDefaultDevice() != nil else{throw XCTSkip("Native live dieline projection requires Metal.")}
    _=NSApplication.shared
    let directory=FileManager.default.temporaryDirectory.appendingPathComponent("lab-paper-drag-"+UUID().uuidString),repository=try ProjectRepository(root:directory),store=StudioStore(repository:repository,seedLibrary:false)
    var project=try PaperSamples.cosmetics(),object=try XCTUnwrap(project.objects.first)
    object.paperConstruction!.insideArtworkSourceID=nil;object.artwork!.snapEnabled=false;object.position = .init();object.rotation=0
    project.objects=[object];store.engine.project=project;store.showingHome=false;store.select(object.id);store.showPaper(.dieline,object:object,split:true)
    let session=store.artworkSession,window=NSWindow(contentRect:.init(x:-10000,y:-10000,width:800,height:650),styleMask:[.titled],backing:.buffered,defer:false)
    window.isReleasedWhenClosed=false
    let scroll=NSScrollView(frame:window.contentView!.bounds),canvas=VectorCanvasView(frame:window.contentView!.bounds)
    scroll.allowsMagnification=true;scroll.minMagnification=0.08;scroll.maxMagnification=24
    canvas.session=session;session.canvas=canvas;scroll.documentView=canvas;window.contentView=scroll;window.makeFirstResponder(canvas);canvas.synchronize();canvas.fit(all:false)
    defer {canvas.finishText();window.close();store.engine.project=nil;try? FileManager.default.removeItem(at:directory)}
    let controller=TableSceneController(),assets=repository.url(for:project.id).appendingPathComponent("Assets")
    func sync()throws {
      controller.sync(try XCTUnwrap(store.project),selection:[],isolated:[],showGrid:false,studio:false,preset:"Daylight",assets:assets,textureLimit:512)
      controller.floorNode.isHidden=true;controller.renderScene();XCTAssertNil(controller.rendererIssue)
    }
    try sync();let renderer=try XCTUnwrap(controller.renderer),net=try object.paperConstruction!.net(),root=try XCTUnwrap(controller.logicalNode(for:object.id))
    XCTAssertEqual(root.childNodes.map(\.name),[PaperGeometry.constructionName],"Paper artwork belongs on registered panels; no generic floating artwork plane may be added.")
    let baseline=Dictionary(uniqueKeysWithValues:GeometryPayloadAdapter().renderables(scene:controller.scene).filter{$0.objectID==object.id}.map{($0.componentID,$0)})
    XCTAssertEqual(baseline.count,net.panels.count*2)
    let uploads=renderer.diagnostics.meshBuilds,physicalBuilds=PaperGeometry.physicalMeshBuilds,parameters=object.parameters,construction=object.paperConstruction
    let camera=SceneCameraPayload.looking(from:.init(240,220,410),at:.init(0,69,0),up:.init(0,1,0),projection:.orthographic(verticalSpanMM:185))
    func pixels()async throws->NSBitmapImageRep {NSBitmapImageRep(cgImage:try await renderer.capture(width:320,height:320,transparent:true,camera:camera))}
    func silhouette(_ bitmap:NSBitmapImageRep)->[Bool] {(0..<320).flatMap{y in (0..<320).map{x in (bitmap.colorAt(x:x,y:y)?.alphaComponent ?? 0)>0.5}}}
    let initialPixels=try await pixels(),initialSilhouette=silhouette(initialPixels),text=try XCTUnwrap(session.art.elements.first{$0.text=="STILL"}),frame=try XCTUnwrap(canvas.activeFrame),originalArt=session.art
    session.choose([])
    let start=CGPoint(x:frame.rect.minX+text.x+text.width/2,y:frame.rect.minY+text.y+text.height/2)
    func event(_ type:NSEvent.EventType,_ p:CGPoint)->NSEvent {NSEvent.mouseEvent(with:type,location:canvas.convert(canvas.documentPoint(p),to:nil),modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:window.windowNumber,context:nil,eventNumber:1,clickCount:1,pressure:type == .leftMouseUp ? 0:1)!}
    canvas.mouseDown(with:event(.leftMouseDown,start));XCTAssertEqual(session.selection,[text.id])
    // More than the recipe cache's 80 entries: continuous native dragging must
    // remain correct when old appearance nodes and their addresses are recycled.
    for step in 1...96 {
      let point=CGPoint(x:start.x+12*Double(step)/96,y:start.y+8*Double(step)/96)
      canvas.mouseDragged(with:event(.leftMouseDragged,point));canvas.synchronize();try sync()
      let current=try XCTUnwrap(store.project?.objects.first)
      XCTAssertEqual(current.parameters,parameters);XCTAssertEqual(current.paperConstruction,construction)
      XCTAssertEqual(current.parameters["fold"],100);XCTAssertEqual(current.parameters["opening"],0)
      let payloads=GeometryPayloadAdapter().renderables(scene:controller.scene).filter{$0.objectID==object.id}
      XCTAssertEqual(payloads.count,baseline.count)
      for payload in payloads {
        let expected=try XCTUnwrap(baseline[payload.componentID])
        XCTAssertEqual(payload.mesh.positionsMM,expected.mesh.positionsMM);XCTAssertEqual(payload.mesh.normals,expected.mesh.normals);XCTAssertEqual(payload.mesh.uvs,expected.mesh.uvs);XCTAssertEqual(payload.transform,expected.transform)
        XCTAssertEqual(payload.mesh.parts.map(\.triangleIndices),expected.mesh.parts.map(\.triangleIndices))
      }
      XCTAssertEqual(renderer.diagnostics.meshBuilds,uploads);XCTAssertEqual(PaperGeometry.physicalMeshBuilds,physicalBuilds)
      if step%12==0 {let frame=try await pixels();XCTAssertEqual(silhouette(frame),initialSilhouette,"Dragging 2D text must not disassemble or hide any 3D panel.")}
    }
    let end=CGPoint(x:start.x+12,y:start.y+8);canvas.mouseUp(with:event(.leftMouseUp,end));try sync()
    let changed=session.art,oldOrigin=originalArt.worldTransform(text).apply(.init()),newText=try XCTUnwrap(changed.elements.first{$0.id==text.id}),newOrigin=changed.worldTransform(newText).apply(.init())
    XCTAssertEqual(newOrigin.x-oldOrigin.x,12,accuracy:1e-6);XCTAssertEqual(newOrigin.y-oldOrigin.y,8,accuracy:1e-6)
    XCTAssertEqual(changed.elements.filter{$0.id != text.id},originalArt.elements.filter{$0.id != text.id})
    let finalPixels=try await pixels();XCTAssertEqual(silhouette(finalPixels),initialSilhouette)
    var changedInk=0
    for y in 0..<320 {for x in 0..<320 {if let a=initialPixels.colorAt(x:x,y:y)?.usingColorSpace(.sRGB),let b=finalPixels.colorAt(x:x,y:y)?.usingColorSpace(.sRGB),max(abs(a.redComponent-b.redComponent),abs(a.greenComponent-b.greenComponent),abs(a.blueComponent-b.blueComponent))>0.08{changedInk+=1}}}
    XCTAssertGreaterThan(changedInk,10,"Actual 3D artwork pixels must follow the native 2D drag.")
    XCTAssertNil(store.error);XCTAssertEqual(store.engine.undoStack.count,1)
  }
  func testReleasedProceduralGeometryCannotAliasOlderGPUMeshBuffers()async throws {
    guard MTLCreateSystemDefaultDevice() != nil else{throw XCTSkip("Geometry resource lifetime validation requires Metal.")}
    let adapter=GeometryPayloadAdapter(),renderer=try RealityKitSceneRenderer(),objectID=UUID(),camera=SceneCameraPayload.looking(from:.init(0,0,1000),at:.zero,up:.init(0,1,0),projection:.orthographic(verticalSpanMM:240))
    try renderer.setCamera(camera)
    for step in 0..<64 {
      let wide=step%2==0,width=wide ? 180.0:20.0
      weak var released:MeshGeometry?
      let payload:SceneRenderablePayload=try autoreleasepool {
        let scene=MeshScene(),root=MeshNode(),geometry=MeshBox(width:width/100,height:1,length:0.5,chamferRadius:0),material=MeshMaterial()
        material.lightingModel = .constant;material.diffuse.contents=NSColor.red;geometry.materials=[material];released=geometry
        root.name="object:"+objectID.uuidString;let body=MeshNode(geometry:geometry);body.name="body";body.categoryBitMask=2;root.addChildNode(body);scene.rootNode.addChildNode(root)
        let payload=try XCTUnwrap(adapter.renderables(scene:scene).first);adapter.clear();return payload
      }
      XCTAssertNil(released,"Renderer caches must not need to keep construction geometry alive.")
      XCTAssertEqual(payload.mesh.positionsMM.map(\.x).max()!-payload.mesh.positionsMM.map(\.x).min()!,width,accuracy:1e-8)
      try renderer.upsert(payload)
      let bitmap=NSBitmapImageRep(cgImage:try await renderer.capture(width:240,height:240,transparent:true)),alpha=try XCTUnwrap(bitmap.colorAt(x:190,y:120)).alphaComponent
      if wide {XCTAssertGreaterThan(alpha,0.99)}else{XCTAssertLessThan(alpha,0.01)}
      XCTAssertEqual(renderer.diagnostics.meshBuilds,step+1,"A new, different physical resource cannot reuse a released resource's cached GPU buffer.")
    }
  }
}
