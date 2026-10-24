import AppKit
import CryptoKit
import FormCore
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
  private var fingerprints: [UUID: RenderSignature] = [:]
  private var selectionNodes: [SCNNode] = []
  private var lastSelection = Set<UUID>()
  private var lastStudio = false
  private var lastPreset = ""
  private(set) var geometryBuilds = 0
  private(set) var lastSyncMilliseconds = 0.0
  var diagnostics: [String: Any] {
    [
      "object_nodes": nodes.count, "geometry_builds": geometryBuilds,
      "last_sync_ms": lastSyncMilliseconds,
      "renders_continuously": view?.rendersContinuously ?? false, "preferred_fps": 60,
    ]
  }
  var camera = CameraState()

  init(store: StudioStore? = nil) {
    self.store = store
    scene.background.contents = NSColor(hex: "#EEEDE8")
    scene.rootNode.addChildNode(objectRoot)
    cameraNode.camera = SCNCamera()
    cameraNode.camera?.fieldOfView = 39
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
  func sync(
    _ project: Project, selection: Set<UUID>, isolated: Set<UUID>, showGrid: Bool, studio: Bool,
    preset: String, assets: URL
  ) {
    let started = CFAbsoluteTimeGetCurrent()
    defer { lastSyncMilliseconds = (CFAbsoluteTimeGetCurrent() - started) * 1000 }
    SCNTransaction.begin()
    SCNTransaction.disableActions = true
    if projectID != project.id {
      objectRoot.childNodes.forEach { $0.removeFromParentNode() }
      nodes = [:]
      fingerprints = [:]
      selectionNodes = []
      lastSelection = []
      projectID = project.id
      camera = project.camera
      updateCamera()
    }
    let live = Set(project.objects.map(\.id))
    for id in Array(nodes.keys) where !live.contains(id) {
      nodes.removeValue(forKey: id)?.removeFromParentNode()
      fingerprints.removeValue(forKey: id)
    }
    var geometryChanged = false
    for object in project.objects {
      let fingerprint = RenderSignature(
        recipe: project.recipe(object.recipeID), parameters: object.parameters,
        material: project.material(object.materialID), color: object.color, artwork: object.artwork,
        asset: object.asset)
      if nodes[object.id] == nil || fingerprints[object.id] != fingerprint {
        nodes[object.id]?.removeFromParentNode()
        let node = GeometryFactory.object(object, project: project, assets: assets)
        geometryBuilds += 1
        node.name = "object:\(object.id.uuidString)"
        nodes[object.id] = node
        objectRoot.addChildNode(node)
        fingerprints[object.id] = fingerprint
        geometryChanged = true
      }
      let node = nodes[object.id]!
      node.position = v(object.position.x / 100, object.position.y / 100, object.position.z / 100)
      node.eulerAngles.y = CGFloat(object.rotation * .pi / 180)
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
  private func rebuildSelection(_ selection: Set<UUID>, studio: Bool) {
    selectionNodes.forEach { $0.removeFromParentNode() }
    selectionNodes = []
    guard !studio else { return }
    for id in selection {
      guard let node = nodes[id] else { continue }
      let bounds = node.boundingBox
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
    SCNTransaction.begin()
    SCNTransaction.animationDuration = animated ? 0.28 : 0
    SCNTransaction.animationTimingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
    cameraNode.camera?.usesOrthographicProjection = camera.projection == "orthographic"
    cameraNode.camera?.orthographicScale = camera.distance * 0.36
    let target = v(camera.target.x, camera.target.y, camera.target.z)
    let elevation = min(max(camera.elevation, 0.04), .pi / 2 - 0.001)
    cameraNode.position = v(
      camera.target.x + camera.distance * cos(elevation) * sin(camera.azimuth),
      camera.target.y + camera.distance * sin(elevation),
      camera.target.z + camera.distance * cos(elevation) * cos(camera.azimuth))
    cameraNode.look(at: target)
    SCNTransaction.commit()
    view?.needsDisplay = true
    if store?.engine.project != nil { store?.engine.project?.camera = camera }
  }
  func resetCamera() {
    if let p = store?.project {
      camera = p.camera
      updateCamera()
    }
  }
  func orbit(dx: CGFloat, dy: CGFloat) {
    camera.projection = "perspective"
    camera.azimuth -= Double(dx) * 0.007
    camera.elevation = min(max(camera.elevation + Double(dy) * 0.006, 0.05), 1.55)
    updateCamera()
  }
  func zoom(_ delta: Double) {
    camera.distance = min(max(camera.distance * exp(delta * 0.008), 1), 300)
    updateCamera()
  }
  func pan(dx: CGFloat, dy: CGFloat) {
    let scale = camera.distance * 0.0013
    let x = Double(dx) * scale
    let y = Double(dy) * scale
    camera.target.x -= x * cos(camera.azimuth) + y * sin(camera.azimuth)
    camera.target.z += x * sin(camera.azimuth) - y * cos(camera.azimuth)
    updateCamera()
  }
  func preset(_ name: String) {
    switch name {
    case "overhead":
      camera.elevation = 1.569
      camera.azimuth = 0
      camera.projection = "orthographic"
    case "front":
      camera.elevation = 0.04
      camera.azimuth = 0
      camera.projection = "orthographic"
    default:
      camera.elevation = 0.70
      camera.azimuth = 0.55
      camera.projection = "perspective"
    }
    updateCamera(animated: true)
    store?.changed(save: false)
  }
  func fitAll() {
    let isolated = store?.isolated ?? []
    frame(ids: Set(nodes.keys.filter { isolated.isEmpty || isolated.contains($0) }))
  }
  func focusSelection() {
    if let selection = store?.engine.selection, !selection.isEmpty { frame(ids: selection) }
  }
  private func frame(ids: Set<UUID>) {
    var low = v(Double.infinity, Double.infinity, Double.infinity)
    var high = v(-Double.infinity, -Double.infinity, -Double.infinity)
    for id in ids {
      guard let node = nodes[id] else { continue }
      let b = node.boundingBox
      for x in [b.min.x, b.max.x] {
        for y in [b.min.y, b.max.y] {
          for z in [b.min.z, b.max.z] {
            let p = node.convertPosition(.init(x, y, z), to: nil)
            low.x = min(low.x, p.x)
            low.y = min(low.y, p.y)
            low.z = min(low.z, p.z)
            high.x = max(high.x, p.x)
            high.y = max(high.y, p.y)
            high.z = max(high.z, p.z)
          }
        }
      }
    }
    guard low.x.isFinite else {
      camera = .init()
      updateCamera(animated: true)
      return
    }
    camera.target = .init(
      Double((low.x + high.x) / 2), Double((low.y + high.y) / 2), Double((low.z + high.z) / 2))
    let extent = Double(max(high.x - low.x, high.y - low.y, high.z - low.z))
    camera.distance = max(extent * 2.55, 3.6)
    updateCamera(animated: true)
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
  func pointOnTable(_ point: NSPoint, height: Double) -> Vector3? {
    guard let view else { return nil }
    let near = view.unprojectPoint(.init(point.x, point.y, 0))
    let far = view.unprojectPoint(.init(point.x, point.y, 1))
    let dy = Double(far.y - near.y)
    guard abs(dy) > 0.000001 else { return nil }
    let t = (height / 100 - Double(near.y)) / dy
    return .init(
      (Double(near.x) + Double(far.x - near.x) * t) * 100, height,
      (Double(near.z) + Double(far.z - near.z) * t) * 100)
  }
  static func preview(
    project: Project, size: CGSize, assets: URL, studio: Bool = false, preset: String = "Daylight"
  ) -> NSImage {
    let controller = TableSceneController()
    controller.sync(
      project, selection: [], isolated: [], showGrid: false, studio: studio, preset: preset,
      assets: assets)
    let renderer = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil)
    renderer.scene = controller.scene
    renderer.pointOfView = controller.cameraNode
    return renderer.snapshot(atTime: 0, with: size, antialiasingMode: .multisampling4X)
  }
  func snapshot(size: CGSize) -> NSImage {
    let renderer = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil)
    renderer.scene = scene
    renderer.pointOfView = cameraNode
    selectionNodes.forEach { $0.isHidden = true }
    defer { selectionNodes.forEach { $0.isHidden = false } }
    return renderer.snapshot(atTime: 0, with: size, antialiasingMode: .multisampling4X)
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
  private var previous = NSPoint.zero
  private var down = NSPoint.zero
  private var dragOrigin: Vector3?
  private var objectPositions: [UUID: Vector3] = [:]
  private var moving = false
  private var spaceHeld = false
  override var acceptsFirstResponder: Bool { true }
  override func mouseDown(with event: NSEvent) {
    window?.makeFirstResponder(self)
    previous = convert(event.locationInWindow, from: nil)
    down = previous
    guard let controller, let store = controller.store else { return }
    if spaceHeld || event.modifierFlags.contains(.option) {
      moving = false
      return
    }
    if let id = controller.objectID(at: previous) {
      if !store.engine.selection.contains(id) || event.modifierFlags.contains(.shift) {
        store.select(id, extending: event.modifierFlags.contains(.shift))
      }
      if event.clickCount == 2 { controller.focusSelection() }
      moving = true
      objectPositions = Dictionary(
        uniqueKeysWithValues: store.selected.filter { !$0.locked }.map { ($0.id, $0.position) })
      dragOrigin = controller.pointOnTable(previous, height: store.primary?.position.y ?? 0)
    } else {
      store.select(nil, extending: event.modifierFlags.contains(.shift))
      moving = false
    }
  }
  override func mouseDragged(with event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    let dx = point.x - previous.x
    let dy = point.y - previous.y
    defer { previous = point }
    guard let controller else { return }
    if spaceHeld || event.modifierFlags.contains(.option) {
      controller.pan(dx: dx, dy: dy)
      return
    }
    if moving, hypot(point.x - down.x, point.y - down.y) > 3, let origin = dragOrigin,
      let now = controller.pointOnTable(point, height: origin.y), let store = controller.store
    {
      let snap = event.modifierFlags.contains(.shift) ? 10.0 : 1.0
      store.edit("Moved objects", coalescing: "move-selection") { p in
        for i in p.objects.indices {
          if let start = self.objectPositions[p.objects[i].id] {
            p.objects[i].position.x = ((start.x + now.x - origin.x) / snap).rounded() * snap
            p.objects[i].position.z = ((start.z + now.z - origin.z) / snap).rounded() * snap
          }
        }
      }
    } else if !moving {
      controller.orbit(dx: dx, dy: dy)
    }
  }
  override func mouseUp(with event: NSEvent) {
    moving = false
    dragOrigin = nil
    controller?.store?.changed()
  }
  override func rightMouseDown(with event: NSEvent) {
    previous = convert(event.locationInWindow, from: nil)
  }
  override func rightMouseDragged(with event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    controller?.orbit(dx: point.x - previous.x, dy: point.y - previous.y)
    previous = point
  }
  override func scrollWheel(with event: NSEvent) {
    if event.modifierFlags.contains(.option) {
      controller?.pan(dx: event.scrollingDeltaX, dy: -event.scrollingDeltaY)
    } else {
      controller?.zoom(Double(event.scrollingDeltaY))
    }
    controller?.store?.changed(save: false)
  }
  override func magnify(with event: NSEvent) {
    controller?.zoom(-Double(event.magnification) * 100)
  }
  override func rotate(with event: NSEvent) {
    controller?.orbit(dx: CGFloat(event.rotation) * 2, dy: 0)
  }
  override func keyDown(with event: NSEvent) {
    if event.keyCode == 49 {
      if !spaceHeld {
        spaceHeld = true
        NSCursor.openHand.push()
      }
    } else if event.keyCode == 51 || event.keyCode == 117 {
      controller?.store?.deleteSelection()
    } else if event.keyCode == 53 {
      if let store = controller?.store, !store.isolated.isEmpty {
        store.isolated = []
        controller?.fitAll()
      } else {
        controller?.store?.select(nil)
      }
    } else if !event.modifierFlags.contains(.command), !event.modifierFlags.contains(.control) {
      switch event.charactersIgnoringModifiers?.lowercased() {
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
  override func keyUp(with event: NSEvent) {
    if event.keyCode == 49 && spaceHeld {
      spaceHeld = false
      NSCursor.pop()
    } else {
      super.keyUp(with: event)
    }
  }
}

@MainActor enum GeometryFactory {
  private static let cache: NSCache<NSString, SCNNode> = {
    let cache = NSCache<NSString, SCNNode>()
    cache.countLimit = 80
    cache.totalCostLimit = 24_000_000
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
  static func object(_ object: ProductObject, project: Project, assets: URL) -> SCNNode {
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
    var signature = (try? JSONEncoder.form.encode(canonical)) ?? Data()
    signature.append((try? JSONEncoder.form.encode(project.material(object.materialID))) ?? Data())
    if let recipe = project.recipe(object.recipeID) {
      signature.append((try? JSONEncoder.form.encode(recipe)) ?? Data())
    }
    signature.append(Data(assets.path.utf8))
    let cacheKey =
      SHA256.hash(data: signature).map { String(format: "%02x", $0) }.joined() as NSString
    if let cached = cache.object(forKey: cacheKey) { return cached.clone() }
    let root = SCNNode()
    let mat = material(object, project: project)
    switch object.recipeID {
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
          artworkPlane(artwork, width: width, depth: depth, y: h + 0.03, assets: assets))
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
            underside: true)
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
    if let artwork = object.artwork, !["sleeve", "booklet"].contains(object.recipeID),
      object["width"] > 0, object["depth"] > 0
    {
      let top = Double(root.boundingBox.max.y) * 100 + 0.04
      root.addChildNode(
        artworkPlane(
          artwork, width: object["width"], depth: object["depth"], y: top, assets: assets))
    }
    cache.setObject(
      root.clone(), forKey: cacheKey, cost: object.artwork == nil ? 30_000 : 2_000_000)
    return root
  }
  static func artworkPlane(
    _ artwork: Artwork, width: Double, depth: Double, y: Double, assets: URL,
    underside: Bool = false
  ) -> SCNNode {
    let material = SCNMaterial()
    material.lightingModel = .physicallyBased
    material.diffuse.contents = ArtworkDrawing.image(
      artwork, width: width, height: depth, assets: assets)
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
  static func lathe(profile: [(Double, Double)], segments: Int) -> SCNGeometry {
    var profile = profile
    if let first = profile.first, let last = profile.last, first.0 != last.0 || first.1 != last.1 {
      profile.append(first)
    }
    var positions: [SCNVector3] = []
    var normals: [SCNVector3] = []
    var indices: [Int32] = []
    for (j, point) in profile.enumerated() {
      let before = profile[max(0, j - 1)]
      let after = profile[min(profile.count - 1, j + 1)]
      let dr = after.0 - before.0
      let dy = after.1 - before.1
      let length = max(hypot(dr, dy), 0.0001)
      for i in 0...segments {
        let angle = Double(i) / Double(segments) * 2 * .pi
        positions.append(v(point.0 * cos(angle) / 100, point.1 / 100, point.0 * sin(angle) / 100))
        normals.append(v(dy / length * cos(angle), -dr / length, dy / length * sin(angle)))
        if j < profile.count - 1 && i < segments {
          let a = Int32(j * (segments + 1) + i)
          let b = a + Int32(segments + 1)
          indices += [a, b, a + 1, a + 1, b, b + 1]
        }
      }
    }
    return SCNGeometry(
      sources: [SCNGeometrySource(vertices: positions), SCNGeometrySource(normals: normals)],
      elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)])
  }
}
