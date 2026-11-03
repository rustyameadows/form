import AppKit
import CoreGraphics
import ImageIO
import Metal
import RealityKit
import simd
import XCTest
import FormCore
import FormGeometry
import FormGraphics
import LabRendering
@testable import FormApp

/// Identical physical buffers/camera, with lighting/material channels isolated.
/// An optional native record replays retained source data; the default fixture is
/// a portable32-leaf stack with the same0.12mm caliper and foreedge camera scale.
@MainActor final class ForeedgeShadowDiagnosticsTests:XCTestCase {
  private func fixture()throws->(Project,ProductObject,URL,StudioShot) {
    let env=ProcessInfo.processInfo.environment
    if let file=env["LAB_FOREEDGE_RENDER_RECORD"],let library=env["LAB_FOREEDGE_PROJECT_LIBRARY"] {
      let record=try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:file))) as! [String:Any]
      let repository=try ProjectRepository(root:URL(fileURLWithPath:library))
      var project=try repository.load(try XCTUnwrap(UUID(uuidString:record["project_id"] as! String)))
      let shot=try JSONDecoder.form.decode(StudioShot.self,from:JSONSerialization.data(withJSONObject:record["shot"]!))
      let objectID=try XCTUnwrap(shot.visibility.objectIDs.first),index=try XCTUnwrap(project.objects.firstIndex{$0.id==objectID})
      project.objects[index].sheetAssembly!.openingDegrees=0;project.objects[index].sheetAssembly!.activeSpread=0;project.objects[index].sheetAssembly!.bendMM=0
      project.objects[index].sheetAssembly!.stock.thicknessMM=0.12
      return(project,project.objects[index],repository.url(for:project.id).appendingPathComponent("Assets"),shot)
    }
    var project=Project(name:"Physical foreedge lighting regression")
    for _ in 0..<64 {
      var page=try project.makeObject(recipeID:"artboard",parameters:["width":180,"depth":240])
      page.artwork = .init(background:"#F4EDDD",elements:[]);project.objects.append(page)
    }
    let publication=try PublicationCommands.createPublication(in:&project,name:"Source leaves",pages:project.objects.map(\.id))
    let stock=PaperStock(thicknessMM:0.12,profile:.init(texture:.cotton,color:"#F4EDDD",roughness:0.92,textureDepthMM:0.006))
    let objectID=try SheetAssemblyCommands.create(in:&project,definition:.init(publicationID:publication,stock:stock))
    let object=try XCTUnwrap(project.objects.first{$0.id==objectID})
    var shot=StudioShot(name:"Matched foreedge",camera:.init(),referenceAspect:1.25)
    shot.camera.azimuth=1.4121410646084953;shot.camera.elevation=0.11794293251491761;shot.camera.distance=0.8879852851080742
    shot.camera.target = .init(1.805,0.0438,0);shot.camera.viewportAspect=1.25
    shot.pixels = .init(width:2000,height:1600);shot.lighting="soft-side-v1";shot.surface="Daylight"
    shot.visibility = .init(mode:.objects,objectIDs:[object.id])
    return(project,object,FileManager.default.temporaryDirectory,shot)
  }
  /// Diagnostic-only copies retain every physical point/face while isolating
  /// geometric-normal interpolation across the long, subpixel bevel strips.
  private func edgeDiagnostic(_ original:SceneMeshPayload,refine:Bool)throws->SceneMeshPayload {
    var mesh=original,changed=false
    for partIndex in original.parts.indices where original.parts[partIndex].materialIndex==2 {
      let part=original.parts[partIndex]
      if !refine {
        for index in Set(part.triangleIndices) {
          let i=Int(index),n=mesh.normals[i],length=hypot(n.x,n.y)
          if length>0 {mesh.normals[i] = .init(n.x/length,n.y/length,0);changed=true}
        }
        continue
      }
      var indices=[UInt32]()
      for offset in stride(from:0,to:part.triangleIndices.count,by:6) {
        guard offset+6<=part.triangleIndices.count else{throw FormError.invalid("Expected source edge quads")}
        let old=Array(part.triangleIndices[offset..<offset+6]).map{Int($0)}
        func same(_ a:Int,_ b:Int)->Bool {original.positionsMM[a]==original.positionsMM[b] && original.normals[a]==original.normals[b]}
        var corners:[Int]
        if same(old[0],old[3]),same(old[2],old[4]) {corners=[old[0],old[1],old[2],old[5]]}
        else if same(old[0],old[3]),same(old[1],old[5]) {corners=[old[0],old[4],old[1],old[2]]}
        else {throw FormError.invalid("Source edge triangles lost their common authored quad")}
        func distance(_ a:Int,_ b:Int)->Double {simd_distance(original.positionsMM[corners[a]],original.positionsMM[corners[b]])}
        if distance(0,1)+distance(3,2)<distance(1,2)+distance(0,3) {corners=[corners[1],corners[2],corners[3],corners[0]]}
        let count=max(1,Int(ceil(max(distance(0,1),distance(3,2))/2)))
        for segment in 0..<count {
          let start=UInt32(mesh.positionsMM.count)
          for (a,b,f) in [(0,1,Double(segment)/Double(count)),(0,1,Double(segment+1)/Double(count)),(3,2,Double(segment+1)/Double(count)),(3,2,Double(segment)/Double(count))] {
            let a=corners[a],b=corners[b],t=Float(f)
            mesh.positionsMM.append(original.positionsMM[a]+(original.positionsMM[b]-original.positionsMM[a])*f)
            if !original.normals.isEmpty{mesh.normals.append(simd_normalize(original.normals[a]*(1-t)+original.normals[b]*t))}
            if !original.uvs.isEmpty{mesh.uvs.append(original.uvs[a]*(1-t)+original.uvs[b]*t)}
            if !original.uvs1.isEmpty{mesh.uvs1.append(original.uvs1[a]*(1-t)+original.uvs1[b]*t)}
            if !original.tangents.isEmpty{mesh.tangents.append(original.tangents[a]*(1-t)+original.tangents[b]*t)}
            if !original.colors.isEmpty{mesh.colors.append(original.colors[a]*(1-t)+original.colors[b]*t)}
          }
          indices += [0,1,2,0,2,3].map{start+UInt32($0)};changed=true
        }
      }
      mesh.parts[partIndex].triangleIndices=indices
    }
    if changed {
      mesh.id += refine ? ":refined-edge-strips":":flat-edge-normals";mesh.revision += ":diagnostic"
      for axis in 0..<3 {
        XCTAssertEqual(mesh.positionsMM.map{$0[axis]}.min()!,original.positionsMM.map{$0[axis]}.min()!,accuracy:1e-9)
        XCTAssertEqual(mesh.positionsMM.map{$0[axis]}.max()!,original.positionsMM.map{$0[axis]}.max()!,accuracy:1e-9)
      }
    }
    return mesh
  }
  private func integratePixels(_ image:CGImage,width:Int,height:Int)throws->CGImage {
    let scale=image.width/width
    guard scale>0,image.width==width*scale,image.height==height*scale,image.bitsPerComponent==8,image.bitsPerPixel==32,image.alphaInfo == .premultipliedLast else{throw FormError.invalid("Pixel integration needs the native opaque RGBA capture and an integer sampling ratio")}
    let input=try XCTUnwrap(image.dataProvider?.data),source=try XCTUnwrap(CFDataGetBytePtr(input)),samples=UInt32(scale*scale)
    let decode=(0..<256).map{index->UInt32 in let v=Double(index)/255;return UInt32(((v<=0.04045 ? v/12.92:pow((v+0.055)/1.055,2.4))*65535).rounded())}
    let encode=(0..<65536).map{index->UInt8 in let v=Double(index)/65535;return UInt8(((v<=0.0031308 ? 12.92*v:1.055*pow(v,1/2.4)-0.055)*255).rounded())}
    var bytes=[UInt8](repeating:255,count:width*height*4),opaque=true
    bytes.withUnsafeMutableBufferPointer { output in
      for y in 0..<height {for x in 0..<width {
        var r:UInt32=0,g:UInt32=0,b:UInt32=0
        for sy in 0..<scale {let row=(y*scale+sy)*image.bytesPerRow
          for sx in 0..<scale {let i=row+(x*scale+sx)*4;r+=decode[Int(source[i])];g+=decode[Int(source[i+1])];b+=decode[Int(source[i+2])];if source[i+3] != 255{opaque=false}}
        }
        let i=(y*width+x)*4;output[i]=encode[Int(r/samples)];output[i+1]=encode[Int(g/samples)];output[i+2]=encode[Int(b/samples)]
      }}
    }
    guard opaque else{throw FormError.invalid("This energy-integration control requires an opaque native capture")}
    let provider=try XCTUnwrap(CGDataProvider(data:Data(bytes) as CFData)),space=try XCTUnwrap(CGColorSpace(name:CGColorSpace.sRGB))
    return try XCTUnwrap(CGImage(width:width,height:height,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:width*4,space:space,bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue),provider:provider,decode:nil,shouldInterpolate:true,intent:.defaultIntent))
  }
  func testLinearPixelIntegrationPreservesEnergyAndDimensions()throws {
    let bytes:[UInt8]=(0..<8).flatMap{index in index%2==0 ? [0,0,0,255]:[255,255,255,255]}
    let provider=try XCTUnwrap(CGDataProvider(data:Data(bytes) as CFData)),space=try XCTUnwrap(CGColorSpace(name:CGColorSpace.sRGB))
    let input=try XCTUnwrap(CGImage(width:4,height:2,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:16,space:space,bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue),provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent))
    let output=try integratePixels(input,width:2,height:1)
    XCTAssertEqual(output.width,2);XCTAssertEqual(output.height,1)
    XCTAssertTrue(CFEqual(try XCTUnwrap(output.colorSpace?.name),CGColorSpace.sRGB))
    let stored=try XCTUnwrap(output.dataProvider?.data),storedBytes=try XCTUnwrap(CFDataGetBytePtr(stored))
    let readback=try XCTUnwrap(CGContext(data:nil,width:2,height:1,bitsPerComponent:8,bytesPerRow:8,space:space,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
    readback.setBlendMode(.copy);readback.interpolationQuality = .none;readback.draw(output,in:.init(x:0,y:0,width:2,height:1))
    let samples=try XCTUnwrap(readback.data).assumingMemoryBound(to:UInt8.self)
    for x in 0..<2 {
      for channel in 0..<3 {
        XCTAssertLessThanOrEqual(abs(Int(storedBytes[x*4+channel])-188),1,"Stored sRGB must retain the linear-light50% energy, not gamma-space128")
        XCTAssertLessThanOrEqual(abs(Int(samples[x*4+channel])-188),1,"Explicit sRGB readback must retain the same energy")
      }
      XCTAssertEqual(storedBytes[x*4+3],255);XCTAssertEqual(samples[x*4+3],255)
    }
  }
  func testActualGPUForeedgeShadowAndMaterialIsolationRetainsPhysicalCalipersAndCamera()async throws {
    guard MTLCreateSystemDefaultDevice() != nil else{throw XCTSkip("Foreedge regression requires the actual Metal renderer.")}
    let(project,object,assets,shot)=try fixture(),before=project
    let controller=TableSceneController()
    controller.sync(project,selection:[],isolated:[object.id],showGrid:false,studio:true,preset:shot.surface,assets:assets,textureLimit:256,renderObjectIDs:[object.id])
    controller.camera=shot.camera;controller.updateCamera();controller.applyShotLighting(shot.lighting,studio:true)
    let camera=controller.cameraPayload(),viewport=CGSize(width:2000,height:1600)
    let plans=try StudioSourceSampling.plans(controller:controller,project:project,camera:camera,viewport:viewport,objectIDs:[object.id],maximumEdge:8192)
    controller.sync(project,selection:[],isolated:[object.id],showGrid:false,studio:true,preset:shot.surface,assets:assets,textureLimit:256,renderObjectIDs:[object.id],sourceSampling:plans)
    let payloads=GeometryPayloadAdapter().renderables(scene:controller.scene)
    let renderer=try RealityKitSceneRenderer();try renderer.setCamera(camera)
    let source=try project.resolvedSheetAssembly(object)
    XCTAssertEqual(source.leaves.count,32);XCTAssertEqual(source.stackThicknessMM,3.84,accuracy:1e-9)
    let folder=ProcessInfo.processInfo.environment["LAB_FOREEDGE_EVIDENCE_DIR"].map{URL(fileURLWithPath:$0)} ?? FileManager.default.temporaryDirectory.appendingPathComponent("form-foreedge-shadow-"+UUID().uuidString)
    try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
    let q=controller.keyLight.simdOrientation.act(.init(0,0,1))
    let background=GeometryPayloadAdapter.color(controller.scene.background.contents),keyColor=GeometryPayloadAdapter.color(controller.keyLight.light?.color)
    var images=[String:NSBitmapImageRep](),reports=[[String:Any]]()
    var builds:Int?
    for (name,shadows,unlit,plain,edgeMode) in [("lit-shadow",true,false,false,0),("lit-no-shadow",false,false,false,0),("constant-textured",false,true,false,0),("plain-shadow",true,false,true,0),("plain-no-shadow",false,false,true,0),("plain-backface-culled",false,false,true,0),("plain-supersampled2x",false,false,true,0),("plain-uv-free",false,false,true,3),("plain-flat-edge-normals",false,false,true,1),("plain-refined-edge-strips",false,false,true,2)] {
      var changedComponents=0,triangleCount=0
      for var payload in payloads {
        if edgeMode>0 {let originalID=payload.mesh.id
          if edgeMode==3 {payload.mesh.uvs=[];payload.mesh.uvs1=[];payload.mesh.tangents=[];payload.mesh.id += ":uv-free";payload.mesh.revision += ":diagnostic"}
          else {payload.mesh=try edgeDiagnostic(payload.mesh,refine:edgeMode==2)}
          if payload.mesh.id != originalID{changedComponents+=1}
        }
        triangleCount+=payload.mesh.triangleCount
        payload.materials=payload.materials.map{original in
          var value=original;value.revision += ":"+name;value.unlit=unlit
          if name=="plain-backface-culled" {value.doubleSided=false}
          if plain {value.baseColor = .init(0.8,0.8,0.8,1);value.baseColorTexture=nil;value.normalTexture=nil;value.metallicTexture=nil;value.roughnessTexture=nil;value.ambientOcclusionTexture=nil;value.emissiveTexture=nil;value.metallic=0;value.roughness=1;value.emissiveColor = .zero}
          return value
        }
        try renderer.upsert(payload)
      }
      try renderer.setLighting(.init(background:background,keyDirection:.init(Float(-q.x),Float(-q.y),Float(-q.z)),keyColor:.init(keyColor.x,keyColor.y,keyColor.z),keyIntensity:3375,fillIntensity:516,shadows:shadows))
      let supersampled=name=="plain-supersampled2x"
      let captured=try await renderer.capture(width:supersampled ? 4000:2000,height:supersampled ? 3200:1600)
      let image:CGImage
      if supersampled {image=try integratePixels(captured,width:2000,height:1600)}else{image=captured}
      let bitmap=NSBitmapImageRep(cgImage:image)
      XCTAssertEqual(image.width,2000);XCTAssertEqual(image.height,1600)
      try XCTUnwrap(bitmap.representation(using:.png,properties:[:])).write(to:folder.appendingPathComponent(name+".png"))
      images[name]=bitmap
      if edgeMode==0 {if let builds {XCTAssertEqual(renderer.diagnostics.meshBuilds,builds,"Lighting/texture diagnostics cannot replace physical geometry")}else{builds=renderer.diagnostics.meshBuilds}}
      if edgeMode>0 {XCTAssertGreaterThanOrEqual(changedComponents,32,"The diagnostic must actually modify every physical leaf edge")}
      reports.append(["mode":name,"mesh_builds":renderer.diagnostics.meshBuilds,"caliper_mm":0.12,"stack_thickness_mm":source.stackThicknessMM,"geometry_diagnostic_components":changedComponents,"triangles":triangleCount,"capture_width":captured.width,"capture_height":captured.height])
    }
    // Probe the actual side face at each physical leaf midplane. Consecutive
    // second differences distinguish high-frequency dashes from smooth lighting.
    func luminance(_ bitmap:NSBitmapImageRep,_ point:CGPoint)->Double? {
      let x=Int(point.x.rounded()),y=Int(point.y.rounded())
      guard (0..<bitmap.pixelsWide).contains(x),(0..<bitmap.pixelsHigh).contains(y),let c=bitmap.colorAt(x:x,y:y)?.usingColorSpace(.sRGB) else{return nil}
      return 0.2126*Double(c.redComponent)+0.7152*Double(c.greenComponent)+0.0722*Double(c.blueComponent)
    }
    var metrics=[String:Double]()
    let root=try XCTUnwrap(controller.objectRoot.childNode(withName:"object:"+object.id.uuidString,recursively:false))
    for (name,bitmap) in images {
      var variation=[Double]()
      for leaf in source.leaves.dropFirst(4).dropLast(4) {
        let node=try XCTUnwrap(root.childNode(withName:SheetAssemblyGeometry.leafName(leaf.id),recursively:true)?.childNode(withName:PaperGeometry.panelPrefix+"face",recursively:true))
        var row=[Double]()
        for index in 0...1000 {
          let local=MeshVector3(leaf.size.x/100,-leaf.size.y*Double(index)/1000/100,0)
          let world=node.convertPosition(local,to:nil).simd*100
          if let projected=SceneProjection.project(world,camera:camera,viewport:viewport),let value=luminance(bitmap,projected){row.append(value)}
        }
        if row.count>2 {for index in 1..<(row.count-1){variation.append(abs(row[index-1]-2*row[index]+row[index+1]))}}
      }
      metrics[name]=variation.isEmpty ? 0:variation.reduce(0,+)/Double(variation.count)
    }
    let report:[String:Any]=["modes":reports,"high_frequency_foreedge_variation":metrics,"physical_geometry_unchanged":project==before,"width":2000,"height":1600]
    try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:folder.appendingPathComponent("diagnostics.json"))
    XCTAssertEqual(project,before);XCTAssertEqual(images.count,10)
    print("FOREDGE_SHADOW_EVIDENCE=\(folder.path)")
    print("FOREDGE_SHADOW_METRICS=\(metrics)")
  }
  func testActualGPUForeedgeDepthAndLayerIsolation()async throws {
    guard MTLCreateSystemDefaultDevice() != nil else{throw XCTSkip("Foreedge regression requires the actual Metal renderer.")}
    let(project,object,assets,shot)=try fixture(),before=project
    let controller=TableSceneController()
    controller.sync(project,selection:[],isolated:[object.id],showGrid:false,studio:true,preset:shot.surface,assets:assets,textureLimit:256,renderObjectIDs:[object.id])
    controller.camera=shot.camera;controller.updateCamera();controller.applyShotLighting(shot.lighting,studio:true)
    let camera=controller.cameraPayload(),viewport=CGSize(width:2000,height:1600)
    let plans=try StudioSourceSampling.plans(controller:controller,project:project,camera:camera,viewport:viewport,objectIDs:[object.id],maximumEdge:8192)
    controller.sync(project,selection:[],isolated:[object.id],showGrid:false,studio:true,preset:shot.surface,assets:assets,textureLimit:256,renderObjectIDs:[object.id],sourceSampling:plans)
    let payloads=GeometryPayloadAdapter().renderables(scene:controller.scene),source=try project.resolvedSheetAssembly(object)
    XCTAssertEqual(source.leaves.count,32);XCTAssertEqual(source.stackThicknessMM,3.84,accuracy:1e-9)
    let chosen=source.leaves[source.leaves.count/2],view=simd_inverse(camera.worldFromCameraMM)
    var depths=[Double]()
    for payload in payloads where payload.objectID==object.id && payload.visible {
      for p in payload.mesh.positionsMM {let q=view*payload.transform.matrixMM*SIMD4(p,1);depths.append(-q.z)}
    }
    let closest=try XCTUnwrap(depths.min()),farthest=try XCTUnwrap(depths.max())
    XCTAssertGreaterThan(closest,0)
    var tight=camera;tight.nearMM=max(0.001,closest*0.5);tight.farMM=max(tight.nearMM+1,farthest*1.25)
    try tight.validate();XCTAssertTrue(depths.allSatisfy{$0>tight.nearMM && $0<tight.farMM})
    let folder=(ProcessInfo.processInfo.environment["LAB_FOREEDGE_EVIDENCE_DIR"].map{URL(fileURLWithPath:$0)} ?? FileManager.default.temporaryDirectory.appendingPathComponent("form-foreedge-depth-"+UUID().uuidString)).appendingPathComponent("depth-and-layers")
    try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
    let renderer=try RealityKitSceneRenderer(),q=controller.keyLight.simdOrientation.act(.init(0,0,1))
    let background=GeometryPayloadAdapter.color(controller.scene.background.contents),keyColor=GeometryPayloadAdapter.color(controller.keyLight.light?.color)
    let root=try XCTUnwrap(controller.objectRoot.childNode(withName:"object:"+object.id.uuidString,recursively:false))
    var reports=[[String:Any]]()
    let modes:[(String,Int,Bool,Int,Bool)]=[
      ("stack-reference",0,false,0,false),("stack-grounding-disabled",0,false,0,false),("stack-tight-clips",1,false,0,false),
      ("stack-near-only",2,false,0,false),("stack-far-only",3,false,0,false),
      ("single-leaf",0,true,0,false),("single-leaf-tight-clips",1,true,0,false),
      ("stack-buried-caps-removed",0,false,1,false),("stack-all-leaf-caps-removed",0,false,2,false),
      ("single-leaf-caps-removed",0,true,2,false),
      ("stack-geometric-bevel-normals",0,false,0,true),("stack-geometric-bevel-normals-tight",1,false,0,true)]
    for (name,clipMode,single,capMode,faceted) in modes {
      var visibleLeaves=Set<UUID>(),removedTriangles=0,changedNormalVertices=0
      var disabledCapOnlyComponents=[String]()
      for var payload in payloads {
        let original=payload.mesh,leaf=source.leaves.first{payload.componentID.contains(SheetAssemblyGeometry.leafName($0.id))}
        if single,payload.objectID==object.id {payload.visible=payload.visible && leaf?.id==chosen.id}
        if let leaf,payload.visible{visibleLeaves.insert(leaf.id)}
        if let leaf,capMode>0 {
          payload.mesh.parts=original.parts.filter { part in
            if part.materialIndex>=2{return true}
            return capMode==1 && (part.materialIndex==0 ? leaf.frontVisible:leaf.backVisible)
          }
          removedTriangles+=original.triangleCount-payload.mesh.triangleCount
          if payload.mesh.parts.isEmpty {
            // Some cap/finish surfaces are separate source components. Keep
            // their exact buffers, but disable the cap-only rendered entity.
            disabledCapOnlyComponents.append(payload.componentID)
            payload.mesh=original;payload.visible=false
          }else{
            payload.mesh.id += ":"+name+":"+payload.mesh.parts.map{String($0.materialIndex)}.joined(separator:",")
            payload.mesh.revision += ":diagnostic"
          }
        }
        if faceted,leaf != nil {
          for part in original.parts where part.materialIndex==2 {
            for offset in stride(from:0,to:part.triangleIndices.count,by:3) {
              let ids=part.triangleIndices[offset..<offset+3].map{Int($0)},a=original.positionsMM[ids[0]],b=original.positionsMM[ids[1]],c=original.positionsMM[ids[2]]
              let normal=simd_normalize(simd_cross(b-a,c-a)),prior=ids.reduce(SIMD3<Double>.zero){$0+SIMD3<Double>(original.normals[$1])}
              XCTAssertGreaterThan(simd_dot(normal,simd_normalize(prior)),0.95,"Physical winding must agree with the source normal field")
              for index in ids {payload.mesh.normals[index]=SIMD3<Float>(normal);changedNormalVertices+=1}
            }
          }
          payload.mesh.id += ":geometric-bevel-normals";payload.mesh.revision += ":diagnostic"
        }
        XCTAssertEqual(payload.mesh.positionsMM,original.positionsMM,"No localization control may change caliper, silhouette or pose")
        if !faceted{XCTAssertEqual(payload.mesh.normals,original.normals)}
        payload.materials=payload.materials.map{original in
          var value=original;value.revision += ":"+name;value.baseColor = .init(0.8,0.8,0.8,1)
          value.baseColorTexture=nil;value.normalTexture=nil;value.metallicTexture=nil;value.roughnessTexture=nil;value.ambientOcclusionTexture=nil;value.emissiveTexture=nil;value.metallic=0;value.roughness=1;value.emissiveColor = .zero
          return value
        }
        try renderer.upsert(payload)
      }
      var groundingState=[(Entity,GroundingShadowComponent?)]()
      if name=="stack-grounding-disabled" {
        // The diagnostic deliberately changes only public RealityKit components
        // on this local renderer, without adding a production control/test hook.
        let stage=try XCTUnwrap(Mirror(reflecting:renderer).children.first{$0.label=="sceneRoot"}?.value as? Entity,"The local renderer scene must remain discoverable for this diagnostic")
        func disableGrounding(_ entity:Entity) {
          if entity is ModelEntity {
            groundingState.append((entity,entity.components[GroundingShadowComponent.self]))
            entity.components.set(GroundingShadowComponent(castsShadow:false,receivesShadow:false))
          }
          for child in entity.children{disableGrounding(child)}
        }
        disableGrounding(stage);XCTAssertGreaterThanOrEqual(groundingState.count,32)
      }
      defer{for (entity,prior) in groundingState {if let prior{entity.components.set(prior)}else{entity.components.remove(GroundingShadowComponent.self)}}}
      XCTAssertEqual(visibleLeaves.count,single ? 1:32)
      if capMode>0{XCTAssertGreaterThan(removedTriangles,0)}
      if faceted{XCTAssertGreaterThan(changedNormalVertices,0)}
      var activeCamera=camera
      if clipMode==1 || clipMode==2{activeCamera.nearMM=tight.nearMM}
      if clipMode==1 || clipMode==3{activeCamera.farMM=tight.farMM}
      try renderer.setCamera(activeCamera)
      XCTAssertEqual(renderer.camera.projection,camera.projection)
      for column in 0..<4{XCTAssertEqual(renderer.camera.worldFromCameraMM[column],camera.worldFromCameraMM[column])}
      try renderer.setLighting(.init(background:background,keyDirection:.init(Float(-q.x),Float(-q.y),Float(-q.z)),keyColor:.init(keyColor.x,keyColor.y,keyColor.z),keyIntensity:3375,fillIntensity:516,shadows:false))
      let captured=try await renderer.capture(width:2000,height:1600),bitmap=NSBitmapImageRep(cgImage:captured)
      try XCTUnwrap(bitmap.representation(using:.png,properties:[:])).write(to:folder.appendingPathComponent(name+".png"))
      func variation(_ leaves:[ResolvedSheetAssemblyLeaf])throws->Double {
        var differences=[Double]()
        for leaf in leaves {
          let node=try XCTUnwrap(root.childNode(withName:SheetAssemblyGeometry.leafName(leaf.id),recursively:true)?.childNode(withName:PaperGeometry.panelPrefix+"face",recursively:true))
          var row=[Double]()
          for index in 0...1000 {
            let local=MeshVector3(leaf.size.x/100,-leaf.size.y*Double(index)/1000/100,0),world=node.convertPosition(local,to:nil).simd*100
            if let p=SceneProjection.project(world,camera:camera,viewport:viewport) {
              let x=Int(p.x.rounded()),y=Int(p.y.rounded())
              if (0..<bitmap.pixelsWide).contains(x),(0..<bitmap.pixelsHigh).contains(y),let color=bitmap.colorAt(x:x,y:y)?.usingColorSpace(.sRGB) {row.append(0.2126*Double(color.redComponent)+0.7152*Double(color.greenComponent)+0.0722*Double(color.blueComponent))}
            }
          }
          if row.count>2 {for index in 1..<(row.count-1){differences.append(abs(row[index-1]-2*row[index]+row[index+1]))}}
        }
        return differences.isEmpty ? 0:differences.reduce(0,+)/Double(differences.count)
      }
      reports.append(["mode":name,"near_mm":activeCamera.nearMM,"far_mm":activeCamera.farMM,"closest_subject_depth_mm":closest,"farthest_subject_depth_mm":farthest,"center_leaf_variation":try variation([chosen]),"visible_interior_variation":try variation(single ? [chosen]:Array(source.leaves.dropFirst(4).dropLast(4))),"visible_leaves":visibleLeaves.count,"removed_triangles":removedTriangles,"disabled_cap_only_components":disabledCapOnlyComponents,"geometric_normal_vertices":changedNormalVertices,"grounding_overrides":groundingState.count,"existing_grounding_components":groundingState.filter{$0.1 != nil}.count,"caliper_mm":0.12,"physical_positions_unchanged":true])
      try JSONSerialization.data(withJSONObject:["modes":reports,"source_unchanged":project==before,"camera_pose_unchanged":true,"output_pixels":[2000,1600]],options:[.prettyPrinted,.sortedKeys]).write(to:folder.appendingPathComponent("diagnostics.json"))
    }
    XCTAssertEqual(project,before)
    print("FOREDGE_DEPTH_EVIDENCE=\(folder.path)")
    print("FOREDGE_DEPTH_METRICS=\(reports)")
  }

  func testActualGPUForeedgeExactPixelIntegration()async throws {
    guard MTLCreateSystemDefaultDevice() != nil else{throw XCTSkip("Foreedge regression requires the actual Metal renderer.")}
    let(project,object,assets,shot)=try fixture(),before=project
    let controller=TableSceneController()
    controller.sync(project,selection:[],isolated:[object.id],showGrid:false,studio:true,preset:shot.surface,assets:assets,textureLimit:256,renderObjectIDs:[object.id])
    controller.camera=shot.camera;controller.updateCamera();controller.applyShotLighting(shot.lighting,studio:true)
    let camera=controller.cameraPayload(),viewport=CGSize(width:2000,height:1600)
    let plans=try StudioSourceSampling.plans(controller:controller,project:project,camera:camera,viewport:viewport,objectIDs:[object.id],maximumEdge:8192)
    controller.sync(project,selection:[],isolated:[object.id],showGrid:false,studio:true,preset:shot.surface,assets:assets,textureLimit:256,renderObjectIDs:[object.id],sourceSampling:plans)
    let source=try project.resolvedSheetAssembly(object),renderer=try RealityKitSceneRenderer(),q=controller.keyLight.simdOrientation.act(.init(0,0,1))
    for var payload in GeometryPayloadAdapter().renderables(scene:controller.scene) {
      payload.materials=payload.materials.map{original in var v=original;v.revision += ":sampling";v.baseColor = .init(0.8,0.8,0.8,1);v.baseColorTexture=nil;v.normalTexture=nil;v.metallicTexture=nil;v.roughnessTexture=nil;v.ambientOcclusionTexture=nil;v.emissiveTexture=nil;v.metallic=0;v.roughness=1;v.emissiveColor = .zero;return v}
      try renderer.upsert(payload)
    }
    let background=GeometryPayloadAdapter.color(controller.scene.background.contents),keyColor=GeometryPayloadAdapter.color(controller.keyLight.light?.color)
    try renderer.setLighting(.init(background:background,keyDirection:.init(Float(-q.x),Float(-q.y),Float(-q.z)),keyColor:.init(keyColor.x,keyColor.y,keyColor.z),keyIntensity:3375,fillIntensity:516,shadows:false))
    try renderer.setCamera(camera)
    let builds=renderer.diagnostics.meshBuilds,root=try XCTUnwrap(controller.objectRoot.childNode(withName:"object:"+object.id.uuidString,recursively:false))
    let folder=(ProcessInfo.processInfo.environment["LAB_FOREEDGE_EVIDENCE_DIR"].map{URL(fileURLWithPath:$0)} ?? FileManager.default.temporaryDirectory.appendingPathComponent("form-foreedge-integration-"+UUID().uuidString)).appendingPathComponent("exact-pixel-integration")
    try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
    var reports=[[String:Any]]()
    for scale in 1...3 {
      let captured=try await renderer.capture(width:2000*scale,height:1600*scale)
      let image:CGImage
      if scale==1{image=captured}else{image=try integratePixels(captured,width:2000,height:1600)}
      XCTAssertEqual(image.width,2000);XCTAssertEqual(image.height,1600);XCTAssertEqual(renderer.diagnostics.meshBuilds,builds)
      let bitmap=NSBitmapImageRep(cgImage:image)
      try XCTUnwrap(bitmap.representation(using:.png,properties:[:])).write(to:folder.appendingPathComponent("linear-box-\(scale)x.png"))
      var rms=[Double](),peak=[Double](),frequencies=[Double]()
      for leaf in source.leaves.dropFirst(4).dropLast(4) {
        let node=try XCTUnwrap(root.childNode(withName:SheetAssemblyGeometry.leafName(leaf.id),recursively:true)?.childNode(withName:PaperGeometry.panelPrefix+"face",recursively:true))
        var row=[Double]()
        for index in 100...900 {
          let local=MeshVector3(leaf.size.x/100,-leaf.size.y*Double(index)/1000/100,0),world=node.convertPosition(local,to:nil).simd*100
          if let p=SceneProjection.project(world,camera:camera,viewport:viewport) {let x=Int(p.x.rounded()),y=Int(p.y.rounded());if (0..<bitmap.pixelsWide).contains(x),(0..<bitmap.pixelsHigh).contains(y),let c=bitmap.colorAt(x:x,y:y)?.usingColorSpace(.sRGB){row.append(0.2126*Double(c.redComponent)+0.7152*Double(c.greenComponent)+0.0722*Double(c.blueComponent))}}
        }
        if row.count>2 {
          let mean=row.reduce(0,+)/Double(row.count),center=Double(row.count-1)/2
          var numerator=0.0,denominator=0.0
          for index in row.indices {let d=Double(index)-center;numerator+=d*(row[index]-mean);denominator+=d*d}
          let slope=numerator/denominator,residuals=row.indices.map{row[$0]-mean-slope*(Double($0)-center)},sorted=residuals.sorted()
          rms.append(sqrt(residuals.reduce(0){$0+$1*$1}/Double(row.count)));peak.append(sorted[Int(Double(sorted.count-1)*0.99)]-sorted[Int(Double(sorted.count-1)*0.01)])
          for i in 1..<(row.count-1){frequencies.append(abs(row[i-1]-2*row[i]+row[i+1]))}
        }
      }
      func mean(_ values:[Double])->Double{values.reduce(0,+)/Double(max(1,values.count))}
      reports.append(["sampling_scale":scale,"capture_pixels":[captured.width,captured.height],"output_pixels":[image.width,image.height],"rms_alias_contrast":mean(rms),"p99_p01_alias_contrast":mean(peak),"second_difference":mean(frequencies),"caliper_mm":0.12,"geometry_camera_normals_unchanged":true])
      try JSONSerialization.data(withJSONObject:["modes":reports,"source_unchanged":project==before],options:[.prettyPrinted,.sortedKeys]).write(to:folder.appendingPathComponent("diagnostics.json"))
    }
    XCTAssertEqual(project,before)
    print("FOREDGE_INTEGRATION_EVIDENCE=\(folder.path)")
    print("FOREDGE_INTEGRATION_METRICS=\(reports)")
  }

  func testActualGPUProjectiveCameraParityAndBoundedAccumulation()async throws {
    guard let device=MTLCreateSystemDefaultDevice() else{throw XCTSkip("The camera integration proof requires actual Metal.")}
    let(project,object,assets,shot)=try fixture(),before=project,controller=TableSceneController()
    controller.sync(project,selection:[],isolated:[object.id],showGrid:false,studio:true,preset:shot.surface,assets:assets,textureLimit:256,renderObjectIDs:[object.id])
    controller.camera=shot.camera;controller.updateCamera();controller.applyShotLighting(shot.lighting,studio:true)
    let camera=controller.cameraPayload(),width=2000,height=1600
    let plans=try StudioSourceSampling.plans(controller:controller,project:project,camera:camera,viewport:.init(width:width,height:height),objectIDs:[object.id],maximumEdge:8192)
    controller.sync(project,selection:[],isolated:[object.id],showGrid:false,studio:true,preset:shot.surface,assets:assets,textureLimit:256,renderObjectIDs:[object.id],sourceSampling:plans)
    let sourceRenderer=try RealityKitSceneRenderer()
    for var payload in GeometryPayloadAdapter().renderables(scene:controller.scene) {
      payload.materials=payload.materials.map{original in var v=original;v.revision += ":projective";v.baseColor = .init(0.8,0.8,0.8,1);v.baseColorTexture=nil;v.normalTexture=nil;v.metallicTexture=nil;v.roughnessTexture=nil;v.ambientOcclusionTexture=nil;v.emissiveTexture=nil;v.metallic=0;v.roughness=1;v.emissiveColor = .zero;return v}
      try sourceRenderer.upsert(payload)
    }
    let q=controller.keyLight.simdOrientation.act(.init(0,0,1)),background=GeometryPayloadAdapter.color(controller.scene.background.contents),keyColor=GeometryPayloadAdapter.color(controller.keyLight.light?.color)
    try sourceRenderer.setCamera(camera)
    try sourceRenderer.setLighting(.init(background:background,keyDirection:.init(Float(-q.x),Float(-q.y),Float(-q.z)),keyColor:.init(keyColor.x,keyColor.y,keyColor.z),keyIntensity:3375,fillIntensity:516,shadows:false))
    let native=try await sourceRenderer.capture(width:width,height:height),builds=sourceRenderer.diagnostics.meshBuilds
    let mirror=Mirror(reflecting:sourceRenderer)
    let originalRoot=try XCTUnwrap(mirror.children.first{$0.label=="sceneRoot"}?.value as? Entity),originalRenderer=try XCTUnwrap(mirror.children.first{$0.label=="rendered"}?.value as? RealityRenderer)
    let root=originalRoot.clone(recursive:true),renderer=try RealityRenderer(),lens=try XCTUnwrap(root.findEntity(named:"LAB camera")),light=try XCTUnwrap(root.findEntity(named:"LAB environment"))
    func rebind(_ entity:Entity){if entity is ModelEntity{entity.components.set(ImageBasedLightReceiverComponent(imageBasedLight:light))};for child in entity.children{rebind(child)}}
    rebind(root);renderer.entities.append(root);renderer.activeCamera=lens;renderer.cameraSettings=originalRenderer.cameraSettings
    lens.components.remove(PerspectiveCameraComponent.self);lens.components.remove(OrthographicCameraComponent.self)
    guard case .perspective(let fov)=camera.projection else{throw FormError.invalid("This retained source uses the perspective acceptance camera")}
    let n=Float(camera.nearMM/1000),f=Float(camera.farMM/1000),y=1/tan(Float(fov) * .pi/360),x=y/(Float(width)/Float(height))
    let projection=simd_float4x4(SIMD4(x,0,0,0),SIMD4(0,y,0,0),SIMD4(0,0,n/(f-n),-1),SIMD4(0,0,n*f/(f-n),0))
    let descriptor=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.bgra8Unorm_srgb,width:width,height:height,mipmapped:false)
    descriptor.usage=[.renderTarget,.shaderRead];descriptor.storageMode=device.hasUnifiedMemory ? .shared:.managed
    let texture=try XCTUnwrap(device.makeTexture(descriptor:descriptor)),output=try RealityRenderer.CameraOutput(.singleProjection(colorTexture:texture)),queue=try XCTUnwrap(device.makeCommandQueue())
    @MainActor func frame(_ dx:Float,_ dy:Float)async throws->CGImage {
      var shifted=projection;shifted.columns.2.x+=2*dx/Float(width);shifted.columns.2.y+=2*dy/Float(height)
      lens.components.set(ProjectiveTransformCameraComponent(projectionMatrix:shifted))
      try await withCheckedThrowingContinuation{(continuation:CheckedContinuation<Void,Error>) in do{try renderer.updateAndRender(deltaTime:1/60,cameraOutput:output,onComplete:{_ in continuation.resume()})}catch{continuation.resume(throwing:error)}}
      if !device.hasUnifiedMemory {let command=try XCTUnwrap(queue.makeCommandBuffer()),blit=try XCTUnwrap(command.makeBlitCommandEncoder());blit.synchronize(resource:texture);blit.endEncoding();await withCheckedContinuation{(continuation:CheckedContinuation<Void,Never>) in command.addCompletedHandler{_ in continuation.resume()};command.commit()}}
      var bytes=[UInt8](repeating:0,count:width*height*4)
      texture.getBytes(&bytes,bytesPerRow:width*4,from:.init(origin:.init(x:0,y:0,z:0),size:.init(width:width,height:height,depth:1)),mipmapLevel:0)
      let provider=try XCTUnwrap(CGDataProvider(data:Data(bytes) as CFData)),p3=try XCTUnwrap(CGColorSpace(name:CGColorSpace.displayP3)),srgb=try XCTUnwrap(CGColorSpace(name:CGColorSpace.sRGB))
      let raw=try XCTUnwrap(CGImage(width:width,height:height,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:width*4,space:p3,bitmapInfo:[.byteOrder32Little,CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedFirst.rawValue)],provider:provider,decode:nil,shouldInterpolate:true,intent:.defaultIntent))
      let normalized=try XCTUnwrap(CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:srgb,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
      normalized.draw(raw,in:.init(x:0,y:0,width:width,height:height));return try XCTUnwrap(normalized.makeImage())
    }
    func difference(_ a:CGImage,_ b:CGImage,shift:Int=0)throws->Double {
      let ad=try XCTUnwrap(a.dataProvider?.data),bd=try XCTUnwrap(b.dataProvider?.data),ap=try XCTUnwrap(CFDataGetBytePtr(ad)),bp=try XCTUnwrap(CFDataGetBytePtr(bd))
      var total=0.0,count=0
      for y in 8..<(height-8){for x in 8..<(width-8){for c in 0..<3{total+=Double(abs(Int(ap[y*a.bytesPerRow+(x+shift)*4+c])-Int(bp[y*b.bytesPerRow+x*4+c])));count+=1}}}
      return total/Double(count)/255
    }
    let folder=(ProcessInfo.processInfo.environment["LAB_FOREEDGE_EVIDENCE_DIR"].map{URL(fileURLWithPath:$0)} ?? FileManager.default.temporaryDirectory.appendingPathComponent("form-projective-aa-"+UUID().uuidString)).appendingPathComponent("projective-accumulation")
    try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
    func save(_ image:CGImage,_ name:String)throws {let destination=try XCTUnwrap(CGImageDestinationCreateWithURL(folder.appendingPathComponent(name+".png") as CFURL,"public.png" as CFString,1,nil));CGImageDestinationAddImage(destination,image,nil);XCTAssertTrue(CGImageDestinationFinalize(destination))}
    let zero=try await frame(0,0),shifted=try await frame(4,0),parity=try difference(native,zero),unaligned=try difference(zero,shifted),aligned=try difference(zero,shifted,shift:4)
    try save(native,"native-reference");try save(zero,"projective-zero");try save(shifted,"projective-shift4")
    var report:[String:Any]=["native_projective_zero_mae":parity,"unshifted_mae":unaligned,"shift4_aligned_mae":aligned,"output_pixels":[width,height],"source_unchanged":project==before,"camera_pose_unchanged":true]
    try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:folder.appendingPathComponent("diagnostics.json"))
    XCTAssertLessThan(parity,1.0/255,"Zero-jitter custom projection must retain native framing/color")
    XCTAssertGreaterThan(unaligned,0.00001,"The public projective camera must honor off-axis terms")
    XCTAssertLessThan(aligned,unaligned*0.25,"A4-pixel projection shift must match the exact corresponding image translation")
    guard parity<1.0/255,unaligned>0.00001,aligned<unaligned*0.25 else{return}
    let decode=(0..<256).map{index->UInt32 in let v=Double(index)/255;return UInt32(((v<=0.04045 ? v/12.92:pow((v+0.055)/1.055,2.4))*65535).rounded())}
    let encode=(0..<65536).map{index->UInt8 in let v=Double(index)/65535;return UInt8(((v<=0.0031308 ? 12.92*v:1.055*pow(v,1/2.4)-0.055)*255).rounded())}
    var accumulation=[UInt32](repeating:0,count:width*height*3),offsets=[[Float]]()
    for sample in 0..<16 {
      var bits=sample,radical:Float=0,weight:Float=0.5
      while bits>0{radical+=Float(bits&1)*weight;bits>>=1;weight*=0.5}
      let dx=(Float(sample)+0.5)/16-0.5,dy=radical+0.5/16-0.5
      offsets.append([dx,dy]);let image=try await frame(dx,dy),data=try XCTUnwrap(image.dataProvider?.data),pixels=try XCTUnwrap(CFDataGetBytePtr(data))
      accumulation.withUnsafeMutableBufferPointer{values in for index in 0..<(width*height){values[index*3]+=decode[Int(pixels[index*4])];values[index*3+1]+=decode[Int(pixels[index*4+1])];values[index*3+2]+=decode[Int(pixels[index*4+2])]}}
    }
    var bytes=[UInt8](repeating:255,count:width*height*4)
    bytes.withUnsafeMutableBufferPointer{pixels in for index in 0..<(width*height){pixels[index*4]=encode[Int(accumulation[index*3]/16)];pixels[index*4+1]=encode[Int(accumulation[index*3+1]/16)];pixels[index*4+2]=encode[Int(accumulation[index*3+2]/16)]}}
    let provider=try XCTUnwrap(CGDataProvider(data:Data(bytes) as CFData)),space=try XCTUnwrap(CGColorSpace(name:CGColorSpace.sRGB))
    let integrated=try XCTUnwrap(CGImage(width:width,height:height,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:width*4,space:space,bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue),provider:provider,decode:nil,shouldInterpolate:true,intent:.defaultIntent))
    try save(integrated,"projective-hammersley16")
    XCTAssertEqual(sourceRenderer.diagnostics.meshBuilds,builds);XCTAssertEqual(project,before)
    XCTAssertEqual(offsets.map{$0[0]}.reduce(0,+),0,accuracy:1e-6);XCTAssertEqual(offsets.map{$0[1]}.reduce(0,+),0,accuracy:1e-6)
    report["samples"]=16;report["sample_offsets_pixels"]=offsets;report["reused_render_targets"]=1;report["unchanged_mesh_builds"]=builds
    try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:folder.appendingPathComponent("diagnostics.json"))
    print("FOREDGE_PROJECTIVE_EVIDENCE=\(folder.path)")
    print("FOREDGE_PROJECTIVE_METRICS=\(report)")
  }

  func testProductionStillSuppressesForeedgeAliasWithExactPixelsSourceAndCamera()async throws {
    guard MTLCreateSystemDefaultDevice() != nil else{throw XCTSkip("The still regression requires actual Metal.")}
    let(project,object,assets,shot)=try fixture(),before=project,controller=TableSceneController()
    controller.sync(project,selection:[],isolated:[object.id],showGrid:false,studio:true,preset:shot.surface,assets:assets,textureLimit:256,renderObjectIDs:[object.id])
    controller.camera=shot.camera;controller.updateCamera();controller.applyShotLighting(shot.lighting,studio:true)
    let camera=controller.cameraPayload(),viewport=CGSize(width:2000,height:1600)
    let plans=try StudioSourceSampling.plans(controller:controller,project:project,camera:camera,viewport:viewport,objectIDs:[object.id],maximumEdge:8192)
    controller.sync(project,selection:[],isolated:[object.id],showGrid:false,studio:true,preset:shot.surface,assets:assets,textureLimit:256,renderObjectIDs:[object.id],sourceSampling:plans)
    let renderer=try RealityKitSceneRenderer()
    for var payload in GeometryPayloadAdapter().renderables(scene:controller.scene) {
      payload.materials=payload.materials.map{original in var v=original;v.revision += ":production-regression";v.baseColor = .init(0.8,0.8,0.8,1);v.baseColorTexture=nil;v.normalTexture=nil;v.metallicTexture=nil;v.roughnessTexture=nil;v.ambientOcclusionTexture=nil;v.emissiveTexture=nil;v.metallic=0;v.roughness=1;v.emissiveColor = .zero;return v}
      try renderer.upsert(payload)
    }
    let q=controller.keyLight.simdOrientation.act(.init(0,0,1)),background=GeometryPayloadAdapter.color(controller.scene.background.contents),keyColor=GeometryPayloadAdapter.color(controller.keyLight.light?.color)
    try renderer.setCamera(camera);try renderer.setLighting(.init(background:background,keyDirection:.init(Float(-q.x),Float(-q.y),Float(-q.z)),keyColor:.init(keyColor.x,keyColor.y,keyColor.z),keyIntensity:3375,fillIntensity:516,shadows:false))
    let builds=renderer.diagnostics.meshBuilds,raw=try await renderer.capture(width:2000,height:1600)
    XCTAssertEqual(renderer.diagnostics.lastCaptureSamples,1);XCTAssertEqual(renderer.diagnostics.lastCaptureAccumulatorBytes,0)
    let final=try await renderer.capture(width:2000,height:1600,sampling:.still)
    XCTAssertEqual(final.width,2000);XCTAssertEqual(final.height,1600)
    XCTAssertEqual(renderer.diagnostics.meshBuilds,builds);XCTAssertEqual(renderer.diagnostics.lastCaptureSamples,16);XCTAssertEqual(renderer.diagnostics.lastCaptureAccumulatorBytes,51_200_000)
    for column in 0..<4{XCTAssertEqual(renderer.camera.worldFromCameraMM[column],camera.worldFromCameraMM[column])}
    XCTAssertEqual(renderer.camera.projection,camera.projection);XCTAssertEqual(renderer.camera.nearMM,camera.nearMM);XCTAssertEqual(renderer.camera.farMM,camera.farMM)
    let source=try project.resolvedSheetAssembly(object),root=try XCTUnwrap(controller.objectRoot.childNode(withName:"object:"+object.id.uuidString,recursively:false))
    func contrast(_ image:CGImage)throws->(Double,Double) {
      let data=try XCTUnwrap(image.dataProvider?.data),pixels=try XCTUnwrap(CFDataGetBytePtr(data))
      var rms=[Double](),peaks=[Double]()
      for leaf in source.leaves.dropFirst(4).dropLast(4) {
        let node=try XCTUnwrap(root.childNode(withName:SheetAssemblyGeometry.leafName(leaf.id),recursively:true)?.childNode(withName:PaperGeometry.panelPrefix+"face",recursively:true))
        var row=[Double]()
        for index in 100...900 {
          let world=node.convertPosition(.init(leaf.size.x/100,-leaf.size.y*Double(index)/1000/100,0),to:nil).simd*100
          if let p=SceneProjection.project(world,camera:camera,viewport:viewport){let x=Int(p.x.rounded()),y=Int(p.y.rounded());if x>=0,x<image.width,y>0,y<image.height-1 {var value=0.0;for dy in -1...1{let i=(y+dy)*image.bytesPerRow+x*4;value+=(0.2126*Double(pixels[i])+0.7152*Double(pixels[i+1])+0.0722*Double(pixels[i+2]))/255};row.append(value/3)}}
        }
        guard row.count>2 else{continue}
        let mean=row.reduce(0,+)/Double(row.count),center=Double(row.count-1)/2
        var numerator=0.0,denominator=0.0
        for i in row.indices{let dx=Double(i)-center;numerator+=dx*(row[i]-mean);denominator+=dx*dx}
        let slope=numerator/denominator,residual=row.indices.map{row[$0]-mean-slope*(Double($0)-center)},sorted=residual.sorted()
        rms.append(sqrt(residual.reduce(0){$0+$1*$1}/Double(row.count)));peaks.append(sorted[Int(Double(sorted.count-1)*0.99)]-sorted[Int(Double(sorted.count-1)*0.01)])
      }
      return(rms.reduce(0,+)/Double(rms.count),peaks.reduce(0,+)/Double(peaks.count))
    }
    let rawContrast=try contrast(raw),finalContrast=try contrast(final)
    XCTAssertLessThan(finalContrast.0,rawContrast.0*0.6,"The final image must remove high-contrast aliasing while retaining the physical edge lines")
    XCTAssertLessThan(finalContrast.1,rawContrast.1*0.65)
    XCTAssertEqual(project,before);XCTAssertEqual(source.stackThicknessMM,3.84,accuracy:1e-9)
    let folder=(ProcessInfo.processInfo.environment["LAB_FOREEDGE_EVIDENCE_DIR"].map{URL(fileURLWithPath:$0)} ?? FileManager.default.temporaryDirectory.appendingPathComponent("form-production-still-"+UUID().uuidString)).appendingPathComponent("production-still")
    try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
    for (name,image) in [("before-native",raw),("after-final",final)]{let destination=try XCTUnwrap(CGImageDestinationCreateWithURL(folder.appendingPathComponent(name+".png") as CFURL,"public.png" as CFString,1,nil));CGImageDestinationAddImage(destination,image,nil);XCTAssertTrue(CGImageDestinationFinalize(destination))}
    let report:[String:Any]=["before_rms":rawContrast.0,"after_rms":finalContrast.0,"before_p99_p01":rawContrast.1,"after_p99_p01":finalContrast.1,"samples":16,"accumulator_bytes":renderer.diagnostics.lastCaptureAccumulatorBytes,"output_pixels":[2000,1600],"caliper_mm":0.12,"source_camera_geometry_unchanged":true,"mesh_builds":builds]
    try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:folder.appendingPathComponent("diagnostics.json"))
    print("FOREDGE_PRODUCTION_EVIDENCE=\(folder.path)");print("FOREDGE_PRODUCTION_METRICS=\(report)")
  }

}
