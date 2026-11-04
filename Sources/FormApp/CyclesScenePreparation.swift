import AppKit
import CryptoKit
import FormCore
import FormGraphics
import FormGeometry
import ImageIO
import LabRendering
import simd

@MainActor enum LabCyclesRuntime {
  static let service=CyclesRenderService()
  static var cacheURL:URL {
    FileManager.default.urls(for:.cachesDirectory,in:.userDomainMask)[0]
      .appendingPathComponent("LAB/Cycles",isDirectory:true)
  }
  static func configuration(_ settings:CyclesRenderSettings,pixels:StudioPixels,preview:Bool)->CyclesRenderConfiguration {
    let scale=preview ? min(1,1280/Double(max(pixels.width,pixels.height))):1
    var value=CyclesRenderConfiguration(purpose:preview ? .preview:.final,
      width:max(1,Int(Double(pixels.width)*scale)),height:max(1,Int(Double(pixels.height)*scale)),
      samples:preview ? settings.previewSamples:settings.samples,
      adaptiveThreshold:preview ? 0.05:settings.noiseThreshold,denoise:settings.denoise,
      device:settings.device == .automatic ? .auto:settings.device == .metal ? .metal:.cpu)
    value.exposureEV=settings.exposure;value.maxBounces=settings.maxBounces
    value.displacementDicingRate=settings.displacementDicingRate
    value.displacementMaxTriangles=settings.displacementMaxTriangles
    value.displacementMaxSubdivisions=settings.displacementMaxSubdivisions
    return value
  }
  static func color(_ hex:String)->SIMD3<Float> {
    let c=GeometryPayloadAdapter.color(NSColor(hex:hex));return linear(.init(c.x,c.y,c.z))
  }
  static func linear(_ value:SIMD3<Float>)->SIMD3<Float> {
    func channel(_ v:Float)->Float {v<=0.04045 ? v/12.92:pow((v+0.055)/1.055,2.4)}
    return .init(channel(value.x),channel(value.y),channel(value.z))
  }
}

extension TableSceneController {
  /// Freeze the displayed graph without changing navigation or runtime cloth.
  func cyclesSnapshot(settings:CyclesRenderSettings,camera override:SceneCameraPayload?=nil)async throws->SceneSnapshot {
    guard let (project,assets)=pathTracingSource else {throw FormError.invalid("Open a project before rendering.")}
    try settings.validate()
    let before=try cyclesSceneKey(settings:settings),sourceDigest=try project.studioDesignDigest()
    // Capture every live value before the first suspension. A Table final may
    // freeze a running simulation; navigation and later frames cannot replace
    // the geometry, curve deformation, visibility or camera of this revision.
    var payloads=try adapter.pathTracingRenderables(scene:scene,assets:assets)
    let physicalIDs=Set(project.objects.map(\.id))
    var curves=[SceneCurvePayload](),omitted=Set<String>(),attachedJobs=[CyclesAttachedSurface.Prepared]()
    for object in project.objects where object.textile?.embroidery != nil {
      guard let entry=payloads.first(where:{$0.objectID==object.id && $0.visible && adapter.nodes[$0.componentID]?.name==EmbroiderySceneSurface.faceName}),
        let node=adapter.nodes[entry.componentID] else {continue}
      let frame:(UUID)->ClothFrame? = {[weak self] id in self?.store?.cloth.frame(for:id,projectID:project.id)}
      let attached=try CyclesAttachedSurface(object:object,project:project,frame:frame)
      let stitches=try CyclesEmbroidery.curves(object:object,project:project,faceNode:node,assets:assets,
        frame:frame,attachedSurface:attached,deferAttachedMapping:attached != nil)
      if let attached {
        guard let container=node.parent,container.name==EmbroiderySceneSurface.containerName else {throw FormError.invalid("The attached embroidery has no shared backing container.")}
        var indices=[Int](),local=[SceneRenderablePayload]()
        for index in payloads.indices where payloads[index].objectID==object.id && payloads[index].visible && payloads[index].componentID != entry.componentID {
          guard let component=adapter.nodes[payloads[index].componentID],CyclesAttachedSurface.contains(component,in:container) else {continue}
          indices.append(index);local.append(try attached.localPayload(payloads[index],node:component,container:container))
        }
        attachedJobs.append(.init(mapping:attached,indices:indices,renderables:local,curves:stitches))
      } else {curves+=stitches}
      omitted.insert(entry.componentID)
    }
    // Freeze node membership now; no graph or live frame is read after the
    // detached material-surface preparation starts.
    let floorComponents=Set(payloads.filter{adapter.nodes[$0.componentID] === floorNode}.map(\.componentID))
    let included=Set(payloads.filter {payload in
      guard payload.visible,!omitted.contains(payload.componentID),let node=adapter.nodes[payload.componentID] else{return false}
      if node === floorNode {return true}
      guard physicalIDs.contains(payload.objectID),node.name != "selection",node.name != PaperGeometry.highlightName else{return false}
      return node.geometry?.elements.contains(where:{$0.primitiveType == .triangles || $0.primitiveType == .triangleStrip}) == true
    }.map(\.componentID))
    var renderables=payloads.filter{included.contains($0.componentID)}
    // Fast viewing lowers the ground by 0.8 mm to avoid editor Z-fighting.
    // The physical contact plane remains at world zero in a path-traced scene.
    for index in renderables.indices where adapter.nodes[renderables[index].componentID] === floorNode {
      renderables[index].transform.translationMM.y=0
    }
    func light(position:SIMD3<Double>,target:SIMD3<Double>,color:SIMD3<Float>,power:Double,size:SIMD2<Double>)->SceneAreaLight {
      let direction=simd_normalize(position-target),up:SIMD3<Double>=abs(direction.y)>0.999 ? .init(0,0,1):.init(0,1,0)
      return .init(transform:SceneCameraPayload.looking(from:position,at:target,up:up).worldFromCameraMM,
        color:color,power:power,sizeMM:size)
    }
    let lights:[SceneAreaLight]
    if let authored=settings.areaLights {
      lights=authored.map{l in var result=light(position:.init(l.positionMM.x,l.positionMM.y,l.positionMM.z),
        target:.init(l.targetMM.x,l.targetMM.y,l.targetMM.z),color:LabCyclesRuntime.color(l.color),power:l.powerWatts,size:.init(l.sizeMM.x,l.sizeMM.y));result.shape=l.shape == .disk ? .disk:.rectangle;return result}
    } else {
      // Legacy viewport intensities are visual units, not measured radiant
      // watts. A neutral-card Cycles calibration keeps all three presets below
      // clipping while preserving their relative power, placement and color.
      var presetLights=[SceneAreaLight]()
      if !keyLight.isHidden,let source=keyLight.light {
        var transform=keyLight.worldTransform.raw
        transform.columns.3.x*=100;transform.columns.3.y*=100;transform.columns.3.z*=100
        let color=GeometryPayloadAdapter.color(source.color)
        presetLights.append(.init(transform:transform,color:LabCyclesRuntime.linear(.init(color.x,color.y,color.z)),
          power:max(0,source.intensity)*8.25/850,sizeMM:.init(500,500)))
      }
      if let fill=scene.rootNode.childNodes.first(where:{$0.light?.type == .omni}),!fill.isHidden,let source=fill.light {
        let t=fill.worldTransform.raw.columns.3,color=GeometryPayloadAdapter.color(source.color)
        presetLights.append(light(position:.init(t.x*100,t.y*100,t.z*100),target:.zero,
          color:LabCyclesRuntime.linear(.init(color.x,color.y,color.z)),power:max(0,source.intensity)*2.75/100,size:.init(700,700)))
      }
      lights=presetLights
    }
    var environment=SceneRenderEnvironment(color:LabCyclesRuntime.color(settings.environmentColor),strength:settings.environmentStrength,
      rotationDegrees:settings.environmentRotationDegrees)
    if settings.areaLights==nil,let ambient=scene.rootNode.childNodes.first(where:{$0.light?.type == .ambient}),let source=ambient.light {
      let color=GeometryPayloadAdapter.color(source.color)
      environment.color *= LabCyclesRuntime.linear(.init(color.x,color.y,color.z))
      environment.strength *= ambient.isHidden ? 0:max(0,source.intensity)/400
    }
    if let texture=settings.environmentTexture {
      let url=try texture.verifiedURL(in:assets)
      guard let source=CGImageSourceCreateWithURL(url as CFURL,nil),let image=CGImageSourceCreateImageAtIndex(source,0,nil) else{throw FormError.invalid("The environment image cannot be decoded.")}
      var value=SceneTexturePayload(image:image,revision:texture.sha256)
      value.encoding=texture.colorSpace == .srgb ? .srgb:.linear
      environment.texture=value
    }
    let camera=override ?? cameraPayload()
    let external=try await prepareExternalPayloads(project:project,assets:assets,physical:true)
    if !attachedJobs.isEmpty {
      let mapped=try await CyclesAttachedSurface.prepare(attachedJobs)
      for job in mapped {
        for (index,payload) in zip(job.indices,job.renderables) {payloads[index]=payload}
        curves+=job.curves
      }
      renderables=payloads.filter{included.contains($0.componentID)}
      // The physical floor correction was applied to the filtered value above.
      for index in renderables.indices where floorComponents.contains(renderables[index].componentID) {renderables[index].transform.translationMM.y=0}
    }
    try Task.checkCancellation()
    guard let (current,currentAssets)=pathTracingSource,current.id==project.id,
      currentAssets.standardizedFileURL.resolvingSymlinksInPath().path==assets.standardizedFileURL.resolvingSymlinksInPath().path,
      try current.studioDesignDigest()==sourceDigest else {throw CyclesRenderError.cancelled}
    renderables += external.filter(\.visible)
    guard !renderables.isEmpty || !curves.isEmpty else{throw FormError.invalid("The current view has no visible physical objects.")}
    let key=before+":"+String(describing:camera.projection)+":"+String(describing:camera.worldFromCameraMM)
    let revision=SHA256.hash(data:Data(key.utf8)).map{String(format:"%02x",$0)}.joined()
    var snapshot=SceneSnapshot(revision:revision,renderables:renderables,curves:curves,camera:camera,lights:lights,environment:environment,
      apertureFStop:settings.depthOfField ? settings.fStop:nil,focusDistanceMM:settings.depthOfField ? settings.focusDistanceMM:nil)
    snapshot.projectID=project.id
    return snapshot
  }
  func cyclesSceneKey(settings:CyclesRenderSettings)throws->String {
    guard let (project,_)=pathTracingSource else{throw FormError.invalid("Open a project before rendering.")}
    if cyclesContentKey==nil {
      var content=Data(try project.studioDesignDigest().utf8)
      func append(_ node:MeshNode) {
        guard node.name != "selection",node.name != PaperGeometry.highlightName else{return}
        content.append(Data("\(node.name ?? ""):\(node.isHidden):\(node.opacity):\(node.worldTransform.raw)".utf8))
        if let geometry=node.geometry {content.append(Data("\(geometry.resourceID):\(geometry.resourceRevision)".utf8))}
        for child in node.childNodes {append(child)}
      }
      append(objectRoot)
      for payload in extraRenderables {content.append(Data("\(payload.componentID):\(payload.mesh.revision):\(payload.visible):\(payload.transform)".utf8))}
      cyclesContentKey=SHA256.hash(data:content).map{String(format:"%02x",$0)}.joined()
    }
    var data=Data(cyclesContentKey!.utf8)
    data.append(try JSONEncoder.form.encode(camera));data.append(try JSONEncoder.form.encode(settings))
    for node in scene.rootNode.childNodes where node.light != nil {
      data.append(Data("\(node.worldTransform.raw):\(String(describing:node.light?.color)):\(node.light?.intensity ?? 0):\(node.light?.shadowRadius ?? 0):\(node.isHidden)".utf8))
    }
    let surface=floorNode.geometry?.firstMaterial
    data.append(Data("\(floorNode.isHidden):\(floorNode.worldTransform.raw):\(surface?.diffuse.resourceRevision ?? 0):\(surface?.roughness.resourceRevision ?? 0):\(String(describing:surface?.diffuse.contents))".utf8))
    return SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()
  }
}
