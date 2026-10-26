import AppKit
import CryptoKit
import FormCore
import FormGraphics
import Metal
import SceneKit
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
private func v(_ x: Double, _ y: Double, _ z: Double) -> SCNVector3 { .init(x, y, z) }
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
}

@MainActor final class TableSceneController {
  let scene = SCNScene()
  let cameraNode = SCNNode()
  let objectRoot = SCNNode()
  let grid = SCNNode()
  let keyLight = SCNNode()
  let floorNode = SCNNode()
  weak var store: StudioStore?
  weak var view: TableSCNView?
  private var projectID: UUID?
  private var nodes: [UUID: SCNNode] = [:]
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
  private var geometryBounds: [UUID: (min: SCNVector3, max: SCNVector3)] = [:]
  private var selectionNodes: [SCNNode] = []
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
      "renders_continuously": view?.rendersContinuously ?? false, "preferred_fps": 60,
      "orbit_direction": "followPointer",
      "orbit_speed": CameraPreferences().effectiveOrbitSpeed,
      "mouse": view?.inputDiagnostics ?? [:],
    ]
  }
  var camera = CameraState()

  init(store: StudioStore? = nil) {
    self.store = store
    if let saved = store?.project?.camera { camera = saved }
    scene.background.contents = NSColor(hex: "#EEEDE8")
    scene.rootNode.addChildNode(objectRoot)
    cameraNode.camera = SCNCamera()
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
    let ambient = SCNNode()
    ambient.light = SCNLight()
    ambient.light?.type = .ambient
    ambient.light?.intensity = 400
    ambient.light?.color = NSColor(hex: "#F7F7F2")
    scene.rootNode.addChildNode(ambient)
    keyLight.light = SCNLight()
    keyLight.light?.type = .directional
    keyLight.light?.intensity = 800
    keyLight.light?.color = NSColor(hex: "#FFF5E7")
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
    let fill = SCNNode()
    fill.light = SCNLight()
    fill.light?.type = .omni
    fill.light?.intensity = 100
    fill.light?.color = NSColor(hex: "#E2EAF6")
    fill.position = v(8, 7, -5)
    scene.rootNode.addChildNode(fill)
    let floor = SCNFloor()
    floor.reflectivity = 0
    let surface = SCNMaterial()
    surface.diffuse.contents = NSColor(hex: "#EEEDE8")
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
    var vertices: [SCNVector3] = []
    for i in -50...50 {
      let f = Double(i)
      vertices += [v(f, 0, -50), v(f, 0, 50), v(-50, 0, f), v(50, 0, f)]
    }
    let source = SCNGeometrySource(vertices: vertices)
    let element = SCNGeometryElement(
      indices: Array(0..<Int32(vertices.count)), primitiveType: .line)
    grid.geometry = SCNGeometry(sources: [source], elements: [element])
    grid.position.y = -0.006
    grid.categoryBitMask = 4
    let material = SCNMaterial()
    material.lightingModel = .constant
    material.diffuse.contents = NSColor(hex: "#B3B6AF").withAlphaComponent(0.21)
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
    preset: String, assets: URL, textureLimit: Int = 2048
  ) {
    let started = CFAbsoluteTimeGetCurrent()
    defer { lastSyncMilliseconds = (CFAbsoluteTimeGetCurrent() - started) * 1000 }
    SCNTransaction.begin()
    SCNTransaction.disableActions = true
    if projectID != project.id {
      view?.cancelPointerInteraction()
      objectRoot.childNodes.forEach { $0.removeFromParentNode() }
      nodes = [:]
      clothSurfaces=[:];clothIssues=[:]
      embroideryIssues=[:];embroideryDigests=[:]
      fingerprints = [:]
      geometryBounds = [:]
      selectionNodes = []
      lastSelection = []
      projectID = project.id
      camera = project.camera
      updateCamera()
    }
    let physicalObjects = project.objects.filter { !$0.isCanvasWorkspace }
    let live = Set(physicalObjects.map(\.id))
    for id in Array(nodes.keys) where !live.contains(id) {
      nodes.removeValue(forKey: id)?.removeFromParentNode()
      clothSurfaces.removeValue(forKey:id);clothIssues.removeValue(forKey:id)
      fingerprints.removeValue(forKey: id)
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
        fabricPattern: (try? project.resolvedFabricPattern(materialID: object.materialID))?.renderDefinition,cloth:object.cloth, merchandiseSurface:project.conformedMerchandiseSignature(object),merchandiseMaterials:project.merchandiseMaterialDependencies(object),assemblyRevision:object.patternAssembly==nil ? nil:ClothSceneSurface.sourceIdentity(object:object,project:project).revision)
      if let node=nodes[object.id],let prior=fingerprints[object.id],prior != fingerprint,
        canUpdateEmbroiderySurface(prior,fingerprint,object:object) {
        EmbroiderySceneSurface.update(node,object:object,project:project,assets:assets,textureLimit:textureLimit)
        fingerprints[object.id]=fingerprint;geometryBounds[object.id]=node.boundingBox;geometryChanged=true
        updateEmbroideryStatus(object,project:project,textureLimit:textureLimit)
      } else if nodes[object.id] == nil || fingerprints[object.id] != fingerprint {
        nodes[object.id]?.removeFromParentNode()
        let node:SCNNode
        if object.isFlexibleSurface {
          do {
            let surface=try ClothSceneSurface(object:object,project:project,frame:store?.cloth.frame(for:object,in:project),assets:assets,textureLimit:textureLimit)
            clothSurfaces[object.id]=surface;clothIssues[object.id]=nil;node=surface.root
          } catch {clothIssues[object.id]=error.localizedDescription;clothSurfaces[object.id]=nil;node=SCNNode()}
        } else {
          clothSurfaces[object.id]=nil;clothIssues[object.id]=nil
          node=GeometryFactory.object(object,project:project,assets:assets,textureLimit:textureLimit)
        }
        geometryBuilds += 1
        node.name = "object:\(object.id.uuidString)"
        nodes[object.id] = node
        geometryBounds[object.id] = clothSurfaces[object.id]?.geometricBounds ?? node.boundingBox
        objectRoot.addChildNode(node)
        fingerprints[object.id] = fingerprint
        updateEmbroideryStatus(object,project:project,textureLimit:textureLimit)
        geometryChanged = true
      }
      let node = nodes[object.id]!
      if object.recipeID == "clock" { GeometryFactory.updateClockHands(node, object: object) }
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
        node.eulerAngles = SCNVector3(placement.underside ? Float.pi : 0,
          Float(placement.rotation * .pi / 180),0)
      }
      node.isHidden = !isolated.isEmpty && !isolated.contains(object.id)
    }
    grid.isHidden = !showGrid || studio
    if selection != lastSelection || geometryChanged {
      rebuildSelection(selection, studio: studio)
      lastSelection = selection
    }
    if studio != lastStudio || preset != lastPreset {
      let color =
        studio
        ? (preset == "Warm paper" ? "#E9DFCA" : preset == "Graphite" ? "#3E4345" : "#E9E9E5")
        : "#EEEDE8"
      scene.background.contents = NSColor(hex: color)
      floorNode.geometry?.firstMaterial?.diffuse.contents = NSColor(hex: color)
      keyLight.light?.intensity = studio ? 850 : 800
      keyLight.light?.shadowRadius = studio ? 9 : 5
      lastStudio = studio
      lastPreset = preset
      rebuildSelection(selection, studio: studio)
    }
    SCNTransaction.commit()
    view?.needsDisplay = true
  }
  private func applyClothPlacement(_ placement:ClothSurfacePlacement,to node:SCNNode) {
    let p=placement.positionMm,n=placement.normal,t=placement.materialTangent
    let x=SIMD3<Float>(Float(t.x),Float(t.y),Float(t.z)),y=SIMD3<Float>(Float(n.x),Float(n.y),Float(n.z)),z=simd_cross(x,y)
    node.position=SCNVector3(p.x/100,p.y/100,p.z/100);node.simdOrientation=simd_quatf(simd_float3x3(columns:(x,y,z)))
  }
  func updateClothFrame(_ frame:ClothFrame,objectID:UUID) {
    guard let project=store?.project,project.id==projectID,let object=project.objects.first(where:{$0.id==objectID}),let surface=clothSurfaces[objectID],(try? AssemblyProducts.study(for:object,in:project))?.mesh==surface.surface.mesh else {return}
    do {
      try surface.update(frame);geometryBounds[objectID]=surface.geometricBounds
      for object in project.objects where object.clothAttachment?.surfaceObjectID==objectID || object.patternAssemblyAttachment?.surfaceObjectID==objectID {
        if let node=nodes[object.id],let placement=try store?.cloth.placement(of:object,in:project) {applyClothPlacement(placement,to:node)}
      }
      rebuildSelection(lastSelection,studio:lastStudio);view?.needsDisplay=true
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
  func clothBounds(for id:UUID)->(min:SCNVector3,max:SCNVector3)? {clothSurfaces[id]?.geometricBounds}
  private func rebuildSelection(_ selection: Set<UUID>, studio: Bool) {
    selectionNodes.forEach { $0.removeFromParentNode() }
    selectionNodes = []
    guard !studio else { return }
    for id in selection {
      guard let node = nodes[id] else { continue }
      let bounds = geometryBounds[id] ?? node.boundingBox
      let min = bounds.min
      let max = bounds.max
      let p: CGFloat = 0.035
      let x0 = min.x - p
      let x1 = max.x + p
      let y0 = min.y - p
      let y1 = max.y + p
      let z0 = min.z - p
      let z1 = max.z + p
      let points = [
        SCNVector3(x0, y0, z0), SCNVector3(x1, y0, z0), SCNVector3(x1, y0, z1),
        SCNVector3(x0, y0, z1), SCNVector3(x0, y1, z0), SCNVector3(x1, y1, z0),
        SCNVector3(x1, y1, z1), SCNVector3(x0, y1, z1),
      ]
      let indices: [Int32] = [
        0, 1, 1, 2, 2, 3, 3, 0, 4, 5, 5, 6, 6, 7, 7, 4, 0, 4, 1, 5, 2, 6, 3, 7,
      ]
      let geometry = SCNGeometry(
        sources: [SCNGeometrySource(vertices: points)],
        elements: [SCNGeometryElement(indices: indices, primitiveType: .line)])
      let material = SCNMaterial()
      material.lightingModel = .constant
      material.diffuse.contents = NSColor(hex: "#CF6945")
      material.readsFromDepthBuffer = false
      material.writesToDepthBuffer = false
      geometry.materials = [material]
      let outline = SCNNode(geometry: geometry)
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
    SCNTransaction.begin()
    // Navigation is immediate: a drag must start from the view the user sees.
    SCNTransaction.disableActions = true
    SCNTransaction.animationDuration = 0
    cameraNode.removeAllAnimations()
    cameraNode.camera?.removeAllAnimations()
    cameraNode.camera?.usesOrthographicProjection = camera.projection == "orthographic"
    cameraNode.camera?.orthographicScale = camera.distance * CameraFraming.orthographicFactor
    SceneCamera.position(cameraNode, using: camera)
    floorNode.isHidden = cameraNode.position.y < 0
    SCNTransaction.commit()
    view?.needsDisplay = true
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
      let b = geometryBounds[id] ?? node.boundingBox
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
        right: (store.mode == .studio ? 264 + 48 : store.surfaceLayout == .split || store.primary == nil ? 0 : ObjectInspector.width + 48) / max(1, viewport.width),
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
  func objectID(at point: NSPoint) -> UUID? {
    guard let view else { return nil }
    for hit in view.hitTest(point, options: [.categoryBitMask: 2, .ignoreHiddenNodes: true]) {
      var node: SCNNode? = hit.node
      while let current = node {
        if let name = current.name, name.hasPrefix("object:"),
          let id = UUID(uuidString: String(name.dropFirst(7)))
        {
          return id
        }
        node = current.parent
      }
    }
    return nil
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
    let q=view.projectPoint(SCNVector3(target.x/100,target.y/100,target.z/100)),point=NSPoint(x:q.x,y:q.y)
    guard point.x.isFinite,point.y.isFinite,view.bounds.contains(point) else{return nil}
    let hits=view.hitTest(point,options:[.categoryBitMask:6,.ignoreHiddenNodes:true,.searchMode:SCNHitTestSearchMode.all.rawValue,.backFaceCulling:false])
    for hit in hits {
      var node:SCNNode?=hit.node,owner:UUID?
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
    project: Project, size: CGSize, assets: URL, studio: Bool = false, preset: String = "Daylight",
    fitContents: Bool = false
  ) -> NSImage {
    let controller = TableSceneController()
    controller.sync(
      project, selection: [], isolated: [], showGrid: false, studio: studio, preset: preset,
      assets: assets)
    if fitContents {
      controller.frame(
        ids: Set(controller.nodes.keys), aspect: size.width / max(1, size.height), animated: false)
    }
    let renderer = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil)
    renderer.scene = controller.scene
    let outputCamera = controller.outputCamera(size: size)
    controller.scene.rootNode.addChildNode(outputCamera)
    defer { outputCamera.removeFromParentNode() }
    renderer.pointOfView = outputCamera
    return renderer.snapshot(atTime: 0, with: size, antialiasingMode: .multisampling4X)
  }
  func snapshot(size: CGSize) -> NSImage {
    let renderer = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil)
    renderer.scene = scene
    let outputCamera = outputCamera(size: size)
    scene.rootNode.addChildNode(outputCamera)
    defer { outputCamera.removeFromParentNode() }
    renderer.pointOfView = outputCamera
    selectionNodes.forEach { $0.isHidden = true }
    defer { selectionNodes.forEach { $0.isHidden = false } }
    return renderer.snapshot(atTime: 0, with: size, antialiasingMode: .multisampling4X)
  }
  private func outputCamera(size: CGSize) -> SCNNode {
    let node = cameraNode.clone()
    node.camera = cameraNode.camera?.copy() as? SCNCamera
    let factor = CameraFraming.viewportExpansion(
      from: camera.viewportAspect,
      to: size.width / max(1, size.height))
    if let lens = node.camera {
      if lens.usesOrthographicProjection {
        lens.orthographicScale *= factor
      } else {
        lens.fieldOfView = atan(tan(lens.fieldOfView * .pi / 360) * factor) * 360 / .pi
      }
    }
    return node
  }
}

@MainActor struct TableCanvas: NSViewRepresentable {
  @EnvironmentObject var store: StudioStore
  func makeNSView(context: Context) -> TableSCNView {
    let controller = store.scene ?? TableSceneController(store: store)
    store.scene = controller
    let view = TableSCNView(
      frame: .zero,
      options: [SCNView.Option.preferredRenderingAPI.rawValue: SCNRenderingAPI.metal.rawValue])
    view.controller = controller
    controller.view = view
    view.scene = controller.scene
    view.pointOfView = controller.cameraNode
    view.backgroundColor = NSColor(hex: "#EEEDE8")
    view.antialiasingMode = .multisampling4X
    view.preferredFramesPerSecond = 60
    view.rendersContinuously = false
    view.autoenablesDefaultLighting = false
    view.allowsCameraControl = false
    view.setAccessibilityLabel("The Table, 3D creative workspace")
    return view
  }
  func updateNSView(_ view: TableSCNView, context: Context) {
    guard let project = store.project else { return }
    _ = store.revision
    view.controller?.sync(
      project, selection: store.engine.selection, isolated: store.isolated,
      showGrid: store.showGrid, studio: store.mode == .studio, preset: store.studioPreset,
      assets: store.repository.url(for: project.id).appendingPathComponent("Assets"))
  }
}

@MainActor final class TableSCNView: SCNView {
  weak var controller: TableSceneController?
  var onEscape: (() -> Void)?
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
      if action != .move {
        store.select(controller.objectID(at: point), extending: event.modifierFlags.contains(.shift))
      }
      if event.clickCount == 2 { controller.focusSelection() }
    }
    pointerActive = false
    phase = "ended"
    dragOrigin = nil
    attachmentDrag = nil
    objectPositions = [:]
    controller?.store?.cameraChanged()
  }
  override func scrollWheel(with event: NSEvent) {
    let delta = -Double(event.scrollingDeltaY) * (event.hasPreciseScrollingDeltas ? 0.35 : 1)
    controller?.zoom(delta)
  }
  override func magnify(with event: NSEvent) {
    controller?.zoom(-Double(event.magnification) * 100)
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

@MainActor enum GeometryFactory {
  static func artworkDefinition(_ artwork:Artwork,object:ProductObject)->Artwork {
    object.textile?.embroidery != nil ? artwork.embroideryRenderDefinition:artwork.renderDefinition
  }
  static func geometryParameters(_ object: ProductObject) -> [String: Double] {
    object.recipeID == "clock"
      ? object.parameters.filter { !["hour", "minute", "hands"].contains($0.key) }
      : object.parameters
  }
  private(set) static var fontRevision = 0
  static func invalidateFontResources() {
    cache.removeAllObjects()
    artworkImages.removeAllObjects()
    EmbroiderySurface.invalidate()
    fontRevision += 1
  }
  private static let cache: NSCache<NSString, SCNNode> = {
    let cache = NSCache<NSString, SCNNode>()
    cache.countLimit = 80
    cache.totalCostLimit = 64_000_000
    return cache
  }()
  private static var surfaceImages: [String: NSImage] = [:]
  static func material(_ object: ProductObject, project: Project) -> SCNMaterial {
    let preset = project.material(object.materialID)
    let result = SCNMaterial()
    result.lightingModel = .physicallyBased
    if ["Wood", "Paper", "Fabric"].contains(preset.category) {
      result.diffuse.contents = surfaceImage(preset.category, color: object.color ?? preset.color)
    } else {
      result.diffuse.contents = NSColor(hex: object.color ?? preset.color)
    }
    result.roughness.contents = preset.roughness
    result.metalness.contents = preset.metallic
    return result
  }
  private static func surfaceImage(_ category: String, color: String) -> NSImage {
    let key = category + color
    if let image = surfaceImages[key] { return image }
    let size = 128
    let base = NSColor(hex: color).usingColorSpace(.sRGB)!
    let rep = NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
      samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
      bytesPerRow: 0, bitsPerPixel: 0)!
    let pixels = rep.bitmapData!
    for y in 0..<size {
      for x in 0..<size {
        let noise = Double((x &* 167 + y &* 311 + x &* y &* 13) % 97) / 97 - 0.5
        let grain =
          category == "Wood"
          ? sin(Double(x) * 0.5 + sin(Double(y) * 0.04) * 2) * 0.035 + noise * 0.015
          : category == "Fabric" ? (Double(x % 3 + y % 3) - 2) * 0.012 : noise * 0.022
        let index = y * rep.bytesPerRow + x * 4
        pixels[index] = UInt8(min(255, max(0, (base.redComponent + grain) * 255)))
        pixels[index + 1] = UInt8(min(255, max(0, (base.greenComponent + grain) * 255)))
        pixels[index + 2] = UInt8(min(255, max(0, (base.blueComponent + grain) * 255)))
        pixels[index + 3] = 255
      }
    }
    let image = NSImage(size: .init(width: size, height: size))
    image.addRepresentation(rep)
    if surfaceImages.count >= 80 { surfaceImages.removeAll(keepingCapacity: true) }
    surfaceImages[key] = image
    return image
  }
  static func solid(
    _ geometry: SCNGeometry, _ material: SCNMaterial, at position: SCNVector3 = .init()
  ) -> SCNNode {
    geometry.materials = [material]
    let node = SCNNode(geometry: geometry)
    node.position = position
    node.categoryBitMask = 2
    return node
  }
  static func box(
    _ width: Double, _ height: Double, _ depth: Double, _ material: SCNMaterial, x: Double = 0,
    y: Double = 0, z: Double = 0, corner: Double = 0
  ) -> SCNNode {
    solid(
      SCNBox(
        width: mm(width), height: mm(max(height, 0.1)), length: mm(depth),
        chamferRadius: mm(min(corner, width / 2, height / 2, depth / 2))), material,
      at: v(x / 100, y / 100, z / 100))
  }
  static func object(
    _ sourceObject: ProductObject, project: Project, assets: URL, textureLimit: Int = 2048
  ) -> SCNNode {
    if sourceObject.isFlexibleSurface,let cloth=try? ClothSceneSurface(object:sourceObject,project:project,assets:assets,textureLimit:textureLimit) {return cloth.root}
    var object = sourceObject
    object.artwork = project.surfaceArtwork(sourceObject)
    object.artworkSourceID = nil
    object.artworkFit = nil
    var canonical = object
    let neutral = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
    canonical.id = neutral
    canonical.designID = neutral
    canonical.parentIterationID = nil
    canonical.groupID = nil
    canonical.name = ""
    canonical.position = .init()
    canonical.rotation = 0
    canonical.relationship = ""
    canonical.locked = false
    canonical.textile = canonical.textile?.renderDefinition
    canonical.artwork = canonical.artwork.map {artworkDefinition($0,object:object)}
    let artworkData = canonical.artwork.flatMap { try? $0.renderCacheData() }
    canonical.artwork = nil
    canonical.parameters = geometryParameters(object)
    var signature = (try? JSONEncoder.form.encode(canonical)) ?? Data()
    if let artworkData { signature.append(artworkData) }
    signature.append((try? JSONEncoder.form.encode(project.material(object.materialID).withoutFabricPattern)) ?? Data())
    if let pattern = try? project.resolvedFabricPattern(materialID: object.materialID) {
      signature.append((try? JSONEncoder.form.encode(pattern.renderDefinition)) ?? Data())
      signature.append(Data("fabric-fonts:\(fontRevision)".utf8))
    }
    if let recipe = project.recipe(object.recipeID) {
      signature.append((try? JSONEncoder.form.encode(recipe)) ?? Data())
    }
    if let materials=project.merchandiseMaterialDependencies(object){signature.append((try? JSONEncoder.form.encode(materials)) ?? Data())}
    if let surface=project.conformedMerchandiseSignature(object){signature.append((try? JSONEncoder.form.encode(surface)) ?? Data())}
    signature.append(Data(assets.path.utf8))
    signature.append(Data("texture-limit:\(textureLimit)".utf8))
    let cacheKey =
      SHA256.hash(data: signature).map { String(format: "%02x", $0) }.joined() as NSString
    if let cached = cache.object(forKey: cacheKey) {
      let node = cached.clone()
      if object.recipeID == "clock" { updateClockHands(node, object: object) }
      return node
    }
    let root = SCNNode()
    let mat = material(object, project: project)
    switch object.recipeID {
    case "crewTee":root.addChildNode(MerchandiseGeometry.tee(object,project:project,assets:assets,limit:textureLimit))
    case "curvedCap":root.addChildNode(MerchandiseGeometry.cap(object,project:project,assets:assets,limit:textureLimit))
    case "canvasTote":root.addChildNode(MerchandiseGeometry.tote(object,project:project,assets:assets,limit:textureLimit))
    case "textilePrint":root.addChildNode(MerchandiseGeometry.directArtwork(object,project:project,assets:assets,limit:textureLimit))
    case "bomberJacket":
      root.addChildNode(TextileGeometry.bomber(object, project: project, assets: assets, textureLimit: textureLimit))
    case "textilePatch", "textileLabel":
      root.addChildNode(TextileGeometry.decoration(object, project: project, assets: assets, textureLimit: textureLimit))
    case "clock":
      let d = object["diameter"]
      let r = d / 2
      let t = object["thickness"]
      let b = object["bore"] / 2
      let profile = NSBezierPath(ovalIn: .init(x: mm(-r), y: mm(-r), width: mm(d), height: mm(d)))
      // Scene units are 100 mm. AppKit's default flatness would reduce a dial to a few edges.
      profile.flatness = mm(0.02)
      profile.windingRule = .evenOdd
      profile.appendOval(in: .init(x: mm(-b), y: mm(-b), width: mm(2 * b), height: mm(2 * b)))
      // A bounded radial mesh keeps the bore and bevels accurate without the
      // excessive cap/chamfer tessellation of an extruded Bezier shape.
      let bevel = min(0.2, t / 4)
      let body = lathe(
        profile: [
          (b + bevel, 0), (r - bevel, 0), (r, bevel), (r, t - bevel),
          (r - bevel, t), (b + bevel, t), (b, t - bevel), (b, bevel),
        ], segments: 256)
      let dial = solid(body, mat)
      dial.name = "clock.dial"
      root.addChildNode(dial)
      if let art = object.artwork {
        let face = SCNShape(path: profile, extrusionDepth: 0.0002)
        let ink = SCNMaterial()
        ink.lightingModel = .physicallyBased
        ink.diffuse.contents = artworkImage(
          art, width: d, depth: d, assets: assets, textureLimit: textureLimit,
          definition: artworkData)
        ink.roughness.contents = 0.9
        let node = solid(face, ink, at: v(0, (t + 0.03) / 100, 0))
        node.eulerAngles.x = -.pi / 2
        node.name = "clock.face"
        root.addChildNode(node)
      }
      func hand(name: String, length: Double, width: Double, y: Double, color: String) {
        let path = NSBezierPath(
          roundedRect: .init(
            x: mm(-width / 2), y: mm(-d * 0.045), width: mm(width), height: mm(length + d * 0.045)),
          xRadius: mm(width / 2), yRadius: mm(width / 2))
        path.flatness = mm(0.02)
        let mesh = SCNShape(path: path, extrusionDepth: mm(0.8))
        let material = SCNMaterial()
        material.lightingModel = .physicallyBased
        material.diffuse.contents = NSColor(hex: color)
        material.roughness.contents = 0.6
        let shape = solid(mesh, material)
        shape.eulerAngles.x = -.pi / 2
        let pivot = SCNNode()
        pivot.name = name
        pivot.position = v(0, y / 100, 0)
        pivot.addChildNode(shape)
        root.addChildNode(pivot)
      }
      hand(name: "clock.hour", length: d * 0.235, width: d * 0.022, y: t + 1.2, color: "#28312D")
      hand(name: "clock.minute", length: d * 0.335, width: d * 0.013, y: t + 2.4, color: "#C96543")
      let brass = SCNMaterial()
      brass.lightingModel = .physicallyBased
      brass.diffuse.contents = NSColor(hex: "#B99363")
      brass.metalness.contents = 0.65
      brass.roughness.contents = 0.4
      let pin = solid(
        SCNCylinder(radius: mm(d * 0.018), height: mm(1.6)), brass, at: v(0, (t + 4) / 100, 0))
      pin.name = "clock.pin"
      root.addChildNode(pin)
      updateClockHands(root, object: object)
    case "lamp":
      let h = object["height"]
      let shadeH = min(object["shadeHeight"], h - 35)
      let base = object["baseDiameter"]
      let stemH = max(20, h - shadeH / 2 - 12)
      let baseGeometry = SCNCylinder(radius: mm(base / 2), height: mm(12))
      baseGeometry.radialSegmentCount = 80
      root.addChildNode(solid(baseGeometry, mat, at: v(0, 0.06, 0)))
      let stem = SCNCylinder(radius: mm(object["stemDiameter"] / 2), height: mm(stemH))
      stem.radialSegmentCount = 32
      root.addChildNode(solid(stem, mat, at: v(0, (stemH / 2 + 12) / 100, 0)))
      let shade = lathe(
        profile: [
          (object["shadeDiameter"] / 2, h - shadeH), (object["topDiameter"] / 2, h),
          (max(object["topDiameter"] / 2 - object["wall"], 1), h),
          (max(object["shadeDiameter"] / 2 - object["wall"], 1), h - shadeH),
        ], segments: 96)
      mat.isDoubleSided = true
      root.addChildNode(solid(shade, mat))
      let bulbMat = SCNMaterial()
      bulbMat.diffuse.contents = NSColor(hex: "#FFF2C8")
      bulbMat.emission.contents = NSColor(hex: "#D5BD81")
      bulbMat.roughness.contents = 1
      let bulb = SCNSphere(radius: mm(24))
      root.addChildNode(solid(bulb, bulbMat, at: v(0, (h - shadeH / 2) / 100, 0)))
    case "paperStack":
      let width = object["width"]
      let depth = object["depth"]
      let count = Int(object["sheets"])
      let thickness = object["thickness"]
      let edge = SCNMaterial()
      edge.diffuse.contents = NSColor(hex: "#C8C6BC")
      edge.roughness.contents = 1
      root.addChildNode(
        box(
          width, Double(count) * thickness, depth, edge, y: Double(count) * thickness / 2,
          corner: 0.15))
      let visible = min(count, 35)
      for i in 0..<visible {
        let y = Double(i) * Double(count) / Double(max(visible, 1)) * thickness
        root.addChildNode(
          box(width + 0.15, thickness * 0.75, depth + 0.15, mat, y: y + thickness / 2, corner: 0.1))
      }
    case "booklet":
      let width = object["width"]
      let depth = object["depth"]
      let h = object["pages"] / 2 * object["thickness"] + 0.8
      let pages = SCNMaterial()
      pages.diffuse.contents = NSColor(hex: "#E6E2D8")
      pages.roughness.contents = 1
      root.addChildNode(box(width - 1, h - 0.6, depth - 1, pages, x: 0.4, y: h / 2, corner: 0.1))
      root.addChildNode(box(width, 0.3, depth, mat, y: 0.15, corner: 0.1))
      root.addChildNode(box(width, 0.3, depth, mat, y: h - 0.15, corner: 0.1))
      root.addChildNode(box(0.8, h, depth, mat, x: -width / 2 + 0.4, y: h / 2))
      if let artwork = object.artwork {
        root.addChildNode(
          artworkPlane(
            artwork, width: width, depth: depth, y: h + 0.03, assets: assets,
            textureLimit: textureLimit, definition: artworkData))
      }
    case "sleeve":
      let width = object["width"]
      let depth = object["depth"]
      let spine = object["height"]
      let stock = object["stock"]
      let tab = object["tab"]
      let angle = object["fold"] / 100 * .pi / 2
      root.addChildNode(box(width, stock, depth, mat, y: stock / 2))
      var parent = root
      var previousWidth = width / 2
      for (i, panelWidth) in [spine, width, spine, tab].enumerated() {
        let hinge = SCNNode()
        hinge.position = v(previousWidth / 100, stock / 200, 0)
        hinge.eulerAngles.z = CGFloat(angle)
        parent.addChildNode(hinge)
        hinge.addChildNode(box(panelWidth, stock, depth, mat, x: panelWidth / 2))
        if i == 1, let artwork = object.artwork {
          let art = artworkPlane(
            artwork, width: panelWidth, depth: depth, y: -stock / 2 - 0.04, assets: assets,
            underside: true, textureLimit: textureLimit, definition: artworkData)
          art.position.x = CGFloat(panelWidth / 200)
          hinge.addChildNode(art)
        }
        parent = hinge
        previousWidth = panelWidth
      }
    case "vase":
      let h = object["height"]
      let radius = object["diameter"] / 2
      let neck = object["neck"] / 2
      let wall = min(object["wall"], neck * 0.8)
      let profile: [(Double, Double)] = [
        (radius * 0.55, 0), (radius * 0.8, h * 0.04), (radius, h * 0.2), (radius * 0.99, h * 0.46),
        (radius * 0.77, h * 0.7), (neck, h * 0.9), (neck, h), (neck - wall, h),
        (neck - wall, h * 0.9), (radius * 0.77 - wall, h * 0.7), (radius * 0.99 - wall, h * 0.46),
        (radius - wall, h * 0.2), (radius * 0.55 - wall, wall), (0, wall), (0, 0),
      ]
      mat.isDoubleSided = true
      root.addChildNode(solid(lathe(profile: profile, segments: 96), mat))
    case "profile":
      let path = NSBezierPath()
      let count = max(3, min(12, Int(object["sides"])))
      for i in 0..<count {
        let a = Double(i) / Double(count) * 2 * .pi
        let point = NSPoint(
          x: mm(object["width"] / 2 * cos(a)), y: mm(object["depth"] / 2 * sin(a)))
        if i == 0 { path.move(to: point) } else { path.line(to: point) }
      }
      path.close()
      let shape = SCNShape(path: path, extrusionDepth: mm(object["height"]))
      shape.chamferRadius = 0.005
      let node = solid(shape, mat)
      node.eulerAngles.x = -.pi / 2
      root.addChildNode(node)
    case "reference", "artboard":
      root.addChildNode(box(object["width"], 0.5, object["depth"], mat, y: 0.25, corner: 0.2))
      if let asset = object.asset, !asset.contains("/"),
        let image = NSImage(contentsOf: assets.appendingPathComponent(asset))
      {
        let surface = SCNMaterial()
        surface.lightingModel = .constant
        surface.diffuse.contents = image
        let plane = SCNPlane(width: mm(object["width"]), height: mm(object["depth"]))
        let node = solid(plane, surface, at: v(0, 0.006, 0))
        node.eulerAngles.x = -.pi / 2
        root.addChildNode(node)
      }
    default:
      if let recipe = project.recipe(object.recipeID) {
        for part in recipe.parts {
          guard let p = try? part.evaluate(object.parameters) else { continue }
          let geo: SCNGeometry
          switch part.kind {
          case "cylinder":
            let c = SCNCylinder(radius: mm(p["radius"] ?? 50), height: mm(p["height"] ?? 100))
            c.radialSegmentCount = 64
            geo = c
          case "cone":
            let c = SCNCone(
              topRadius: mm(p["topRadius"] ?? 0), bottomRadius: mm(p["bottomRadius"] ?? 50),
              height: mm(p["height"] ?? 100))
            c.radialSegmentCount = 64
            geo = c
          case "sphere": geo = SCNSphere(radius: mm(p["radius"] ?? 50))
          case "torus":
            geo = SCNTorus(
              ringRadius: mm(p["ringRadius"] ?? 50), pipeRadius: mm(p["pipeRadius"] ?? 5))
          default:
            let w = p["width"] ?? 100
            let h = p["height"] ?? 100
            let d = p["depth"] ?? 100
            geo = SCNBox(
              width: mm(w), height: mm(h), length: mm(d),
              chamferRadius: mm(min(p["corner"] ?? 1, w / 2, h / 2, d / 2)))
          }
          var partMat = mat
          if let color = part.color {
            partMat = mat.copy() as! SCNMaterial
            partMat.diffuse.contents = NSColor(hex: color)
          }
          let node = solid(
            geo, partMat, at: v((p["x"] ?? 0) / 100, (p["y"] ?? 0) / 100, (p["z"] ?? 0) / 100))
          node.eulerAngles = v(
            (p["rotationX"] ?? 0) * .pi / 180, (p["rotationY"] ?? 0) * .pi / 180,
            (p["rotationZ"] ?? 0) * .pi / 180)
          root.addChildNode(node)
        }
      }
    }
    if let artwork = object.artwork, !["sleeve", "booklet", "clock", "bomberJacket", "textilePatch", "textileLabel", "crewTee", "curvedCap", "canvasTote", "textilePrint"].contains(object.recipeID),
      object["width"] > 0, object["depth"] > 0
    {
      let top = Double(root.boundingBox.max.y) * 100 + 0.04
      root.addChildNode(
        artworkPlane(
          artwork, width: object["width"], depth: object["depth"], y: top, assets: assets,
          textureLimit: textureLimit, definition: artworkData))
    }
    var imageBytes = 0
    var counted = Set<ObjectIdentifier>()
    func countImages(_ node: SCNNode) {
      for material in node.geometry?.materials ?? [] {
        for property in [material.diffuse,material.normal] {
        if let image = property.contents as? NSImage,
          counted.insert(ObjectIdentifier(image)).inserted
        {
          let pixels =
            image.representations.map { $0.pixelsWide * $0.pixelsHigh }.max()
            ?? Int(image.size.width * image.size.height)
          // Account for the bitmap and a corresponding GPU texture.
          imageBytes += pixels * 8
        }
        }
      }
    }
    countImages(root)
    root.enumerateChildNodes { node, _ in countImages(node) }
    cache.setObject(root.clone(), forKey: cacheKey, cost: max(30_000, imageBytes))
    return root
  }
  static func artworkPlane(
    _ artwork: Artwork, width: Double, depth: Double, y: Double, assets: URL,
    underside: Bool = false, textureLimit: Int = 2048, definition: Data? = nil
  ) -> SCNNode {
    let material = SCNMaterial()
    material.lightingModel = .physicallyBased
    material.diffuse.contents = artworkImage(
      artwork, width: width, depth: depth, assets: assets, textureLimit: textureLimit,
      definition: definition)
    material.roughness.contents = 0.88
    material.isDoubleSided = true
    if underside {
      var transform = SCNMatrix4Identity
      transform.m11 = -1
      transform.m22 = -1
      transform.m41 = 1
      transform.m42 = 1
      material.diffuse.contentsTransform = transform
    }
    let plane = SCNPlane(width: mm(width), height: mm(depth))
    let node = solid(plane, material, at: v(0, y / 100, 0))
    node.eulerAngles.x = underside ? .pi / 2 : -.pi / 2
    return node
  }
  static func updateClockHands(_ root: SCNNode, object: ProductObject) {
    root.childNode(withName: "clock.hour", recursively: true)?.eulerAngles.y = CGFloat(
      -(object["hour"] + object["minute"] / 60) * .pi / 6)
    root.childNode(withName: "clock.minute", recursively: true)?.eulerAngles.y = CGFloat(
      -object["minute"] * .pi / 30)
    for name in ["clock.hour", "clock.minute", "clock.pin"] {
      root.childNode(withName: name, recursively: true)?.isHidden = object["hands"] < 0.5
    }
  }
  private static let artworkImages: NSCache<NSString, NSImage> = {
    let cache = NSCache<NSString, NSImage>()
    cache.totalCostLimit = 16_000_000
    cache.countLimit = 24
    return cache
  }()
  private static func artworkImage(
    _ art: Artwork, width: Double, depth: Double, assets: URL, textureLimit: Int,
    definition: Data? = nil
  ) -> NSImage {
    var signature = definition ?? (try? art.renderCacheData()) ?? Data()
    signature.append(Data("\(width),\(depth),\(textureLimit),\(fontRevision),\(assets.path)".utf8))
    let key = SHA256.hash(data: signature).map { String(format: "%02x", $0) }.joined() as NSString
    if let image = artworkImages.object(forKey: key) { return image }
    let image = ArtworkDrawing.image(
      art, width: width, height: depth, assets: assets,
      pixelsPerMM: min(max(5, 1024 / max(width, depth)), Double(textureLimit) / max(width, depth)))
    let pixels = image.representations.map { $0.pixelsWide * $0.pixelsHigh }.max() ?? 1
    artworkImages.setObject(image, forKey: key, cost: pixels * 8)
    return image
  }
  static func lathe(profile: [(Double, Double)], segments: Int) -> SCNGeometry {
    var profile = profile
    if let first = profile.first, let last = profile.last, first.0 != last.0 || first.1 != last.1 {
      profile.append(first)
    }
    var positions: [SCNVector3] = []
    var normals: [SCNVector3] = []
    var coordinates: [CGPoint] = []
    var indices: [Int32] = []
    let perimeter = zip(profile, profile.dropFirst()).reduce(0.0) {
      $0 + hypot($1.1.0 - $1.0.0, $1.1.1 - $1.0.1)
    }
    var travel = 0.0
    for (j, point) in profile.enumerated() {
      let before = profile[max(0, j - 1)]
      let after = profile[min(profile.count - 1, j + 1)]
      if j > 0 { travel += hypot(point.0 - before.0, point.1 - before.1) }
      let dr = after.0 - before.0
      let dy = after.1 - before.1
      let length = max(hypot(dr, dy), 0.0001)
      for i in 0...segments {
        let angle = Double(i) / Double(segments) * 2 * .pi
        positions.append(v(point.0 * cos(angle) / 100, point.1 / 100, point.0 * sin(angle) / 100))
        normals.append(v(dy / length * cos(angle), -dr / length, dy / length * sin(angle)))
        coordinates.append(
          .init(x: Double(i) / Double(segments), y: travel / max(perimeter, 0.001)))
        if j < profile.count - 1 && i < segments {
          let a = Int32(j * (segments + 1) + i)
          let b = a + Int32(segments + 1)
          indices += [a, b, a + 1, a + 1, b, b + 1]
        }
      }
    }
    return SCNGeometry(
      sources: [
        SCNGeometrySource(vertices: positions), SCNGeometrySource(normals: normals),
        SCNGeometrySource(textureCoordinates: coordinates),
      ],
      elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)])
  }
}
