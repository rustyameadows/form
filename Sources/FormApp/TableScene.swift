import AppKit
import simd
import CryptoKit
import FormCore
import FormGraphics
import Metal
import FormGeometry
import LabRendering
import SwiftUI

extension NSColor {
  convenience init(hex: String) {
    let value =
      UInt64(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0xEDE8DA
    self.init(
      srgbRed: CGFloat((value >> 16) & 255) / 255, green: CGFloat((value >> 8) & 255) / 255,
      blue: CGFloat(value & 255) / 255, alpha: 1)
  }
}
private func v(_ x: Double, _ y: Double, _ z: Double) -> MeshVector3 { .init(x, y, z) }
private func mm(_ value: Double) -> CGFloat { CGFloat(value / 100) }

private struct RenderSignature: Equatable {
  let recipe: Recipe?
  let parameters: [String: Double]
  let material: FormCore.Material
  let color: String?
  let artwork: Artwork?
  let asset: String?
  let fontRevision: Int
  let textureLimit: Int
  let textile: TextileProduct?
  let fabricPattern: ResolvedFabricPattern?
  let cloth:ClothStudy?
  let merchandiseSurface:[String:Double]?
  let merchandiseMaterials:[FormCore.Material]?
  let assemblyRevision:String?
  let modelRevision:String?
  let paperRevision:String?
}

@MainActor final class TableSceneController {
  let scene = MeshScene()
  let cameraNode = MeshNode()
  let objectRoot = MeshNode()
  let grid = MeshNode()
  let keyLight = MeshNode()
  let floorNode = MeshNode()
  weak var store: StudioStore?
  weak var view: TableSceneView?
  private var projectID: UUID?
  private var nodes: [UUID: MeshNode] = [:]
  private var clothSurfaces:[UUID:ClothSceneSurface]=[:]
  private var clothIssues:[UUID:String]=[:]
  private var embroideryIssues:[UUID:String]=[:]
  private var embroideryDigests:[UUID:String]=[:]
  func embroideryIssue(for id:UUID)->String? {embroideryIssues[id]}
  func embroiderySourceDigest(for id:UUID)->String? {embroideryDigests[id]}
  private func updateEmbroideryStatus(_ object:ProductObject,project:Project,textureLimit:Int) {
    let status=EmbroiderySceneSurface.status(object:object,project:project,textureLimit:textureLimit)
    embroideryIssues[object.id]=status.issue;embroideryDigests[object.id]=status.digest
  }
  private var fingerprints: [UUID: RenderSignature] = [:]
  private struct PaperPoseState:Equatable {let fold:Double;let opening:Double}
  private var paperPoseStates:[UUID:PaperPoseState]=[:]
  private var geometryBounds: [UUID: (min: MeshVector3, max: MeshVector3)] = [:]
  private var selectionNodes: [MeshNode] = []
  private var lastSelection = Set<UUID>()
  private var lastStudio = false
  private var lastPreset = ""
  private(set) var geometryBuilds = 0
  private(set) var lastSyncMilliseconds = 0.0
  var diagnostics: [String: Any] {
    [
      "object_nodes": nodes.count, "geometry_builds": geometryBuilds,
      "cloth_surfaces":clothSurfaces.count,"cloth_issues":Dictionary(uniqueKeysWithValues:clothIssues.map {($0.key.uuidString,$0.value)}),
      "embroidery_program_builds":EmbroiderySurface.programBuilds,"embroidery_texture_builds":EmbroiderySurface.textureBuilds,
      "embroidery_texture_max_edge":EmbroiderySurface.maximumTextureEdge,
      "embroidery_issues":Dictionary(uniqueKeysWithValues:embroideryIssues.map {($0.key.uuidString,$0.value)}),
      "embroidery_sources":Dictionary(uniqueKeysWithValues:embroideryDigests.map {($0.key.uuidString,$0.value)}),
      "last_sync_ms": lastSyncMilliseconds,
      "renders_continuously": false, "renderer": "RealityKit", "renderer_issue": rendererIssue ?? "", "mesh_uploads":renderer?.diagnostics.meshBuilds ?? 0, "texture_uploads":renderer?.diagnostics.textureUploads ?? 0, "renderer_warnings":(renderer?.diagnostics.warnings ?? [])+adapter.warnings, "preferred_fps": 60,
      "orbit_direction": "followPointer",
      "orbit_speed": CameraPreferences().effectiveOrbitSpeed,
      "mouse": view?.inputDiagnostics ?? [:],
    ]
  }
  var camera = CameraState()
  let adapter=GeometryPayloadAdapter()
  private(set) var renderer:RealityKitSceneRenderer?
  private(set) var rendererIssue:String?
  private var renderedComponents=Set<String>()
  var extraRenderables:[SceneRenderablePayload]=[]
  private var captureSource:Project?
  private var captureAssets:URL?
  private var captureVisibility=Set<UUID>()
  private var captureObjectIDs:Set<UUID>?
  private var externalCaptureRevision:String?
  var externalCapturePreparationCheckpoint:(()async->Void)?
  func prepareExternalForCapture(project:Project,assets:URL)async throws {
    let objects=project.objects.filter{!$0.isCanvasWorkspace && (captureObjectIDs?.contains($0.id) ?? true) && ($0.meshAsset != nil || $0.cadRepresentation != nil)}
    guard !objects.isEmpty else{return}
    let revision=try project.studioDesignDigest()+"/"+assets.path+"/"+(captureObjectIDs?.map(\.uuidString).sorted().joined(separator:",") ?? "all")
    if externalCaptureRevision==revision {return}
    var artwork:[UUID:CGImage]=[:],artRevisions:[UUID:String]=[:]
    for object in objects where object.meshAsset != nil {
      if let art=project.surfaceArtwork(object) {
        artwork[object.id]=GeometryFactory.artworkImage(art,width:object.artworkSize.x,depth:object.artworkSize.y,assets:assets,textureLimit:2048).cgImage(forProposedRect:nil,context:nil,hints:nil)
        artRevisions[object.id]=(try? art.renderCacheData()).map{SHA256.hash(data:$0).map{String(format:"%02x",$0)}.joined()} ?? "none"
      }
    }
    let images=artwork,revisions=artRevisions,materials=project.materials+FormCore.Material.presets
    let worker=Task.detached(priority:.userInitiated) {
      var output=[SceneRenderablePayload]()
      for object in objects {
        try Task.checkCancellation()
        if let reference=object.meshAsset {
          let document=try ModelAssetCoordinator.readAsset(reference,assets:assets)
          let scene=try MeshAssetSceneAdapter.prepare(document:document,reference:reference)
          let appearance=try MeshAssetSceneAdapter.appearance(scene,reference:reference,artwork:images[object.id],artworkRevision:revisions[object.id] ?? "none")
          output+=MeshAssetSceneAdapter.renderables(appearance,objectID:object.id,positionMM:.init(object.position.x,object.position.y,object.position.z),yawDegrees:object.rotation,scalePercent:object["scalePercent"])
        } else {
          let prepared=try CADSceneAdapter.prepare(for:object,assets:assets)
          output+=try await CADSurfaceAppearance.apply(prepared,object:object,project:project,assets:assets,materials:materials)
        }
      }
      return output
    }
    let payloads=try await withTaskCancellationHandler(operation:{try await worker.value},onCancel:{worker.cancel()})
    if let checkpoint=externalCapturePreparationCheckpoint {await checkpoint()}
    try Task.checkCancellation()
    guard projectID==project.id,(try captureSource?.studioDesignDigest()) == (try project.studioDesignDigest()) else{throw FormError.invalid("The model changed while preparing its render. Capture again from the current source.")}
    extraRenderables=payloads
    for index in extraRenderables.indices {extraRenderables[index].visible=captureVisibility.isEmpty || captureVisibility.contains(extraRenderables[index].objectID)}
    externalCaptureRevision=revision;renderScene()
  }
  func renderScene() {
    guard let renderer else{return}
    let payloads=adapter.renderables(scene:scene)+extraRenderables
    var live=Set<String>()
    do {
      for payload in payloads {try renderer.upsert(payload);live.insert(payload.componentID)}
      for id in renderedComponents.subtracting(live) {renderer.remove(componentID:id)}
      renderedComponents=live;rendererIssue=nil
      updateRenderCamera();updateRenderLighting()
    } catch {rendererIssue=error.localizedDescription;store?.error="3D viewport: \(error.localizedDescription)"}
  }
  func updateRenderCamera() {
    do {try renderer?.setCamera(cameraPayload())}catch{rendererIssue=error.localizedDescription}
  }
  func updateRenderLighting() {
    let c=GeometryPayloadAdapter.color(scene.background.contents)
    let key=GeometryPayloadAdapter.color(keyLight.light?.color)
    let q=keyLight.worldTransform.raw.columns.2
    let ambient=scene.rootNode.childNodes.first{$0.light?.type == .ambient}?.light?.intensity ?? 400
    let fill=scene.rootNode.childNodes.first{$0.light?.type == .omni}?.light?.intensity ?? 100
    do {try renderer?.setLighting(.init(background:c,keyDirection:.init(Float(-q.x),Float(-q.y),Float(-q.z)),keyColor:.init(key.x,key.y,key.z),keyIntensity:Float(keyLight.light?.intensity ?? 800)*3.75,fillIntensity:Float(ambient+fill)*1.2,shadows:keyLight.light?.castsShadow ?? true))} catch {rendererIssue=error.localizedDescription}
  }
  func cameraPayload(size:CGSize?=nil)->SceneCameraPayload {
    let lens=cameraNode.camera ?? MeshCamera();var matrix=cameraNode.worldTransform.raw
    matrix.columns.3.x *= 100;matrix.columns.3.y *= 100;matrix.columns.3.z *= 100
    let factor=size.map{CameraFraming.viewportExpansion(from:camera.viewportAspect,to:$0.width/max(1,$0.height))} ?? 1
    let projection:SceneCameraProjection=lens.usesOrthographicProjection ? .orthographic(verticalSpanMM:2*lens.orthographicScale*100*factor):.perspective(verticalFieldOfViewDegrees:atan(tan(lens.fieldOfView * .pi/360)*factor)*360 / .pi)
    return .init(worldFromCameraMM:matrix,projection:projection,nearMM:lens.zNear*100,farMM:lens.zFar*100)
  }

  init(store: StudioStore? = nil) {
    self.store = store
    do {renderer=try RealityKitSceneRenderer()}catch{rendererIssue=error.localizedDescription}
    if let saved = store?.project?.camera { camera = saved }
    scene.background.contents = NSColor(hex: "#F2F2F2")
    scene.rootNode.addChildNode(objectRoot)
    cameraNode.camera = MeshCamera()
    cameraNode.camera?.fieldOfView = 39
    cameraNode.camera?.projectionDirection = .vertical
    cameraNode.camera?.zNear = 0.01
    cameraNode.camera?.zFar = 1500
    cameraNode.camera?.wantsHDR = true
    cameraNode.camera?.exposureOffset = -0.15
    cameraNode.camera?.averageGray = 0.18
    cameraNode.camera?.wantsExposureAdaptation = false
    cameraNode.camera?.bloomIntensity = 0
    scene.rootNode.addChildNode(cameraNode)
    let ambient = MeshNode()
    ambient.light = MeshLight()
    ambient.light?.type = .ambient
    ambient.light?.intensity = 400
    ambient.light?.color = NSColor(hex: "#FFFFFF")
    scene.rootNode.addChildNode(ambient)
    keyLight.light = MeshLight()
    keyLight.light?.type = .directional
    keyLight.light?.intensity = 800
    keyLight.light?.color = NSColor(hex: "#FFFFFF")
    keyLight.light?.castsShadow = true
    keyLight.light?.shadowMode = .forward
    keyLight.light?.shadowRadius = 5
    keyLight.light?.shadowSampleCount = 24
    keyLight.light?.shadowMapSize = CGSize(width: 2048, height: 2048)
    keyLight.light?.shadowColor = NSColor.black.withAlphaComponent(0.26)
    keyLight.light?.orthographicScale = 22
    keyLight.light?.zNear = 0.1
    keyLight.light?.zFar = 80
    keyLight.position = v(-6, 12, 7)
    keyLight.look(at: v(0, 0, 0))
    scene.rootNode.addChildNode(keyLight)
    let fill = MeshNode()
    fill.light = MeshLight()
    fill.light?.type = .omni
    fill.light?.intensity = 100
    fill.light?.color = NSColor(hex: "#FFFFFF")
    fill.position = v(8, 7, -5)
    scene.rootNode.addChildNode(fill)
    let floor = MeshFloor()
    floor.reflectivity = 0
    let surface = MeshMaterial()
    surface.diffuse.contents = NSColor(hex: "#F2F2F2")
    surface.roughness.contents = 1
    surface.lightingModel = .physicallyBased
    floor.materials = [surface]
    floorNode.geometry = floor
    floorNode.position.y = -0.008
    floorNode.categoryBitMask = 4
    scene.rootNode.addChildNode(floorNode)
    buildGrid()
    scene.rootNode.addChildNode(grid)
    grid.isHidden = true
    updateCamera()
  }
  private func buildGrid() {
    var vertices: [MeshVector3] = []
    for i in -50...50 {
      let f = Double(i)
      vertices += [v(f, 0, -50), v(f, 0, 50), v(-50, 0, f), v(50, 0, f)]
    }
    let source = MeshGeometrySource(vertices: vertices)
    let element = MeshGeometryElement(
      indices: Array(0..<Int32(vertices.count)), primitiveType: .line)
    grid.geometry = MeshGeometry(sources: [source], elements: [element])
    grid.position.y = -0.006
    grid.categoryBitMask = 4
    let material = MeshMaterial()
    material.lightingModel = .constant
    material.diffuse.contents = NSColor(hex: "#B3B3B3").withAlphaComponent(0.21)
    material.writesToDepthBuffer = false
    grid.geometry?.materials = [material]
  }
  private func canUpdateEmbroiderySurface(_ old:RenderSignature,_ new:RenderSignature,object:ProductObject)->Bool {
    guard ["textilePatch","textileLabel"].contains(object.recipeID),old.textile?.embroidery != nil || new.textile?.embroidery != nil else {return false}
    var a=old.textile,b=new.textile;a?.embroidery=nil;b?.embroidery=nil
    return old.recipe==new.recipe && old.parameters==new.parameters && old.material==new.material && old.color==new.color && old.asset==new.asset && a==b && old.fabricPattern==new.fabricPattern
  }
  func sync(
    _ project: Project, selection: Set<UUID>, isolated: Set<UUID>, showGrid: Bool, studio: Bool,
    preset: String, assets: URL, textureLimit: Int = 2048, renderObjectIDs:Set<UUID>?=nil
  ) {
    captureSource=project;captureAssets=assets;captureVisibility=isolated;captureObjectIDs=renderObjectIDs
    let started = CFAbsoluteTimeGetCurrent()
    defer { lastSyncMilliseconds = (CFAbsoluteTimeGetCurrent() - started) * 1000 }
    if projectID != project.id {
      view?.cancelPointerInteraction()
      objectRoot.childNodes.forEach { $0.removeFromParentNode() }
      nodes = [:]
      clothSurfaces=[:];clothIssues=[:]
      embroideryIssues=[:];embroideryDigests=[:]
      fingerprints = [:]
      paperPoseStates=[:]
      geometryBounds = [:]
      selectionNodes = []
      lastSelection = []
      projectID = project.id
      adapter.clear();renderer?.reset();renderedComponents=[];extraRenderables=[]
      camera = project.camera
      updateCamera()
    }
    let physicalObjects = project.objects.filter { !$0.isCanvasWorkspace && (renderObjectIDs?.contains($0.id) ?? true) }
    let live = Set(physicalObjects.map(\.id))
    for id in Array(nodes.keys) where !live.contains(id) {
      nodes.removeValue(forKey: id)?.removeFromParentNode()
      clothSurfaces.removeValue(forKey:id);clothIssues.removeValue(forKey:id)
      fingerprints.removeValue(forKey: id)
      paperPoseStates.removeValue(forKey:id)
      embroideryIssues.removeValue(forKey:id);embroideryDigests.removeValue(forKey:id)
      geometryBounds.removeValue(forKey: id)
    }
    var geometryChanged = false
    for object in physicalObjects {
      let fingerprint = RenderSignature(
        recipe: project.recipe(object.recipeID),
        parameters: GeometryFactory.geometryParameters(object),
        material: project.material(object.materialID).withoutFabricPattern, color: object.color,
        artwork: project.surfaceArtwork(object).map {GeometryFactory.artworkDefinition($0,object:object)},
        asset: object.asset,
        fontRevision: project.editableArtwork(object) == nil && project.material(object.materialID).fabric?.pattern == nil ? 0 : GeometryFactory.fontRevision,
        textureLimit: textureLimit, textile: object.textile?.renderDefinition,
        fabricPattern: (try? project.resolvedFabricPattern(materialID: object.materialID))?.renderDefinition,cloth:object.cloth, merchandiseSurface:project.conformedMerchandiseSignature(object),merchandiseMaterials:project.merchandiseMaterialDependencies(object),assemblyRevision:object.patternAssembly==nil ? nil:ClothSceneSurface.sourceIdentity(object:object,project:project).revision,modelRevision:object.meshAsset.map{$0.geometryRevision+"/"+$0.appearanceRevision} ?? object.cadRepresentation?.definitionSHA256,paperRevision:PaperGeometry.sourceRevision(object,project:project))
      if let node=nodes[object.id],let prior=fingerprints[object.id],prior != fingerprint,
        canUpdateEmbroiderySurface(prior,fingerprint,object:object) {
        EmbroiderySceneSurface.update(node,object:object,project:project,assets:assets,textureLimit:textureLimit)
        fingerprints[object.id]=fingerprint;geometryBounds[object.id]=physicalBounds(of:node);geometryChanged=true
        updateEmbroideryStatus(object,project:project,textureLimit:textureLimit)
      } else if nodes[object.id] == nil || fingerprints[object.id] != fingerprint {
        nodes[object.id]?.removeFromParentNode()
        let node:MeshNode
        if object.meshAsset != nil || object.cadRepresentation != nil {
          node=MeshNode();clothSurfaces[object.id]=nil;clothIssues[object.id]=nil
        } else if object.isFlexibleSurface {
          do {
            let surface=try ClothSceneSurface(object:object,project:project,frame:store?.cloth.frame(for:object,in:project),assets:assets,textureLimit:textureLimit)
            clothSurfaces[object.id]=surface;clothIssues[object.id]=nil;node=surface.root
          } catch {clothIssues[object.id]=error.localizedDescription;clothSurfaces[object.id]=nil;node=MeshNode()}
        } else {
          clothSurfaces[object.id]=nil;clothIssues[object.id]=nil
          node=GeometryFactory.object(object,project:project,assets:assets,textureLimit:textureLimit)
        }
        geometryBuilds += 1
        node.name = "object:\(object.id.uuidString)"
        nodes[object.id] = node
        geometryBounds[object.id] = clothSurfaces[object.id]?.geometricBounds ?? physicalBounds(of:node)
        objectRoot.addChildNode(node)
        fingerprints[object.id] = fingerprint
        updateEmbroideryStatus(object,project:project,textureLimit:textureLimit)
        geometryChanged = true
      }
      let node = nodes[object.id]!
      if let reference=object.meshAsset {
        let size=reference.boundsMM.size,s=object["scalePercent"]/100
        geometryBounds[object.id] = (.init(-size.x*s/200,0,-size.z*s/200),.init(size.x*s/200,size.y*s/100,size.z*s/200))
      } else if let representation=object.cadRepresentation {
        let lo=representation.minimum,hi=representation.maximum
        geometryBounds[object.id] = (.init(lo.x/100,lo.y/100,lo.z/100),.init(hi.x/100,hi.y/100,hi.z/100))
      }
      if object.recipeID == "clock" { GeometryFactory.updateClockHands(node, object: object) }
      if object.recipeID == "deskClock" {DeskClockGeometry.updateHands(node,object:object)}
      if PaperConstruction.isPaper(object),let paper=try? PaperConstruction.definition(for:object) {
        let highlighted=(!studio && selection.contains(object.id) && store?.primary?.id==object.id) ? store?.paperSelectedPanelID:nil
        try? PaperGeometry.updatePose(node,object:object,selectedPanelID:highlighted)
        let pose=PaperPoseState(fold:paper.foldPercent,opening:paper.openingPercent)
        if paperPoseStates[object.id] != pose {
          geometryBounds[object.id]=physicalBounds(of:node);geometryChanged=true;paperPoseStates[object.id]=pose
        }
      }
      let placement = project.textilePlacement(object)
      node.position = v(placement.position.x / 100, placement.position.y / 100, placement.position.z / 100)
      if let cloth=try? (store != nil ? store!.cloth.placement(of:object,in:project):project.clothPlacement(object)) {
        applyClothPlacement(cloth,to:node)
      } else if let right=placement.basisRight,let down=placement.basisDown {
        let n=placement.normal
        node.simdOrientation=simd_quatf(simd_float3x3(columns:(SIMD3(Float(right.x),Float(right.y),Float(right.z)),SIMD3(Float(n.x),Float(n.y),Float(n.z)),SIMD3(Float(down.x),Float(down.y),Float(down.z)))))
      } else if object.textile?.attachment != nil {
        let normal = SIMD3<Float>(Float(placement.normal.x), Float(placement.normal.y), Float(placement.normal.z))
        node.simdOrientation = simd_quatf(from: SIMD3<Float>(0,1,0), to: normal)
          * simd_quatf(angle: Float(placement.rotation * .pi / 180), axis: SIMD3<Float>(0,1,0))
      } else {
        node.eulerAngles = MeshVector3(placement.underside ? Double.pi : 0,placement.rotation * .pi / 180,0)
      }
      node.isHidden = !isolated.isEmpty && !isolated.contains(object.id)
    }
    if let store {
      extraRenderables=[]
      for object in physicalObjects {
        var external:[SceneRenderablePayload]=[]
        if object.meshAsset != nil {
          let artwork=project.surfaceArtwork(object)
          let image=artwork.map{GeometryFactory.artworkImage($0,width:object.artworkSize.x,depth:object.artworkSize.y,assets:assets,textureLimit:textureLimit).cgImage(forProposedRect:nil,context:nil,hints:nil)} ?? nil
          let revision=artwork.flatMap{try? $0.renderCacheData()}.map{SHA256.hash(data:$0).map{String(format:"%02x",$0)}.joined()} ?? "none"
          external=store.modelAssets.resolvedScene(for:object,assets:assets,artwork:image,artworkRevision:revision) ?? []
        } else if object.cadRepresentation != nil {external=store.cad.resolvedScene(for:object,assets:assets) ?? []}
        for index in external.indices {external[index].visible=isolated.isEmpty || isolated.contains(object.id)}
        extraRenderables+=external
      }
    }
    // Cached external buffers belong to the source revision; visibility belongs
    // to this composition, including offscreen controllers without a store.
    for index in extraRenderables.indices {
      let id=extraRenderables[index].objectID
      extraRenderables[index].visible=live.contains(id) && (isolated.isEmpty || isolated.contains(id))
    }
    grid.isHidden = !showGrid || studio
    if selection != lastSelection || geometryChanged {
      rebuildSelection(selection, studio: studio)
      lastSelection = selection
    }
    if studio != lastStudio || preset != lastPreset {
      let color =
        studio
        ? (preset == "Warm paper" ? "#E9DFCA" : preset == "Graphite" ? "#3E4345" : "#F2F2F2")
        : "#F2F2F2"
      scene.background.contents = NSColor(hex: color)
      floorNode.geometry?.firstMaterial?.diffuse.contents = NSColor(hex: color)
      keyLight.light?.intensity = studio ? 850 : 800
      keyLight.light?.shadowRadius = studio ? 9 : 5
      lastStudio = studio
      lastPreset = preset
      rebuildSelection(selection, studio: studio)
    }
    renderScene()
  }
  private func applyClothPlacement(_ placement:ClothSurfacePlacement,to node:MeshNode) {
    let p=placement.positionMm,n=placement.normal,t=placement.materialTangent
    let x=SIMD3<Float>(Float(t.x),Float(t.y),Float(t.z)),y=SIMD3<Float>(Float(n.x),Float(n.y),Float(n.z)),z=simd_cross(x,y)
    node.position=MeshVector3(p.x/100,p.y/100,p.z/100);node.simdOrientation=simd_quatf(simd_float3x3(columns:(x,y,z)))
  }
  func updateClothFrame(_ frame:ClothFrame,objectID:UUID) {
    guard let project=store?.project,project.id==projectID,let object=project.objects.first(where:{$0.id==objectID}),let surface=clothSurfaces[objectID],(try? AssemblyProducts.study(for:object,in:project))?.mesh==surface.surface.mesh else {return}
    do {
      try surface.update(frame);geometryBounds[objectID]=surface.geometricBounds
      for object in project.objects where object.clothAttachment?.surfaceObjectID==objectID || object.patternAssemblyAttachment?.surfaceObjectID==objectID {
        if let node=nodes[object.id],let placement=try store?.cloth.placement(of:object,in:project) {applyClothPlacement(placement,to:node)}
      }
      rebuildSelection(lastSelection,studio:lastStudio);renderScene()
    } catch {clothIssues[objectID]=error.localizedDescription}
  }
  func resetClothFrame(objectID:UUID) {
    guard let project=store?.project,let object=project.objects.first(where:{$0.id==objectID}),let study=try? AssemblyProducts.study(for:object,in:project),let frame=try? ClothSolver(mesh:study.mesh,settings:study.settings,colliders:study.colliders,preparation:study.preparation).frame else {return}
    updateClothFrame(frame,objectID:objectID)
  }
  func worldPosition(_ object:ProductObject)->Vector3 {
    guard let project=store?.project else {return object.position}
    if let placement=try? store?.cloth.placement(of:object,in:project) {return placement.positionMm}
    return project.textilePlacement(object).position
  }
  func clothBounds(for id:UUID)->(min:MeshVector3,max:MeshVector3)? {clothSurfaces[id]?.geometricBounds}
  func refreshInterfaceAccent(_ color: NSColor) {
    for node in selectionNodes { node.geometry?.firstMaterial?.diffuse.contents = color }
    if !selectionNodes.isEmpty { renderScene() }
  }
  private func rebuildSelection(_ selection: Set<UUID>, studio: Bool) {
    selectionNodes.forEach { $0.removeFromParentNode() }
    selectionNodes = []
    guard !studio else { return }
    for id in selection {
      guard let node = nodes[id] else { continue }
      let bounds = geometryBounds[id] ?? physicalBounds(of:node)
      let min = bounds.min
      let max = bounds.max
      let p: Double = 0.035
      let x0 = min.x - p
      let x1 = max.x + p
      let y0 = min.y - p
      let y1 = max.y + p
      let z0 = min.z - p
      let z1 = max.z + p
      let points = [
        MeshVector3(x0, y0, z0), MeshVector3(x1, y0, z0), MeshVector3(x1, y0, z1),
        MeshVector3(x0, y0, z1), MeshVector3(x0, y1, z0), MeshVector3(x1, y1, z0),
        MeshVector3(x1, y1, z1), MeshVector3(x0, y1, z1),
      ]
      let indices: [Int32] = [
        0, 1, 1, 2, 2, 3, 3, 0, 4, 5, 5, 6, 6, 7, 7, 4, 0, 4, 1, 5, 2, 6, 3, 7,
      ]
      let geometry = MeshGeometry(
        sources: [MeshGeometrySource(vertices: points)],
        elements: [MeshGeometryElement(indices: indices, primitiveType: .line)])
      let material = MeshMaterial()
      material.lightingModel = .constant
      material.diffuse.contents = Palette.accentNS
      material.readsFromDepthBuffer = false
      material.writesToDepthBuffer = false
      geometry.materials = [material]
      let outline = MeshNode(geometry: geometry)
      outline.name = "selection"
      outline.categoryBitMask = 4
      outline.renderingOrder = 100
      node.addChildNode(outline)
      selectionNodes.append(outline)
    }
  }
  func updateCamera(animated: Bool = false) {
    if let size = view?.bounds.size, size.width > 0, size.height > 0 {
      camera.viewportAspect = size.width / size.height
    }
    // Navigation is immediate: a drag must start from the view the user sees.
    cameraNode.removeAllAnimations()
    cameraNode.camera?.removeAllAnimations()
    cameraNode.camera?.usesOrthographicProjection = camera.projection == "orthographic"
    cameraNode.camera?.orthographicScale = camera.distance * CameraFraming.orthographicFactor
    SceneCamera.position(cameraNode, using: camera)
    let floorHidden=cameraNode.position.y<0,changed=floorNode.isHidden != floorHidden
    floorNode.isHidden=floorHidden
    if changed {renderScene()} else{updateRenderCamera()}
    if let projectID, store?.engine.project?.id == projectID {
      store?.engine.project?.camera = camera
    }
  }
  func resetCamera() {
    view?.cancelPointerInteraction()
    if let p = store?.project {
      camera = p.camera
      updateCamera()
    }
  }
  func orbit(dx: CGFloat, dy: CGFloat) {
    camera = CameraNavigation.orbited(
      camera, dx: Double(dx), dy: Double(dy), viewportHeight: Double(view?.bounds.height ?? 700))
    updateCamera()
  }
  func zoom(_ delta: Double) {
    camera = CameraNavigation.zoomed(camera, delta: delta)
    updateCamera()
    store?.cameraChanged()
  }
  func pan(dx: CGFloat, dy: CGFloat) {
    camera = CameraNavigation.panned(
      camera, dx: Double(dx), dy: Double(dy), viewportHeight: Double(view?.bounds.height ?? 700),
      fieldOfView: Double(cameraNode.camera?.fieldOfView ?? 39))
    updateCamera()
  }
  func preset(_ name: String) {
    if store?.studioShots.referenceAspect != nil {
      store?.studioShots.leaveReview()
      view?.window?.contentView?.needsLayout=true
      view?.window?.contentView?.layoutSubtreeIfNeeded()
    }
    if store != nil { view?.window?.makeFirstResponder(view) }
    view?.cancelPointerInteraction()
    camera.orientation = nil
    switch name {
    case "overhead":
      camera.elevation = .pi / 2
      camera.azimuth = 0
      camera.projection = "orthographic"
    case "front":
      camera.elevation = 0
      camera.azimuth = 0
      camera.projection = "orthographic"
    default:
      camera.elevation = 0.70
      camera.azimuth = 0.55
      camera.projection = "perspective"
    }
    // Named views always recover the entire project, never a stale pan target.
    store?.isolated = []
    for node in nodes.values { node.isHidden = false }
    for index in extraRenderables.indices {extraRenderables[index].visible=true}
    renderScene()
    frame(ids: Set(nodes.keys), animated: false)
    store?.cameraChanged()
  }
  func fitAll() {
    if store != nil { view?.window?.makeFirstResponder(view) }
    view?.cancelPointerInteraction()
    let isolated = store?.isolated ?? []
    frame(ids: Set(nodes.keys.filter { isolated.isEmpty || isolated.contains($0) }))
    store?.cameraChanged()
  }
  func focusSelection() {
    if store != nil { view?.window?.makeFirstResponder(view) }
    view?.cancelPointerInteraction()
    if let selection = store?.engine.selection, !selection.isEmpty {
      frame(ids: selection)
      store?.cameraChanged()
    }
  }
  private func frame(ids: Set<UUID>, aspect: Double? = nil, animated: Bool = true) {
    var points: [Vector3] = []
    for id in ids {
      guard let node = nodes[id] else { continue }
      let b = geometryBounds[id] ?? physicalBounds(of:node)
      for x in [b.min.x, b.max.x] {
        for y in [b.min.y, b.max.y] {
          for z in [b.min.z, b.max.z] {
            let p = node.convertPosition(.init(x, y, z), to: nil)
            points.append(.init(Double(p.x), Double(p.y), Double(p.z)))
          }
        }
      }
    }
    guard !points.isEmpty else {
      camera = .init()
      updateCamera(animated: true)
      return
    }
    let viewport = view?.bounds.size ?? CGSize(width: 600, height: 400)
    var insets = CameraFraming.Insets()
    if aspect == nil, view != nil, let store {
      // Reserve the floating inspector and camera bar without changing the
      // subject-centered orbit pivot or the camera's actual viewport aspect.
      insets = .init(
        top: 80 / max(1, viewport.height),
        right: (store.mode == .studio ? 264 + 48 : store.surfaceLayout == .split || store.primary == nil || store.environment != .form ? 0 : ObjectInspector.width + 48) / max(1, viewport.width),
        bottom: 80 / max(1, viewport.height))
    }
    let fitted = CameraFraming.fitted(
      camera, points: points,
      aspect: aspect ?? Double(viewport.width / max(1, viewport.height)),
      fieldOfView: Double(cameraNode.camera?.fieldOfView ?? 39), insets: insets)
    // A preset may have changed orientation before fitting. Even when bounds
    // need the same distance/target, apply that orientation to the renderer/store.
    camera = fitted
    updateCamera(animated: animated)
  }
  func logicalNode(for id:UUID)->MeshNode? {nodes[id]}
  /// Interface outlines are children of the visible object, but never part of
  /// its physical size. Including the previous padded selection outline would
  /// grow the next outline on every in-place pose or appearance update.
  private func physicalBounds(of root:MeshNode)->(min:MeshVector3,max:MeshVector3) {
    let adornments=Set(selectionNodes.map(ObjectIdentifier.init))
    func measure(_ node:MeshNode)->(min:MeshVector3,max:MeshVector3)? {
      guard !adornments.contains(ObjectIdentifier(node)),node.name != PaperGeometry.highlightName else{return nil}
      var points=node.geometry?.sources(for:.vertex).flatMap(\.vectors) ?? []
      for child in node.childNodes {
        guard let b=measure(child) else{continue}
        for x in [b.min.x,b.max.x] {for y in [b.min.y,b.max.y] {for z in [b.min.z,b.max.z] {
          let p=child.transform.raw*SIMD4(x,y,z,1);points.append(.init(p.x,p.y,p.z))
        }}}
      }
      guard let first=points.first else{return nil}
      var low=first.simd,high=low
      for point in points.dropFirst(){low=simd_min(low,point.simd);high=simd_max(high,point.simd)}
      return(.init(low),.init(high))
    }
    return measure(root) ?? (.init(),.init())
  }
  func localBounds(for id:UUID)->(min:MeshVector3,max:MeshVector3)? {geometryBounds[id] ?? nodes[id].map{physicalBounds(of:$0)}}
  func paperPanelID(at point:NSPoint)->String? {
    guard let hit=view?.sceneHits(point).first else{return nil}
    return PaperGeometry.panelID(from:hit.node)
  }
  func objectID(at point:NSPoint)->UUID? {
    guard let view else{return nil}
    return renderer?.pick(atTopLeft:.init(x:point.x,y:view.bounds.height-point.y),viewport:view.bounds.size)?.objectID
  }
  /// Stable plane used only for a singly selected attached decoration. The
  /// resulting pointer ray still has to hit its actual visible material panel.
  func pointOnPlane(_ point:NSPoint,through origin:Vector3,normal:Vector3)->Vector3? {
    guard let view else{return nil}
    let near=view.unprojectPoint(.init(point.x,point.y,0)),far=view.unprojectPoint(.init(point.x,point.y,1))
    let a=SIMD3<Double>(Double(near.x)*100,Double(near.y)*100,Double(near.z)*100),b=SIMD3<Double>(Double(far.x)*100,Double(far.y)*100,Double(far.z)*100),n=SIMD3<Double>(normal.x,normal.y,normal.z),p=SIMD3<Double>(origin.x,origin.y,origin.z),d=b-a,denominator=simd_dot(d,n)
    guard denominator.isFinite,abs(denominator)>1e-9 else{return nil}
    let t=simd_dot(p-a,n)/denominator
    guard t.isFinite,(0...1).contains(t) else{return nil}
    let q=a+d*t;return .init(q.x,q.y,q.z)
  }
  func attachmentTarget(_ target:Vector3,for object:ProductObject)->Vector3? {
    guard let view,let project=store?.project,let parentID=object.patternAssemblyAttachment?.surfaceObjectID ?? object.clothAttachment?.surfaceObjectID,
      let surface=clothSurfaces[parentID] else{return nil}
    let panel:Int
    if let attached=object.patternAssemblyAttachment,let parent=project.objects.first(where:{$0.id==parentID}),let product=try? AssemblyProducts.product(for:parent,in:project),let value=product.panels.first(where:{$0.id==attached.anchor.panel}) {panel=value.panelIndex}
    else if let attached=object.clothAttachment {panel=surface.surface.mesh.panelID(forTriangle:attached.anchor.triangle)}
    else {return nil}
    let q=view.projectPoint(MeshVector3(target.x/100,target.y/100,target.z/100)),point=NSPoint(x:q.x,y:q.y)
    guard point.x.isFinite,point.y.isFinite,view.bounds.contains(point) else{return nil}
    let hits=view.sceneHits(point)
    for hit in hits {
      var node:MeshNode?=hit.node,owner:UUID?
      while let current=node {if let name=current.name,name.hasPrefix("object:"),let id=UUID(uuidString:String(name.dropFirst(7))) {owner=id;break};node=current.parent}
      guard let owner else{continue}
      if owner==object.id {continue}
      guard owner==parentID,hit.node === surface.surface.node,surface.surface.panelIDsByGeometryElement.indices.contains(hit.geometryIndex),surface.surface.panelIDsByGeometryElement[hit.geometryIndex]==panel else{return nil}
      let near=view.unprojectPoint(.init(point.x,point.y,0))
      if clothSurfaces.values.contains(where:{$0.supportOccludes(from:near,to:hit.worldCoordinates)}) {return nil}
      return .init(Double(hit.worldCoordinates.x)*100,Double(hit.worldCoordinates.y)*100,Double(hit.worldCoordinates.z)*100)
    }
    return nil
  }
  func pointOnTable(_ point: NSPoint, height: Double) -> Vector3? {
    guard let view else { return nil }
    let near = view.unprojectPoint(.init(point.x, point.y, 0))
    let far = view.unprojectPoint(.init(point.x, point.y, 1))
    let dy = Double(far.y - near.y)
    guard abs(dy) > 0.000001 else { return nil }
    let t = (height / 100 - Double(near.y)) / dy
    guard t.isFinite, t >= 0, t <= 1 else { return nil }
    return .init(
      (Double(near.x) + Double(far.x - near.x) * t) * 100, height,
      (Double(near.z) + Double(far.z - near.z) * t) * 100)
  }
  static func preview(
    project:Project,size:CGSize,assets:URL,studio:Bool=false,preset:String="Daylight",fitContents:Bool=false
  )async throws->NSImage {
    let controller=TableSceneController()
    controller.sync(project,selection:[],isolated:[],showGrid:false,studio:studio,preset:preset,assets:assets)
    if fitContents {controller.frame(ids:Set(controller.nodes.keys),aspect:size.width/max(1,size.height),animated:false)}
    return try await controller.snapshot(size:size)
  }
  func snapshot(size:CGSize,camera outputCamera:SceneCameraPayload?=nil)async throws->NSImage {
    guard let renderer else{throw FormError.invalid(rendererIssue ?? "RealityKit renderer is unavailable.")}
    if let project=captureSource,let assets=captureAssets {try await prepareExternalForCapture(project:project,assets:assets)}
    // Selection is an editing overlay and never part of a project export.
    let overlays=selectionNodes,hidden=overlays.map(\.isHidden);overlays.forEach{$0.isHidden=true};renderScene()
    defer {for (node,wasHidden) in zip(overlays,hidden){node.isHidden=wasHidden};renderScene()}
    let image=try await renderer.capture(width:Int(size.width),height:Int(size.height),camera:outputCamera ?? cameraPayload(size:size))
    return NSImage(cgImage:image,size:size)
  }

}

@MainActor struct TableCanvas: NSViewRepresentable {
  @EnvironmentObject var store: StudioStore
  func makeNSView(context: Context) -> TableSceneView {
    let controller = store.scene ?? TableSceneController(store: store)
    store.scene = controller
    let view = TableSceneView(frame:.zero)
    view.controller = controller
    controller.view = view
    view.setAccessibilityLabel("The Table, 3D creative workspace")
    return view
  }
  func updateNSView(_ view: TableSceneView, context: Context) {
    guard let project = store.project else { return }
    _ = store.revision
    view.controller?.sync(
      project, selection: store.engine.selection, isolated: store.isolated,
      showGrid: store.showGrid, studio: store.mode == .studio, preset: store.studioPreset,
      assets: store.repository.url(for: project.id).appendingPathComponent("Assets"))
    view.controller?.applyShotLighting(store.studioShots.lighting,studio:store.mode == .studio)
  }
}

@MainActor final class TableSceneView:NSView {
  weak var controller:TableSceneController? {didSet{installViewport()}}
  private func installViewport() {
    subviews.forEach{$0.removeFromSuperview()}
    if let viewport=controller?.renderer?.nativeView {viewport.frame=bounds;viewport.autoresizingMask=[.width,.height];addSubview(viewport)}
    else {let label=NSTextField(labelWithString:controller?.rendererIssue ?? "3D renderer unavailable");label.frame=bounds.insetBy(dx:24,dy:24);label.autoresizingMask=[.width,.height];addSubview(label)}
  }
  override func hitTest(_ point:NSPoint)->NSView? {isHidden || !bounds.contains(convert(point,from:superview)) ? nil:self}
  func projectPoint(_ p:MeshVector3)->MeshVector3 {
    guard let controller,let q=SceneProjection.project(p.simd*100,camera:controller.cameraPayload(),viewport:bounds.size) else{return .init(.nan,.nan,.nan)}
    let camera=controller.cameraPayload(),local=camera.worldFromCameraMM.inverse*SIMD4(p.simd*100,1),depth = -local.z
    let normalized:Double
    switch camera.projection {
    case .orthographic:normalized=(depth-camera.nearMM)/(camera.farMM-camera.nearMM)
    case .perspective:normalized=camera.farMM/(camera.farMM-camera.nearMM)-camera.farMM*camera.nearMM/((camera.farMM-camera.nearMM)*depth)
    }
    return .init(q.x,bounds.height-q.y,normalized)
  }
  func unprojectPoint(_ p:MeshVector3)->MeshVector3 {
    guard let c=controller,let ray=SceneProjection.ray(camera:c.cameraPayload(),atTopLeft:.init(x:p.x,y:bounds.height-p.y),viewport:bounds.size) else{return .init(.nan,.nan,.nan)}
    let camera=c.cameraPayload(),z=SIMD3(camera.worldFromCameraMM.columns.2.x,camera.worldFromCameraMM.columns.2.y,camera.worldFromCameraMM.columns.2.z)
    let depth:Double
    switch camera.projection {
    case .orthographic:depth=camera.nearMM+(camera.farMM-camera.nearMM)*p.z
    case .perspective:depth=camera.nearMM*camera.farMM/(camera.farMM-p.z*(camera.farMM-camera.nearMM))
    }
    let denom = -simd_dot(ray.direction,z)
    return .init((ray.originMM+ray.direction*(depth/max(1e-12,denom)))/100)
  }
  func sceneHits(_ point:NSPoint)->[GeometryPayloadAdapter.Hit] {
    guard let controller,let renderer=controller.renderer else{return []}
    return renderer.picks(atTopLeft:.init(x:point.x,y:bounds.height-point.y),viewport:bounds.size).compactMap{hit in
      guard let node=controller.adapter.nodes[hit.componentID] ?? controller.logicalNode(for:hit.objectID) else{return nil}
      return .init(node:node,geometryIndex:Int(hit.partID?.dropFirst(8) ?? "0") ?? 0,worldCoordinates:.init(hit.pointMM/100),objectID:hit.objectID)
    }
  }
  var onEscape: (() -> Void)?
  // Separate presentation viewports reuse the established navigation contract.
  var onCameraInteraction:(()->Void)?
  var onObjectPick:((UUID?)->Void)?
  private enum DragAction { case orbit, move }
  private var action: DragAction = .orbit
  private var previous = NSPoint.zero
  private var down = NSPoint.zero
  private var dragOrigin: Vector3?
  private struct AttachmentDrag {var objectID:UUID,projectID:UUID,plane:Vector3,normal:Vector3,down:Vector3,initial:Vector3,sourceRevision:String,parentPosition:Vector3,parentRotation:Double}
  private var attachmentDrag:AttachmentDrag?
  private var objectPositions: [UUID: Vector3] = [:]
  private var dragged = false
  private var pointerActive = false
  private var gestureCount = 0
  private var eventCount = 0
  private var totalDelta = NSPoint.zero
  private var lastAction = "none"
  private var phase = "idle"
  var inputDiagnostics: [String: Any] {
    ["gesture_count": gestureCount, "event_count": eventCount,
     "dx": totalDelta.x, "dy": totalDelta.y, "action": lastAction, "phase": phase]
  }
  override var acceptsFirstResponder: Bool { true }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  override func resetCursorRects() {
    addCursorRect(bounds, cursor: controller?.store?.tableTool == .move ? .arrow : .openHand)
  }
  func cancelPointerInteraction() {
    if pointerActive { phase = "cancelled" }
    pointerActive = false
    dragged = false
    dragOrigin = nil
    attachmentDrag = nil
    objectPositions = [:]
  }
  override func viewWillMove(toWindow newWindow: NSWindow?) {
    cancelPointerInteraction()
    super.viewWillMove(toWindow: newWindow)
  }
  override func setFrameSize(_ newSize: NSSize) {
    let changed = frame.size != newSize
    super.setFrameSize(newSize)
    if changed {
      cancelPointerInteraction()
      controller?.updateCamera()
    }
  }
  override func mouseDown(with event: NSEvent) {
    window?.makeFirstResponder(self)
    controller?.store?.activateDesignSurface(.table)
    cancelPointerInteraction()
    previous = convert(event.locationInWindow, from: nil)
    down = previous
    pointerActive = true
    gestureCount += 1
    eventCount = 0
    totalDelta = .zero
    phase = "began"
    lastAction = "none"
    action = .orbit
    guard let controller else { return }
    if controller.store?.tableTool == .move, let store = controller.store,
      let id = controller.objectID(at: previous)
    {
      if !store.engine.selection.contains(id) || event.modifierFlags.contains(.shift) {
        store.select(id, extending: event.modifierFlags.contains(.shift))
      }
      action = .move
      objectPositions = Dictionary(
        uniqueKeysWithValues: store.selected.filter { !$0.locked }.map { ($0.id, controller.worldPosition($0)) })
      dragOrigin = controller.pointOnTable(previous, height: store.primary.map {controller.worldPosition($0).y} ?? 0)
      if store.selected.count==1,objectPositions.count==1,let object=store.primary,object.isClothAttached,let project=store.project,
        let parentID=object.patternAssemblyAttachment?.surfaceObjectID ?? object.clothAttachment?.surfaceObjectID,let parent=project.objects.first(where:{$0.id==parentID}) {
        let initial=controller.worldPosition(object),normal=CameraNavigation.basis(controller.camera).outward
        if controller.attachmentTarget(initial,for:object)==nil {objectPositions=[:];return}
        if let at=controller.pointOnPlane(previous,through:initial,normal:normal) {attachmentDrag = .init(objectID:object.id,projectID:project.id,plane:initial,normal:normal,down:at,initial:initial,sourceRevision:ClothSceneSurface.sourceIdentity(object:parent,project:project).revision,parentPosition:parent.position,parentRotation:parent.rotation)}
      }
    }
  }
  override func mouseDragged(with event: NSEvent) {
    // A late drag after a missed/cancelled mouse-down must never reuse an old anchor.
    guard pointerActive, let controller else { return }
    let point = convert(event.locationInWindow, from: nil)
    guard point.x.isFinite, point.y.isFinite else { return }
    let wasDragged = dragged
    dragged = dragged || hypot(point.x - down.x, point.y - down.y) > 3
    defer { previous = point }
    guard dragged else { return }
    let anchor = wasDragged ? previous : down
    let dx = point.x - anchor.x
    let dy = point.y - anchor.y
    eventCount += 1
    totalDelta.x += dx
    totalDelta.y += dy
    phase = "dragging"
    switch action {
    case .orbit:
      if event.modifierFlags.contains(.shift) {
        lastAction = "pan"
        controller.pan(dx: dx, dy: dy)
      } else {
        lastAction = "orbit"
        controller.orbit(dx: dx, dy: dy)
      }
    case .move:
      lastAction = "move"
      if let drag=attachmentDrag {
        guard let store=controller.store,let project=store.project,project.id==drag.projectID,
          let object=project.objects.first(where:{$0.id==drag.objectID}),object.isClothAttached,!object.locked,
          let parentID=object.patternAssemblyAttachment?.surfaceObjectID ?? object.clothAttachment?.surfaceObjectID,let parent=project.objects.first(where:{$0.id==parentID}),parent.position==drag.parentPosition,parent.rotation==drag.parentRotation,
          ClothSceneSurface.sourceIdentity(object:parent,project:project).revision==drag.sourceRevision,
          let now=controller.pointOnPlane(point,through:drag.plane,normal:drag.normal) else{return}
        let snap=event.modifierFlags.contains(.shift) ? 10.0:1.0
        let proposed=Vector3(((drag.initial.x+now.x-drag.down.x)/snap).rounded()*snap,((drag.initial.y+now.y-drag.down.y)/snap).rounded()*snap,((drag.initial.z+now.z-drag.down.z)/snap).rounded()*snap)
        guard let target=controller.attachmentTarget(proposed,for:object) else{return}
        store.edit("Moved attached material point",coalescing:"move-selection") {p in try store.cloth.reposition(object.id,to:target,in:&p)}
        return
      }
      guard let origin = dragOrigin,
        let now = controller.pointOnTable(point, height: origin.y), let store = controller.store,
        !objectPositions.isEmpty
      else { return }
      let snap = event.modifierFlags.contains(.shift) ? 10.0 : 1.0
      store.edit("Moved objects", coalescing: "move-selection") { p in
        for i in p.objects.indices {
          if let start = self.objectPositions[p.objects[i].id] {
            // A selected decoration follows its moving garment. Moving both
            // independently would apply the same translation twice and make
            // the result depend on their saved object order.
            if let parent = p.objects[i].textile?.attachment?.garmentID ?? p.objects[i].clothAttachment?.surfaceObjectID ?? p.objects[i].patternAssemblyAttachment?.surfaceObjectID,
              self.objectPositions[parent] != nil { continue }
            let target = Vector3(((start.x + now.x - origin.x) / snap).rounded() * snap,
              start.y, ((start.z + now.z - origin.z) / snap).rounded() * snap)
            if p.objects[i].isClothAttached {try store.cloth.reposition(p.objects[i].id,to:target,in:&p)}
            else {p.setTextileWorldPosition(p.objects[i].id,to:target)}
          }
        }
      }
    }
  }
  override func mouseUp(with event: NSEvent) {
    guard pointerActive else { return }
    if !dragged, let controller, let store = controller.store {
      let point = convert(event.locationInWindow, from: nil)
      let objectID=controller.objectID(at:point)
      if action != .move {
        store.select(objectID, extending:event.modifierFlags.contains(.shift))
      }
      if !event.modifierFlags.contains(.shift),let objectID,let panelID=controller.paperPanelID(at:point) {
        store.selectPaperPanel(objectID:objectID,panelID:panelID)
      }
      if event.clickCount == 2 { controller.focusSelection() }
    }
    pointerActive = false
    phase = "ended"
    dragOrigin = nil
    attachmentDrag = nil
    objectPositions = [:]
    controller?.store?.cameraChanged()
    if !dragged,controller?.store==nil {onObjectPick?(controller?.objectID(at:convert(event.locationInWindow,from:nil)))}
    if dragged {onCameraInteraction?()}
  }
  override func scrollWheel(with event: NSEvent) {
    let delta = -Double(event.scrollingDeltaY) * (event.hasPreciseScrollingDeltas ? 0.35 : 1)
    controller?.zoom(delta)
    onCameraInteraction?()
  }
  override func magnify(with event: NSEvent) {
    controller?.zoom(-Double(event.magnification) * 100)
    onCameraInteraction?()
  }
  override func keyDown(with event: NSEvent) {
    if event.keyCode == 53, let onEscape { onEscape(); return }
    if event.keyCode == 51 || event.keyCode == 117 {
      controller?.store?.deleteSelection()
    } else if event.keyCode == 53 {
      cancelPointerInteraction()
      if let store = controller?.store, !store.isolated.isEmpty {
        store.isolated = []
        controller?.fitAll()
      } else {
        controller?.store?.select(nil)
      }
    } else if !event.modifierFlags.contains(.command), !event.modifierFlags.contains(.control) {
      switch event.charactersIgnoringModifiers?.lowercased() {
      case "o": controller?.store?.setTableTool(.orbit)
      case "v": controller?.store?.setTableTool(.move)
      case "f": controller?.focusSelection()
      case "i": controller?.store?.isolate()
      case "1": controller?.preset("perspective")
      case "2": controller?.preset("overhead")
      case "3": controller?.preset("front")
      case "g" where event.modifierFlags.contains(.shift): controller?.store?.showGrid.toggle()
      default: super.keyDown(with: event)
      }
    } else {
      super.keyDown(with: event)
    }
  }
  override func resignFirstResponder() -> Bool {
    cancelPointerInteraction()
    return super.resignFirstResponder()
  }
}
