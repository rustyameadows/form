import AppKit
import FormCore
import FormCADModel
import FormGeometry
import FormGraphics
import LabRendering
import Metal
import simd
import XCTest
@testable import FormApp

@MainActor final class SheetAssemblyGeometryTests:XCTestCase {
  private let assets=FileManager.default.temporaryDirectory
  private func fixture()throws->(Project,ProductObject) {
    var project=Project(name:"Linked physical faces")
    for index in 0..<4 {
      var page=try project.makeObject(recipeID:"artboard",name:"Face \(index+1)",parameters:["width":100,"depth":140])
      let red=ArtworkElement(kind:"rectangle",x:5,y:5,width:8,height:8,color:"#FF0000")
      let blue=ArtworkElement(kind:"rectangle",x:85,y:5,width:8,height:8,color:"#0000FF")
      var text=ArtworkElement(kind:"text",x:20,y:30,width:40,height:24,text:index==1 ? "F":"P\(index+1)",color:"#000000",fontSize:30)
      text.typography = .init();text.typography!.fontName="HelveticaNeue-Medium"
      page.artwork=Artwork(background:"#FFFFFF",elements:[red,blue,text]);project.objects.append(page)
    }
    let id=try PublicationCommands.createPublication(in:&project,name:"Physical order",pages:project.objects.map(\.id))
    let stock=PaperStock(thicknessMM:0.2,profile:.init(texture:.smooth,color:"#FFFFFF",textureDepthMM:0))
    let assembly=try SheetAssemblyCommands.create(in:&project,definition:.init(publicationID:id,stock:stock,openingDegrees:180,activeSpread:1))
    return(project,project.objects.first{$0.id==assembly}!)
  }
  private func panel(_ root:MeshNode,_ leaf:UUID)throws->MeshNode {
    try XCTUnwrap(root.childNode(withName:SheetAssemblyGeometry.leafName(leaf),recursively:true)?.childNode(withName:PaperGeometry.panelPrefix+"face",recursively:true))
  }
  func testOpeningUpdatesPoseWithoutNewPhysicalMeshesTexturesOrCanonicalWrites()throws {
    var (project,object)=try fixture();object.sheetAssembly!.openingDegrees=130
    project.objects[project.objects.firstIndex{$0.id==object.id}!]=object
    let root=GeometryFactory.object(object,project:project,assets:assets,textureLimit:256)
    let revision=SheetAssemblyGeometry.sourceRevision(object,project:project)
    let meshes=PaperGeometry.physicalMeshBuilds,textures=PaperGeometry.textureBuilds
    let originalSources=project.objects.filter{$0.id != object.id}
    object.sheetAssembly!.openingDegrees=85
    project.objects[project.objects.firstIndex{$0.id==object.id}!]=object
    XCTAssertEqual(SheetAssemblyGeometry.sourceRevision(object,project:project),revision)
    let next=GeometryFactory.object(object,project:project,assets:assets,textureLimit:256)
    XCTAssertEqual(PaperGeometry.physicalMeshBuilds,meshes);XCTAssertEqual(PaperGeometry.textureBuilds,textures)
    let leaves=try project.resolvedSheetAssembly(object).leaves
    let old=try panel(root,leaves[0].id),new=try panel(next,leaves[0].id)
    XCTAssertNotEqual(old.worldTransform.raw,new.worldTransform.raw)
    XCTAssertEqual(old.geometry?.name,new.geometry?.name)
    XCTAssertEqual(project.objects.filter{$0.id != object.id},originalSources)
  }
  func testActualGPUActiveSpreadShowsCanonicalBackGlyphUprightAndPreservesWindingAndColors()async throws {
    guard MTLCreateSystemDefaultDevice() != nil else{throw XCTSkip("Native sheet registration requires Metal.")}
    let (project,object)=try fixture(),before=project
    let root=try SheetAssemblyGeometry.make(object,project:project,assets:assets,limit:1024)
    root.name="object:"+object.id.uuidString
    root.enumerateChildNodes{node,_ in for material in node.geometry?.materials ?? [] {material.lightingModel = .constant}}
    let resolved=try project.resolvedSheetAssembly(object),left=try panel(root,resolved.leaves[0].id)
    let scene=MeshScene();scene.rootNode.addChildNode(root)
    let adapter=GeometryPayloadAdapter(),renderer=try RealityKitSceneRenderer()
    for payload in adapter.renderables(scene:scene){try renderer.upsert(payload)}
    let camera=SceneCameraPayload.looking(from:.init(0,1000,0),at:.zero,up:.init(0,0,-1),projection:.orthographic(verticalSpanMM:165))
    try renderer.setCamera(camera)
    let captured=try await renderer.capture(width:1000,height:800,transparent:true)
    let image=NSBitmapImageRep(cgImage:captured)
    let evidence=FileManager.default.temporaryDirectory.appendingPathComponent("form-sheet-glyph-"+UUID().uuidString)
    try FileManager.default.createDirectory(at:evidence,withIntermediateDirectories:true)
    try XCTUnwrap(image.representation(using:.png,properties:[:])).write(to:evidence.appendingPathComponent("actual-gpu.png"))
    func saveImage(_ image:NSImage,_ name:String)throws {
      let cg=try XCTUnwrap(image.cgImage(forProposedRect:nil,context:nil,hints:nil))
      try XCTUnwrap(NSBitmapImageRep(cgImage:cg).representation(using:.png,properties:[:])).write(to:evidence.appendingPathComponent(name))
    }
    try saveImage(ArtworkRenderer.image(project.objects[1].artwork!,width:100,height:140,assets:assets,pixelsPerMM:8),"canonical-back.png")
    try saveImage(try XCTUnwrap(left.geometry?.materials[1].diffuse.contents as? NSImage),"physical-back-material.png")
    print("SHEET_GLYPH_EVIDENCE=\(evidence.path)")
    func color(_ canonical:Point2)throws->NSColor {
      // On a turned leaf, readable back coordinates are reversed only in the
      // physical registration; the camera sees their original left-to-right order.
      let local=MeshVector3((100-canonical.x)/100,-canonical.y/100,-0.001)
      let point=left.convertPosition(local,to:nil).simd*100
      let pixel=try XCTUnwrap(SceneProjection.project(point,camera:camera,viewport:.init(width:1000,height:800)))
      return try XCTUnwrap(image.colorAt(x:Int(pixel.x),y:Int(pixel.y))?.usingColorSpace(.sRGB))
    }
    let red=try color(.init(9,9)),blue=try color(.init(89,9))
    XCTAssertGreaterThan(red.redComponent,red.blueComponent+0.5)
    XCTAssertGreaterThan(blue.blueComponent,blue.redComponent+0.5)
    let source=project.objects[1].artwork!.elements.last!,outline=try TypographyEngine.outlines(source),bounds=outline.boundingBoxOfPath
    var sample:CGPoint?
    // Choose a genuinely interior, asymmetric glyph region rather than the first
    // outline crossing: source-map bilinear filtering and a GPU pixel footprint
    // can turn an edge-adjacent mathematical point into a half-covered texel.
    for radius in [0.45,0.40,0.35,0.30,0.25,0.20] where sample==nil {
      for y in 1..<40 {for x in 1..<40 where sample==nil {
        let point=CGPoint(x:bounds.minX+bounds.width*Double(x)/40,y:bounds.minY+bounds.height*Double(y)/40)
        let mirror=CGPoint(x:bounds.minX+bounds.maxX-point.x,y:point.y)
        let directions:[CGPoint]=[.init(x:1,y:0),.init(x:-1,y:0),.init(x:0,y:1),.init(x:0,y:-1),
          .init(x:0.707,y:0.707),.init(x:-0.707,y:0.707),.init(x:0.707,y:-0.707),.init(x:-0.707,y:-0.707)]
        let filled=directions.allSatisfy{outline.contains(.init(x:point.x+$0.x*radius,y:point.y+$0.y*radius),using:.winding,transform:.identity)}
        let empty=directions.allSatisfy{!outline.contains(.init(x:mirror.x+$0.x*radius,y:mirror.y+$0.y*radius),using:.winding,transform:.identity)}
        if filled && empty {sample=point}
      }}
    }
    let point=try XCTUnwrap(sample),mirror=CGPoint(x:bounds.minX+bounds.maxX-point.x,y:point.y)
    let ink=try color(.init(source.x+point.x,source.y+point.y)),paper=try color(.init(source.x+mirror.x,source.y+mirror.y))
    let samples:[String:Any]=["source_point":[point.x,point.y],"reflected_point":[mirror.x,mirror.y],
      "actual_ink_red":ink.redComponent,"actual_reflected_red":paper.redComponent]
    try JSONSerialization.data(withJSONObject:samples,options:[.prettyPrinted,.sortedKeys]).write(to:evidence.appendingPathComponent("samples.json"))
    XCTAssertLessThan(ink.redComponent,0.35,"An asymmetric F must appear in its canonical orientation on the left page.")
    XCTAssertGreaterThan(paper.redComponent,0.65,"The reflected F location must remain unprinted.")
    XCTAssertEqual(project,before)
  }
  func testCoverCropsTranslateWithoutScalingAndFinalSamplingSpendsOnExposedFaces()throws {
    var (project,object)=try fixture()
    var wrap=try project.makeObject(recipeID:"artboard",parameters:["width":210,"depth":140])
    let mark=ArtworkElement(kind:"text",x:115,y:20,width:70,height:20,text:"Front original",fontSize:18)
    wrap.artwork=Artwork(elements:[mark]);project.objects.append(wrap)
    let face=ResolvedSheetAssemblyFace(sourceObjectID:wrap.id,sourceSide:.outside,originMM:.init(110,0))
    let cropped=try XCTUnwrap(SheetAssemblyGeometry.prepared(face,size:.init(100,140),inside:false,project:project))
    let value=try XCTUnwrap(cropped.elements.first)
    XCTAssertEqual(cropped.worldTransform(value).apply(.init()).x,5,accuracy:1e-10)
    XCTAssertEqual(value.width,mark.width);XCTAssertEqual(value.fontSize,mark.fontSize);XCTAssertEqual(value.text,mark.text)
    object.sheetAssembly!.openingDegrees=180
    project.objects[project.objects.firstIndex{$0.id==object.id}!]=object
    let controller=TableSceneController()
    controller.sync(project,selection:[],isolated:[],showGrid:false,studio:true,preset:"Daylight",assets:assets,textureLimit:256,renderObjectIDs:[object.id])
    let camera=SceneCameraPayload.looking(from:.init(0,1000,0),at:.zero,up:.init(0,0,-1),projection:.orthographic(verticalSpanMM:165))
    let plans=try StudioSourceSampling.plans(controller:controller,project:project,camera:camera,
      viewport:.init(width:3072,height:2400),objectIDs:[object.id],maximumEdge:8192)
    let plan=try XCTUnwrap(plans[object.id]),leaves=try project.resolvedSheetAssembly(object).leaves
    let left=try XCTUnwrap(plan.surfaces[SheetAssemblyGeometry.surfaceKey("leaf:"+leaves[0].id.uuidString,inside:true)])
    let hidden=try XCTUnwrap(plan.surfaces[SheetAssemblyGeometry.surfaceKey("leaf:"+leaves[0].id.uuidString,inside:false)])
    XCTAssertGreaterThan(left.maximumPixels,100_000);XCTAssertLessThanOrEqual(hidden.maximumPixels,64)
    XCTAssertLessThanOrEqual(plan.surfaces.values.reduce(0){$0+$1.maximumPixels},SourceTextureSampling.maximumPixels)
    XCTAssertEqual(project.objects.first{$0.id==wrap.id},wrap)
  }
  func testCanonicalStoryEditChangesActualPaperMaterialPixelsWhilePageFramesStayExact()throws {
    var (project,object)=try fixture()
    object.sheetAssembly!.openingDegrees=0;object.sheetAssembly!.activeSpread=0
    project.objects[project.objects.firstIndex{$0.id==object.id}!]=object
    let page=project.objects[0],frame=StoryFrameID(objectID:page.id,elementID:page.artwork!.elements.last!.id)
    let story=try PublicationCommands.createStory(in:&project,frames:[frame],publicationID:object.sheetAssembly!.publicationID)
    let sources=project.objects,resolved=try project.resolvedSheetAssembly(object)
    func materialPixels(_ project:Project)throws->(Data,String?) {
      let root=try SheetAssemblyGeometry.make(object,project:project,assets:assets,limit:1024)
      let face=try panel(root,resolved.leaves[0].id),image=try XCTUnwrap(face.geometry?.materials[0].diffuse.contents as? NSImage)
      let cg=try XCTUnwrap(image.cgImage(forProposedRect:nil,context:nil,hints:nil))
      let bytes=try XCTUnwrap(cg.dataProvider?.data)
      return (bytes as Data,face.geometry?.name)
    }
    let before=try materialPixels(project),beforeRevision=SheetAssemblyGeometry.sourceRevision(object,project:project)
    var text=project.textStories!.first{$0.id==story}!.sourceElement;text.text="WWWWWW"
    try PublicationCommands.setSource(in:&project,storyID:story,source:text)
    XCTAssertEqual(project.objects,sources,"Original page frames keep only stable story references.")
    let after=try materialPixels(project)
    XCTAssertNotEqual(after.0,before.0,"The actual printed face map must refresh when only the canonical story changes.")
    XCTAssertEqual(after.1,before.1,"A source text edit must not rebuild stock topology.")
    XCTAssertNotEqual(SheetAssemblyGeometry.sourceRevision(object,project:project),beforeRevision)
  }
  private func curvedFixture(width:Double=40,height:Double=60,thickness:Double=0.4,bend:Double=20,active:Int=0)throws->(Project,ProductObject) {
    var project=Project(name:"Actual curved source tails"),pages=[UUID]()
    for index in 0..<64 {
      var page=try project.makeObject(recipeID:"artboard",name:"Canonical \(index+1)",parameters:["width":width,"depth":height])
      page.artwork=Artwork(background:index==61 ? "#00FF00":"#0000FF",elements:[])
      project.objects.append(page);pages.append(page.id)
    }
    let publication=try PublicationCommands.createPublication(in:&project,name:"Curved material source",pages:pages)
    let stock=PaperStock(thicknessMM:thickness,profile:.init(texture:.smooth,color:"#FFFFFF",textureDepthMM:0))
    let id=try SheetAssemblyCommands.create(in:&project,definition:.init(publicationID:publication,stock:stock,
      openingDegrees:180,activeSpread:active,bendMM:bend))
    return(project,project.objects.first{$0.id==id}!)
  }
  func testActualGPUBentLowerPrintedCapRemainsVisibleBeyondItsOpaqueNeighbor()async throws {
    guard MTLCreateSystemDefaultDevice() != nil else{throw XCTSkip("Native curved source proof requires Metal.")}
    let(project,object)=try curvedFixture(),before=project
    let resolved=try project.resolvedSheetAssembly(object),inner=resolved.leaves[30],outer=resolved.leaves[31]
    let root=try SheetAssemblyGeometry.make(object,project:project,assets:assets,limit:128)
    root.enumerateChildNodes{node,_ in for material in node.geometry?.materials ?? [] {material.lightingModel = .constant}}
    let node=try panel(root,inner.id)
    var low=0.0,high=Double.pi/2
    for _ in 0..<40 {let a=(low+high)/2;if 40*(1-cos(a))/a<20 {low=a}else{high=a}}
    let radius=40/((low+high)/2),innerRadius=radius-inner.stackOffsetMM,outerRadius=radius-outer.stackOffsetMM
    let angle=(40/innerRadius+40/outerRadius)/2
    let surfaceRadius=radius-inner.stackOffsetMM+inner.stock.resolvedThicknessMM/2
    let local=MeshVector3(surfaceRadius*sin(angle)/100,-0.3,(radius-surfaceRadius*cos(angle))/100)
    let point=node.convertPosition(local,to:nil).simd*100
    let origin=node.convertPosition(.init(),to:nil).simd
    let direction=node.convertPosition(.init(sin(angle),0,-cos(angle)),to:nil).simd-origin
    let camera=SceneCameraPayload.looking(from:point+simd_normalize(direction)*1000,at:point,up:.init(0,0,-1),projection:.orthographic(verticalSpanMM:3))
    let scene=MeshScene();scene.rootNode.addChildNode(root)
    let adapter=GeometryPayloadAdapter(),renderer=try RealityKitSceneRenderer()
    for payload in adapter.renderables(scene:scene){try renderer.upsert(payload)}
    try renderer.setCamera(camera)
    let captured=try await renderer.capture(width:800,height:600,transparent:true)
    let bitmap=NSBitmapImageRep(cgImage:captured)
    let pixel=try XCTUnwrap(SceneProjection.project(point,camera:camera,viewport:.init(width:800,height:600)))
    var red=0.0,green=0.0,blue=0.0
    for dy in -2...2 {for dx in -2...2 {
      let color=try XCTUnwrap(bitmap.colorAt(x:Int(pixel.x)+dx,y:Int(pixel.y)+dy)?.usingColorSpace(.sRGB))
      red+=color.redComponent;green+=color.greenComponent;blue+=color.blueComponent
    }}
    let evidence=FileManager.default.temporaryDirectory.appendingPathComponent("form-bent-cap-"+UUID().uuidString)
    try FileManager.default.createDirectory(at:evidence,withIntermediateDirectories:true)
    try XCTUnwrap(bitmap.representation(using:.png,properties:[:])).write(to:evidence.appendingPathComponent("actual-exposed-back-cap.png"))
    print("BENT_CAP_EVIDENCE=\(evidence.path)")
    XCTAssertGreaterThan(green/25,0.8)
    XCTAssertGreaterThan((green-red)/25,0.6)
    XCTAssertGreaterThan((green-blue)/25,0.6,"The real exposed back cap must retain its green canonical printing; white blank stock is incorrect.")
    XCTAssertEqual(project,before)
  }
  func testSixtyFourPageCurvedSourcePlansPrioritizeExteriorFacesAndKeepEditingAndFinalBudgetsBounded()throws {
    let(project,object)=try curvedFixture(width:180,height:240,thickness:0.12,bend:2.4,active:16)
    let resolved=try project.resolvedSheetAssembly(object),controller=TableSceneController()
    controller.sync(project,selection:[],isolated:[],showGrid:false,studio:true,preset:"Daylight",assets:assets,textureLimit:512,renderObjectIDs:[object.id])
    let subject=try XCTUnwrap(controller.objectRoot.childNode(withName:"object:"+object.id.uuidString,recursively:false))
    var editingPixels=0
    for surface in try SheetAssemblyGeometry.surfaces(root:subject,object:object,project:project) {
      let material=try XCTUnwrap(surface.node.geometry?.materials[surface.inside ? 1:0])
      let image=try XCTUnwrap(material.diffuse.contents as? NSImage)
      let cg=try XCTUnwrap(image.cgImage(forProposedRect:nil,context:nil,hints:nil))
      editingPixels+=cg.width*cg.height
    }
    XCTAssertLessThanOrEqual(editingPixels,512*512)
    let camera=SceneCameraPayload.looking(from:.init(0,1500,0),at:.zero,up:.init(0,0,-1),projection:.orthographic(verticalSpanMM:300))
    let plans=try StudioSourceSampling.plans(controller:controller,project:project,camera:camera,viewport:.init(width:2400,height:1800),objectIDs:[object.id],maximumEdge:8192)
    let plan=try XCTUnwrap(plans[object.id])
    let primary=try XCTUnwrap(plan.surfaces[SheetAssemblyGeometry.surfaceKey("leaf:"+resolved.leaves[16].id.uuidString,inside:false)])
    let tail=try XCTUnwrap(plan.surfaces[SheetAssemblyGeometry.surfaceKey("leaf:"+resolved.leaves[17].id.uuidString,inside:false)])
    XCTAssertGreaterThan(tail.maximumPixels,64)
    XCTAssertGreaterThan(primary.maximumPixels,tail.maximumPixels*5)
    let charged=plan.surfaces.values.reduce(0){$0+$1.maximumPixels}
    XCTAssertLessThanOrEqual(charged,SourceTextureSampling.maximumPixels)
    var actualPixels=0
    for value in plan.surfaces.values {let size=try value.rasterSize(width:180,height:240);actualPixels+=size.width*size.height}
    XCTAssertLessThanOrEqual(actualPixels,charged)
    print("BENT_SOURCE_BUDGET=faces:\(plan.surfaces.count),editingPixels:\(editingPixels),finalPixels:\(actualPixels),chargedPixels:\(charged),primaryPixels:\(primary.maximumPixels),tailPixels:\(tail.maximumPixels),sourceBytes:\(charged*SourceTextureSampling.chargedBytesPerPixel)")
    XCTAssertEqual(project.objects.count,65)
  }
  func testBendPreservesMaterialArcCoordinatesRealPlySlotsAndNonzeroCaliper()throws {
    let polygon:[Point2]=[.init(0,0),.init(100,0),.init(100,140),.init(0,140)]
    let base=try PaperGeometry.panelMesh(.init(id:"sheet",name:"Sheet",role:.body,polygon:polygon),netSize:.init(100,140),thicknessMM:0.2)
    let source=base.sources(for:.vertex).first!.vectors
    let bent=try SheetAssemblyGeometry.bent(base,widthMM:100,riseMM:12,normalOffsetMM:0.4,segments:32)
    XCTAssertEqual(base.sources(for:.vertex).first!.vectors,source)
    XCTAssertEqual(bent.elements.count,base.elements.count)
    let positions=bent.sources(for:.vertex).first!.vectors,uv=bent.sources(for:.texcoord).first!.points
    XCTAssertGreaterThan(positions.count,source.count);XCTAssertLessThan(positions.count,500_000)
    XCTAssertGreaterThan(positions.map{$0.z*100}.max()!,12)
    XCTAssertLessThan(positions.map{$0.x*100}.max()!,100,"Bending conserves physical arc length rather than stretching XY width.")
    XCTAssertTrue(uv.allSatisfy{$0.x>=(-1e-8) && $0.x<=1+1e-8 && $0.y>=(-1e-8) && $0.y<=1+1e-8})
    var low=0.0,high=Double.pi/2
    for _ in 0..<40 {let angle=(low+high)/2;if 100*(1-cos(angle))/angle<12 {low=angle}else{high=angle}}
    let referenceRadius=100/((low+high)/2),neutralRadius=referenceRadius-0.4
    for (index,p) in positions.enumerated() {
      let angle=atan2(p.x*100,referenceRadius-p.z*100)
      XCTAssertEqual(neutralRadius*angle,Double(uv[index].x)*100,accuracy:1e-7,
        "Each neutral leaf must preserve its original physical material coordinate despite its stack offset.")
    }
    let normals=bent.sources(for:.normal).first!.vectors
    XCTAssertTrue(normals.allSatisfy{$0.x.isFinite && $0.y.isFinite && $0.z.isFinite})
    for normal in normals {XCTAssertEqual(simd_length(normal.simd),1,accuracy:1e-10)}
    let flatNormals=base.sources(for:.normal).first!.vectors
    XCTAssertTrue(flatNormals.contains{abs($0.x)>0.01 && abs($0.z)>0.01},"The fixture must include real bevel normals.")
    let narrow=try PaperGeometry.panelMesh(.init(id:"narrow",name:"Narrow sheet",role:.body,
      polygon:[.init(0,0),.init(1,0),.init(1,4),.init(0,4)]),netSize:.init(1,4),thicknessMM:0.02)
    // This valid0.02mm stock has less than the old arbitrary0.5mm radius reserve.
    XCTAssertNoThrow(try SheetAssemblyGeometry.bent(narrow,widthMM:1,riseMM:0.05,normalOffsetMM:9.6,segments:16))
    XCTAssertThrowsError(try SheetAssemblyGeometry.bent(base,widthMM:100,riseMM:12,normalOffsetMM:1000,segments:32))
  }
}
